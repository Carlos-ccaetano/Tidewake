defmodule Tidewake.Workers.DeliverWebhookWorkerTest do
  use Tidewake.DataCase, async: false
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.FailingDeliveryAdapter
  alias Tidewake.Webhooks
  alias Tidewake.Workers.DeliverWebhookWorker

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(url, body, headers) do
    send(self(), {:delivered, url, body, headers})
    Process.get(:worker_adapter_response, {:ok, %{status: 204, headers: []}})
  end

  test "builds the first attempt on the default queue with one Oban attempt" do
    changeset = DeliverWebhookWorker.new_for_delivery(1)

    assert changeset.valid?
    job = apply_changes(changeset)
    assert job.args == %{"delivery_id" => 1, "attempt_number" => 1}
    assert job.queue == "default"
    assert job.max_attempts == 1
    assert job.worker == "Tidewake.Workers.DeliverWebhookWorker"
    assert job.unique.keys == [:delivery_id, :attempt_number]
  end

  test "builds an immediate job for an explicit logical attempt" do
    changeset = DeliverWebhookWorker.new_for_delivery(1, 2)

    assert changeset.valid?
    job = apply_changes(changeset)
    assert job.args == %{"delivery_id" => 1, "attempt_number" => 2}
    assert job.queue == "default"
    assert job.max_attempts == 1
  end

  test "builds a scheduled job for an explicit logical attempt" do
    scheduled_at = ~U[2099-01-15 12:00:00.123456Z]

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, job} =
               DeliverWebhookWorker.new_scheduled_for_delivery(1, 3, scheduled_at)
               |> Oban.insert()

      assert job.args == %{"delivery_id" => 1, "attempt_number" => 3}
      assert job.scheduled_at == scheduled_at
      assert job.state == "scheduled"
      assert job.max_attempts == 1
    end)
  end

  test "rejects invalid delivery IDs" do
    for id <- [0, -1, "1", 1.0, nil] do
      assert_raise FunctionClauseError, fn ->
        DeliverWebhookWorker.new_for_delivery(id)
      end
    end
  end

  test "rejects invalid logical attempts and scheduled times" do
    for attempt_number <- [0, -1, "1", 1.0, nil] do
      assert_raise FunctionClauseError, fn ->
        DeliverWebhookWorker.new_for_delivery(1, attempt_number)
      end

      assert_raise FunctionClauseError, fn ->
        DeliverWebhookWorker.new_scheduled_for_delivery(
          1,
          attempt_number,
          ~U[2099-01-15 12:00:00.123456Z]
        )
      end
    end

    non_utc = %{~U[2099-01-15 12:00:00.123456Z] | utc_offset: 3_600}

    assert_raise FunctionClauseError, fn ->
      DeliverWebhookWorker.new_scheduled_for_delivery(1, 1, non_utc)
    end
  end

  test "active equivalent jobs conflict" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} =
               DeliverWebhookWorker.new_for_delivery(1, 2)
               |> Oban.insert()

      assert {:ok, conflicting} =
               DeliverWebhookWorker.new_for_delivery(1, 2)
               |> Oban.insert()

      assert conflicting.conflict?
      assert conflicting.id == first.id
      assert Repo.aggregate(Oban.Job, :count) == 1
    end)
  end

  test "different logical attempts for the same delivery coexist" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} =
               DeliverWebhookWorker.new_for_delivery(1, 1)
               |> Oban.insert()

      assert {:ok, second} =
               DeliverWebhookWorker.new_for_delivery(1, 2)
               |> Oban.insert()

      refute first.conflict?
      refute second.conflict?
      refute second.id == first.id
      assert Repo.aggregate(Oban.Job, :count) == 2
    end)
  end

  test "a terminal job does not block future scheduling" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} =
               1
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert :ok = Oban.cancel_job(first)
      assert Repo.get!(Oban.Job, first.id).state == "cancelled"

      assert {:ok, rescheduled} =
               1
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      refute rescheduled.conflict?
      refute rescheduled.id == first.id
      assert Repo.aggregate(Oban.Job, :count) == 2
    end)
  end

  test "executes through Oban inline mode using the configured deterministic adapter" do
    delivery = delivery_fixture()

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert job.state == "completed"
      assert job.attempt == 1
      assert job.max_attempts == 1
      assert job.args == %{"delivery_id" => delivery.id, "attempt_number" => 1}
    end)

    finalized = Webhooks.get_delivery(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "succeeded"
    assert attempt.http_status == 204
    assert attempt.attempt_number == 1
  end

  test "executes a legacy one-key job as the first attempt" do
    delivery = delivery_fixture()

    assert :ok = perform_job(DeliverWebhookWorker, %{delivery_id: delivery.id})

    finalized = Webhooks.get_delivery(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.attempt_number == 1
  end

  test "passes the logical attempt number to the processor" do
    configure_delivery_adapter(__MODULE__)
    delivery = delivery_fixture()

    delivery
    |> change(
      attempt_count: 1,
      next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
    )
    |> Repo.update!()

    assert :ok =
             perform_job(DeliverWebhookWorker, %{
               delivery_id: delivery.id,
               attempt_number: 2
             })

    assert_received {:delivered, _, _, _}
    finalized = Webhooks.get_delivery(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 2
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.attempt_number == 2
  end

  test "cancels a stale legacy job before calling the adapter" do
    configure_delivery_adapter(__MODULE__)
    delivery = delivery_fixture()

    persisted =
      delivery
      |> change(attempt_count: 1)
      |> Repo.update!()

    assert {:cancel, :stale_attempt} =
             perform_job(DeliverWebhookWorker, %{delivery_id: delivery.id})

    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == persisted
    assert Webhooks.list_attempts(delivery) == []
  end

  test "cancels a job that runs before its persisted schedule" do
    configure_delivery_adapter(__MODULE__)
    delivery = delivery_fixture()

    persisted =
      delivery
      |> change(next_attempt_at: ~U[2099-01-15 12:00:00.123456Z])
      |> Repo.update!()

    assert {:cancel, :not_due} =
             perform_job(DeliverWebhookWorker, %{
               delivery_id: delivery.id,
               attempt_number: 1
             })

    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == persisted
    assert Webhooks.list_attempts(delivery) == []
  end

  test "completes a scheduled job when the endpoint became inactive" do
    configure_delivery_adapter(FailingDeliveryAdapter)

    {:ok, event} =
      Webhooks.create_event(%{
        external_id: "evt_worker_cancelled",
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Inactive before processing",
        url: "https://endpoint.invalid/http-error"
      })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{delivery: delivery, job: job}} =
               Webhooks.schedule_delivery(event, endpoint)

      assert job.state == "available"
      assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.attempt == 1
      assert completed_job.max_attempts == 1

      cancelled = Webhooks.get_delivery(delivery.id)
      assert cancelled.status == "cancelled"
      assert cancelled.attempt_count == 0
      assert cancelled.completed_at != nil
      assert Webhooks.list_attempts(cancelled) == []
      assert [] = all_enqueued(worker: DeliverWebhookWorker)
    end)
  end

  test "cancels a missing delivery without retrying" do
    assert {:cancel, :not_found} =
             perform_job(DeliverWebhookWorker, %{
               delivery_id: 2_147_483_647,
               attempt_number: 1
             })

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               2_147_483_647
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert job.state == "cancelled"
      assert job.attempt == 1
    end)
  end

  test "propagates a processor error without retrying" do
    delivery = delivery_fixture()
    {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)

    assert {:error, :invalid_transition} =
             perform_job(DeliverWebhookWorker, %{
               delivery_id: delivery.id,
               attempt_number: 1
             })

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert job.state == "discarded"
      assert job.attempt == 1
    end)

    assert Webhooks.list_attempts(delivery) == []
  end

  test "completes the current job after scheduling a retryable HTTP failure" do
    configure_delivery_adapter(FailingDeliveryAdapter)
    delivery = delivery_fixture("/http-error")

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert job.state == "available"
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.attempt == 1
      assert completed_job.max_attempts == 1
    end)

    pending = Webhooks.get_delivery(delivery.id)
    assert pending.status == "pending"
    assert pending.attempt_count == 1
    assert pending.completed_at == nil
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert attempt.error_type == nil
    assert attempt.next_attempt_at == pending.next_attempt_at

    assert [retry_job] = all_enqueued(worker: DeliverWebhookWorker)
    assert retry_job.args == %{"delivery_id" => delivery.id, "attempt_number" => 2}
    assert retry_job.scheduled_at == pending.next_attempt_at
    assert retry_job.state == "scheduled"
    assert Tidewake.Repo.aggregate(Oban.Job, :count, :id) == 2
  end

  test "completes the current job after scheduling a retryable transport failure" do
    configure_delivery_adapter(FailingDeliveryAdapter)
    delivery = delivery_fixture("/timeout")

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert job.state == "available"
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.attempt == 1
      assert completed_job.max_attempts == 1
    end)

    pending = Webhooks.get_delivery(delivery.id)
    assert pending.status == "pending"
    assert pending.attempt_count == 1
    assert pending.completed_at == nil
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "transport_error"
    assert attempt.http_status == nil
    assert attempt.error_type == "timeout"
    assert attempt.next_attempt_at == pending.next_attempt_at

    assert [retry_job] = all_enqueued(worker: DeliverWebhookWorker)
    assert retry_job.args == %{"delivery_id" => delivery.id, "attempt_number" => 2}
    assert retry_job.scheduled_at == pending.next_attempt_at
    assert retry_job.state == "scheduled"
    assert Tidewake.Repo.aggregate(Oban.Job, :count, :id) == 2
  end

  test "rejects invalid or additional job arguments" do
    for args <- [
          %{},
          %{attempt_number: 1},
          %{delivery_id: 0},
          %{delivery_id: "1"},
          %{delivery_id: 1, attempt_number: 0},
          %{delivery_id: 1, attempt_number: -1},
          %{delivery_id: 1, attempt_number: "1"},
          %{delivery_id: 1, body: "secret"},
          %{delivery_id: 1, attempt_number: 1, body: "secret"}
        ] do
      assert {:cancel, :invalid_args} = perform_job(DeliverWebhookWorker, args)
    end
  end

  defp configure_delivery_adapter(adapter) do
    previous_adapter = Application.fetch_env(:tidewake, :delivery_adapter)
    Application.put_env(:tidewake, :delivery_adapter, adapter)

    on_exit(fn ->
      case previous_adapter do
        {:ok, previous_adapter} ->
          Application.put_env(:tidewake, :delivery_adapter, previous_adapter)

        :error ->
          Application.delete_env(:tidewake, :delivery_adapter)
      end
    end)
  end

  defp delivery_fixture(path \\ "/webhooks") do
    {:ok, event} =
      Webhooks.create_event(%{
        external_id: "evt_worker",
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Local validation",
        url: "https://endpoint.invalid#{path}"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end
end

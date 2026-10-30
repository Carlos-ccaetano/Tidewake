defmodule Tidewake.Workers.DeliverWebhookWorkerTest do
  use Tidewake.DataCase, async: false
  import Tidewake.WebhooksFixtures, only: [legacy_project: 0]
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.FailingDeliveryAdapter
  alias Tidewake.Webhooks
  alias Tidewake.Workers.DeliverWebhookWorker

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(url, body, headers) do
    case Process.get(:worker_adapter_responses) do
      [response | remaining] ->
        call_number = Process.get(:worker_adapter_call_count, 0) + 1
        Process.put(:worker_adapter_call_count, call_number)
        Process.put(:worker_adapter_responses, remaining)
        send(self(), {:lifecycle_adapter_called, call_number})
        response

      [] ->
        raise "controlled adapter response queue exhausted"

      nil ->
        send(self(), {:delivered, url, body, headers})
        Process.get(:worker_adapter_response, {:ok, %{status: 204, headers: []}})
    end
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

  test "builds an immediate cycle-aware job with exactly four identity arguments" do
    changeset = DeliverWebhookWorker.new_for_delivery(123, 7, 1, 1)

    assert changeset.valid?
    job = apply_changes(changeset)

    assert job.args == %{
             "delivery_id" => 123,
             "attempt_number" => 7,
             "retry_cycle" => 1,
             "cycle_attempt_number" => 1
           }

    assert job.queue == "default"
    assert job.max_attempts == 1
    assert job.worker == "Tidewake.Workers.DeliverWebhookWorker"

    assert job.unique.keys == [
             :delivery_id,
             :attempt_number,
             :retry_cycle,
             :cycle_attempt_number
           ]
  end

  test "builds a scheduled cycle-aware job at the requested time" do
    scheduled_at = ~U[2099-01-15 12:00:00.123456Z]

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, job} =
               DeliverWebhookWorker.new_scheduled_for_delivery(123, 7, 1, 1, scheduled_at)
               |> Oban.insert()

      assert job.args == %{
               "delivery_id" => 123,
               "attempt_number" => 7,
               "retry_cycle" => 1,
               "cycle_attempt_number" => 1
             }

      assert job.scheduled_at == scheduled_at
      assert job.state == "scheduled"
      assert job.max_attempts == 1

      assert job.unique.keys == [
               :delivery_id,
               :attempt_number,
               :retry_cycle,
               :cycle_attempt_number
             ]
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

  test "rejects invalid cycle-aware job identities and scheduled times" do
    scheduled_at = ~U[2099-01-15 12:00:00.123456Z]

    for {delivery_id, attempt_number, retry_cycle, cycle_attempt_number} <- [
          {0, 7, 1, 1},
          {123, 0, 1, 1},
          {123, 7, -1, 1},
          {123, 7, 1, 0},
          {123, 7, "1", 1},
          {123, 7, 1, "1"}
        ] do
      assert_raise FunctionClauseError, fn ->
        DeliverWebhookWorker.new_for_delivery(
          delivery_id,
          attempt_number,
          retry_cycle,
          cycle_attempt_number
        )
      end

      assert_raise FunctionClauseError, fn ->
        DeliverWebhookWorker.new_scheduled_for_delivery(
          delivery_id,
          attempt_number,
          retry_cycle,
          cycle_attempt_number,
          scheduled_at
        )
      end
    end

    non_utc = %{scheduled_at | utc_offset: 3_600}

    assert_raise FunctionClauseError, fn ->
      DeliverWebhookWorker.new_scheduled_for_delivery(123, 7, 1, 1, non_utc)
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

  test "active equivalent cycle-aware jobs conflict on the complete identity" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} =
               DeliverWebhookWorker.new_for_delivery(123, 7, 1, 1)
               |> Oban.insert()

      assert {:ok, conflicting} =
               DeliverWebhookWorker.new_for_delivery(123, 7, 1, 1)
               |> Oban.insert()

      assert conflicting.conflict?
      assert conflicting.id == first.id
      assert Repo.aggregate(Oban.Job, :count) == 1
    end)
  end

  test "cycle-aware jobs with different identity fields do not conflict" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      jobs =
        for {delivery_id, attempt_number, retry_cycle, cycle_attempt_number} <- [
              {123, 7, 1, 1},
              {124, 7, 1, 1},
              {123, 8, 1, 1},
              {123, 7, 2, 1},
              {123, 7, 1, 2}
            ] do
          assert {:ok, job} =
                   DeliverWebhookWorker.new_for_delivery(
                     delivery_id,
                     attempt_number,
                     retry_cycle,
                     cycle_attempt_number
                   )
                   |> Oban.insert()

          refute job.conflict?
          job
        end

      assert length(Enum.uniq_by(jobs, & &1.id)) == 5
      assert Repo.aggregate(Oban.Job, :count) == 5
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

    finalized = Webhooks.get_delivery_internal(delivery.id)
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

    finalized = Webhooks.get_delivery_internal(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.attempt_number == 1
  end

  test "executes a cycle-aware job through the processor and persists its identity" do
    configure_delivery_adapter(__MODULE__)

    delivery =
      delivery_fixture()
      |> change(attempt_count: 6, retry_cycle: 1, cycle_attempt_count: 0)
      |> Repo.update!()

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               DeliverWebhookWorker.new_for_delivery(delivery.id, 7, 1, 1)
               |> Oban.insert()

      assert job.state == "completed"
      assert job.attempt == 1
      assert job.max_attempts == 1

      assert job.args == %{
               "delivery_id" => delivery.id,
               "attempt_number" => 7,
               "retry_cycle" => 1,
               "cycle_attempt_number" => 1
             }
    end)

    assert_received {:delivered, _, _, _}
    finalized = Webhooks.get_delivery_internal(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 7
    assert finalized.retry_cycle == 1
    assert finalized.cycle_attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.attempt_number == 7
    assert attempt.retry_cycle == 1
    assert attempt.cycle_attempt_number == 1
    assert attempt.result == "succeeded"
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
    finalized = Webhooks.get_delivery_internal(delivery.id)
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
    assert Webhooks.get_delivery_internal(delivery.id) == persisted
    assert Webhooks.list_attempts(delivery) == []
  end

  for {label, attempt_number, retry_cycle, cycle_attempt_number} <- [
        {"lifetime attempt", 6, 1, 1},
        {"retry cycle", 7, 0, 1},
        {"cycle ordinal", 7, 1, 2}
      ] do
    test "cancels a stale cycle-aware #{label} before calling the adapter" do
      configure_delivery_adapter(__MODULE__)

      delivery =
        delivery_fixture()
        |> change(attempt_count: 6, retry_cycle: 1, cycle_attempt_count: 0)
        |> Repo.update!()

      assert {:cancel, :stale_attempt} =
               perform_job(DeliverWebhookWorker, %{
                 delivery_id: delivery.id,
                 attempt_number: unquote(attempt_number),
                 retry_cycle: unquote(retry_cycle),
                 cycle_attempt_number: unquote(cycle_attempt_number)
               })

      refute_received {:delivered, _, _, _}
      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Webhooks.list_attempts(delivery) == []
      assert Repo.aggregate(Oban.Job, :count) == 0
    end
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

    assert {:cancel, :not_due} =
             perform_job(DeliverWebhookWorker, %{
               delivery_id: delivery.id,
               attempt_number: 1,
               retry_cycle: 0,
               cycle_attempt_number: 1
             })

    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery_internal(delivery.id) == persisted
    assert Webhooks.list_attempts(delivery) == []
  end

  test "completes a scheduled job when the endpoint became inactive" do
    configure_delivery_adapter(FailingDeliveryAdapter)

    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: "evt_worker_cancelled",
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Inactive before processing",
        url: "https://endpoint.invalid/http-error"
      })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{delivery: delivery, job: job}} =
               Webhooks.schedule_delivery(event, endpoint)

      assert job.state == "available"

      assert {:ok, _endpoint} =
               Webhooks.update_endpoint(legacy_project(), endpoint, %{active: false})

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)

      completed_job = Repo.get!(Oban.Job, job.id)
      assert completed_job.state == "completed"
      assert completed_job.attempt == 1
      assert completed_job.max_attempts == 1

      cancelled = Webhooks.get_delivery_internal(delivery.id)
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

    assert {:cancel, :not_found} =
             perform_job(DeliverWebhookWorker, %{
               delivery_id: 2_147_483_647,
               attempt_number: 1,
               retry_cycle: 0,
               cycle_attempt_number: 1
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

    pending = Webhooks.get_delivery_internal(delivery.id)
    assert pending.status == "pending"
    assert pending.attempt_count == 1
    assert pending.completed_at == nil
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert attempt.error_type == nil
    assert attempt.next_attempt_at == pending.next_attempt_at

    assert [retry_job] = all_enqueued(worker: DeliverWebhookWorker)

    assert retry_job.args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => 2,
             "retry_cycle" => 0,
             "cycle_attempt_number" => 2
           }

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

    pending = Webhooks.get_delivery_internal(delivery.id)
    assert pending.status == "pending"
    assert pending.attempt_count == 1
    assert pending.completed_at == nil
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "transport_error"
    assert attempt.http_status == nil
    assert attempt.error_type == "timeout"
    assert attempt.next_attempt_at == pending.next_attempt_at

    assert [retry_job] = all_enqueued(worker: DeliverWebhookWorker)

    assert retry_job.args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => 2,
             "retry_cycle" => 0,
             "cycle_attempt_number" => 2
           }

    assert retry_job.scheduled_at == pending.next_attempt_at
    assert retry_job.state == "scheduled"
    assert Tidewake.Repo.aggregate(Oban.Job, :count, :id) == 2
  end

  test "a retryable failure schedules one successor that later succeeds" do
    configure_delivery_adapter(__MODULE__)

    put_adapter_responses([
      {:ok, %{status: 503, headers: []}},
      {:ok, %{status: 202, headers: []}}
    ])

    delivery = delivery_fixture()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first_job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
      assert_received {:lifecycle_adapter_called, 1}

      pending = Webhooks.get_delivery_internal(delivery.id)
      assert pending.status == "pending"
      assert pending.attempt_count == 1
      assert pending.completed_at == nil

      assert [first_attempt] = Webhooks.list_attempts(pending)
      assert first_attempt.attempt_number == 1
      assert first_attempt.result == "http_error"
      assert first_attempt.http_status == 503
      assert first_attempt.next_attempt_at == pending.next_attempt_at

      assert [second_job] = all_enqueued(worker: DeliverWebhookWorker)

      assert second_job.args == %{
               "delivery_id" => delivery.id,
               "attempt_number" => 2,
               "retry_cycle" => 0,
               "cycle_attempt_number" => 2
             }

      assert second_job.scheduled_at == first_attempt.next_attempt_at
      assert second_job.state == "scheduled"
      assert Repo.get!(Oban.Job, first_job.id).state == "completed"

      original_retry_at = first_attempt.next_attempt_at
      make_retry_due(pending, second_job)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
      assert_received {:lifecycle_adapter_called, 2}
      refute_received {:lifecycle_adapter_called, _}

      succeeded = Webhooks.get_delivery_internal(delivery.id)
      assert succeeded.status == "succeeded"
      assert succeeded.attempt_count == 2
      assert succeeded.next_attempt_at == nil
      assert succeeded.completed_at != nil

      assert [persisted_first, second_attempt] = Webhooks.list_attempts(succeeded)
      assert persisted_first.attempt_number == 1
      assert persisted_first.next_attempt_at == original_retry_at
      assert second_attempt.attempt_number == 2
      assert second_attempt.result == "succeeded"
      assert second_attempt.http_status == 202
      assert second_attempt.next_attempt_at == nil
      assert all_enqueued(worker: DeliverWebhookWorker) == []
      assert Repo.aggregate(Oban.Job, :count, :id) == 2
    end)
  end

  test "six retryable failures exhaust the delivery without another job" do
    configure_delivery_adapter(__MODULE__)
    put_adapter_responses(List.duplicate({:ok, %{status: 503, headers: []}}, 6))
    delivery = delivery_fixture()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _first_job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      Enum.each(1..6, fn attempt_number ->
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
        assert_received {:lifecycle_adapter_called, ^attempt_number}

        persisted = Webhooks.get_delivery_internal(delivery.id)
        attempts = Webhooks.list_attempts(persisted)
        assert Enum.map(attempts, & &1.attempt_number) == Enum.to_list(1..attempt_number)

        if attempt_number < 6 do
          assert persisted.status == "pending"
          assert persisted.attempt_count == attempt_number
          assert [successor] = all_enqueued(worker: DeliverWebhookWorker)

          assert successor.args == %{
                   "delivery_id" => delivery.id,
                   "attempt_number" => attempt_number + 1,
                   "retry_cycle" => 0,
                   "cycle_attempt_number" => attempt_number + 1
                 }

          assert successor.scheduled_at == persisted.next_attempt_at
          make_retry_due(persisted, successor)
        else
          assert persisted.status == "failed"
          assert persisted.attempt_count == 6
          assert persisted.next_attempt_at == nil
          assert persisted.completed_at != nil
          assert all_enqueued(worker: DeliverWebhookWorker) == []
        end
      end)

      refute_received {:lifecycle_adapter_called, _}
      assert Process.get(:worker_adapter_responses) == []
      assert Repo.aggregate(Oban.Job, :count, :id) == 6
    end)
  end

  test "a permanent HTTP failure finishes without scheduling a successor" do
    configure_delivery_adapter(__MODULE__)
    put_adapter_responses([{:ok, %{status: 400, headers: []}}])
    delivery = delivery_fixture()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
      assert_received {:lifecycle_adapter_called, 1}
      refute_received {:lifecycle_adapter_called, _}

      failed = Webhooks.get_delivery_internal(delivery.id)
      assert failed.status == "failed"
      assert failed.attempt_count == 1
      assert failed.next_attempt_at == nil

      assert [attempt] = Webhooks.list_attempts(failed)
      assert attempt.attempt_number == 1
      assert attempt.result == "http_error"
      assert attempt.http_status == 400
      assert attempt.next_attempt_at == nil
      assert all_enqueued(worker: DeliverWebhookWorker) == []
      assert Repo.aggregate(Oban.Job, :count, :id) == 1
    end)
  end

  test "a duplicate logical attempt is rejected before calling the adapter" do
    configure_delivery_adapter(__MODULE__)
    put_adapter_responses([{:ok, %{status: 503, headers: []}}])
    delivery = delivery_fixture()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
      assert_received {:lifecycle_adapter_called, 1}

      persisted = Webhooks.get_delivery_internal(delivery.id)
      assert persisted.status == "pending"
      assert persisted.attempt_count == 1
      assert [persisted_attempt] = Webhooks.list_attempts(persisted)

      assert {:cancel, :stale_attempt} =
               perform_job(DeliverWebhookWorker, %{
                 delivery_id: delivery.id,
                 attempt_number: 1
               })

      refute_received {:lifecycle_adapter_called, _}
      assert Webhooks.get_delivery_internal(delivery.id) == persisted
      assert Webhooks.list_attempts(persisted) == [persisted_attempt]
      assert [_successor] = all_enqueued(worker: DeliverWebhookWorker)
    end)
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

  test "rejects missing, extra, or invalid cycle-aware arguments before calling the adapter" do
    configure_delivery_adapter(__MODULE__)
    delivery = delivery_fixture()

    for args <- [
          %{delivery_id: delivery.id, attempt_number: 1, retry_cycle: 0},
          %{delivery_id: delivery.id, attempt_number: 1, cycle_attempt_number: 1},
          %{
            delivery_id: delivery.id,
            attempt_number: 1,
            retry_cycle: 0,
            cycle_attempt_number: 1,
            body: "secret"
          },
          %{
            delivery_id: delivery.id,
            attempt_number: "1",
            retry_cycle: 0,
            cycle_attempt_number: 1
          },
          %{
            delivery_id: delivery.id,
            attempt_number: 1,
            retry_cycle: "0",
            cycle_attempt_number: 1
          },
          %{
            delivery_id: delivery.id,
            attempt_number: 1,
            retry_cycle: 0,
            cycle_attempt_number: 0
          }
        ] do
      assert {:cancel, :invalid_args} = perform_job(DeliverWebhookWorker, args)
      refute_received {:delivered, _, _, _}
      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Webhooks.list_attempts(delivery) == []
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

  defp put_adapter_responses(responses) do
    Process.put(:worker_adapter_responses, responses)
    Process.put(:worker_adapter_call_count, 0)
  end

  defp make_retry_due(delivery, job) do
    due_at = DateTime.add(DateTime.utc_now(), -1, :second)

    delivery
    |> change(next_attempt_at: due_at)
    |> Repo.update!()

    job
    |> change(state: "available", scheduled_at: due_at)
    |> Repo.update!()
  end

  defp delivery_fixture(path \\ "/webhooks") do
    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: "evt_worker",
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Local validation",
        url: "https://endpoint.invalid#{path}"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end
end

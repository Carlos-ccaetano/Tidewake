defmodule Tidewake.Workers.DeliverWebhookWorkerTest do
  use Tidewake.DataCase, async: false
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.FailingDeliveryAdapter
  alias Tidewake.Webhooks
  alias Tidewake.Workers.DeliverWebhookWorker

  test "builds a default queue job with only the delivery ID and one attempt" do
    changeset = DeliverWebhookWorker.new(%{"delivery_id" => 1})

    assert changeset.valid?
    job = apply_changes(changeset)
    assert job.args == %{"delivery_id" => 1}
    assert job.queue == "default"
    assert job.max_attempts == 1
    assert job.worker == "Tidewake.Workers.DeliverWebhookWorker"
  end

  test "executes through Oban inline mode using the configured deterministic adapter" do
    delivery = delivery_fixture()

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               %{delivery_id: delivery.id}
               |> DeliverWebhookWorker.new()
               |> Oban.insert()

      assert job.state == "completed"
      assert job.attempt == 1
      assert job.max_attempts == 1
      assert job.args == %{"delivery_id" => delivery.id}
    end)

    finalized = Webhooks.get_delivery(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "succeeded"
    assert attempt.http_status == 204
    assert attempt.attempt_number == 1
  end

  test "cancels a missing delivery without retrying" do
    assert {:cancel, :not_found} =
             perform_job(DeliverWebhookWorker, %{delivery_id: 2_147_483_647})

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               %{delivery_id: 2_147_483_647}
               |> DeliverWebhookWorker.new()
               |> Oban.insert()

      assert job.state == "cancelled"
      assert job.attempt == 1
    end)
  end

  test "propagates a processor error without retrying" do
    delivery = delivery_fixture()
    {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)

    assert {:error, :invalid_transition} =
             perform_job(DeliverWebhookWorker, %{delivery_id: delivery.id})

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               %{delivery_id: delivery.id}
               |> DeliverWebhookWorker.new()
               |> Oban.insert()

      assert job.state == "discarded"
      assert job.attempt == 1
    end)

    assert Webhooks.list_attempts(delivery) == []
  end

  test "completes an HTTP failure job without retrying" do
    configure_delivery_adapter(FailingDeliveryAdapter)
    delivery = delivery_fixture("/http-error")

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               %{delivery_id: delivery.id}
               |> DeliverWebhookWorker.new()
               |> Oban.insert()

      assert job.state == "completed"
      assert job.attempt == 1
      assert job.max_attempts == 1
    end)

    finalized = Webhooks.get_delivery(delivery.id)
    assert finalized.status == "failed"
    assert finalized.attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert attempt.error_type == nil
    assert [] = all_enqueued(worker: DeliverWebhookWorker)
    assert Tidewake.Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  test "completes a transport failure job without retrying" do
    configure_delivery_adapter(FailingDeliveryAdapter)
    delivery = delivery_fixture("/timeout")

    Oban.Testing.with_testing_mode(:inline, fn ->
      assert {:ok, job} =
               %{delivery_id: delivery.id}
               |> DeliverWebhookWorker.new()
               |> Oban.insert()

      assert job.state == "completed"
      assert job.attempt == 1
      assert job.max_attempts == 1
    end)

    finalized = Webhooks.get_delivery(delivery.id)
    assert finalized.status == "failed"
    assert finalized.attempt_count == 1
    assert [attempt] = Webhooks.list_attempts(delivery)
    assert attempt.result == "transport_error"
    assert attempt.http_status == nil
    assert attempt.error_type == "timeout"
    assert [] = all_enqueued(worker: DeliverWebhookWorker)
    assert Tidewake.Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  test "rejects invalid or additional job arguments" do
    for args <- [%{}, %{delivery_id: 0}, %{delivery_id: "1"}, %{delivery_id: 1, body: "secret"}] do
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

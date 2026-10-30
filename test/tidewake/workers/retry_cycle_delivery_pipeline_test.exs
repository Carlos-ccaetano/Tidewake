defmodule Tidewake.Workers.RetryCycleDeliveryPipelineTest do
  use Tidewake.DataCase, async: false
  import Tidewake.WebhooksFixtures, only: [legacy_project: 0]
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.Webhooks
  alias Tidewake.Workers.DeliverWebhookWorker

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(_url, _body, _headers) do
    call_number = Process.get(:cycle_pipeline_adapter_calls, 0) + 1
    Process.put(:cycle_pipeline_adapter_calls, call_number)
    send(self(), {:cycle_pipeline_adapter_called, call_number})
    {:ok, %{status: 503, headers: []}}
  end

  test "a later cycle gets six attempts and schedules only five successors" do
    configure_delivery_adapter()
    delivery = delivery_fixture()
    history = Webhooks.list_attempts(delivery)

    assert delivery.status == "pending"
    assert delivery.attempt_count == 6
    assert delivery.retry_cycle == 1
    assert delivery.cycle_attempt_count == 0
    assert Enum.map(history, & &1.attempt_number) == Enum.to_list(1..6)
    assert Enum.all?(history, &(&1.retry_cycle == 0))
    assert Enum.map(history, & &1.cycle_attempt_number) == Enum.to_list(1..6)

    Oban.Testing.with_testing_mode(:manual, fn ->
      for identity <- [
            %{attempt_number: 7, retry_cycle: 0, cycle_attempt_number: 1},
            %{attempt_number: 7, retry_cycle: 1, cycle_attempt_number: 2}
          ] do
        assert {:cancel, :stale_attempt} =
                 perform_job(
                   DeliverWebhookWorker,
                   Map.put(identity, :delivery_id, delivery.id)
                 )

        refute_received {:cycle_pipeline_adapter_called, _}
        assert Webhooks.get_delivery_internal(delivery.id) == delivery
        assert Webhooks.list_attempts(delivery) == history
      end

      assert {:ok, first_job} =
               delivery.id
               |> DeliverWebhookWorker.new_for_delivery(7, 1, 1)
               |> Oban.insert()

      assert first_job.args == %{
               "delivery_id" => delivery.id,
               "attempt_number" => 7,
               "retry_cycle" => 1,
               "cycle_attempt_number" => 1
             }

      Enum.each(1..6, fn cycle_attempt_number ->
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
        assert_received {:cycle_pipeline_adapter_called, ^cycle_attempt_number}

        persisted = Webhooks.get_delivery_internal(delivery.id)
        attempts = Webhooks.list_attempts(persisted)
        current = List.last(attempts)

        assert Enum.take(attempts, 6) == history

        assert Enum.map(attempts, & &1.attempt_number) ==
                 Enum.to_list(1..(6 + cycle_attempt_number))

        assert Enum.map(Enum.drop(attempts, 6), & &1.retry_cycle) ==
                 List.duplicate(1, cycle_attempt_number)

        assert Enum.map(Enum.drop(attempts, 6), & &1.cycle_attempt_number) ==
                 Enum.to_list(1..cycle_attempt_number)

        assert current.result == "http_error"
        assert current.http_status == 503
        assert persisted.attempt_count == 6 + cycle_attempt_number
        assert persisted.retry_cycle == 1
        assert persisted.cycle_attempt_count == cycle_attempt_number

        if cycle_attempt_number < 6 do
          assert persisted.status == "pending"
          assert [successor] = all_enqueued(worker: DeliverWebhookWorker)

          assert successor.args == %{
                   "delivery_id" => delivery.id,
                   "attempt_number" => 7 + cycle_attempt_number,
                   "retry_cycle" => 1,
                   "cycle_attempt_number" => cycle_attempt_number + 1
                 }

          assert successor.scheduled_at == persisted.next_attempt_at
          assert current.next_attempt_at == persisted.next_attempt_at

          if cycle_attempt_number == 1 do
            assert DateTime.diff(current.next_attempt_at, current.completed_at, :second) in 5..10
          end

          make_retry_due(persisted, successor)
        else
          assert persisted.status == "failed"
          assert persisted.next_attempt_at == nil
          assert current.next_attempt_at == nil
          assert all_enqueued(worker: DeliverWebhookWorker) == []
        end
      end)

      refute_received {:cycle_pipeline_adapter_called, _}
      assert Process.get(:cycle_pipeline_adapter_calls) == 6
      assert Repo.aggregate(Oban.Job, :count, :id) == 6
      assert length(Webhooks.list_attempts(delivery)) == 12
    end)
  end

  defp configure_delivery_adapter do
    previous_adapter = Application.fetch_env(:tidewake, :delivery_adapter)
    Application.put_env(:tidewake, :delivery_adapter, __MODULE__)

    on_exit(fn ->
      case previous_adapter do
        {:ok, adapter} -> Application.put_env(:tidewake, :delivery_adapter, adapter)
        :error -> Application.delete_env(:tidewake, :delivery_adapter)
      end
    end)
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

  defp delivery_fixture do
    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: "evt_cycle_pipeline",
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Cycle pipeline validation",
        url: "https://endpoint.invalid/webhooks"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    timestamp = DateTime.utc_now()

    for attempt_number <- 1..6 do
      assert {:ok, _attempt} =
               Webhooks.create_attempt(
                 %{delivery | cycle_attempt_count: attempt_number - 1},
                 %{
                   attempt_number: attempt_number,
                   result: "http_error",
                   http_status: 503,
                   duration_ms: 0,
                   started_at: timestamp,
                   completed_at: timestamp
                 }
               )
    end

    delivery
    |> change(attempt_count: 6, retry_cycle: 1, cycle_attempt_count: 0)
    |> Repo.update!()
  end
end

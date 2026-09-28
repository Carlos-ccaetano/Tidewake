defmodule Tidewake.Workers.RecoverStaleDeliveriesWorkerTest do
  use Tidewake.DataCase, async: false
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Attempt, Delivery}
  alias Tidewake.Workers.{DeliverWebhookWorker, RecoverStaleDeliveriesWorker}

  @recovery_event [:tidewake, :webhooks, :delivery, :recovery]

  test "completes normally when there are no candidates" do
    attach_telemetry()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})
      assert Repo.aggregate(Oban.Job, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end)

    assert_receive {:telemetry_event, @recovery_event,
                    %{
                      recovered_count: 0,
                      skipped_count: 0,
                      error_count: 0,
                      duration_ms: duration_ms
                    }, %{}}

    assert is_integer(duration_ms)
    assert duration_ms >= 0
    refute_receive {:telemetry_event, @recovery_event, _, _}
  end

  test "active maintenance jobs are unique" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} =
               %{}
               |> RecoverStaleDeliveriesWorker.new()
               |> Oban.insert()

      assert {:ok, conflicting} =
               %{}
               |> RecoverStaleDeliveriesWorker.new()
               |> Oban.insert()

      assert conflicting.conflict?
      assert conflicting.id == first.id
      assert Repo.aggregate(Oban.Job, :count) == 1
    end)
  end

  test "recovers multiple old deliveries without executing them" do
    now = DateTime.utc_now()

    first =
      "multiple_first"
      |> delivery_fixture()
      |> put_processing(DateTime.add(now, -600, :second), %{attempt_count: 2})

    second =
      "multiple_second"
      |> delivery_fixture()
      |> put_processing(DateTime.add(now, -360, :second))

    recent =
      "multiple_recent"
      |> delivery_fixture()
      |> put_processing(DateTime.add(now, -240, :second))

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})

      assert Webhooks.get_delivery(first.id).status == "pending"
      assert Webhooks.get_delivery(first.id).attempt_count == 2
      assert Webhooks.get_delivery(second.id).status == "pending"
      assert Webhooks.get_delivery(recent.id).status == "processing"

      jobs = delivery_jobs()

      assert Enum.map(jobs, & &1.args) == [
               %{"delivery_id" => first.id},
               %{"delivery_id" => second.id}
             ]

      assert Enum.all?(jobs, &(&1.state == "available"))
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  test "ignores an active-job race without duplication and continues the batch" do
    stale_at = DateTime.add(DateTime.utc_now(), -360, :second)
    attach_telemetry()

    blocked =
      "concurrent_blocked"
      |> delivery_fixture()
      |> put_processing(stale_at)

    recoverable =
      "concurrent_recoverable"
      |> delivery_fixture()
      |> put_processing(stale_at)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, active_job} =
               blocked.id
               |> DeliverWebhookWorker.new_for_delivery()
               |> Oban.insert()

      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})

      assert Webhooks.get_delivery(blocked.id).status == "processing"
      assert Webhooks.get_delivery(recoverable.id).status == "pending"

      jobs = delivery_jobs()
      assert length(jobs) == 2
      assert Enum.count(jobs, &(&1.args == %{"delivery_id" => blocked.id})) == 1
      assert Enum.count(jobs, &(&1.args == %{"delivery_id" => recoverable.id})) == 1
      assert Enum.any?(jobs, &(&1.id == active_job.id))
      assert Repo.aggregate(Attempt, :count) == 0
    end)

    assert_receive {:telemetry_event, @recovery_event,
                    %{
                      recovered_count: 1,
                      skipped_count: 1,
                      error_count: 0,
                      duration_ms: duration_ms
                    } = measurements, metadata}

    assert duration_ms >= 0
    assert metadata == %{}

    assert Map.keys(measurements) |> Enum.sort() ==
             [:duration_ms, :error_count, :recovered_count, :skipped_count]

    telemetry_data = inspect({measurements, metadata})
    refute telemetry_data =~ "endpoint.invalid"
    refute telemetry_data =~ "order_id"
    refute telemetry_data =~ "authorization"
    refute telemetry_data =~ "secret"
    refute_received {:telemetry_event, @recovery_event, _, _}
  end

  test "recovers at most 100 deliveries in deterministic order" do
    stale_at = DateTime.add(DateTime.utc_now(), -360, :second)

    deliveries =
      for index <- 1..101 do
        "batch_#{index}"
        |> delivery_fixture()
        |> put_processing(stale_at)
      end

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})

      statuses =
        from(delivery in Delivery,
          where: delivery.id in ^Enum.map(deliveries, & &1.id),
          order_by: [asc: delivery.id],
          select: delivery.status
        )
        |> Repo.all()

      assert Enum.count(statuses, &(&1 == "pending")) == 100
      assert List.last(statuses) == "processing"

      jobs = delivery_jobs()
      assert length(jobs) == 100

      assert Enum.map(jobs, & &1.args) ==
               Enum.map(Enum.take(deliveries, 100), &%{"delivery_id" => &1.id})

      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  test "builds a one-attempt maintenance job and accepts only an empty payload" do
    changeset = RecoverStaleDeliveriesWorker.new(%{})

    assert changeset.valid?
    job = apply_changes(changeset)
    assert job.args == %{}
    assert job.queue == "maintenance"
    assert job.max_attempts == 1

    for args <- [%{limit: 1}, %{stale_before: "2026-09-28T12:00:00Z"}] do
      assert {:cancel, :invalid_args} = perform_job(RecoverStaleDeliveriesWorker, args)
    end
  end

  test "base Oban config keeps delivery concurrency and schedules recovery every minute" do
    oban_config = base_oban_config()

    assert oban_config[:queues] == [default: 10, maintenance: 1]

    assert oban_config[:cron] == [
             crontab: [
               {"* * * * *", RecoverStaleDeliveriesWorker}
             ]
           ]

    assert :ok = Oban.Config.validate(oban_config)
  end

  test "test config keeps queues and plugins disabled" do
    oban_config = Application.fetch_env!(:tidewake, Oban)

    assert oban_config[:testing] == :inline
    assert oban_config[:queues] == false
    assert oban_config[:plugins] == false
  end

  defp delivery_jobs do
    from(job in Oban.Job,
      where: job.worker == "Tidewake.Workers.DeliverWebhookWorker",
      order_by: [asc: job.id]
    )
    |> Repo.all()
  end

  defp base_oban_config do
    "../../../config/config.exs"
    |> Path.expand(__DIR__)
    |> Config.Reader.read!(env: :dev)
    |> Keyword.fetch!(:tidewake)
    |> Keyword.fetch!(Oban)
  end

  defp delivery_fixture(suffix) do
    {:ok, event} =
      Webhooks.create_event(%{
        external_id: "evt_recovery_worker_#{suffix}",
        event_type: "order.created",
        payload: %{"order_id" => suffix}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Recovery endpoint #{suffix}",
        url: "https://endpoint.invalid/webhooks/#{suffix}"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end

  defp put_processing(delivery, updated_at, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{status: "processing", updated_at: updated_at})

    delivery
    |> change(attrs)
    |> Repo.update!()
  end

  def handle_telemetry(event_name, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry do
    handler_id = "delivery-recovery-worker-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @recovery_event,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end

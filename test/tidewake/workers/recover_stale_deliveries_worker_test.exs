defmodule Tidewake.Workers.RecoverStaleDeliveriesWorkerTest do
  use Tidewake.DataCase, async: false
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Attempt, Delivery}
  alias Tidewake.Workers.{DeliverWebhookWorker, RecoverStaleDeliveriesWorker}

  test "completes normally when there are no candidates" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})
      assert Repo.aggregate(Oban.Job, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
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

  test "accepts only an empty maintenance job payload" do
    changeset = RecoverStaleDeliveriesWorker.new(%{})

    assert changeset.valid?
    job = apply_changes(changeset)
    assert job.args == %{}
    assert job.queue == "default"
    assert job.max_attempts == 1

    for args <- [%{limit: 1}, %{stale_before: "2026-09-28T12:00:00Z"}] do
      assert {:cancel, :invalid_args} = perform_job(RecoverStaleDeliveriesWorker, args)
    end
  end

  defp delivery_jobs do
    from(job in Oban.Job,
      where: job.worker == "Tidewake.Workers.DeliverWebhookWorker",
      order_by: [asc: job.id]
    )
    |> Repo.all()
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
end

defmodule Tidewake.Workers.CrashRecoveryTest do
  use Tidewake.DataCase, async: false
  use Oban.Testing, repo: Tidewake.Repo

  import Tidewake.WebhooksFixtures, only: [legacy_project: 0]

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Attempt, Delivery}
  alias Tidewake.Workers.{DeliverWebhookWorker, RecoverStaleDeliveriesWorker}

  test "technical executions have a timeout shorter than orphan rescue" do
    for worker <- [DeliverWebhookWorker, RecoverStaleDeliveriesWorker] do
      assert worker.timeout(%Oban.Job{}) == :timer.minutes(2)
    end
  end

  test "a fetch interrupted before claim can progress after Lifeline discards its job" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery, job: job} = scheduled_delivery("before_claim")
      orphan(job)

      assert {:ok, [%{state: "discarded"}]} =
               Oban.Engine.rescue_jobs(Oban.config(), Oban.Job, rescue_after: 300_000)

      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})
      assert replacement(delivery, job)
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  test "discarded technical work is reconciled without a persisted HTTP attempt" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery, job: job} = scheduled_delivery("discarded")
      job |> change(state: "discarded", attempt: 1) |> Repo.update!()

      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})
      assert replacement(delivery, job)
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  test "100 blocked candidates cannot starve later abandoned work" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      for index <- 1..100 do
        %{delivery: delivery} = scheduled_delivery("blocked_#{index}")
        delivery |> change(status: "processing") |> Repo.update!() |> age()
      end

      %{delivery: delivery, job: job} = scheduled_delivery("after_blocked")
      job |> change(state: "discarded", attempt: 1) |> Repo.update!()
      delivery |> change(status: "processing") |> Repo.update!() |> age()

      assert :ok = perform_job(RecoverStaleDeliveriesWorker, %{})
      assert replacement(delivery, job)
      assert Repo.get!(Delivery, delivery.id).status == "pending"
    end)
  end

  test "an orphaned maintenance execution cannot prevent the next cron insertion" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, job} = %{} |> RecoverStaleDeliveriesWorker.new() |> Oban.insert()
      orphan(job)

      assert {:ok, next} = %{} |> RecoverStaleDeliveriesWorker.new() |> Oban.insert()
      refute next.conflict?
      refute next.id == job.id
      assert Repo.get!(Oban.Job, job.id).state == "executing"
    end)
  end

  test "late completion cannot finalize the replacement claim or schedule its retry" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery, job: job} = scheduled_delivery("late_completion")
      assert {:ok, old_claim} = Webhooks.claim_delivery(delivery.id)
      job |> change(state: "discarded", attempt: 1) |> Repo.update!()
      age(old_claim)

      assert {:ok, %{delivery: recovered, job: next}} =
               Webhooks.recover_stale_delivery(delivery.id, DateTime.utc_now())

      assert recovered.recovery_count == 1
      assert :ok = perform_job(DeliverWebhookWorker, next.args)
      assert Repo.get!(Delivery, delivery.id).status == "succeeded"
      assert {:error, :invalid_transition} = Webhooks.finalize_delivery(old_claim, outcome())
      assert Repo.aggregate(Attempt, :count) == 1
    end)
  end

  test "a recovered claim fences both terminal and retry writes while processing" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery, job: job} = scheduled_delivery("fence")
      assert {:ok, old_claim} = Webhooks.claim_delivery(delivery.id)
      job |> change(state: "discarded", attempt: 1) |> Repo.update!()
      age(old_claim)

      assert {:ok, %{job: next}} =
               Webhooks.recover_stale_delivery(delivery.id, DateTime.utc_now())

      identity = %{
        attempt_number: next.args["attempt_number"],
        retry_cycle: next.args["retry_cycle"],
        cycle_attempt_number: next.args["cycle_attempt_number"],
        recovery_count: next.args["recovery_count"]
      }

      assert {:ok, current} = Webhooks.claim_delivery(delivery.id, identity)
      assert {:error, :stale_attempt} = Webhooks.finalize_delivery(old_claim, outcome())

      assert {:error, :stale_attempt} =
               Webhooks.schedule_delivery_retry(old_claim, outcome(), DateTime.utc_now())

      assert Repo.get!(Delivery, delivery.id).recovery_count == current.recovery_count
      assert Repo.aggregate(Attempt, :count) == 0
      assert {:ok, _} = Webhooks.finalize_delivery(current, outcome())
      assert Repo.aggregate(Attempt, :count) == 1
    end)
  end

  test "technical recovery is finite and does not invent HTTP outcomes" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery, job: initial} = scheduled_delivery("bounded")

      last =
        Enum.reduce(1..Delivery.max_recoveries(), initial, fn generation, job ->
          job |> change(state: "discarded", attempt: 1) |> Repo.update!()
          age(Repo.get!(Delivery, delivery.id))

          assert {:ok, %{delivery: pending, job: replacement}} =
                   Webhooks.recover_stale_delivery(delivery.id, DateTime.utc_now())

          assert pending.recovery_count == generation
          assert pending.attempt_count == 0
          replacement
        end)

      last |> change(state: "discarded", attempt: 1) |> Repo.update!()
      age(Repo.get!(Delivery, delivery.id))

      assert {:ok, %{delivery: failed, job: nil}} =
               Webhooks.recover_stale_delivery(delivery.id, DateTime.utc_now())

      assert failed.status == "failed"
      assert failed.attempt_count == 0
      assert failed.cycle_attempt_count == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(Oban.Job, :count) == Delivery.max_recoveries() + 1

      assert {:error, :invalid_transition} =
               Webhooks.recover_stale_delivery(delivery.id, DateTime.utc_now())

      scope = Tidewake.ProjectsFixtures.scope_fixture("admin", legacy_project()).scope

      assert {:ok, %{request: %{outcome: "accepted"}}} =
               Webhooks.request_manual_retry(scope, failed.id, "synthetic-recovery-manual-key")

      reopened = Repo.get!(Delivery, failed.id)
      assert reopened.retry_cycle == 1
      assert reopened.recovery_count == 0
      assert reopened.attempt_count == 0
      assert {:cancel, :stale_attempt} = perform_job(DeliverWebhookWorker, initial.args)
      assert Repo.get!(Delivery, failed.id).status == "pending"
    end)
  end

  test "replacement preserves a future due time" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery, job: old} = scheduled_delivery("future")
      future = DateTime.add(DateTime.utc_now(), 3600)
      delivery |> change(next_attempt_at: future) |> Repo.update!() |> age()
      old |> change(state: "cancelled") |> Repo.update!()

      assert {:ok, %{delivery: pending, job: replacement}} =
               Webhooks.recover_stale_delivery(delivery.id, DateTime.utc_now())

      assert pending.next_attempt_at == future
      assert replacement.scheduled_at == future
      assert replacement.state == "scheduled"
      assert {:cancel, :not_due} = perform_job(DeliverWebhookWorker, replacement.args)
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  test "legacy and old-cycle jobs cannot enter a manual cycle with zero HTTP attempts" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      %{delivery: delivery} = scheduled_delivery("legacy_manual")
      delivery |> change(retry_cycle: 1) |> Repo.update!()

      for args <- [
            %{"delivery_id" => delivery.id},
            %{"delivery_id" => delivery.id, "attempt_number" => 1},
            %{
              "delivery_id" => delivery.id,
              "attempt_number" => 1,
              "retry_cycle" => 0,
              "cycle_attempt_number" => 1
            }
          ] do
        assert {:cancel, :stale_attempt} = perform_job(DeliverWebhookWorker, args)
      end

      assert Repo.get!(Delivery, delivery.id).status == "pending"
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  defp outcome do
    now = DateTime.utc_now()

    %{
      result: "succeeded",
      http_status: 202,
      duration_ms: 0,
      started_at: now,
      completed_at: now,
      response_metadata: %{}
    }
  end

  defp scheduled_delivery(suffix) do
    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: "crash_#{suffix}",
        event_type: "synthetic.created",
        payload: %{"synthetic" => true}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Synthetic recovery",
        url: "https://endpoint.invalid/recovery"
      })

    {:ok, %{delivery: delivery} = result} = Webhooks.schedule_delivery(event, endpoint)
    age(delivery)
    result
  end

  defp age(delivery) do
    delivery |> change(updated_at: DateTime.add(DateTime.utc_now(), -600)) |> Repo.update!()
  end

  defp orphan(job) do
    job
    |> change(
      state: "executing",
      attempt: 1,
      attempted_at: DateTime.add(DateTime.utc_now(), -600)
    )
    |> Repo.update!()
  end

  defp replacement(delivery, old_job) do
    Repo.exists?(
      from job in Oban.Job,
        where: job.id != ^old_job.id and job.state in ["available", "scheduled"],
        where: job.worker == ^Oban.Worker.to_string(DeliverWebhookWorker),
        where: fragment("?->>'delivery_id'", job.args) == ^to_string(delivery.id)
    )
  end
end

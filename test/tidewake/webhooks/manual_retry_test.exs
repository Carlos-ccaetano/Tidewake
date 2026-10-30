defmodule Tidewake.Webhooks.ManualRetryTest do
  use ExUnit.Case, async: false
  import Tidewake.WebhooksFixtures, only: [legacy_project: 0]

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Repo

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Delivery, ManualRetryActor, ManualRetryIdempotency, ManualRetryRequest}
  alias Tidewake.Workers.DeliverWebhookWorker

  @key "manual-retry-key-0001"
  @completed_at ~U[2026-10-20 10:00:00.123456Z]

  setup tags do
    unless tags[:unboxed], do: Tidewake.DataCase.setup_sandbox(tags)
    Process.put(:oban_testing, :manual)
    {:ok, actor: actor()}
  end

  for cycle <- 0..2 do
    @cycle cycle
    test "accepts cycle #{@cycle} into #{@cycle + 1} with one immediate complete job", %{
      actor: actor
    } do
      delivery = delivery_fixture(%{retry_cycle: @cycle})
      history = Webhooks.list_attempts(delivery)
      event = Webhooks.get_event(legacy_project(), delivery.event_id)
      endpoint = Webhooks.get_endpoint(legacy_project(), delivery.endpoint_id)
      before_request = DateTime.utc_now()

      assert {:ok, %{request: request, replayed?: false}} =
               Webhooks.request_manual_retry(delivery.id, actor, @key)

      assert request.outcome == "accepted"
      assert request.reason == nil
      assert request.delivery_id == delivery.id
      assert request.observed_status == "failed"
      assert request.observed_attempt_count == delivery.attempt_count
      assert request.observed_retry_cycle == @cycle
      assert request.observed_completed_at == @completed_at
      assert request.resulting_retry_cycle == @cycle + 1
      assert request.actor_type == actor.type
      assert request.actor_subject == actor.subject
      assert request.source == actor.source
      assert DateTime.compare(request.requested_at, before_request) in [:eq, :gt]
      assert DateTime.compare(request.requested_at, DateTime.utc_now()) in [:eq, :lt]
      assert request == Repo.get!(ManualRetryRequest, request.id)

      pending = Webhooks.get_delivery_internal(delivery.id)
      assert pending.status == "pending"
      assert pending.retry_cycle == @cycle + 1
      assert pending.cycle_attempt_count == 0
      assert pending.attempt_count == delivery.attempt_count
      assert pending.completed_at == nil
      assert pending.next_attempt_at == nil
      assert pending.id == delivery.id
      assert pending.event_id == event.id
      assert pending.endpoint_id == endpoint.id
      assert pending.inserted_at == delivery.inserted_at
      assert Webhooks.get_event(legacy_project(), event.id) == event
      assert Webhooks.get_endpoint(legacy_project(), endpoint.id) == endpoint
      assert Webhooks.list_attempts(delivery) == history
      assert length(history) == delivery.attempt_count
      assert Repo.aggregate(ManualRetryRequest, :count) == 1

      assert [job] = Repo.all(Oban.Job)

      assert job.args == %{
               "delivery_id" => delivery.id,
               "attempt_number" => delivery.attempt_count + 1,
               "retry_cycle" => @cycle + 1,
               "cycle_attempt_number" => 1
             }

      assert job.state == "available"
      assert job.worker == Oban.Worker.to_string(DeliverWebhookWorker)
      assert job.max_attempts == 1
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) in [:eq, :lt]
    end
  end

  test "accepts an early permanent failure without resetting lifetime numbering", %{actor: actor} do
    delivery = delivery_fixture(%{cycle_attempt_count: 1})

    assert {:ok, %{request: %{outcome: "accepted"}}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    assert [%{args: %{"attempt_number" => 2, "cycle_attempt_number" => 1}}] = Repo.all(Oban.Job)
    assert Webhooks.get_delivery_internal(delivery.id).attempt_count == 1
  end

  for status <- ~w(pending processing succeeded cancelled) do
    @status status
    test "records state_not_failed for #{@status} without any transition", %{actor: actor} do
      delivery = delivery_fixture(%{status: @status})
      history = Webhooks.list_attempts(delivery)

      assert {:ok, %{request: request, replayed?: false}} =
               Webhooks.request_manual_retry(delivery.id, actor, @key)

      assert request.outcome == "rejected"
      assert request.reason == "state_not_failed"
      assert request.observed_status == @status
      assert request.observed_attempt_count == delivery.attempt_count
      assert request.observed_retry_cycle == delivery.retry_cycle
      assert request.observed_completed_at == delivery.completed_at
      assert request.resulting_retry_cycle == nil
      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Webhooks.list_attempts(delivery) == history
      assert Repo.all(Oban.Job) == []
      assert Repo.aggregate(ManualRetryRequest, :count) == 1
    end
  end

  test "rejects cycle three with its complete history intact", %{actor: actor} do
    delivery = delivery_fixture(%{retry_cycle: 3})
    history = Webhooks.list_attempts(delivery)
    assert length(history) == 24

    assert {:ok, %{request: request, replayed?: false}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    assert request.outcome == "rejected"
    assert request.reason == "manual_cycle_limit_reached"
    assert request.resulting_retry_cycle == nil
    assert Webhooks.get_delivery_internal(delivery.id) == delivery
    assert Webhooks.list_attempts(delivery) == history
    assert Repo.all(Oban.Job) == []
  end

  test "rejects inactive endpoints before the cycle limit", %{actor: actor} do
    delivery = delivery_fixture(%{retry_cycle: 3})

    {:ok, endpoint} =
      Webhooks.update_endpoint(
        legacy_project(),
        Webhooks.get_endpoint(legacy_project(), delivery.endpoint_id),
        %{active: false}
      )

    history = Webhooks.list_attempts(delivery)
    assert {:ok, %{request: request}} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    assert request.outcome == "rejected"
    assert request.reason == "endpoint_inactive"
    assert request.resulting_retry_cycle == nil
    assert Webhooks.get_delivery_internal(delivery.id) == delivery
    assert Webhooks.get_endpoint(legacy_project(), endpoint.id) == endpoint
    assert Webhooks.list_attempts(delivery) == history
    assert Repo.all(Oban.Job) == []
  end

  test "non-failed state takes precedence over inactive endpoint and exhausted cycles", %{
    actor: actor
  } do
    for status <- ~w(pending processing succeeded cancelled) do
      delivery = delivery_fixture(%{status: status, retry_cycle: 3})

      Webhooks.update_endpoint(
        legacy_project(),
        Webhooks.get_endpoint(legacy_project(), delivery.endpoint_id),
        %{active: false}
      )

      assert {:ok, %{request: %{reason: "state_not_failed"}}} =
               Webhooks.request_manual_retry(delivery.id, actor, @key <> status)

      assert Webhooks.get_delivery_internal(delivery.id) == delivery
    end

    assert Repo.all(Oban.Job) == []
  end

  test "missing delivery returns not_found without consuming the key", %{actor: actor} do
    assert {:error, :not_found} =
             Webhooks.request_manual_retry(9_223_372_036_854_775_807, actor, @key)

    assert_empty_audit_and_jobs()
    delivery = delivery_fixture()
    assert {:ok, %{replayed?: false}} = Webhooks.request_manual_retry(delivery.id, actor, @key)
  end

  test "invalid arguments fail before any database query", %{actor: actor} do
    delivery = delivery_fixture()
    observe_queries()

    for id <- [nil, 0, -1, "1", 1.0, %{}, 9_223_372_036_854_775_808] do
      assert {:error, :invalid_arguments} = Webhooks.request_manual_retry(id, actor, @key)
    end

    for invalid_actor <- [
          nil,
          %{},
          Map.from_struct(actor),
          "actor",
          :user,
          %{actor | subject: ""},
          %{actor | type: "admin"},
          %{actor | source: "web"},
          Map.put(actor, :token, "test-only-token")
        ] do
      assert {:error, :invalid_arguments} =
               Webhooks.request_manual_retry(delivery.id, invalid_actor, @key)
    end

    refute_received :manual_retry_database_query
    assert Webhooks.get_delivery_internal(delivery.id) == delivery
    assert_empty_audit_and_jobs()
  end

  test "invalid keys fail before any database query", %{actor: actor} do
    delivery = delivery_fixture()
    observe_queries()

    for key <- [
          nil,
          "",
          "short",
          String.duplicate("x", 129),
          "key with spaces!!",
          String.duplicate("é", 16),
          123,
          %{}
        ] do
      assert {:error, :invalid_idempotency_key} =
               Webhooks.request_manual_retry(delivery.id, actor, key)
    end

    refute_received :manual_retry_database_query
    assert_empty_audit_and_jobs()
  end

  test "accepted replay returns the original evidence after state and endpoint change", %{
    actor: actor
  } do
    delivery = delivery_fixture()

    assert {:ok, %{request: original, replayed?: false}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    pending = Webhooks.get_delivery_internal(delivery.id)

    Webhooks.update_endpoint(
      legacy_project(),
      Webhooks.get_endpoint(legacy_project(), delivery.endpoint_id),
      %{active: false}
    )

    jobs = Repo.all(Oban.Job)

    assert {:ok, %{request: ^original, replayed?: true}} =
             Webhooks.request_manual_retry(delivery.id, %{actor | source: "admin_cli"}, @key)

    assert Webhooks.get_delivery_internal(delivery.id) == pending
    assert Repo.all(Oban.Job) == jobs
    assert Repo.all(ManualRetryRequest) == [original]
    assert original.source == "api"
  end

  test "rejected replay preserves the first decision even after eligibility changes", %{
    actor: actor
  } do
    delivery = delivery_fixture()

    Webhooks.update_endpoint(
      legacy_project(),
      Webhooks.get_endpoint(legacy_project(), delivery.endpoint_id),
      %{active: false}
    )

    assert {:ok, %{request: original}} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    assert original.reason == "endpoint_inactive"

    Webhooks.update_endpoint(
      legacy_project(),
      Webhooks.get_endpoint(legacy_project(), delivery.endpoint_id),
      %{active: true}
    )

    assert {:ok, %{request: ^original, replayed?: true}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    assert Webhooks.get_delivery_internal(delivery.id) == delivery
    assert Repo.all(ManualRetryRequest) == [original]
    assert Repo.all(Oban.Job) == []
  end

  test "a fresh key after acceptance records the pending state", %{actor: actor} do
    delivery = delivery_fixture()
    assert {:ok, %{request: accepted}} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    pending = Webhooks.get_delivery_internal(delivery.id)
    jobs = Repo.all(Oban.Job)

    assert {:ok, %{request: rejected, replayed?: false}} =
             Webhooks.request_manual_retry(delivery.id, actor, "manual-retry-key-0002")

    assert rejected.outcome == "rejected"
    assert rejected.reason == "state_not_failed"
    assert rejected.observed_status == "pending"
    assert rejected.observed_retry_cycle == 1
    assert rejected.resulting_retry_cycle == nil
    assert Repo.get!(ManualRetryRequest, accepted.id) == accepted
    assert Repo.aggregate(ManualRetryRequest, :count) == 2
    assert Webhooks.get_delivery_internal(delivery.id) == pending
    assert Repo.all(Oban.Job) == jobs
  end

  test "the same actor's key cannot name a different delivery", %{actor: actor} do
    first = delivery_fixture()
    second = delivery_fixture()
    assert {:ok, %{request: original}} = Webhooks.request_manual_retry(first.id, actor, @key)
    jobs = Repo.all(Oban.Job)
    assert {:error, :idempotency_conflict} = Webhooks.request_manual_retry(second.id, actor, @key)
    assert Webhooks.get_delivery_internal(second.id) == second
    assert Repo.all(ManualRetryRequest) == [original]
    assert Repo.all(Oban.Job) == jobs
  end

  test "actor type and subject scope the key independently", %{actor: actor} do
    for scoped_actor <- [actor, %{actor | type: "user"}, %{actor | subject: "other-actor"}] do
      delivery = delivery_fixture()

      assert {:ok, %{request: %{outcome: "accepted"}, replayed?: false}} =
               Webhooks.request_manual_retry(delivery.id, scoped_actor, @key)
    end

    assert Repo.aggregate(ManualRetryRequest, :count) == 3
    assert Repo.aggregate(Oban.Job, :count) == 3
  end

  test "only the prepared digests reach persisted audit and job arguments", %{actor: actor} do
    delivery = delivery_fixture()
    assert {:ok, prepared} = ManualRetryIdempotency.prepare(delivery.id, @key)

    assert {:ok, %{request: request} = result} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    assert request.idempotency_key_digest == prepared.idempotency_key_digest
    assert request.request_fingerprint == prepared.request_fingerprint
    refute inspect(result, limit: :infinity) =~ @key

    refute inspect(Map.from_struct(Repo.get!(ManualRetryRequest, request.id)), limit: :infinity) =~
             @key

    assert [job] = Repo.all(Oban.Job)
    refute inspect(job.args) =~ @key
    refute inspect(job.args) =~ actor.subject
  end

  for state <- ~w(available scheduled executing retryable suspended) do
    @job_state state
    test "an active two-field legacy job in #{@job_state} rolls back acceptance", %{actor: actor} do
      delivery = delivery_fixture()

      job =
        insert_job(
          %{"delivery_id" => delivery.id, "attempt_number" => delivery.attempt_count + 1},
          @job_state
        )

      assert {:error, :active_job} = Webhooks.request_manual_retry(delivery.id, actor, @key)
      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Repo.all(ManualRetryRequest) == []
      assert Repo.all(Oban.Job) == [job]
    end
  end

  test "audit identity never enters Ecto query telemetry", %{actor: actor} do
    delivery = delivery_fixture()
    handler = "manual-retry-private-query-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:tidewake, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:manual_retry_query_metadata, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{request: request}} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    assert {:ok, %{replayed?: true}} = Webhooks.request_manual_retry(delivery.id, actor, @key)

    metadata =
      Stream.repeatedly(fn ->
        receive do
          {:manual_retry_query_metadata, metadata} -> metadata
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert metadata != []

    for query <- metadata do
      refute query.source == "manual_retry_requests"

      for protected <- [
            actor.type,
            actor.subject,
            actor.source,
            @key,
            request.idempotency_key_digest,
            request.request_fingerprint
          ] do
        refute protected in query.params
      end
    end
  end

  test "an active delivery-only legacy job cannot cross the cycle boundary", %{actor: actor} do
    delivery = delivery_fixture()
    job = insert_job(%{"delivery_id" => delivery.id})
    assert {:error, :active_job} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    assert Webhooks.get_delivery_internal(delivery.id) == delivery
    assert Repo.all(ManualRetryRequest) == []
    assert Repo.all(Oban.Job) == [job]
  end

  test "complete cycle job conflict rolls back audit and delivery and does not consume the key",
       %{actor: actor} do
    delivery = delivery_fixture()
    {:ok, conflict} = DeliverWebhookWorker.new_for_delivery(delivery.id, 7, 1, 1) |> Oban.insert()
    before = Repo.get!(Oban.Job, conflict.id)
    assert {:error, :active_job} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    assert Webhooks.get_delivery_internal(delivery.id) == delivery
    assert Repo.all(ManualRetryRequest) == []
    assert Repo.all(Oban.Job) == [before]
    conflict |> change(state: "completed", completed_at: DateTime.utc_now()) |> Repo.update!()

    assert {:ok, %{request: %{outcome: "accepted"}, replayed?: false}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)
  end

  test "completed, cancelled, discarded, stale and other-worker jobs are preserved", %{
    actor: actor
  } do
    delivery = delivery_fixture()
    args = %{"delivery_id" => delivery.id, "attempt_number" => 7}
    jobs = for state <- ~w(completed cancelled discarded), do: insert_job(args, state)
    stale = insert_job(%{"delivery_id" => delivery.id, "attempt_number" => 6})
    other = insert_job(args, "available", "UnrelatedWorker")
    cycle = insert_job(Map.merge(args, %{"retry_cycle" => 0, "cycle_attempt_number" => 1}))

    assert {:ok, %{request: %{outcome: "accepted"}}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    for job <- jobs ++ [stale, other, cycle], do: assert(Repo.get!(Oban.Job, job.id) == job)
    assert Repo.aggregate(Oban.Job, :count) == length(jobs) + 4
  end

  test "rejection does not turn an existing job into an active_job error", %{actor: actor} do
    delivery = delivery_fixture(%{status: "pending"})
    job = insert_job(%{"delivery_id" => delivery.id})

    assert {:ok, %{request: %{outcome: "rejected", reason: "state_not_failed"}}} =
             Webhooks.request_manual_retry(delivery.id, actor, @key)

    assert Repo.all(Oban.Job) == [job]
    assert Webhooks.get_delivery_internal(delivery.id) == delivery
  end

  for table <- ~w(manual_retry_requests deliveries oban_jobs) do
    @failure_table table
    test "a #{@failure_table} persistence failure leaves no partial acceptance", %{actor: actor} do
      delivery = delivery_fixture()
      history = Webhooks.list_attempts(delivery)
      # PostgreSQL DDL is transactional and removed by this synchronous test's sandbox.
      Repo.query!(
        "ALTER TABLE #{@failure_table} ADD CONSTRAINT reject_manual_retry_test CHECK (false) NOT VALID"
      )

      assert {:error, :persistence_error} =
               Webhooks.request_manual_retry(delivery.id, actor, @key)

      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Webhooks.list_attempts(delivery) == history
      assert_empty_audit_and_jobs()
      Repo.query!("ALTER TABLE #{@failure_table} DROP CONSTRAINT reject_manual_retry_test")
      assert {:ok, %{replayed?: false}} = Webhooks.request_manual_retry(delivery.id, actor, @key)
    end
  end

  @tag :unboxed
  test "concurrent reuse across deliveries resolves the unique-index winner", %{actor: actor} do
    # Separate committed connections are necessary to exercise PostgreSQL's
    # unique-index race; a shared sandbox connection would serialize both calls.
    actor = %{actor | subject: "race-actor-#{System.unique_integer([:positive])}"}

    [first, second] =
      Sandbox.unboxed_run(Repo, fn ->
        [delivery_fixture(), delivery_fixture()]
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = [first.id, second.id]

        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("(?->>'delivery_id')::bigint", job.args) in ^ids
          )
        )

        Repo.delete_all(
          from(request in ManualRetryRequest, where: request.actor_subject == ^actor.subject)
        )

        Repo.delete_all(
          from(attempt in Tidewake.Webhooks.Attempt, where: attempt.delivery_id in ^ids)
        )

        Repo.delete_all(from(delivery in Delivery, where: delivery.id in ^ids))

        Repo.delete_all(
          from(event in Tidewake.Webhooks.Event,
            where: event.id in ^[first.event_id, second.event_id]
          )
        )

        Repo.delete_all(
          from(endpoint in Tidewake.Webhooks.Endpoint,
            where: endpoint.id in ^[first.endpoint_id, second.endpoint_id]
          )
        )
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            # Both lookups can finish, but INSERTs wait for this table lock. Each
            # contender must observe no prior key before either can persist it.
            Repo.query!("LOCK TABLE manual_retry_requests IN SHARE MODE")

            tasks =
              for delivery <- [first, second] do
                Task.Supervisor.async_nolink(supervisor, fn ->
                  Sandbox.unboxed_run(Repo, fn ->
                    Process.put(:oban_testing, :manual)
                    Webhooks.request_manual_retry(delivery.id, actor, @key)
                  end)
                end)
              end

            await_blocked_manual_retry_inserts(System.monotonic_time(:millisecond) + 5_000)
            tasks
          end)

        tasks
      end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, %{replayed?: false}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :idempotency_conflict})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert [request] =
               Repo.all(
                 from(request in ManualRetryRequest,
                   where: request.actor_subject == ^actor.subject
                 )
               )

      winner = Enum.find([first, second], &(&1.id == request.delivery_id))
      loser = Enum.find([first, second], &(&1.id != request.delivery_id))
      assert request.outcome == "accepted"
      assert Webhooks.get_delivery_internal(winner.id).status == "pending"
      assert Webhooks.get_delivery_internal(loser.id) == loser

      assert Repo.aggregate(
               from(job in Oban.Job,
                 where:
                   fragment("(?->>'delivery_id')::bigint", job.args) in ^[first.id, second.id]
               ),
               :count
             ) == 1
    end)
  end

  defp await_blocked_manual_retry_inserts(deadline) do
    %{rows: [[waiting]]} =
      Repo.query!("""
      SELECT count(*) FROM pg_locks
      WHERE relation = 'manual_retry_requests'::regclass
        AND mode = 'RowExclusiveLock' AND NOT granted
      """)

    cond do
      waiting == 2 ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        await_blocked_manual_retry_inserts(deadline)

      true ->
        flunk("both audit inserts did not reach the PostgreSQL lock")
    end
  end

  defp actor do
    {:ok, actor} =
      ManualRetryActor.new(%{type: "service_account", subject: "opaque-actor-001", source: "api"})

    actor
  end

  defp delivery_fixture(overrides \\ %{}) do
    cycle = Map.get(overrides, :retry_cycle, 0)
    cycle_count = Map.get(overrides, :cycle_attempt_count, 6)

    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: "manual-retry-#{System.unique_integer([:positive])}",
        event_type: "order.created",
        payload: %{"immutable" => true}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Manual retry",
        url: "https://endpoint.invalid/webhook"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

    for prior_cycle <- 0..cycle,
        ordinal <- 1..if(prior_cycle == cycle, do: cycle_count, else: 6) do
      number = prior_cycle * 6 + ordinal
      next_at = if ordinal < 6, do: DateTime.add(@completed_at, ordinal, :second)

      assert {:ok, _attempt} =
               Webhooks.create_attempt(
                 %{delivery | retry_cycle: prior_cycle, cycle_attempt_count: ordinal - 1},
                 %{
                   attempt_number: number,
                   result: "http_error",
                   http_status: 503,
                   duration_ms: 1,
                   started_at: @completed_at,
                   completed_at: @completed_at,
                   next_attempt_at: next_at
                 }
               )
    end

    attrs =
      Map.merge(
        %{
          status: "failed",
          attempt_count: cycle * 6 + cycle_count,
          retry_cycle: cycle,
          cycle_attempt_count: cycle_count,
          completed_at: @completed_at
        },
        overrides
      )

    delivery |> Delivery.changeset(attrs) |> Repo.update!()
  end

  defp insert_job(args, state \\ "available", worker \\ nil) do
    Oban.Job.new(args, worker: worker || DeliverWebhookWorker)
    |> change(state: state)
    |> Repo.insert!()
    |> then(&Repo.get!(Oban.Job, &1.id))
  end

  defp assert_empty_audit_and_jobs do
    assert Repo.all(ManualRetryRequest) == []
    assert Repo.all(Oban.Job) == []
  end

  defp observe_queries do
    handler = "manual-retry-no-query-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:tidewake, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          send(parent, :manual_retry_database_query)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end

defmodule Tidewake.Webhooks.ManualRetryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Repo
  alias Tidewake.Webhooks

  alias Tidewake.Webhooks.{
    Attempt,
    Delivery,
    Endpoint,
    Event,
    ManualRetryActor,
    ManualRetryRequest
  }

  alias Tidewake.Workers.DeliverWebhookWorker

  @key "concurrent-manual-retry-key-0001"
  @other_key "concurrent-manual-retry-key-0002"
  @completed_at ~U[2026-10-20 10:00:00.123456Z]
  @barrier_timeout 10_000

  setup tags do
    # Oban checks the task's caller chain as well as the task's own mode.
    Process.put(:oban_testing, :manual)
    # Shared sandbox connections serialize queries before PostgreSQL can see a
    # race. As in ManualRetryTest, commit only these fixtures and give each task
    # its own unboxed checkout. Cleanup is restricted to this test's records.
    fixtures =
      Sandbox.unboxed_run(Repo, fn ->
        for _index <- 1..Map.get(tags, :delivery_count, 1) do
          delivery_fixture(Map.get(tags, :retry_cycle, 0))
        end
      end)

    on_exit(fn -> cleanup_fixtures(fixtures) end)
    {:ok, fixtures: fixtures, actor: actor()}
  end

  test "same delivery, actor and key converge on one accepted record and replay", %{
    fixtures: [fixture],
    actor: actor
  } do
    call = {fixture.delivery.id, actor, @key}
    results = concurrent_requests([call, call], :delivery)

    assert {:ok, %{request: original, replayed?: false}} =
             Enum.find(results, &match?({:ok, %{replayed?: false}}, &1))

    assert {:ok, %{request: ^original, replayed?: true}} =
             Enum.find(results, &match?({:ok, %{replayed?: true}}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      assert requests_for([fixture]) == [original]
      assert original.outcome == "accepted"
      assert original.reason == nil
      assert_single_transition(fixture)
    end)
  end

  test "different keys on one delivery produce one acceptance and one state rejection", %{
    fixtures: [fixture],
    actor: actor
  } do
    results =
      concurrent_requests(
        [
          {fixture.delivery.id, actor, @key},
          {fixture.delivery.id, actor, @other_key}
        ],
        :delivery
      )

    Sandbox.unboxed_run(Repo, fn ->
      {accepted, rejected} = assert_two_decisions(fixture, results)
      refute accepted.idempotency_key_digest == rejected.idempotency_key_digest
      assert accepted.actor_subject == rejected.actor_subject
    end)
  end

  @tag delivery_count: 2
  test "one actor's key across deliveries has one winner and no partial losing effects", %{
    fixtures: [first, second] = fixtures,
    actor: actor
  } do
    results =
      concurrent_requests(
        [
          {first.delivery.id, actor, @key},
          {second.delivery.id, actor, @key}
        ],
        :audit_insert
      )

    assert Enum.count(results, &(&1 == {:error, :idempotency_conflict})) == 1

    assert {:ok, %{request: request, replayed?: false}} =
             Enum.find(results, &match?({:ok, _}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      winner = Enum.find(fixtures, &(&1.delivery.id == request.delivery_id))
      loser = Enum.find(fixtures, &(&1.delivery.id != request.delivery_id))
      assert requests_for(fixtures) == [request]
      assert request.outcome == "accepted"
      assert_single_transition(winner)
      assert Webhooks.get_delivery(loser.delivery.id) == loser.delivery
      assert jobs_for([loser]) == []
      assert_history_unchanged(loser)
      assert length(jobs_for(fixtures)) == 1
    end)
  end

  for actor_dimension <- [:type, :subject] do
    @actor_dimension actor_dimension
    test "different actor #{@actor_dimension} scopes independently consume the same key", %{
      fixtures: [fixture],
      actor: first_actor
    } do
      second_actor =
        case @actor_dimension do
          :type -> actor(first_actor.subject, "user")
          :subject -> actor()
        end

      results =
        concurrent_requests(
          [
            {fixture.delivery.id, first_actor, @key},
            {fixture.delivery.id, second_actor, @key}
          ],
          :delivery
        )

      Sandbox.unboxed_run(Repo, fn ->
        {accepted, rejected} = assert_two_decisions(fixture, results)
        assert accepted.idempotency_key_digest == rejected.idempotency_key_digest
        assert accepted.request_fingerprint == rejected.request_fingerprint

        assert MapSet.new([
                 {accepted.actor_type, accepted.actor_subject},
                 {rejected.actor_type, rejected.actor_subject}
               ]) ==
                 MapSet.new([
                   {first_actor.type, first_actor.subject},
                   {second_actor.type, second_actor.subject}
                 ])
      end)
    end
  end

  @tag retry_cycle: 2
  test "two contenders at cycle two advance only once to the final cycle", %{
    fixtures: [fixture],
    actor: actor
  } do
    assert fixture.delivery.retry_cycle == 2

    results =
      concurrent_requests(
        [
          {fixture.delivery.id, actor, @key},
          {fixture.delivery.id, actor, @other_key}
        ],
        :delivery
      )

    Sandbox.unboxed_run(Repo, fn ->
      {accepted, rejected} = assert_two_decisions(fixture, results)
      assert accepted.observed_retry_cycle == 2
      assert accepted.resulting_retry_cycle == 3
      assert rejected.observed_retry_cycle == 3
      assert rejected.resulting_retry_cycle == nil
      assert Webhooks.get_delivery(fixture.delivery.id).retry_cycle == 3
      assert Enum.all?(requests_for([fixture]), &(&1.resulting_retry_cycle in [nil, 3]))
      assert [%{args: %{"retry_cycle" => 3, "attempt_number" => 19}}] = jobs_for([fixture])
    end)
  end

  defp concurrent_requests(calls, barrier_kind) do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    tasks =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            hold_database_barrier(calls, barrier_kind)
            %{rows: [[controller_backend]]} = Repo.query!("SELECT pg_backend_pid()")

            tasks = start_contenders(supervisor, calls, parent, barrier)
            backends = await_ready(tasks, barrier)

            assert length(Enum.uniq([controller_backend | backends])) == length(tasks) + 1
            Enum.each(tasks, &send(&1.pid, {barrier, :start}))

            await_database_waiters(
              backends,
              System.monotonic_time(:millisecond) + @barrier_timeout
            )

            tasks
          end)

        tasks
      end)

    # Await all replies and monitor shutdown before inspecting committed state.
    # The supervised tasks and unboxed_run's after block also release resources
    # if an assertion or a request fails.
    Enum.map(tasks, &Task.await(&1, @barrier_timeout))
  end

  defp start_contenders(supervisor, calls, parent, barrier) do
    Enum.map(calls, fn call ->
      Task.Supervisor.async_nolink(supervisor, fn ->
        run_request(call, parent, barrier)
      end)
    end)
  end

  defp await_ready(tasks, barrier) do
    Enum.map(tasks, fn task ->
      pid = task.pid
      assert_receive {^barrier, :ready, ^pid, backend}, @barrier_timeout
      backend
    end)
  end

  defp run_request({delivery_id, actor, key}, parent, barrier) do
    Sandbox.unboxed_run(Repo, fn ->
      Oban.Testing.with_testing_mode(:manual, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {barrier, :ready, self(), backend})

        receive do
          {^barrier, :start} -> Webhooks.request_manual_retry(delivery_id, actor, key)
        after
          @barrier_timeout -> flunk("request did not reach the start barrier")
        end
      end)
    end)
  end

  defp hold_database_barrier(calls, :delivery) do
    ids = calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    # Both commands must be waiting on the real delivery row lock before release.
    Repo.all(
      from(delivery in Delivery,
        where: delivery.id in ^ids,
        order_by: delivery.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp hold_database_barrier(_calls, :audit_insert) do
    # Different deliveries must both see an absent key. Hold INSERTs, while
    # allowing their lookups, so the unique index arbitrates after release.
    Repo.query!("LOCK TABLE manual_retry_requests IN SHARE MODE")
  end

  defp await_database_waiters(backends, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM unnest($1::integer[]) AS workers(pid)
        WHERE cardinality(pg_blocking_pids(pid)) > 0
        """,
        [backends]
      )

    cond do
      waiting == length(backends) -> :ok
      System.monotonic_time(:millisecond) < deadline -> await_database_waiters(backends, deadline)
      true -> flunk("both request connections did not reach the PostgreSQL lock barrier")
    end
  end

  defp assert_two_decisions(fixture, results) do
    requests =
      Enum.map(results, fn result ->
        assert {:ok, %{request: request, replayed?: false}} = result
        request
      end)

    assert Enum.sort_by(requests, & &1.id) == requests_for([fixture])
    assert Enum.sort(Enum.map(requests, & &1.outcome)) == ["accepted", "rejected"]
    accepted = Enum.find(requests, &(&1.outcome == "accepted"))
    rejected = Enum.find(requests, &(&1.outcome == "rejected"))
    assert accepted.observed_status == "failed"
    assert accepted.observed_retry_cycle == fixture.delivery.retry_cycle
    assert accepted.observed_completed_at == fixture.delivery.completed_at
    assert accepted.resulting_retry_cycle == fixture.delivery.retry_cycle + 1
    assert accepted.reason == nil
    assert rejected.reason == "state_not_failed"
    assert rejected.observed_status == "pending"
    assert rejected.observed_retry_cycle == accepted.resulting_retry_cycle
    assert rejected.observed_completed_at == nil
    assert rejected.resulting_retry_cycle == nil
    assert accepted.observed_attempt_count == fixture.delivery.attempt_count
    assert rejected.observed_attempt_count == fixture.delivery.attempt_count
    assert_single_transition(fixture)
    {accepted, rejected}
  end

  defp assert_single_transition(fixture) do
    delivery = fixture.delivery
    pending = Webhooks.get_delivery(delivery.id)
    assert pending.status == "pending"
    assert pending.retry_cycle == delivery.retry_cycle + 1
    assert pending.cycle_attempt_count == 0
    assert pending.attempt_count == delivery.attempt_count
    assert pending.completed_at == nil
    assert pending.next_attempt_at == nil
    assert pending.inserted_at == delivery.inserted_at
    assert [job] = jobs_for([fixture])
    assert job.worker == Oban.Worker.to_string(DeliverWebhookWorker)
    assert job.state == "available"
    assert job.max_attempts == 1

    assert job.args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => delivery.attempt_count + 1,
             "retry_cycle" => delivery.retry_cycle + 1,
             "cycle_attempt_number" => 1
           }

    assert_history_unchanged(fixture)
  end

  defp assert_history_unchanged(fixture) do
    assert Webhooks.list_attempts(fixture.delivery) == fixture.attempts
    assert Webhooks.get_event(fixture.event.id) == fixture.event
    assert Webhooks.get_endpoint(fixture.endpoint.id) == fixture.endpoint
  end

  defp requests_for(fixtures) do
    ids = Enum.map(fixtures, & &1.delivery.id)

    Repo.all(
      from(request in ManualRetryRequest,
        where: request.delivery_id in ^ids,
        order_by: request.id
      )
    )
  end

  defp jobs_for(fixtures) do
    ids = Enum.map(fixtures, & &1.delivery.id)

    Repo.all(
      from(job in Oban.Job,
        where: fragment("(?->>'delivery_id')::bigint", job.args) in ^ids,
        order_by: job.id
      )
    )
  end

  defp actor(subject \\ Ecto.UUID.generate(), type \\ "service_account") do
    {:ok, actor} = ManualRetryActor.new(%{type: type, subject: subject, source: "api"})
    actor
  end

  defp delivery_fixture(cycle) do
    {:ok, event} =
      Webhooks.create_event(%{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{"immutable" => true}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Concurrent retry",
        url: "https://endpoint.invalid/webhook"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

    for retry_cycle <- 0..cycle, ordinal <- 1..6 do
      assert {:ok, _attempt} =
               Webhooks.create_attempt(
                 %{delivery | retry_cycle: retry_cycle, cycle_attempt_count: ordinal - 1},
                 %{
                   attempt_number: retry_cycle * 6 + ordinal,
                   result: "http_error",
                   http_status: 503,
                   duration_ms: 1,
                   started_at: @completed_at,
                   completed_at: @completed_at,
                   next_attempt_at:
                     if(ordinal < 6, do: DateTime.add(@completed_at, ordinal, :second))
                 }
               )
    end

    delivery =
      delivery
      |> Delivery.changeset(%{
        status: "failed",
        attempt_count: (cycle + 1) * 6,
        retry_cycle: cycle,
        cycle_attempt_count: 6,
        completed_at: @completed_at
      })
      |> Repo.update!()

    %{
      delivery: delivery,
      attempts: Webhooks.list_attempts(delivery),
      event: event,
      endpoint: endpoint
    }
  end

  defp cleanup_fixtures(fixtures) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        ids = Enum.map(fixtures, & &1.delivery.id)
        event_ids = Enum.map(fixtures, & &1.event.id)
        endpoint_ids = Enum.map(fixtures, & &1.endpoint.id)

        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("(?->>'delivery_id')::bigint", job.args) in ^ids
          )
        )

        Repo.delete_all(from(request in ManualRetryRequest, where: request.delivery_id in ^ids))
        Repo.delete_all(from(attempt in Attempt, where: attempt.delivery_id in ^ids))
        Repo.delete_all(from(delivery in Delivery, where: delivery.id in ^ids))
        Repo.delete_all(from(event in Event, where: event.id in ^event_ids))
        Repo.delete_all(from(endpoint in Endpoint, where: endpoint.id in ^endpoint_ids))
      end)
    end)
  end
end

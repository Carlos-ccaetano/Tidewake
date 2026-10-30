defmodule Tidewake.Webhooks.ManualRetryAuthorizationTest do
  use Tidewake.DataCase, async: false

  alias Tidewake.{Projects, ProjectsFixtures, Webhooks}
  alias Tidewake.Projects.{Scope, ServiceAccount}

  alias Tidewake.Webhooks.{
    Attempt,
    Delivery,
    Endpoint,
    Event,
    ManualRetryActor,
    ManualRetryRequest
  }

  @key "authorized-manual-retry-key-0001"
  @opts [log: false, telemetry_event: nil]
  @decision_fields ~w(id delivery_id outcome reason requested_at resulting_retry_cycle)a

  setup do
    Process.put(:oban_testing, :manual)
    own = ProjectsFixtures.scope_fixture()
    foreign = ProjectsFixtures.scope_fixture()

    %{
      own: own,
      foreign: foreign,
      delivery: delivery_fixture(own.project),
      foreign_delivery: delivery_fixture(foreign.project)
    }
  end

  test "admin derives audit identity and v2 while returning only decision fields", context do
    %{own: own, delivery: delivery} = context

    assert {:ok, %{request: view, replayed?: false} = result} =
             Webhooks.request_manual_retry(own.scope, delivery.id, @key)

    assert Enum.sort(Map.keys(view)) == Enum.sort(@decision_fields)
    assert view.outcome == "accepted"
    audit = Repo.get!(ManualRetryRequest, view.id, @opts)
    assert audit.actor_type == "service_account"
    assert audit.actor_subject == own.account.public_id
    assert audit.source == "api"
    assert audit.request_fingerprint_version == 2

    assert {:ok, expected} =
             Webhooks.ManualRetryIdempotency.prepare(own.project.public_id, delivery.id, @key)

    assert audit.request_fingerprint == expected.request_fingerprint
    assert view == Map.take(audit, @decision_fields)
    assert_public_result(result, context)
    assert [%{args: args}] = Repo.all(Oban.Job, @opts)

    assert args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => 2,
             "retry_cycle" => 1,
             "cycle_attempt_number" => 1
           }
  end

  for role <- ~w(producer viewer) do
    test "#{role} is forbidden before any Repo query, regardless of target or key", context do
      scope = ProjectsFixtures.scope_fixture(unquote(role), context.own.project).scope
      before = snapshot()

      for id <- [context.delivery.id, context.foreign_delivery.id, 0, 9_223_372_036_854_775_807],
          key <- [@key, nil] do
        {result, calls} = observe_repo(fn -> Webhooks.request_manual_retry(scope, id, key) end)
        assert result == {:error, :forbidden}
        assert calls == []
      end

      assert snapshot() == before
    end
  end

  test "foreign and absent deliveries are identical even when the actor's key already exists",
       context do
    scope = context.own.scope
    assert {:ok, _} = Webhooks.request_manual_retry(scope, context.delivery.id, @key)
    before = snapshot()

    for id <- [context.foreign_delivery.id, 9_223_372_036_854_775_807] do
      assert Webhooks.request_manual_retry(scope, id, @key) == {:error, :not_found}
      assert snapshot() == before
    end
  end

  test "maps, incomplete structs, old actors and malformed Scope fields fail closed", context do
    scope = context.own.scope
    before = snapshot()

    for invalid <- [
          nil,
          %{},
          Map.from_struct(scope),
          struct(Scope),
          Map.delete(scope, :actor_subject),
          Map.put(scope, :token, "private-token"),
          %{scope | role: "owner"},
          %{scope | project_id: 0},
          %{scope | service_account_id: "1"},
          %{scope | actor_subject: "invalid"},
          %{scope | project_public_id: "123E4567-E89B-12D3-A456-426614174000"},
          %ManualRetryActor{type: "service_account", subject: scope.actor_subject, source: "api"}
        ] do
      {result, calls} =
        observe_repo(fn ->
          Webhooks.request_manual_retry(invalid, context.delivery.id, @key)
        end)

      assert result == {:error, :forbidden}
      assert calls == []
    end

    assert Webhooks.request_manual_retry(context.delivery.id, scope, @key) == {:error, :forbidden}
    assert snapshot() == before
  end

  test "well-shaped but mismatched identities are checked against persisted authority", context do
    %{own: own, foreign: foreign} = context
    before = snapshot()
    # Struct shape cannot prove provenance; persisted identity checks are additional defense.
    for scope <- [
          %{own.scope | actor_subject: foreign.scope.actor_subject},
          %{own.scope | service_account_id: foreign.scope.service_account_id},
          %{own.scope | project_id: foreign.scope.project_id},
          %{own.scope | project_public_id: foreign.scope.project_public_id},
          %{own.scope | service_account_id: 9_223_372_036_854_775_807}
        ] do
      assert Scope.valid?(scope)

      assert Webhooks.request_manual_retry(scope, context.delivery.id, @key) ==
               {:error, :forbidden}
    end

    producer = ProjectsFixtures.scope_fixture("producer", own.project).scope

    assert Webhooks.request_manual_retry(%{producer | role: "admin"}, context.delivery.id, @key) ==
             {:error, :forbidden}

    assert snapshot() == before
  end

  test "invalid input from an authorized Scope is rejected before locks or queries", context do
    before = snapshot()

    for key <- [nil, "short", "a key with spaces"] do
      {result, calls} =
        observe_repo(fn ->
          Webhooks.request_manual_retry(context.own.scope, context.delivery.id, key)
        end)

      assert result == {:error, :invalid_idempotency_key}
      assert calls == []
    end

    for id <- [nil, 0, -1, "1", 1.0, 9_223_372_036_854_775_808] do
      {result, calls} =
        observe_repo(fn ->
          Webhooks.request_manual_retry(context.own.scope, id, @key)
        end)

      assert result == {:error, :invalid_arguments}
      assert calls == []
    end

    assert snapshot() == before
  end

  for state <- [:disabled_account, :suspended_project, :persisted_role] do
    test "#{state} denies a stale Scope before first decision or replay", context do
      %{own: own, delivery: delivery} = context
      assert {:ok, _} = Webhooks.request_manual_retry(own.scope, delivery.id, @key)

      case unquote(state) do
        :disabled_account ->
          assert {:ok, _} = Projects.disable_service_account(own.account, DateTime.utc_now())

        :suspended_project ->
          assert {:ok, _} = Projects.suspend_project(own.project, DateTime.utc_now())

        :persisted_role ->
          assert {1, _} =
                   Repo.update_all(
                     from(a in ServiceAccount, where: a.id == ^own.account.id),
                     [set: [role: "viewer"]],
                     @opts
                   )
      end

      before = snapshot()

      for key <- [@key, @key <> "-fresh"] do
        assert Webhooks.request_manual_retry(own.scope, delivery.id, key) == {:error, :forbidden}
        assert snapshot() == before
      end

      case Scope.authenticate(own.issued.token, DateTime.utc_now()) do
        {:ok, refreshed} ->
          assert Webhooks.request_manual_retry(refreshed, delivery.id, @key) ==
                   {:error, :forbidden}

        {:error, :invalid_credential} ->
          :ok
      end
    end
  end

  test "replay rechecks functional permission and creates no further effects", context do
    %{own: own, delivery: delivery} = context
    assert {:ok, first} = Webhooks.request_manual_retry(own.scope, delivery.id, @key)
    before = snapshot()

    for role <- ~w(producer viewer) do
      assert Webhooks.request_manual_retry(%{own.scope | role: role}, delivery.id, @key) ==
               {:error, :forbidden}

      assert snapshot() == before
    end

    assert {:ok, replay} = Webhooks.request_manual_retry(own.scope, delivery.id, @key)
    assert replay == %{first | replayed?: true}
    assert snapshot() == before
    assert_public_result(replay, context)
  end

  test "credential rotation preserves actor subject and the same replay", context do
    %{own: own, delivery: delivery} = context
    assert {:ok, first} = Webhooks.request_manual_retry(own.scope, delivery.id, @key)

    assert {:ok, issued} =
             Projects.issue_credential(own.account, DateTime.add(DateTime.utc_now(), 3600))

    assert {:ok, refreshed} = Scope.authenticate(issued.token, DateTime.utc_now())

    assert {:ok, _} =
             Projects.revoke_credential(
               own.account,
               own.issued.credential.public_id,
               DateTime.utc_now()
             )

    assert Scope.authenticate(own.issued.token, DateTime.utc_now()) ==
             {:error, :invalid_credential}

    before = snapshot()
    assert {:ok, replay} = Webhooks.request_manual_retry(refreshed, delivery.id, @key)
    assert replay == %{first | replayed?: true}
    assert snapshot() == before
  end

  test "rejected decisions and replays also respect the public allowlist", context do
    %{own: own, delivery: delivery} = context

    assert {:ok, _} =
             Webhooks.update_endpoint(
               own.project,
               Webhooks.get_endpoint(own.project, delivery.endpoint_id),
               %{active: false}
             )

    assert {:ok, first} = Webhooks.request_manual_retry(own.scope, delivery.id, @key)
    assert first.request.outcome == "rejected"
    assert first.request.reason == "endpoint_inactive"
    assert first.request.resulting_retry_cycle == nil
    assert Enum.sort(Map.keys(first.request)) == Enum.sort(@decision_fields)
    assert_public_result(first, context)
    before = snapshot()
    assert {:ok, replay} = Webhooks.request_manual_retry(own.scope, delivery.id, @key)
    assert replay == %{first | replayed?: true}
    assert snapshot() == before
  end

  test "Repo observer detects a real query as a positive control", _context do
    {_rows, calls} = observe_repo(fn -> Repo.all(Endpoint, @opts) end)
    assert :prepare_query in calls
  end

  defp assert_public_result(result, context) do
    serialized = inspect(result, limit: :infinity)

    for identity <- [context.own, context.foreign],
        secret <- [
          identity.issued.token,
          identity.issued.credential.public_id,
          identity.scope.actor_subject,
          identity.project.public_id,
          @key
        ] do
      leaked = String.contains?(serialized, secret)
      refute leaked, "public decision exposed authentication or idempotency data"
    end

    for field <-
          ~w(project_id service_account_id credential_id idempotency_key_digest request_fingerprint) do
      refute serialized =~ field
    end
  end

  defp snapshot do
    Enum.map([Delivery, ManualRetryRequest, Oban.Job, Attempt, Endpoint, Event], fn schema ->
      Repo.all(from(row in schema, order_by: row.id), @opts)
    end)
  end

  defp delivery_fixture(project) do
    {:ok, event} =
      Webhooks.create_event(project, %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{"private" => true}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(project, %{
        name: "Retry boundary",
        url: "https://endpoint.invalid/private"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    completed = DateTime.add(DateTime.utc_now(), -60)

    {:ok, _} =
      Webhooks.create_attempt(delivery, %{
        attempt_number: 1,
        result: "transport_error",
        duration_ms: 0,
        started_at: completed,
        completed_at: completed
      })

    delivery
    |> Delivery.changeset(%{
      status: "failed",
      attempt_count: 1,
      cycle_attempt_count: 1,
      completed_at: completed
    })
    |> Repo.update!(@opts)
  end

  defp observe_repo(fun) do
    supervisor = start_supervised!(Task.Supervisor, id: make_ref())
    collector = Task.Supervisor.async_nolink(supervisor, fn -> collect_calls([]) end)

    patterns = [
      {Repo, :prepare_query, 3},
      {Repo, :insert, 2},
      {Repo, :update, 2},
      {Repo, :delete, 2},
      {Repo, :insert_all, 3},
      {Repo, :update_all, 3},
      {Repo, :delete_all, 2},
      {Repo, :query, 3}
    ]

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call, {:tracer, collector.pid}])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^barrier}, 5_000
      send(collector.pid, :finish)
      {result, Task.await(collector)}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, {Repo, function, _args}} -> collect_calls([function | calls])
      :finish -> Enum.reverse(calls)
    end
  end
end

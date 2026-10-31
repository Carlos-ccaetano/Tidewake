defmodule Tidewake.Webhooks.ManualRetryAuditTest do
  use Tidewake.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Tidewake.ProjectsFixtures, only: [scope_fixture: 0, scope_fixture: 2]

  import Tidewake.WebhooksFixtures,
    only: [manual_retry_audit_fixture: 1, manual_retry_audit_fixture: 2]

  alias Tidewake.{Projects, Repo, Webhooks}
  alias Tidewake.Projects.ManualRetryRateLimit

  @fields ~w(id delivery_id outcome reason requested_at resulting_retry_cycle actor_type actor_subject source)a
  @opts [log: false, telemetry_event: nil]

  setup do
    identity = scope_fixture()
    Map.put(identity, :delivery, delivery_fixture(identity.project))
  end

  test "selects only snapshots for the scoped delivery as plain maps", ctx do
    own = manual_retry_audit_fixture(ctx.delivery)
    other_delivery = delivery_fixture(ctx.project)
    manual_retry_audit_fixture(other_delivery)
    foreign = scope_fixture()
    foreign_delivery = delivery_fixture(foreign.project)
    manual_retry_audit_fixture(foreign_delivery)
    assert {:ok, %{data: [row], page: %{next_before_id: nil}}} = list(ctx)
    assert row == Map.take(own, @fields)
    refute is_struct(row)
    assert Enum.sort(Map.keys(row)) == Enum.sort(@fields)
    assert Repo.all(ManualRetryRateLimit, @opts) == []
  end

  test "foreign and absent deliveries are identical and never query audit", ctx do
    foreign = scope_fixture()
    delivery = delivery_fixture(foreign.project)
    manual_retry_audit_fixture(delivery)

    for id <- [delivery.id, 9_223_372_036_854_775_807] do
      {result, queries} =
        observe_queries(fn -> Webhooks.list_manual_retry_audit(ctx.scope, id) end)

      assert result == {:error, :not_found}
      assert queries == ["service_accounts", "deliveries"]
    end
  end

  test "observer sees protected audit queries on a permitted read", ctx do
    manual_retry_audit_fixture(ctx.delivery)
    {{:ok, _page}, queries} = observe_queries(fn -> list(ctx) end)
    assert queries == ["service_accounts", "deliveries", "manual_retry_requests"]
  end

  test "producer and viewer fail before any database query", ctx do
    for role <- ~w(producer viewer) do
      identity = scope_fixture(role, ctx.project)

      {result, queries} =
        observe_queries(fn ->
          Webhooks.list_manual_retry_audit(identity.scope, ctx.delivery.id)
        end)

      assert result == {:error, :forbidden}
      assert queries == []
    end
  end

  test "untrusted shapes and unknown roles fail closed before queries", ctx do
    for scope <- [nil, Map.from_struct(ctx.scope), %{ctx.scope | role: "owner"}] do
      {result, queries} =
        observe_queries(fn -> Webhooks.list_manual_retry_audit(scope, ctx.delivery.id) end)

      assert result == {:error, :forbidden}
      assert queries == []
    end
  end

  test "stale disabled account is denied by persisted authority", ctx do
    {:ok, _account} = Projects.disable_service_account(ctx.account, DateTime.utc_now())
    assert list(ctx) == {:error, :forbidden}
  end

  test "stale suspended project is denied by persisted authority", ctx do
    {:ok, _project} = Projects.suspend_project(ctx.project, DateTime.utc_now())
    assert list(ctx) == {:error, :forbidden}
  end

  test "mismatched authority cannot choose another project", ctx do
    other = scope_fixture()

    scope = %{
      ctx.scope
      | project_id: other.project.id,
        project_public_id: other.project.public_id
    }

    assert Webhooks.list_manual_retry_audit(scope, ctx.delivery.id) == {:error, :forbidden}
  end

  test "invalid normalized options and IDs are rejected before querying", ctx do
    for options <- [
          %{},
          %{limit: 0, before_id: nil},
          %{limit: 101, before_id: nil},
          %{limit: "1", before_id: nil},
          %{limit: 1, before_id: 0},
          %{limit: 1, before_id: -1},
          %{limit: 1, before_id: "1"},
          %{limit: 1, before_id: 9_223_372_036_854_775_808},
          %{limit: 1, before_id: nil, extra: true},
          [limit: 1, before_id: nil]
        ] do
      {result, queries} = observe_queries(fn -> list(ctx, options) end)
      assert result == {:error, :invalid_arguments}
      assert queries == []
    end

    for id <- [nil, "1", 0, -1, 9_223_372_036_854_775_808] do
      assert Webhooks.list_manual_retry_audit(ctx.scope, id) == {:error, :invalid_arguments}
    end
  end

  test "default page is fifty and only lookahead creates a continuation", ctx do
    rows = for _ <- 1..51, do: manual_retry_audit_fixture(ctx.delivery)
    assert {:ok, %{data: data, page: %{next_before_id: cursor}}} = list(ctx)
    assert Enum.map(data, & &1.id) == rows |> Enum.reverse() |> Enum.take(50) |> Enum.map(& &1.id)
    assert cursor == List.last(data).id

    assert {:ok, %{data: [last], page: %{next_before_id: nil}}} =
             list(ctx, %{limit: 50, before_id: cursor})

    assert last.id == hd(rows).id
  end

  test "maximum page is one hundred without clamping; reads one extra row", ctx do
    rows = for _ <- 1..101, do: manual_retry_audit_fixture(ctx.delivery)

    assert {:ok, %{data: data, page: %{next_before_id: cursor}}} =
             list(ctx, %{limit: 100, before_id: nil})

    assert length(data) == 100
    assert cursor == Enum.at(rows, 1).id

    assert {:ok, %{data: [last], page: %{next_before_id: nil}}} =
             list(ctx, %{limit: 100, before_id: cursor})

    assert last.id == hd(rows).id
  end

  test "exclusive cursor visits a stable history once without gaps", ctx do
    rows = for _ <- 1..5, do: manual_retry_audit_fixture(ctx.delivery)
    assert {:ok, first} = list(ctx, %{limit: 2, before_id: nil})
    assert {:ok, second} = list(ctx, %{limit: 2, before_id: first.page.next_before_id})
    assert {:ok, third} = list(ctx, %{limit: 2, before_id: second.page.next_before_id})
    assert third.page.next_before_id == nil

    assert Enum.map(first.data ++ second.data ++ third.data, & &1.id) ==
             Enum.map(Enum.reverse(rows), & &1.id)
  end

  test "empty and exactly full final pages have null cursor", ctx do
    assert list(ctx) == {:ok, %{data: [], page: %{next_before_id: nil}}}
    for _ <- 1..3, do: manual_retry_audit_fixture(ctx.delivery)

    assert {:ok, %{data: data, page: %{next_before_id: nil}}} =
             list(ctx, %{limit: 3, before_id: nil})

    assert length(data) == 3

    assert list(ctx, %{limit: 3, before_id: 1}) ==
             {:ok, %{data: [], page: %{next_before_id: nil}}}
  end

  test "new rows after page one do not change its continuation", ctx do
    rows = for _ <- 1..4, do: manual_retry_audit_fixture(ctx.delivery)
    assert {:ok, first} = list(ctx, %{limit: 2, before_id: nil})
    newer = manual_retry_audit_fixture(ctx.delivery)
    assert {:ok, second} = list(ctx, %{limit: 2, before_id: first.page.next_before_id})

    assert Enum.map(second.data, & &1.id) ==
             rows |> Enum.take(2) |> Enum.reverse() |> Enum.map(& &1.id)

    refute newer.id in Enum.map(second.data, & &1.id)
    assert second.page.next_before_id == nil
  end

  test "historical v1 and v2 attribution is read without replacing snapshots", ctx do
    actor = scope_fixture("admin", ctx.project)

    first =
      manual_retry_audit_fixture(ctx.delivery, %{
        actor_subject: actor.account.public_id,
        source: "admin_cli"
      })

    second =
      manual_retry_audit_fixture(ctx.delivery, %{
        actor_type: "user",
        actor_subject: "retired-opaque-user",
        source: "liveview",
        request_fingerprint_version: 2,
        outcome: "accepted",
        reason: nil,
        observed_status: "failed",
        resulting_retry_cycle: 1,
        requested_at: ~U[2026-10-25 10:00:00.123456Z]
      })

    {:ok, _} = Projects.disable_service_account(actor.account, DateTime.utc_now())
    Repo.update!(Ecto.Changeset.change(actor.account, name: "Changed"), @opts)
    assert {:ok, %{data: data}} = list(ctx)
    assert data == Enum.map([second, first], &Map.take(&1, @fields))
  end

  test "supports the named cursor index and preserves the historical index" do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
        ["manual_retry_requests_delivery_id_cursor_index"],
        @opts
      )

    assert definition =~ "(delivery_id, id DESC)"

    %{rows: [[1]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
        ["manual_retry_requests_delivery_inserted_at_index"],
        @opts
      )
  end

  test "storage failure returns a bounded error and recovery permits reading", ctx do
    Repo.query!("ALTER TABLE manual_retry_requests RENAME TO audit_read_failure", [], @opts)

    try do
      assert list(ctx) == {:error, :persistence_error}
    after
      Repo.query!("ALTER TABLE audit_read_failure RENAME TO manual_retry_requests", [], @opts)
    end

    assert {:ok, _page} = list(ctx)
  end

  test "reading does not emit protected queries or log correlation material", ctx do
    audit = manual_retry_audit_fixture(ctx.delivery)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:tidewake, :repo, :query], &__MODULE__.query_event/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive :query_event
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs = capture_log(fn -> assert {:ok, _page} = list(ctx) end)

      for value <- [
            ctx.issued.token,
            ctx.account.public_id,
            ctx.project.public_id,
            audit.actor_subject,
            audit.idempotency_key_digest,
            audit.request_fingerprint
          ] do
        refute logs =~ value
      end

      refute_received :query_event
    after
      Logger.configure(level: level)
    end
  end

  def query_event(_event, _measurements, _metadata, parent) do
    if self() == parent, do: send(parent, :query_event)
  end

  defp list(ctx, options \\ %{limit: 50, before_id: nil}),
    do: Webhooks.list_manual_retry_audit(ctx.scope, ctx.delivery.id, options)

  defp delivery_fixture(project) do
    {:ok, event} =
      Webhooks.create_event(project, %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(project, %{name: "Audit", url: "https://endpoint.invalid/private"})

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end

  defp observe_queries(fun) do
    supervisor = start_supervised!(Task.Supervisor, id: make_ref())
    collector = Task.Supervisor.async_nolink(supervisor, fn -> collect_queries([]) end)
    :erlang.trace_pattern({Repo, :prepare_query, 3}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, collector.pid}])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^barrier}, 5000
      send(collector.pid, :finish)
      {result, Task.await(collector)}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Repo, :prepare_query, 3}, false, [:local])
    end
  end

  defp collect_queries(queries) do
    receive do
      {:trace, _pid, :call, {Repo, :prepare_query, [_operation, query, _opts]}} ->
        {source, _schema} = query.from.source
        collect_queries([source | queries])

      :finish ->
        Enum.reverse(queries)
    end
  end
end

defmodule Tidewake.Webhooks.ProjectOwnershipTest do
  use Tidewake.DataCase, async: false

  alias Tidewake.Projects
  alias Tidewake.Projects.Scope
  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Delivery, Endpoint, Event}

  @opts [log: false, telemetry_event: nil]
  @event %{external_id: "shared-external-id", event_type: "order.created", payload: %{}}
  @endpoint %{name: "Consumer", url: "https://endpoint.invalid/webhook"}

  setup do
    {:ok, first} = Projects.create_project(%{name: "First", slug: "ownership-first"})
    {:ok, second} = Projects.create_project(%{name: "Second", slug: "ownership-second"})
    %{first: first, second: second}
  end

  test "endpoint CRUD scopes queries, reloads supplied records and never transfers ownership",
       %{first: first, second: second} do
    {:ok, own} = Webhooks.create_endpoint(first, Map.put(@endpoint, :project_id, second.id))
    {:ok, foreign} = Webhooks.create_endpoint(second, @endpoint)
    assert own.project_id == first.id
    assert Webhooks.list_endpoints(first) == [own]
    assert Webhooks.list_active_endpoints(second) == [foreign]
    assert Webhooks.get_endpoint(first, foreign.id) == nil
    assert Webhooks.get_endpoint(first, -1) == nil
    assert Webhooks.update_endpoint(first, foreign, %{name: "Stolen"}) == {:error, :not_found}
    assert Webhooks.delete_endpoint(first, foreign) == {:error, :not_found}
    assert Webhooks.change_endpoint(first, foreign) == {:error, :not_found}

    assert {:ok, updated} =
             Webhooks.update_endpoint(first, %{own | project_id: second.id}, %{
               project_id: second.id,
               name: "Updated",
               active: false
             })

    assert updated.project_id == first.id
    assert updated.name == "Updated"
    assert Webhooks.list_active_endpoints(first) == []
    assert Webhooks.get_endpoint(second, foreign.id) == foreign
    assert {:ok, _} = Webhooks.delete_endpoint(first, updated)
    assert Webhooks.get_endpoint(first, own.id) == nil
  end

  test "event identity and lookups are local to the trusted project", %{
    first: first,
    second: second
  } do
    {:ok, own} = Webhooks.create_event(first, Map.put(@event, :project_id, second.id))
    {:ok, foreign} = Webhooks.create_event(second, @event)
    assert own.project_id == first.id
    assert {:error, changeset} = Webhooks.create_event(first, @event)
    assert errors_on(changeset).external_id == ["has already been taken"]
    assert Webhooks.get_event_by_external_id(first, @event.external_id) == own
    assert Webhooks.get_event_by_external_id(second, @event.external_id) == foreign
    assert Webhooks.get_event(first, foreign.id) == nil
    assert Webhooks.get_event(first, -1) == nil
  end

  test "ingestion fans out only within the authenticated scope and keeps job identity unchanged",
       %{first: first, second: second} do
    {:ok, endpoint} = Webhooks.create_endpoint(first, @endpoint)
    {:ok, inactive} = Webhooks.create_endpoint(first, Map.put(@endpoint, :active, false))
    {:ok, foreign_endpoint} = Webhooks.create_endpoint(second, @endpoint)
    {:ok, account} = Projects.create_service_account(first, "admin", %{name: "Service"})
    {:ok, issued} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))
    {:ok, scope} = Scope.authenticate(issued.token, DateTime.utc_now())

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{event: event, deliveries: [delivery], jobs: [job]}} =
               Webhooks.ingest_event(scope, Map.put(@event, :project_id, second.id))

      assert event.project_id == first.id
      assert delivery.project_id == first.id
      assert delivery.event_id == event.id
      assert delivery.endpoint_id == endpoint.id

      assert Enum.sort(Map.keys(job.args)) ==
               ~w(attempt_number cycle_attempt_number delivery_id retry_cycle)

      assert job.args["delivery_id"] == delivery.id
      assert Webhooks.get_delivery(scope, delivery.id) == delivery
      assert Webhooks.get_delivery(second, delivery.id) == nil
      assert Webhooks.list_deliveries_for_event(second, event) == []
      assert Webhooks.list_deliveries_for_event(scope, event) == [delivery]
      assert Webhooks.get_delivery_by_event_and_endpoint(event, inactive) == nil
      assert Webhooks.get_delivery_by_event_and_endpoint(event, foreign_endpoint) == nil
      assert {:error, _} = Webhooks.ingest_event(scope, @event)
      assert Repo.aggregate(Delivery, :count) == 1
      assert Repo.aggregate(Oban.Job, :count) == 1
    end)
  end

  test "database rejects cross-project scheduling and direct delivery inserts",
       %{first: first, second: second} do
    {:ok, event} = Webhooks.create_event(first, @event)
    {:ok, own} = Webhooks.create_endpoint(first, @endpoint)
    {:ok, foreign} = Webhooks.create_endpoint(second, @endpoint)
    assert {:error, changeset} = Webhooks.create_delivery(event, foreign)
    assert errors_on(changeset).endpoint_id == ["does not exist"]

    sql = """
    INSERT INTO deliveries (event_id, endpoint_id, project_id, inserted_at, updated_at)
    VALUES ($1, $2, $3, timezone('UTC', now()), timezone('UTC', now()))
    """

    assert_constraint(
      sql,
      [event.id, foreign.id, first.id],
      :foreign_key_violation,
      "deliveries_endpoint_id_fkey"
    )

    assert_constraint(
      sql,
      [event.id, foreign.id, second.id],
      :foreign_key_violation,
      "deliveries_event_id_fkey"
    )

    assert_constraint(
      sql,
      [event.id, own.id, second.id],
      :foreign_key_violation,
      "deliveries_event_id_fkey"
    )

    assert Repo.aggregate(Delivery, :count) == 0

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:error, :delivery, _, _} = Webhooks.schedule_delivery(event, foreign)
      assert Repo.aggregate(Oban.Job, :count) == 0
    end)

    assert {:ok, delivery} = Webhooks.create_delivery(event, own)
    assert delivery.project_id == first.id
  end

  test "ownership is required, not cast from client attributes and immutable through changesets",
       %{first: first, second: second} do
    for {schema, attrs} <- [
          {Endpoint, @endpoint},
          {Event, @event},
          {Delivery, %{status: "pending", event_id: 1, endpoint_id: 2}}
        ] do
      empty = struct(schema)
      changeset = schema.changeset(empty, Map.put(attrs, :project_id, first.id))
      assert errors_on(changeset).project_id == ["can't be blank"]
      refute Map.has_key?(changeset.changes, :project_id)

      existing = struct(schema, project_id: first.id)
      attempted = schema.changeset(existing, %{project_id: second.id})
      assert Ecto.Changeset.get_field(attempted, :project_id) == first.id
      refute Map.has_key?(attempted.changes, :project_id)
      assert schema.__schema__(:association, :project).related == Tidewake.Projects.Project
    end
  end

  test "PostgreSQL enforces ownership nullability, project references and restrictive deletes",
       %{first: first} do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name, is_nullable FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name = 'project_id'
          AND table_name IN ('endpoints', 'events', 'deliveries') ORDER BY table_name
        """,
        [],
        @opts
      )

    assert rows == [["deliveries", "NO"], ["endpoints", "NO"], ["events", "NO"]]

    sql = """
    INSERT INTO endpoints (name, url, active, project_id, inserted_at, updated_at)
    VALUES ('Consumer', 'https://endpoint.invalid/', true, $1, now(), now())
    """

    assert_constraint(sql, [nil], :not_null_violation, nil)
    assert_constraint(sql, [-1], :foreign_key_violation, "endpoints_project_id_fkey")
    {:ok, _} = Webhooks.create_endpoint(first, @endpoint)

    assert_constraint(
      "DELETE FROM projects WHERE id = $1",
      [first.id],
      :foreign_key_violation,
      "endpoints_project_id_fkey"
    )
  end

  test "missing or arbitrary project input never falls back to legacy" do
    for input <- [nil, %{}, %{project_id: 1}, 1] do
      assert_raise ArgumentError, "Trusted project context required", fn ->
        Webhooks.create_event(input, @event)
      end

      assert_raise ArgumentError, "Trusted project context required", fn ->
        Webhooks.list_endpoints(input)
      end
    end
  end

  defp assert_constraint(sql, params, code, name) do
    assert {:error, %Postgrex.Error{postgres: details}} =
             Repo.query(sql, params, Keyword.put(@opts, :mode, :savepoint))

    assert details.code == code
    if name, do: assert(details.constraint == name)
  end
end

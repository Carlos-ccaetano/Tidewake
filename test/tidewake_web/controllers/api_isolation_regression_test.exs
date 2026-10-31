defmodule TidewakeWeb.ApiIsolationRegressionTest do
  use TidewakeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Tidewake.{Projects, Repo, Webhooks}
  alias Tidewake.Projects.ApiCredential
  alias Tidewake.Webhooks.{Delivery, Endpoint, Event}
  alias TidewakeWeb.{EndpointController, EventController, ManualRetryRequestController}

  @opts [log: false, telemetry_event: nil]
  @roles ~w(admin producer viewer)
  @absent_id 9_223_372_036_854_775_807
  # method, path, controller, action, permission, scoped lookup, status, allowed roles
  @routes [
    {:get, "/api/endpoints", EndpointController, :index, :resources_read, :endpoint_list, 200,
     @roles},
    {:get, "/api/endpoints/:id", EndpointController, :show, :resources_read, :endpoint, 200,
     @roles},
    {:get, "/api/events/:id", EventController, :show, :resources_read, :event, 200, @roles},
    {:get, "/api/events/:id/deliveries", EventController, :deliveries, :resources_read,
     :event_deliveries, 200, @roles},
    {:post, "/api/events", EventController, :create, :events_write, :event_create, 201,
     ~w(admin producer)},
    {:post, "/api/endpoints", EndpointController, :create, :endpoints_write, :endpoint_create,
     201, ~w(admin)},
    {:patch, "/api/endpoints/:id", EndpointController, :update, :endpoints_write, :endpoint, 200,
     ~w(admin)}
  ]

  setup do
    projects = Enum.map(["A", "B"], &project_fixture/1)
    [first, second] = projects
    refute first.project.id == second.project.id
    refute first.project.public_id == second.project.public_id
    supervisor = start_supervised!(Task.Supervisor)
    %{projects: projects, observer_supervisor: supervisor}
  end

  for {method, path, controller, _action, _permission, lookup, status, roles} <- @routes,
      role <- @roles do
    test "#{role} #{method} #{path} isolates both projects", context do
      [first, second] = context.projects

      Oban.Testing.with_testing_mode(:manual, fn ->
        for {own, foreign} <- [{first, second}, {second, first}] do
          identity = own.identities[unquote(role)]
          before = snapshot()

          for token <- [nil, "invalid-token"] do
            {response, observations} =
              observe(context, fn ->
                request(own, foreign, unquote(method), unquote(path), token)
              end)

            assert_failure(response, 401, context.projects)
            assert observations == []
            assert snapshot() == before
          end

          foreign_before = project_snapshot(foreign.project.id)

          {response, observations} =
            observe(context, fn ->
              request(own, foreign, unquote(method), unquote(path), identity.issued.token)
            end)

          if unquote(role in roles) do
            data = json_response(response, unquote(status))["data"]
            assert {:controller, unquote(controller)} in observations
            assert response.assigns.current_scope.project_id == own.project.id
            assert_result(unquote(lookup), unquote(method), data, own)
            assert_private(response, context.projects)

            if unquote(method) == :get, do: assert(snapshot() == before)

            if unquote(lookup) == :event_create do
              after_create = snapshot()

              duplicate =
                request(own, foreign, unquote(method), unquote(path), identity.issued.token)

              assert json_response(duplicate, 409) == %{
                       "error" => %{
                         "code" => "external_id_conflict",
                         "message" => "An event with this external_id already exists"
                       }
                     }

              assert_private(duplicate, context.projects)
              assert snapshot() == after_create
            end
          else
            assert_failure(response, 403, context.projects)
            assert observations == []
            assert snapshot() == before
          end

          assert project_snapshot(foreign.project.id) == foreign_before

          if String.contains?(unquote(path), ":id") do
            before_cross = snapshot()

            responses =
              for target_id <- [resource_id(foreign, unquote(lookup)), @absent_id] do
                {response, observations} =
                  observe(context, fn ->
                    request(
                      own,
                      foreign,
                      unquote(method),
                      unquote(path),
                      identity.issued.token,
                      target_id
                    )
                  end)

                if unquote(role in roles) do
                  assert json_response(response, 404)["error"]["code"] == "not_found"
                else
                  assert_failure(response, 403, context.projects)
                  assert observations == []
                end

                assert_private(response, context.projects)
                response
              end

            [foreign_response, absent_response] = responses
            assert public_response(foreign_response) == public_response(absent_response)
            assert snapshot() == before_cross
          end
        end
      end)
    end
  end

  for state <- [:disabled, :revoked, :expired, :suspended, :removed_shared] do
    test "#{state} stops before controller and business queries on every route", context do
      [first, second] = context.projects

      for {own, foreign} <- [{first, second}, {second, first}] do
        identity = own.identities["admin"]
        token = invalidate(unquote(state), identity)
        before = snapshot()

        for {method, path, _controller, _action, _permission, _lookup, _status, _roles} <- @routes do
          {response, observations} =
            observe(context, fn -> request(own, foreign, method, path, token) end)

          assert_failure(response, 401, context.projects)
          assert observations == []
          assert snapshot() == before
        end
      end
    end
  end

  test "observer detects business queries even with SQL telemetry disabled", context do
    [own, foreign] = context.projects

    {response, observations} =
      observe(context, fn ->
        request(own, foreign, :get, "/api/endpoints", own.identities["viewer"].issued.token)
      end)

    assert json_response(response, 200)["data"] != []
    assert {:controller, EndpointController} in observations
    assert {:query, "endpoints"} in observations
  end

  test "route inventory and permission pipelines include retry POST and audit GET without delete" do
    expected =
      for {method, path, controller, action, _permission, _lookup, _status, _roles} <- @routes do
        {method, path, controller, action}
      end

    actual =
      TidewakeWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/"))
      |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})

    retry_route =
      {:post, "/api/deliveries/:delivery_id/manual-retry-requests", ManualRetryRequestController,
       :create}

    audit_route =
      {:get, "/api/deliveries/:delivery_id/manual-retry-requests", ManualRetryRequestController,
       :index}

    assert Enum.sort(actual) == Enum.sort([retry_route, audit_route | expected])

    retry_info =
      Phoenix.Router.route_info(
        TidewakeWeb.Router,
        "POST",
        "/api/deliveries/1/manual-retry-requests",
        "www.example.com"
      )

    assert retry_info.pipe_through == [:manual_retries]

    audit_info =
      Phoenix.Router.route_info(
        TidewakeWeb.Router,
        "GET",
        "/api/deliveries/1/manual-retry-requests",
        "www.example.com"
      )

    assert audit_info.pipe_through == [:manual_retry_audit]

    for {method, path, _controller, _action, permission, _lookup, _status, _roles} <- @routes do
      info =
        Phoenix.Router.route_info(
          TidewakeWeb.Router,
          String.upcase(to_string(method)),
          String.replace(path, ":id", "1"),
          "www.example.com"
        )

      assert info.pipe_through == [:api, permission]
    end
  end

  test "unsupported cross-project DELETE never changes resources or jobs", %{projects: [a, b]} do
    before = snapshot()

    for {own, foreign} <- [{a, b}, {b, a}],
        role <- @roles,
        path <- ["/api/endpoints/#{foreign.endpoint.id}", "/api/events/#{foreign.event.id}"] do
      response =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{own.identities[role].issued.token}")
        |> delete(path)

      assert json_response(response, 404) == %{"errors" => %{"detail" => "Not Found"}}
      assert snapshot() == before
    end
  end

  defp project_fixture(label) do
    admin = service_account_fixture()

    identities = %{
      "admin" => admin,
      "producer" => service_account_fixture("producer", admin.project),
      "viewer" => service_account_fixture("viewer", admin.project)
    }

    {:ok, endpoint} =
      Webhooks.create_endpoint(admin.project, %{
        name: "Consumer #{label}",
        url: "https://endpoint.invalid/#{label}"
      })

    {:ok, inactive} =
      Webhooks.create_endpoint(admin.project, %{
        name: "Inactive #{label}",
        url: "https://endpoint.invalid/inactive/#{label}",
        active: false
      })

    {:ok, event} =
      Webhooks.create_event(admin.project, %{
        external_id: "same-existing-external-id",
        event_type: "order.created",
        payload: %{origin: label}
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

    %{
      project: admin.project,
      identities: identities,
      endpoint: endpoint,
      inactive: inactive,
      event: Repo.get!(Event, event.id, @opts),
      delivery: delivery
    }
  end

  defp request(own, foreign, method, path, token, target_id \\ nil) do
    id =
      target_id || if(String.contains?(path, "/events/"), do: own.event.id, else: own.endpoint.id)

    path = String.replace(path, ":id", to_string(id))

    injected = %{
      "project_id" => foreign.project.id,
      "project_public_id" => foreign.project.public_id
    }

    path = path <> "?" <> URI.encode_query(injected)

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("project_id", to_string(foreign.project.id))
      |> put_req_header("project_public_id", foreign.project.public_id)
      |> put_req_header("x-project-id", to_string(foreign.project.id))
      |> put_req_header("x-project-public-id", foreign.project.public_id)

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    params = %{
      "name" => "Changed",
      "url" => "https://endpoint.invalid/new",
      "external_id" => "same-ingested-external-id",
      "type" => "order.created",
      "data" => %{"origin" => own.event.payload["origin"]}
    }

    dispatch(conn, @endpoint, method, path, Jason.encode!(Map.merge(params, injected)))
  end

  defp resource_id(project, lookup) when lookup in [:event, :event_deliveries],
    do: project.event.id

  defp resource_id(project, :endpoint), do: project.endpoint.id

  defp assert_result(:endpoint_list, :get, data, own) do
    assert Enum.sort(Enum.map(data, & &1["id"])) == Enum.sort([own.endpoint.id, own.inactive.id])
    Enum.each(data, &assert_fields(&1, :endpoint))
  end

  defp assert_result(:endpoint, :get, data, own) do
    assert data["id"] == own.endpoint.id
    assert data["name"] == own.endpoint.name
    assert_fields(data, :endpoint)
  end

  defp assert_result(:endpoint, :patch, data, own) do
    assert data["id"] == own.endpoint.id
    assert data["name"] == "Changed"
    assert Repo.get!(Endpoint, data["id"], @opts).project_id == own.project.id
    assert_fields(data, :endpoint)
  end

  defp assert_result(:endpoint_create, :post, data, own) do
    assert Repo.get!(Endpoint, data["id"], @opts).project_id == own.project.id
    assert_fields(data, :endpoint)
  end

  defp assert_result(:event, :get, data, own) do
    assert data["id"] == own.event.id
    assert data["external_id"] == "same-existing-external-id"
    assert data["data"] == own.event.payload
    assert_fields(data, :event)
  end

  defp assert_result(:event_deliveries, :get, data, own) do
    assert [%{"id" => id, "endpoint_id" => endpoint_id}] = data
    assert id == own.delivery.id
    assert endpoint_id == own.endpoint.id
    Enum.each(data, &assert_fields(&1, :delivery))
  end

  defp assert_result(:event_create, :post, data, own) do
    event = Repo.get!(Event, data["id"], @opts)
    assert event.project_id == own.project.id
    assert event.external_id == "same-ingested-external-id"
    assert event.payload == own.event.payload
    assert [delivery] = Repo.all(from(d in Delivery, where: d.event_id == ^event.id), @opts)
    assert delivery.project_id == own.project.id
    assert delivery.endpoint_id == own.endpoint.id

    assert [job] =
             Repo.all(from(j in Oban.Job, where: j.args["delivery_id"] == ^delivery.id), @opts)

    assert job.args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => 1,
             "retry_cycle" => 0,
             "cycle_attempt_number" => 1
           }

    assert_fields(data, :event)
  end

  defp assert_fields(data, kind) do
    fields =
      case kind do
        :endpoint ->
          ~w(id name url active inserted_at updated_at)

        :event ->
          ~w(id external_id type data inserted_at updated_at)

        :delivery ->
          ~w(id endpoint_id status attempt_count next_attempt_at completed_at inserted_at updated_at)
      end

    assert Enum.sort(Map.keys(data)) == Enum.sort(fields)
  end

  defp assert_failure(conn, status, projects) do
    expected =
      if status == 401,
        do: %{"code" => "unauthorized", "message" => "Valid service account credential required"},
        else: %{"code" => "forbidden", "message" => "Permission denied"}

    assert json_response(conn, status) == %{"error" => expected}
    assert conn.halted
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_req_header(conn, "authorization") == []
    if status == 401, do: assert(get_resp_header(conn, "www-authenticate") == ["Bearer"])
    assert_private(conn, projects)
  end

  defp assert_private(conn, projects) do
    for field <- ~w(project_id project_public_id service_account_id credential_id token_digest) do
      refute conn.resp_body =~ "\"#{field}\""
    end

    response = conn.resp_body <> inspect(conn.resp_headers)

    for project <- projects,
        {_role, identity} <- project.identities,
        secret <- [
          identity.project.public_id,
          identity.account.public_id,
          identity.issued.credential.public_id,
          identity.issued.token
        ] do
      leaked = String.contains?(response, secret)
      refute leaked, "response exposed authentication metadata"
    end
  end

  defp public_response(conn) do
    {conn.status, Jason.decode!(conn.resp_body),
     Enum.map(~w(content-type cache-control www-authenticate location), fn header ->
       {header, get_resp_header(conn, header)}
     end)}
  end

  defp snapshot do
    Enum.map([Endpoint, Event, Delivery, Oban.Job], fn schema ->
      Repo.all(from(row in schema, order_by: row.id), @opts)
    end)
  end

  defp project_snapshot(id) do
    Enum.map([Endpoint, Event, Delivery], fn schema ->
      Repo.all(from(row in schema, where: row.project_id == ^id, order_by: row.id), @opts)
    end)
  end

  defp invalidate(:removed_shared, _identity), do: "dev-only-api-token-not-for-production"

  defp invalidate(state, identity) do
    now = DateTime.utc_now()

    case state do
      :disabled ->
        assert {:ok, _} = Projects.disable_service_account(identity.account, now)

      :revoked ->
        assert {:ok, _} =
                 Projects.revoke_credential(
                   identity.account,
                   identity.issued.credential.public_id,
                   now
                 )

      :suspended ->
        assert {:ok, _} = Projects.suspend_project(identity.project, now)

      :expired ->
        assert {1, _} =
                 Repo.update_all(
                   from(c in ApiCredential, where: c.id == ^identity.issued.credential.id),
                   [
                     set: [
                       inserted_at: DateTime.add(now, -3600),
                       expires_at: DateTime.add(now, -1)
                     ]
                   ],
                   @opts
                 )
    end

    identity.issued.token
  end

  defp observe(context, request) do
    collector = Task.Supervisor.async_nolink(context.observer_supervisor, fn -> collect([]) end)

    patterns = [
      {Repo, :prepare_query, 3},
      {EndpointController, :call, 2},
      {EventController, :call, 2}
    ]

    # Repo queries opt out of SQL telemetry; observe their public boundary instead.
    Enum.each(patterns, fn {module, _function, _arity} -> Code.ensure_loaded!(module) end)
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call, {:tracer, collector.pid}])

    try do
      response = request.()
      :erlang.trace(self(), false, [:call])
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^barrier}
      send(collector.pid, :finish)
      {response, Task.await(collector)}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
    end
  end

  defp collect(observations) do
    receive do
      {:trace, _pid, :call,
       {Repo, :prepare_query, [_op, %Ecto.Query{from: %{source: {table, _schema}}}, _opts]}}
      when table in ["endpoints", "events", "deliveries"] ->
        collect([{:query, table} | observations])

      {:trace, _pid, :call, {controller, :call, _args}}
      when controller in [EndpointController, EventController] ->
        collect([{:controller, controller} | observations])

      :finish ->
        Enum.reverse(observations)

      _other ->
        collect(observations)
    end
  end
end

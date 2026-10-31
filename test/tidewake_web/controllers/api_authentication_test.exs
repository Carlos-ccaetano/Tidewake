defmodule TidewakeWeb.ApiAuthenticationTest do
  use TidewakeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO, only: [capture_io: 1]

  alias Mix.Tasks.Tidewake.Projects.Create
  alias Mix.Tasks.Tidewake.ServiceAccounts.{Provision, RevokeCredential}
  alias Tidewake.{Projects, Repo, Webhooks}
  alias Tidewake.Projects.{ApiCredential, ServiceAccountToken}
  alias Tidewake.Webhooks.{Delivery, Endpoint, Event}

  @opts [log: false, telemetry_event: nil]
  @routes [
    {:get, "/api/endpoints", 200, ~w(admin producer viewer)},
    {:get, "/api/endpoints/:endpoint_id", 200, ~w(admin producer viewer)},
    {:get, "/api/events/:event_id", 200, ~w(admin producer viewer)},
    {:get, "/api/events/:event_id/deliveries", 200, ~w(admin producer viewer)},
    {:post, "/api/events", 201, ~w(admin producer)},
    {:post, "/api/endpoints", 201, ~w(admin)},
    {:patch, "/api/endpoints/:endpoint_id", 200, ~w(admin)}
  ]

  setup tags do
    identity = service_account_fixture(Map.get(tags, :role, "admin"))

    {:ok, endpoint} =
      Webhooks.create_endpoint(identity.project, %{
        name: "Consumer",
        url: "https://endpoint.invalid/webhook"
      })

    {:ok, event} =
      Webhooks.create_event(identity.project, %{
        external_id: "existing-event",
        event_type: "order.created",
        payload: %{}
      })

    Map.merge(identity, %{endpoint: endpoint, event: event})
  end

  for {method, path, status, roles} <- @routes, role <- ~w(admin producer viewer) do
    @tag role: role
    test "#{role} #{method} #{path} follows the permission matrix", identity do
      before = counts()

      Oban.Testing.with_testing_mode(:manual, fn ->
        response =
          request(identity, unquote(method), unquote(path), [
            {"authorization", "Bearer #{identity.issued.token}"}
          ])

        if unquote(role in roles) do
          assert json_response(response, unquote(status))["data"]
          refute Map.has_key?(response.assigns, :current_project)
          assert response.assigns.current_scope.project_id == identity.project.id
        else
          assert_failure(response, 403, identity)
          assert counts() == before
        end
      end)
    end
  end

  for failure <- [
        :missing,
        :malformed,
        :invalid,
        :unknown,
        :wrong_secret,
        :expired,
        :revoked,
        :disabled,
        :suspended,
        :removed_shared,
        :duplicate
      ] do
    @tag role: "viewer"
    test "#{failure} credentials return 401 before authorization or controller on every route",
         identity do
      headers = invalid_headers(unquote(failure), identity)
      before = counts()

      for {method, path, _status, _roles} <- @routes do
        response = request(identity, method, path, headers)
        assert_failure(response, 401, identity)
        assert counts() == before
      end
    end
  end

  test "browser routes keep their existing public access", %{conn: conn} do
    assert get(conn, ~p"/") |> html_response(200) =~ "Tidewake"
  end

  test "operational tasks provision a usable credential and revocation removes API access" do
    project_output =
      capture_io(fn ->
        Create.run([
          "--name",
          "Operations",
          "--slug",
          "operations-#{Ecto.UUID.generate()}"
        ])
      end)

    [_, project_id] = Regex.run(~r/^Project: ([0-9a-f-]{36})$/m, project_output)

    output =
      capture_io(fn ->
        Provision.run([
          "--project",
          project_id,
          "--name",
          "Operator",
          "--role",
          "admin",
          "--expires-in-days",
          "1"
        ])
      end)

    [_, token] = Regex.run(~r/^Token: (twk_sa\.[^\s]+)$/m, output)

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/endpoints")

    assert json_response(response, 200) == %{"data" => []}
    assert response.assigns.current_scope.project_public_id == project_id

    {:ok, credential_id} = ServiceAccountToken.parse(token)

    capture_io(fn ->
      RevokeCredential.run([
        "--project",
        project_id,
        "--credential",
        credential_id
      ])
    end)

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/endpoints")

    assert json_response(response, 401)["error"]["code"] == "unauthorized"
    assert get_resp_header(response, "cache-control") == ["no-store"]
    refute response.resp_body =~ token
  end

  test "protected route inventory includes retry POST without audit or credential management" do
    routes =
      Phoenix.Router.routes(TidewakeWeb.Router)
      |> Enum.filter(&String.starts_with?(&1.path, "/api/"))
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.sort()

    assert routes ==
             Enum.sort([
               {:get, "/api/endpoints"},
               {:get, "/api/endpoints/:id"},
               {:get, "/api/events/:id"},
               {:get, "/api/events/:id/deliveries"},
               {:post, "/api/events"},
               {:post, "/api/endpoints"},
               {:post, "/api/deliveries/:delivery_id/manual-retry-requests"},
               {:patch, "/api/endpoints/:id"}
             ])
  end

  defp request(identity, method, path, headers) do
    path =
      path
      |> String.replace(":endpoint_id", to_string(identity.endpoint.id))
      |> String.replace(":event_id", to_string(identity.event.id))

    conn = build_conn() |> prepend_req_headers(headers)
    dispatch(conn, @endpoint, method, path, params(method, path))
  end

  defp params(:post, "/api/events"),
    do: %{"external_id" => "new-event", "type" => "order.created", "data" => %{}}

  defp params(:post, "/api/endpoints"),
    do: %{"name" => "New", "url" => "https://endpoint.invalid/new", "role" => "admin"}

  defp params(:patch, _path), do: %{"name" => "Changed", "role" => "admin"}
  defp params(_method, _path), do: %{}

  defp counts, do: Enum.map([Endpoint, Event, Delivery, Oban.Job], &Repo.aggregate(&1, :count))

  defp assert_failure(conn, status, identity) do
    expected =
      if status == 401,
        do: %{"code" => "unauthorized", "message" => "Valid service account credential required"},
        else: %{"code" => "forbidden", "message" => "Permission denied"}

    assert json_response(conn, status) == %{"error" => expected}
    assert conn.halted
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_req_header(conn, "authorization") == []
    if status == 401, do: assert(get_resp_header(conn, "www-authenticate") == ["Bearer"])

    for secret <- [
          identity.issued.token,
          identity.issued.credential.public_id,
          identity.account.public_id,
          identity.project.public_id
        ] do
      refute conn.resp_body =~ secret
    end
  end

  defp invalid_headers(:missing, _identity), do: []

  defp invalid_headers(:malformed, identity),
    do: [{"authorization", "Basic #{identity.issued.token}"}]

  defp invalid_headers(:invalid, _identity), do: [{"authorization", "Bearer invalid-token"}]

  defp invalid_headers(:unknown, identity) do
    token =
      String.replace(
        identity.issued.token,
        identity.issued.credential.public_id,
        Ecto.UUID.generate()
      )

    [{"authorization", "Bearer #{token}"}]
  end

  defp invalid_headers(:wrong_secret, identity) do
    token =
      "twk_sa.#{identity.issued.credential.public_id}." <>
        Base.url_encode64(<<0::256>>, padding: false)

    [{"authorization", "Bearer #{token}"}]
  end

  defp invalid_headers(:removed_shared, _identity),
    do: [{"authorization", "Bearer dev-only-api-token-not-for-production"}]

  defp invalid_headers(:duplicate, identity) do
    List.duplicate({"authorization", "Bearer #{identity.issued.token}"}, 2)
  end

  defp invalid_headers(failure, identity) do
    now = DateTime.utc_now()

    case failure do
      :expired ->
        Repo.update_all(
          from(c in ApiCredential, where: c.id == ^identity.issued.credential.id),
          [set: [inserted_at: DateTime.add(now, -3600), expires_at: DateTime.add(now, -1)]],
          @opts
        )

      :revoked ->
        assert {:ok, _} =
                 Projects.revoke_credential(
                   identity.account,
                   identity.issued.credential.public_id,
                   now
                 )

      :disabled ->
        assert {:ok, _} = Projects.disable_service_account(identity.account, now)

      :suspended ->
        assert {:ok, _} = Projects.suspend_project(identity.project, now)
    end

    [{"authorization", "Bearer #{identity.issued.token}"}]
  end
end

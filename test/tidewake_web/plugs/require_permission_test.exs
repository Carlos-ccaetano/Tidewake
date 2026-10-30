defmodule TidewakeWeb.Plugs.RequirePermissionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Tidewake.Projects.Scope
  alias Tidewake.Repo
  alias TidewakeWeb.Plugs.RequirePermission

  @scope %Scope{
    service_account_id: 71_001,
    actor_subject: "11111111-1111-4111-8111-111111111111",
    project_id: 72_002,
    project_public_id: "22222222-2222-4222-8222-222222222222",
    role: "viewer"
  }
  @forbidden %{"error" => %{"code" => "forbidden", "message" => "Permission denied"}}

  for {permission, allowed_roles} <- [
        resources_read: ~w(admin producer viewer),
        events_write: ~w(admin producer),
        endpoints_write: ~w(admin),
        manual_retries_write: ~w(admin),
        manual_retry_audit_read: ~w(admin)
      ],
      role <- ~w(admin producer viewer) do
    test "#{role} / #{permission} reaches downstream only when allowed" do
      original =
        conn(:get, "/protected") |> assign(:current_scope, %{@scope | role: unquote(role)})

      result = pipeline(original, unquote(permission))

      if unquote(role in allowed_roles) do
        assert result == original
        assert_receive :controller_reached
      else
        assert_forbidden(result)
        refute_received :controller_reached
      end
    end
  end

  test "missing, nil and caller-map scopes fail uniformly instead of crashing" do
    for assigns <- [%{}, %{current_scope: nil}, %{current_scope: Map.from_struct(@scope)}] do
      result = pipeline(%{conn(:get, "/protected") | assigns: assigns}, :resources_read)
      assert_forbidden(result)
      refute_received :controller_reached
    end
  end

  test "unknown or malformed roles and configured permissions fail closed" do
    for role <- [nil, "owner", :admin, %{role: "admin"}] do
      result =
        conn(:get, "/protected")
        |> assign(:current_scope, %{@scope | role: role})
        |> pipeline(:resources_read)

      assert_forbidden(result)
      refute_received :controller_reached
    end

    for permission <- [:unknown, :all, :*, nil, "resources_read", [permission: :resources_read]] do
      result =
        conn(:get, "/protected")
        |> assign(:current_scope, %{@scope | role: "admin"})
        |> pipeline(permission)

      assert_forbidden(result)
      refute_received :controller_reached
    end
  end

  test "request params and headers cannot select role or configured permission" do
    result =
      conn(:post, "/protected?permission=resources_read", %{"role" => "admin"})
      |> put_req_header("x-permission", "resources_read")
      |> put_req_header("x-role", "admin")
      |> assign(:current_scope, @scope)
      |> pipeline(:endpoints_write)

    assert_forbidden(result)
    refute_received :controller_reached
  end

  test "denials overwrite caching and disclose no identity, role, path or token" do
    Tidewake.DataCase.setup_sandbox(%{async: false})
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:tidewake, :repo, :query], &__MODULE__.query_event/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive :authorization_query_event
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          for role <- ~w(admin producer viewer) do
            result =
              conn(:get, "/protected/private-resource-id")
              |> put_req_header("authorization", "Bearer private-token")
              |> put_resp_header("cache-control", "public, max-age=3600")
              |> assign(:current_scope, %{@scope | role: role})
              |> pipeline(:unknown)

            assert_forbidden(result)
            for sensitive <- sensitive_values(), do: refute(result.resp_body =~ sensitive)
            refute_received :controller_reached
          end
        end)

      for sensitive <- sensitive_values(), do: refute(logs =~ sensitive)
      refute_received :authorization_query_event
    after
      Logger.configure(level: previous_level)
    end
  end

  def query_event(_event, _measurements, _metadata, owner) do
    if self() == owner, do: send(owner, :authorization_query_event)
  end

  defp pipeline(conn, permission) do
    Plug.run(conn, [
      {RequirePermission, permission},
      fn conn ->
        send(self(), :controller_reached)
        conn
      end
    ])
  end

  defp assert_forbidden(conn) do
    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == @forbidden
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  defp sensitive_values do
    [
      to_string(@scope.service_account_id),
      @scope.actor_subject,
      to_string(@scope.project_id),
      @scope.project_public_id,
      "admin",
      "producer",
      "viewer",
      "private-resource-id",
      "private-token"
    ]
  end
end

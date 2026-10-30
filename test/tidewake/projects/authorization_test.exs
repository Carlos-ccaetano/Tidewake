defmodule Tidewake.Projects.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Tidewake.Projects.{Authorization, Scope}

  @scope %Scope{
    service_account_id: 71_001,
    actor_subject: "11111111-1111-4111-8111-111111111111",
    project_id: 72_002,
    project_public_id: "22222222-2222-4222-8222-222222222222",
    role: "viewer"
  }

  for {permission, allowed_roles} <- [
        resources_read: ~w(admin producer viewer),
        events_write: ~w(admin producer),
        endpoints_write: ~w(admin),
        manual_retries_write: ~w(admin),
        manual_retry_audit_read: ~w(admin)
      ],
      role <- ~w(admin producer viewer) do
    test "#{role} / #{permission}" do
      assert Authorization.allowed?(%{@scope | role: unquote(role)}, unquote(permission)) ==
               unquote(role in allowed_roles)
    end
  end

  test "unknown, nil and malformed roles never gain access" do
    for role <- [nil, "owner", "ADMIN", "admin ", :admin, ["admin"], %{role: "admin"}],
        permission <- [
          :resources_read,
          :events_write,
          :endpoints_write,
          :manual_retries_write,
          :manual_retry_audit_read
        ] do
      refute Authorization.allowed?(%{@scope | role: role}, permission)
    end
  end

  test "admin has no wildcard or permission-string bypass" do
    for permission <- [
          :unknown,
          :all,
          :*,
          nil,
          "resources_read",
          "endpoints_write",
          [:resources_read],
          %{permission: :resources_read}
        ] do
      refute Authorization.allowed?(%{@scope | role: "admin"}, permission)
    end
  end

  test "only Scope is accepted, never a caller map or role" do
    for input <- [nil, %{}, Map.from_struct(@scope), "admin", :admin, [role: "admin"]] do
      refute Authorization.allowed?(input, :resources_read)
    end
  end
end

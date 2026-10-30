defmodule Tidewake.Projects.ScopeTest do
  use Tidewake.DataCase, async: false

  alias Tidewake.Projects
  alias Tidewake.Projects.Scope

  setup do
    {:ok, project} = Projects.create_project(%{name: "Private project name", slug: "scope-test"})
    %{project: project}
  end

  for role <- ~w(admin producer viewer) do
    test "authenticates #{role} into exactly the five trusted identity fields", %{
      project: project
    } do
      {:ok, account} =
        Projects.create_service_account(project, unquote(role), %{name: "Private account name"})

      {:ok, issued} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))

      assert {:ok, %Scope{} = scope} = Scope.authenticate(issued.token, DateTime.utc_now())

      assert Map.from_struct(scope) == %{
               service_account_id: account.id,
               actor_subject: account.public_id,
               project_id: project.id,
               project_public_id: project.public_id,
               role: unquote(role)
             }

      assert Ecto.UUID.cast(scope.actor_subject) == {:ok, scope.actor_subject}
      assert Ecto.UUID.cast(scope.project_public_id) == {:ok, scope.project_public_id}

      for secret <- [
            issued.token,
            issued.credential.public_id,
            Application.fetch_env!(:tidewake, :service_account_token_pepper),
            project.name,
            account.name
          ],
          do: refute(inspect(scope) =~ secret)
    end
  end

  test "caller maps, records and manually fabricated structs cannot authenticate", %{
    project: project
  } do
    fabricated = %Scope{
      service_account_id: 1,
      actor_subject: Ecto.UUID.generate(),
      project_id: project.id,
      project_public_id: project.public_id,
      role: "admin"
    }

    for input <- [fabricated, Map.from_struct(fabricated), project, nil, "bad"] do
      assert Scope.authenticate(input, DateTime.utc_now()) == {:error, :invalid_credential}
    end

    assert_raise ArgumentError, fn -> struct!(Scope, role: "admin") end
  end

  test "rotation retains scope and revocation forces a fresh authentication", %{project: project} do
    {:ok, account} = Projects.create_service_account(project, "admin", %{name: "Consumer"})
    expiry = DateTime.add(DateTime.utc_now(), 3600)
    {:ok, first} = Projects.issue_credential(account, expiry)
    {:ok, second} = Projects.issue_credential(account, expiry)
    assert {:ok, scope} = Scope.authenticate(first.token, DateTime.utc_now())
    assert {:ok, ^scope} = Scope.authenticate(second.token, DateTime.utc_now())

    assert {:ok, _} =
             Projects.revoke_credential(account, first.credential.public_id, DateTime.utc_now())

    assert Scope.authenticate(first.token, DateTime.utc_now()) == {:error, :invalid_credential}
    assert {:ok, ^scope} = Scope.authenticate(second.token, DateTime.utc_now())
  end

  test "expiry equality is rejected and no caller-supplied time map is trusted", %{
    project: project
  } do
    {:ok, account} = Projects.create_service_account(project, "viewer", %{name: "Consumer"})
    expiry = DateTime.add(DateTime.utc_now(), 3600)
    {:ok, issued} = Projects.issue_credential(account, expiry)

    assert {:ok, %Scope{}} =
             Scope.authenticate(issued.token, DateTime.add(expiry, -1, :microsecond))

    assert Scope.authenticate(issued.token, expiry) == {:error, :invalid_credential}

    assert Scope.authenticate(issued.token, Map.from_struct(expiry)) ==
             {:error, :invalid_credential}
  end
end

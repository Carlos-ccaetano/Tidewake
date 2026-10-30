defmodule Tidewake.ProjectsFixtures do
  @moduledoc false

  alias Tidewake.Projects
  alias Tidewake.Projects.Scope

  def service_account_fixture(role \\ "admin", project \\ nil) do
    {:ok, project} =
      if project,
        do: {:ok, project},
        else: Projects.create_project(%{name: "API test", slug: "api-#{Ecto.UUID.generate()}"})

    {:ok, account} =
      Projects.create_service_account(project, role, %{
        name: "Consumer #{System.unique_integer([:positive])}"
      })

    {:ok, issued} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))
    %{project: project, account: account, issued: issued}
  end

  def scope_fixture(role \\ "admin", project \\ nil) do
    identity = service_account_fixture(role, project)
    {:ok, scope} = Scope.authenticate(identity.issued.token, DateTime.utc_now())
    Map.put(identity, :scope, scope)
  end
end

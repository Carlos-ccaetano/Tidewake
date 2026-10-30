defmodule TidewakeWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TidewakeWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Tidewake.Projects

  using do
    quote do
      # The default endpoint for testing
      @endpoint TidewakeWeb.Endpoint

      use TidewakeWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TidewakeWeb.ConnCase
    end
  end

  setup tags do
    Tidewake.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

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
end

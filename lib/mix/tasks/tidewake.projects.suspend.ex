defmodule Mix.Tasks.Tidewake.Projects.Suspend do
  use Mix.Task

  @shortdoc "Irreversibly suspends the selected project."
  @moduledoc """
  Irreversibly suspends the selected project.

      mix tidewake.projects.suspend --project PROJECT_PUBLIC_ID

  Run in the intended MIX_ENV. Issuance prints a raw token once after commit;
  capture it securely. No task changes roles, ownership or public identities.
  """

  @impl Mix.Task
  def run(args), do: Tidewake.Provisioning.run(:suspend, args, project: :string)
end

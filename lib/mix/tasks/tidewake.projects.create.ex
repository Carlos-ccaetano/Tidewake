defmodule Mix.Tasks.Tidewake.Projects.Create do
  use Mix.Task

  @shortdoc "Creates a project with a new public identity."
  @moduledoc """
  Creates a project with a new public identity.

      mix tidewake.projects.create --name NAME --slug SLUG

  Run in the intended MIX_ENV. Issuance prints a raw token once after commit;
  capture it securely. No task changes roles, ownership or public identities.
  """

  @impl Mix.Task
  def run(args), do: Tidewake.Provisioning.run(:create, args, name: :string, slug: :string)
end

defmodule Mix.Tasks.Tidewake.ServiceAccounts.Provision do
  use Mix.Task

  @shortdoc "Creates a new account and its initial credential atomically."
  @moduledoc """
  Creates a new account and its initial credential atomically.

      mix tidewake.service_accounts.provision --project PROJECT_PUBLIC_ID --name NAME --role ROLE --expires-in-days DAYS

  Run in the intended MIX_ENV. Issuance prints a raw token once after commit;
  capture it securely. No task changes roles, ownership or public identities.
  """

  @impl Mix.Task
  def run(args),
    do:
      Tidewake.Provisioning.run(:provision, args,
        project: :string,
        name: :string,
        role: :string,
        expires_in_days: :integer
      )
end

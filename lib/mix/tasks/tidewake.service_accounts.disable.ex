defmodule Mix.Tasks.Tidewake.ServiceAccounts.Disable do
  use Mix.Task

  @shortdoc "Irreversibly disables an account owned by the selected project."
  @moduledoc """
  Irreversibly disables an account owned by the selected project.

      mix tidewake.service_accounts.disable --project PROJECT_PUBLIC_ID --service-account SERVICE_ACCOUNT_PUBLIC_ID

  Run in the intended MIX_ENV. Issuance prints a raw token once after commit;
  capture it securely. No task changes roles, ownership or public identities.
  """

  @impl Mix.Task
  def run(args),
    do: Tidewake.Provisioning.run(:disable, args, project: :string, service_account: :string)
end

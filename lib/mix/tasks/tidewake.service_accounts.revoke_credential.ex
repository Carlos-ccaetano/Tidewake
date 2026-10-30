defmodule Mix.Tasks.Tidewake.ServiceAccounts.RevokeCredential do
  use Mix.Task

  @shortdoc "Irreversibly revokes a credential owned by the selected project."
  @moduledoc """
  Irreversibly revokes a credential owned by the selected project.

      mix tidewake.service_accounts.revoke_credential --project PROJECT_PUBLIC_ID --credential CREDENTIAL_PUBLIC_ID

  Run in the intended MIX_ENV. Issuance prints a raw token once after commit;
  capture it securely. No task changes roles, ownership or public identities.
  """

  @impl Mix.Task
  def run(args),
    do: Tidewake.Provisioning.run(:revoke, args, project: :string, credential: :string)
end

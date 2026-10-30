defmodule Mix.Tasks.Tidewake.ServiceAccounts.IssueCredential do
  use Mix.Task

  @shortdoc "Issues an additional credential without changing account identity or role."
  @moduledoc """
  Issues an additional credential without changing account identity or role.

      mix tidewake.service_accounts.issue_credential --project PROJECT_PUBLIC_ID --service-account SERVICE_ACCOUNT_PUBLIC_ID --expires-in-days DAYS

  Run in the intended MIX_ENV. Issuance prints a raw token once after commit;
  capture it securely. No task changes roles, ownership or public identities.
  """

  @impl Mix.Task
  def run(args),
    do:
      Tidewake.Provisioning.run(:issue, args,
        project: :string,
        service_account: :string,
        expires_in_days: :integer
      )
end

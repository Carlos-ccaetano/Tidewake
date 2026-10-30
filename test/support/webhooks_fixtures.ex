defmodule Tidewake.WebhooksFixtures do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Projects.{ApiCredential, ServiceAccount}
  alias Tidewake.{ProjectsFixtures, Repo, Webhooks}
  alias Tidewake.Webhooks.ManualRetryRequest

  @opts [log: false, telemetry_event: nil]

  def legacy_project, do: Tidewake.Projects.get_project_by_slug("legacy")

  def retry_scope_fixture(%{unboxed: true}) do
    identity =
      Sandbox.unboxed_run(Repo, fn ->
        ProjectsFixtures.scope_fixture("admin", legacy_project())
      end)

    ExUnit.Callbacks.on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from(c in ApiCredential, where: c.service_account_id == ^identity.account.id),
          @opts
        )

        Repo.delete_all(from(a in ServiceAccount, where: a.id == ^identity.account.id), @opts)
      end)
    end)

    identity.scope
  end

  def retry_scope_fixture(_tags),
    do: ProjectsFixtures.scope_fixture("admin", legacy_project()).scope

  # Domain regressions inspect persisted evidence after checking the public allowlist.
  def retry_and_load_audit(scope, delivery_id, key) do
    case Webhooks.request_manual_retry(scope, delivery_id, key) do
      {:ok, %{request: view} = result} ->
        request = Repo.get!(ManualRetryRequest, view.id, @opts)
        fields = [:id, :delivery_id, :outcome, :reason, :requested_at, :resulting_retry_cycle]
        assert view == Map.take(request, fields)
        {:ok, %{result | request: request}}

      error ->
        error
    end
  end
end

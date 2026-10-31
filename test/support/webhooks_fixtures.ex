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

  def manual_retry_audit_fixture(delivery, attrs \\ %{}) do
    digest = :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode16(case: :lower)

    identity =
      Map.take(attrs, [:actor_type, :actor_subject, :source, :request_fingerprint_version])

    request =
      struct!(
        %ManualRetryRequest{
          delivery_id: delivery.id,
          actor_type: "service_account",
          actor_subject: Ecto.UUID.generate(),
          source: "api",
          idempotency_key_digest: digest,
          request_fingerprint: String.duplicate("f", 64),
          request_fingerprint_version: 1
        },
        identity
      )

    decision =
      Map.merge(
        %{
          requested_at: DateTime.utc_now(),
          outcome: "rejected",
          reason: "state_not_failed",
          observed_status: "pending",
          observed_attempt_count: 0,
          observed_retry_cycle: 0
        },
        attrs
      )

    request |> ManualRetryRequest.changeset(decision) |> Repo.insert!(@opts)
  end

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

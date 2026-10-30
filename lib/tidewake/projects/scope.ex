defmodule Tidewake.Projects.Scope do
  @moduledoc """
  Minimal request identity built only after Projects authenticates a credential.

  Authenticate through this module; there is no supported constructor from
  caller-supplied maps or records. An Elixir struct cannot prove its own origin:
  trusted internal code must never treat request data as a Scope. Sensitive
  commands must revalidate persisted authority at their transaction boundary.
  """

  alias Tidewake.Projects
  alias Tidewake.Projects.ServiceAccount
  alias Tidewake.Repo

  import Ecto.Query, only: [from: 2]

  @enforce_keys [:service_account_id, :actor_subject, :project_id, :project_public_id, :role]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            service_account_id: pos_integer(),
            actor_subject: Ecto.UUID.t(),
            project_id: pos_integer(),
            project_public_id: Ecto.UUID.t(),
            role: String.t()
          }

  @doc "Authenticates persisted credential state before constructing a request scope."
  @spec authenticate(term(), DateTime.t()) :: {:ok, t()} | {:error, :invalid_credential}
  def authenticate(token, now) do
    with {:ok, %{service_account: account, project: project}} <-
           Projects.authenticate_credential(token, now) do
      {:ok, build(account, project)}
    end
  end

  @doc "Checks Scope shape only; this cannot prove authentication provenance."
  def valid?(
        %__MODULE__{
          service_account_id: account_id,
          actor_subject: subject,
          project_id: project_id,
          project_public_id: public_id,
          role: role
        } = scope
      )
      when map_size(scope) == 6 and is_integer(account_id) and account_id > 0 and
             account_id <= 9_223_372_036_854_775_807 and is_integer(project_id) and
             project_id > 0 and project_id <= 9_223_372_036_854_775_807 and
             role in ~w(admin producer viewer) do
    canonical_uuid?(subject) and canonical_uuid?(public_id)
  end

  def valid?(_scope), do: false

  @doc "Rechecks and share-locks persisted authority inside a sensitive command transaction."
  def revalidate(scope) do
    if valid?(scope) and Repo.in_transaction?() do
      query =
        from account in ServiceAccount,
          join: project in assoc(account, :project),
          where:
            account.id == ^scope.service_account_id and account.public_id == ^scope.actor_subject,
          where:
            account.project_id == ^scope.project_id and
              project.public_id == ^scope.project_public_id,
          where:
            account.role == ^scope.role and is_nil(account.disabled_at) and
              project.status == "active",
          select: account.id,
          lock: "FOR SHARE"

      if Repo.one(query, log: false, telemetry_event: nil), do: :ok, else: {:error, :forbidden}
    else
      {:error, :forbidden}
    end
  end

  defp canonical_uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Ecto.UUID.cast(value) == {:ok, value}

  defp canonical_uuid?(_value), do: false

  defp build(account, project) do
    %__MODULE__{
      service_account_id: account.id,
      actor_subject: account.public_id,
      project_id: project.id,
      project_public_id: project.public_id,
      role: account.role
    }
  end
end

defmodule Tidewake.Projects.Scope do
  @moduledoc """
  Minimal request identity built only after Projects authenticates a credential.

  Authenticate through this module; there is no supported constructor from
  caller-supplied maps or records. An Elixir struct cannot prove its own origin:
  trusted internal code must never treat request data as a Scope. Sensitive
  commands must revalidate persisted authority at their transaction boundary.
  """

  alias Tidewake.Projects

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

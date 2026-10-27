defmodule Tidewake.Projects.ServiceAccount do
  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Projects.{ApiCredential, Project}

  schema "service_accounts" do
    belongs_to :project, Project
    field :public_id, Ecto.UUID, autogenerate: true
    field :name, :string
    field :role, :string
    field :disabled_at, :utc_datetime_usec
    has_many :credentials, ApiCredential, foreign_key: :service_account_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(%Project{id: project_id}, role, attrs) do
    %__MODULE__{}
    |> cast(%{project_id: project_id, role: role}, [:project_id, :role])
    |> cast(Map.take(attrs, [:name, "name"]), [:name])
    |> validate_required([:project_id, :role, :name])
    |> validate_number(:project_id, greater_than: 0)
    |> validate_inclusion(:role, ~w(admin producer viewer))
    |> validate_length(:name, min: 1, max: 255, count: :bytes)
    |> database_constraints()
  end

  def disable_changeset(%__MODULE__{disabled_at: nil} = account, now) do
    account
    |> change(disabled_at: now, updated_at: now)
    |> database_constraints()
  end

  def disable_changeset(%__MODULE__{} = account, _now), do: change(account)

  defp database_constraints(changeset) do
    changeset
    |> unique_constraint(:public_id, name: :service_accounts_public_id_index)
    |> unique_constraint([:project_id, :name],
      name: :service_accounts_project_id_name_index,
      error_key: :name
    )
    |> foreign_key_constraint(:project_id, name: :service_accounts_project_id_fkey)
    |> check_constraint(:project_id, name: :service_accounts_project_id_positive)
    |> check_constraint(:name, name: :service_accounts_name_not_blank)
    |> check_constraint(:role, name: :service_accounts_role_allowed)
  end
end

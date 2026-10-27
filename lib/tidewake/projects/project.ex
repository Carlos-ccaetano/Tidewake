defmodule Tidewake.Projects.Project do
  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Projects.ServiceAccount

  schema "projects" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :slug, :string
    field :name, :string
    field :status, :string, default: "active"
    has_many :service_accounts, ServiceAccount

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(Map.take(attrs, [:slug, :name, "slug", "name"]), [:slug, :name])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 3, max: 63, count: :bytes)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    |> validate_length(:name, min: 1, max: 255, count: :bytes)
    |> database_constraints()
  end

  def suspend_changeset(%__MODULE__{status: "suspended"} = project, _now), do: change(project)

  def suspend_changeset(%__MODULE__{status: "active"} = project, now) do
    project
    |> change(status: "suspended", updated_at: now)
    |> database_constraints()
  end

  defp database_constraints(changeset) do
    changeset
    |> unique_constraint(:public_id, name: :projects_public_id_index)
    |> unique_constraint(:slug, name: :projects_slug_index)
    |> check_constraint(:slug, name: :projects_slug_format)
    |> check_constraint(:name, name: :projects_name_not_blank)
    |> check_constraint(:status, name: :projects_status_allowed)
  end
end

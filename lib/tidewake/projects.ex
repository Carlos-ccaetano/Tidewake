defmodule Tidewake.Projects do
  @moduledoc """
  Project identity creation and one-way suspension/disablement.

  Lifecycle operations reload and lock persisted state so stale structs cannot
  replace an identity, reactivate a principal, or overwrite its first disablement.
  """

  import Ecto.Query, only: [from: 2]

  alias Tidewake.Projects.{Project, ServiceAccount}
  alias Tidewake.Repo

  @repo_opts [log: false, telemetry_event: nil]

  def create_project(attrs) do
    attrs |> Project.create_changeset() |> Repo.insert(@repo_opts)
  end

  def get_project_by_public_id(public_id), do: get_by_public_id(Project, public_id)

  def get_project_by_slug(slug) when is_binary(slug) and byte_size(slug) in 3..63 do
    if String.valid?(slug), do: Repo.get_by(Project, [slug: slug], @repo_opts)
  end

  def get_project_by_slug(_slug), do: nil

  def create_service_account(%Project{} = project, role, attrs) do
    project |> ServiceAccount.create_changeset(role, attrs) |> Repo.insert(@repo_opts)
  end

  def get_service_account_by_public_id(public_id), do: get_by_public_id(ServiceAccount, public_id)

  @doc "Disables an account at the explicit UTC time, preserving its first disablement."
  def disable_service_account(%ServiceAccount{} = account, now) do
    transition(ServiceAccount, account, now, &ServiceAccount.disable_changeset/2)
  end

  @doc "Suspends a project at the explicit UTC time; repeated suspension is a no-op."
  def suspend_project(%Project{} = project, now) do
    transition(Project, project, now, &Project.suspend_changeset/2)
  end

  defp get_by_public_id(schema, public_id) do
    case Ecto.UUID.cast(public_id) do
      {:ok, uuid} -> Repo.get_by(schema, [public_id: uuid], @repo_opts)
      :error -> nil
    end
  end

  defp transition(
         schema,
         record,
         %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = now,
         changeset
       )
       when is_integer(record.id) and record.id > 0 do
    now = DateTime.from_unix!(DateTime.to_unix(now, :microsecond), :microsecond)

    Repo.transaction(
      fn ->
        query = from row in schema, where: row.id == ^record.id, lock: "FOR UPDATE"

        case Repo.one(query, @repo_opts) do
          nil -> Repo.rollback(:not_found)
          current -> persist_transition(changeset.(current, now))
        end
      end,
      @repo_opts
    )
  end

  defp transition(_schema, %{id: nil}, %DateTime{}, _changeset), do: {:error, :not_found}
  defp transition(_schema, _record, _now, _changeset), do: {:error, :invalid_timestamp}

  defp persist_transition(changeset) do
    case Repo.update(changeset, @repo_opts) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end

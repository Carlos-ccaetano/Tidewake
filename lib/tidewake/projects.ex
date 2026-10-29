defmodule Tidewake.Projects do
  @moduledoc """
  Project identity and opaque credential lifecycle.

  Lifecycle operations reload and lock persisted state so stale structs cannot
  replace an identity, reactivate a principal, or overwrite its first disablement.
  """

  import Ecto.Query, only: [from: 2]

  alias Tidewake.Projects.{ApiCredential, Project, ServiceAccount, ServiceAccountToken}
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

  @doc "Issues a redacted one-time result only after its own transaction commits."
  def issue_credential(
        %ServiceAccount{id: id},
        %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = expires_at
      )
      when is_integer(id) and id > 0 do
    if Repo.in_transaction?() do
      {:error, :credential_issue_failed}
    else
      Repo.transaction(fn -> issue_for_account(id, expires_at) end, @repo_opts)
    end
  rescue
    _failure -> {:error, :credential_issue_failed}
  end

  def issue_credential(_account, _expires_at), do: {:error, :credential_issue_failed}

  @doc "Revokes an account-owned credential irreversibly, retaining its first timestamp."
  def revoke_credential(
        %ServiceAccount{id: id},
        public_id,
        %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = now
      )
      when is_integer(id) and id > 0 do
    case Ecto.UUID.cast(public_id) do
      {:ok, uuid} -> Repo.transaction(fn -> revoke_for_account(id, uuid, now) end, @repo_opts)
      :error -> {:error, :invalid_credential}
    end
  rescue
    _failure -> {:error, :invalid_credential}
  end

  def revoke_credential(_account, _public_id, _now), do: {:error, :invalid_credential}

  @doc "Authenticates persisted state without returning a token, digest, or credential record."
  def authenticate_credential(
        token,
        %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = now
      ) do
    with {:ok, public_id} <- ServiceAccountToken.parse(token),
         {:ok, digest} <- ServiceAccountToken.digest(token),
         %ApiCredential{revoked_at: nil} = credential <- credential_for_authentication(public_id),
         true <- ServiceAccountToken.secure_match?(digest, credential.secret_digest),
         :gt <- DateTime.compare(credential.expires_at, now),
         %ServiceAccount{
           disabled_at: nil,
           role: role,
           project: %Project{status: "active"} = project
         } =
           account <- credential.service_account,
         true <- role in ~w(admin producer viewer) do
      {:ok, %{service_account: account, project: project}}
    else
      _invalid -> {:error, :invalid_credential}
    end
  rescue
    _failure -> {:error, :invalid_credential}
  end

  def authenticate_credential(_token, _now), do: {:error, :invalid_credential}

  defp issue_for_account(id, expires_at) do
    query =
      from account in ServiceAccount,
        join: project in assoc(account, :project),
        where: account.id == ^id,
        preload: [project: project],
        lock: "FOR SHARE"

    case Repo.one(query, @repo_opts) do
      %ServiceAccount{disabled_at: nil, role: role, project: %Project{status: "active"}} = account
      when role in ~w(admin producer viewer) ->
        persist_credential(account, expires_at)

      _invalid ->
        Repo.rollback(:credential_issue_failed)
    end
  end

  defp revoke_for_account(id, uuid, now) do
    query =
      from credential in ApiCredential,
        where: credential.public_id == ^uuid and credential.service_account_id == ^id,
        lock: "FOR UPDATE"

    case Repo.one(query, @repo_opts) do
      nil -> Repo.rollback(:invalid_credential)
      credential -> persist_revocation(credential, now)
    end
  end

  defp persist_credential(account, expires_at) do
    public_id = Ecto.UUID.generate()

    with {:ok, generated} <- ServiceAccountToken.generate(public_id),
         changeset =
           ApiCredential.create_changeset(
             %ApiCredential{
               service_account_id: account.id,
               public_id: public_id,
               secret_digest: generated.digest,
               inserted_at: DateTime.utc_now()
             },
             %{expires_at: expires_at}
           ),
         {:ok, credential} <- Repo.insert(changeset, @repo_opts) do
      %{generated | credential: %{credential | secret_digest: nil}, digest: nil}
    else
      _failure -> Repo.rollback(:credential_issue_failed)
    end
  end

  defp persist_revocation(%ApiCredential{revoked_at: nil} = credential, now) do
    if DateTime.compare(now, credential.inserted_at) == :lt,
      do: Repo.rollback(:invalid_credential)

    now = DateTime.from_unix!(DateTime.to_unix(now, :microsecond), :microsecond)
    changeset = Ecto.Changeset.change(credential, revoked_at: now)

    case Repo.update(changeset, @repo_opts) do
      {:ok, revoked} -> %{revoked | secret_digest: nil}
      {:error, _changeset} -> Repo.rollback(:invalid_credential)
    end
  end

  defp persist_revocation(credential, _now), do: %{credential | secret_digest: nil}

  defp credential_for_authentication(public_id) do
    query =
      from credential in ApiCredential,
        join: account in assoc(credential, :service_account),
        join: project in assoc(account, :project),
        where: credential.public_id == ^public_id,
        preload: [service_account: {account, project: project}]

    Repo.one(query, @repo_opts)
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

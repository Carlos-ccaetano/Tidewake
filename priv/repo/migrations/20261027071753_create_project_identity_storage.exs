defmodule Tidewake.Repo.Migrations.CreateProjectIdentityStorage do
  use Ecto.Migration

  def up do
    create table(:projects) do
      add :public_id, :uuid, null: false
      add :slug, :string, size: 63, null: false
      add :name, :string, size: 255, null: false
      add :status, :string, size: 16, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:public_id], name: :projects_public_id_index)
    create unique_index(:projects, [:slug], name: :projects_slug_index)

    create constraint(:projects, :projects_slug_format,
             check: """
             octet_length(slug) BETWEEN 3 AND 63 AND
             slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
             """
           )

    create constraint(:projects, :projects_name_not_blank,
             check: "octet_length(name) BETWEEN 1 AND 255 AND name ~ '[^[:space:]]'"
           )

    create constraint(:projects, :projects_status_allowed,
             check: "status IN ('active', 'suspended')"
           )

    # Fixed compatibility identity for existing data, never a security boundary.
    execute """
    INSERT INTO projects (id, public_id, slug, name, status, inserted_at, updated_at)
    VALUES (
      1, '00000000-0000-4000-8000-000000000001', 'legacy', 'Legacy project', 'active',
      timezone('UTC', CURRENT_TIMESTAMP), timezone('UTC', CURRENT_TIMESTAMP)
    )
    """

    execute "SELECT setval(pg_get_serial_sequence('projects', 'id'), 1, true)"

    create table(:service_accounts) do
      add :project_id,
          references(:projects, on_delete: :restrict, name: :service_accounts_project_id_fkey),
          null: false

      add :public_id, :uuid, null: false
      add :name, :string, size: 255, null: false
      add :role, :string, size: 16, null: false
      add :disabled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:service_accounts, [:public_id], name: :service_accounts_public_id_index)

    create unique_index(:service_accounts, [:project_id, :name],
             name: :service_accounts_project_id_name_index
           )

    create index(:service_accounts, [:project_id], name: :service_accounts_project_id_index)

    create constraint(:service_accounts, :service_accounts_name_not_blank,
             check: "octet_length(name) BETWEEN 1 AND 255 AND name ~ '[^[:space:]]'"
           )

    create constraint(:service_accounts, :service_accounts_role_allowed,
             check: "role IN ('admin', 'producer', 'viewer')"
           )

    create constraint(:service_accounts, :service_accounts_project_id_positive,
             check: "project_id > 0"
           )

    create table(:service_account_credentials) do
      add :service_account_id,
          references(:service_accounts,
            on_delete: :restrict,
            name: :service_account_credentials_service_account_id_fkey
          ),
          null: false

      add :public_id, :uuid, null: false
      add :secret_digest, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:service_account_credentials, [:public_id],
             name: :service_account_credentials_public_id_index
           )

    create index(:service_account_credentials, [:service_account_id],
             name: :service_account_credentials_service_account_id_index
           )

    create constraint(:service_account_credentials, :service_account_credentials_digest_length,
             check: "octet_length(secret_digest) = 32"
           )

    create constraint(
             :service_account_credentials,
             :service_account_credentials_service_account_id_positive,
             check: "service_account_id > 0"
           )

    create constraint(
             :service_account_credentials,
             :service_account_credentials_expires_after_insert,
             check: "expires_at > inserted_at"
           )

    create constraint(:service_account_credentials, :service_account_credentials_expiry_bounded,
             check: "expires_at <= inserted_at + interval '365 days'"
           )

    create constraint(:service_account_credentials, :service_account_credentials_revocation_time,
             check: "revoked_at IS NULL OR revoked_at >= inserted_at"
           )
  end

  def down do
    drop table(:service_account_credentials)
    drop table(:service_accounts)
    drop table(:projects)
  end
end

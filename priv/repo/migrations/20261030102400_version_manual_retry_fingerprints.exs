defmodule Tidewake.Repo.Migrations.VersionManualRetryFingerprints do
  use Ecto.Migration

  def up do
    execute "LOCK TABLE manual_retry_requests IN ACCESS EXCLUSIVE MODE"

    alter table(:manual_retry_requests) do
      add :request_fingerprint_version, :smallint
    end

    execute "UPDATE manual_retry_requests SET request_fingerprint_version = 1"

    execute "ALTER TABLE manual_retry_requests ALTER COLUMN request_fingerprint_version SET NOT NULL"

    create constraint(
             :manual_retry_requests,
             :manual_retry_requests_request_fingerprint_version_allowed,
             check: "request_fingerprint_version IN (1, 2)"
           )
  end

  def down do
    execute "LOCK TABLE manual_retry_requests IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM manual_retry_requests WHERE request_fingerprint_version <> 1) THEN
        RAISE EXCEPTION 'Unsafe fingerprint rollback: version 2 audit evidence exists; migrate forward';
      END IF;
    END $$
    """

    drop constraint(
           :manual_retry_requests,
           :manual_retry_requests_request_fingerprint_version_allowed
         )

    alter table(:manual_retry_requests) do
      remove :request_fingerprint_version
    end
  end
end

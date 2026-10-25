defmodule Tidewake.Repo.Migrations.CreateManualRetryRequests do
  use Ecto.Migration

  def change do
    create table(:manual_retry_requests) do
      add :delivery_id,
          references(:deliveries,
            on_delete: :restrict,
            name: :manual_retry_requests_delivery_id_fkey
          ),
          null: false

      add :actor_type, :string, size: 32, null: false
      add :actor_subject, :string, size: 255, null: false
      add :source, :string, size: 16, null: false
      add :idempotency_key_digest, :string, size: 64, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :outcome, :string, size: 16, null: false
      add :reason, :string, size: 64
      add :observed_status, :string, size: 16, null: false
      add :observed_attempt_count, :integer, null: false
      add :observed_retry_cycle, :integer, null: false
      add :observed_completed_at, :utc_datetime_usec
      add :resulting_retry_cycle, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :manual_retry_requests,
             [:actor_type, :actor_subject, :idempotency_key_digest],
             name: :manual_retry_requests_actor_idempotency_key_index
           )

    create index(:manual_retry_requests, [:delivery_id, :inserted_at],
             name: :manual_retry_requests_delivery_inserted_at_index
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_delivery_id_positive,
             check: "delivery_id > 0"
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_actor_type_allowed,
             check: "actor_type IN ('service_account', 'user')"
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_source_allowed,
             check: "source IN ('api', 'liveview', 'admin_cli')"
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_outcome_allowed,
             check: "outcome IN ('accepted', 'rejected')"
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_reason_allowed,
             check: """
             reason IS NULL OR reason IN (
               'state_not_failed', 'endpoint_inactive', 'manual_cycle_limit_reached'
             )
             """
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_observed_status_allowed,
             check:
               "observed_status IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(
             :manual_retry_requests,
             :manual_retry_requests_idempotency_key_digest_format,
             check: """
             octet_length(idempotency_key_digest) = 64 AND
             idempotency_key_digest ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_request_fingerprint_format,
             check: """
             octet_length(request_fingerprint) = 64 AND
             request_fingerprint ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_actor_subject_not_blank,
             check: """
             octet_length(actor_subject) BETWEEN 1 AND 255 AND
             actor_subject ~ '[^[:space:]]'
             """
           )

    create constraint(
             :manual_retry_requests,
             :manual_retry_requests_observed_attempt_count_non_negative,
             check: "observed_attempt_count >= 0"
           )

    create constraint(
             :manual_retry_requests,
             :manual_retry_requests_observed_retry_cycle_in_range,
             check: "observed_retry_cycle BETWEEN 0 AND 3"
           )

    create constraint(
             :manual_retry_requests,
             :manual_retry_requests_resulting_retry_cycle_in_range,
             check: "resulting_retry_cycle IS NULL OR resulting_retry_cycle BETWEEN 1 AND 3"
           )

    create constraint(:manual_retry_requests, :manual_retry_requests_decision_consistent,
             check: """
             (
               outcome = 'accepted' AND reason IS NULL AND resulting_retry_cycle IS NOT NULL AND
               observed_status = 'failed' AND observed_retry_cycle < 3 AND
               resulting_retry_cycle = observed_retry_cycle + 1
             ) OR (
               outcome = 'rejected' AND reason IS NOT NULL AND resulting_retry_cycle IS NULL
             )
             """
           )
  end
end

defmodule Tidewake.Repo.Migrations.CreateDeliveryAttempts do
  use Ecto.Migration

  def change do
    create table(:delivery_attempts) do
      add :delivery_id, references(:deliveries, on_delete: :restrict), null: false
      add :attempt_number, :integer, null: false
      add :result, :string, null: false
      add :http_status, :integer
      add :error_type, :string
      add :duration_ms, :integer, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec, null: false
      add :response_metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:delivery_attempts, [:delivery_id])
    create unique_index(:delivery_attempts, [:delivery_id, :attempt_number])

    create constraint(:delivery_attempts, :delivery_attempts_attempt_number_positive,
             check: "attempt_number > 0"
           )

    create constraint(:delivery_attempts, :delivery_attempts_duration_ms_non_negative,
             check: "duration_ms >= 0"
           )

    create constraint(:delivery_attempts, :delivery_attempts_completed_after_started,
             check: "completed_at >= started_at"
           )

    create constraint(:delivery_attempts, :delivery_attempts_result_allowed,
             check: "result IN ('succeeded', 'http_error', 'transport_error')"
           )
  end
end

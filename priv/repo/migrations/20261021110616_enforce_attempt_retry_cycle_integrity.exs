defmodule Tidewake.Repo.Migrations.EnforceAttemptRetryCycleIntegrity do
  use Ecto.Migration

  def up do
    execute("UPDATE delivery_attempts SET retry_cycle = 0 WHERE retry_cycle IS NULL")

    execute(
      "UPDATE delivery_attempts SET cycle_attempt_number = attempt_number WHERE cycle_attempt_number IS NULL"
    )

    alter table(:delivery_attempts) do
      modify :retry_cycle, :integer, null: false
      modify :cycle_attempt_number, :integer, null: false
    end

    create constraint(:delivery_attempts, :delivery_attempts_retry_cycle_in_range,
             check: "retry_cycle BETWEEN 0 AND 3"
           )

    create constraint(:delivery_attempts, :delivery_attempts_cycle_attempt_number_in_range,
             check: "cycle_attempt_number BETWEEN 1 AND 6"
           )

    create unique_index(:delivery_attempts, [:delivery_id, :retry_cycle, :cycle_attempt_number],
             name: :delivery_attempts_cycle_identity_index
           )
  end

  def down do
    drop index(:delivery_attempts, [:delivery_id, :retry_cycle, :cycle_attempt_number],
           name: :delivery_attempts_cycle_identity_index
         )

    drop constraint(:delivery_attempts, :delivery_attempts_cycle_attempt_number_in_range)
    drop constraint(:delivery_attempts, :delivery_attempts_retry_cycle_in_range)

    alter table(:delivery_attempts) do
      modify :retry_cycle, :integer, null: true
      modify :cycle_attempt_number, :integer, null: true
    end
  end
end

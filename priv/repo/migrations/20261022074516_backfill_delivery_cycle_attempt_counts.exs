defmodule Tidewake.Repo.Migrations.BackfillDeliveryCycleAttemptCounts do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE deliveries
    SET cycle_attempt_count = attempt_count
    WHERE retry_cycle = 0
      AND cycle_attempt_count <> attempt_count
    """)
  end

  def down do
    # The previous counts cannot be reconstructed; preserve the repaired values.
    :ok
  end
end

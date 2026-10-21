defmodule Tidewake.Repo.Migrations.AddRetryCycleCountersToDeliveries do
  use Ecto.Migration

  def change do
    alter table(:deliveries) do
      add :retry_cycle, :integer, null: false, default: 0
      add :cycle_attempt_count, :integer, null: false, default: 0
    end

    create constraint(:deliveries, :deliveries_retry_cycle_in_range,
             check: "retry_cycle BETWEEN 0 AND 3"
           )

    create constraint(:deliveries, :deliveries_cycle_attempt_count_in_range,
             check: "cycle_attempt_count BETWEEN 0 AND 6"
           )
  end
end

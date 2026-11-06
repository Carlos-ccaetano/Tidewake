defmodule Tidewake.Repo.Migrations.AddDeliveryRecoveryCount do
  use Ecto.Migration

  def change do
    alter table(:deliveries) do
      add :recovery_count, :integer, null: false, default: 0
    end

    create constraint(:deliveries, :deliveries_recovery_count_in_range,
             check: "recovery_count BETWEEN 0 AND 6"
           )
  end
end

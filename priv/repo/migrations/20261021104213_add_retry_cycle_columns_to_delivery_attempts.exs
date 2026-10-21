defmodule Tidewake.Repo.Migrations.AddRetryCycleColumnsToDeliveryAttempts do
  use Ecto.Migration

  def change do
    alter table(:delivery_attempts) do
      add :retry_cycle, :integer
      add :cycle_attempt_number, :integer
    end
  end
end

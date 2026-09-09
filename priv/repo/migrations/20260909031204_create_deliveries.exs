defmodule Tidewake.Repo.Migrations.CreateDeliveries do
  use Ecto.Migration

  def change do
    create table(:deliveries) do
      add :event_id, references(:events, on_delete: :restrict), null: false
      add :endpoint_id, references(:endpoints, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deliveries, [:event_id])
    create index(:deliveries, [:endpoint_id])
    create index(:deliveries, [:status])
    create unique_index(:deliveries, [:event_id, :endpoint_id])
  end
end

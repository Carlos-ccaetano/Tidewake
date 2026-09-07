defmodule Tidewake.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :external_id, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:events, [:external_id])
  end
end

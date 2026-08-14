defmodule Tidewake.Repo.Migrations.CreateEndpoints do
  use Ecto.Migration

  def change do
    create table(:endpoints) do
      add :name, :string, null: false
      add :url, :text, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end
  end
end

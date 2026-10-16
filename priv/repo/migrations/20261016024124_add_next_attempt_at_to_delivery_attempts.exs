defmodule Tidewake.Repo.Migrations.AddNextAttemptAtToDeliveryAttempts do
  use Ecto.Migration

  def change do
    alter table(:delivery_attempts) do
      add :next_attempt_at, :utc_datetime_usec
    end
  end
end

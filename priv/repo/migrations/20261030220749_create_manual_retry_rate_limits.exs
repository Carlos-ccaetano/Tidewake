defmodule Tidewake.Repo.Migrations.CreateManualRetryRateLimits do
  use Ecto.Migration

  def change do
    create table(:manual_retry_rate_limits, primary_key: false) do
      add :service_account_id,
          references(:service_accounts,
            on_delete: :delete_all,
            name: :manual_retry_rate_limits_service_account_id_fkey
          ),
          primary_key: true

      add :tokens, :integer, null: false
      add :refilled_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:manual_retry_rate_limits, :manual_retry_rate_limits_tokens_in_range,
             check: "tokens BETWEEN 0 AND 5"
           )
  end
end

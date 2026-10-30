defmodule Tidewake.Projects.ManualRetryRateLimit do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:service_account_id, :id, autogenerate: false}
  schema "manual_retry_rate_limits" do
    field :tokens, :integer
    field :refilled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end

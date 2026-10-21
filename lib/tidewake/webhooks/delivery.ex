defmodule Tidewake.Webhooks.Delivery do
  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Webhooks.{Endpoint, Event, ManualRetryPolicy, RetryPolicy}

  @statuses ~w(pending processing succeeded failed cancelled)
  @fields [
    :status,
    :attempt_count,
    :retry_cycle,
    :cycle_attempt_count,
    :next_attempt_at,
    :completed_at
  ]

  schema "deliveries" do
    belongs_to :event, Event
    belongs_to :endpoint, Endpoint

    field :status, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :retry_cycle, :integer, default: 0
    field :cycle_attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @fields)
    |> validate_required([
      :event_id,
      :endpoint_id,
      :status,
      :attempt_count,
      :retry_cycle,
      :cycle_attempt_count
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:retry_cycle,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: ManualRetryPolicy.max_manual_cycles()
    )
    |> validate_number(:cycle_attempt_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: RetryPolicy.max_attempts()
    )
    |> check_constraint(:retry_cycle, name: :deliveries_retry_cycle_in_range)
    |> check_constraint(:cycle_attempt_count, name: :deliveries_cycle_attempt_count_in_range)
    |> unique_constraint([:event_id, :endpoint_id])
  end
end

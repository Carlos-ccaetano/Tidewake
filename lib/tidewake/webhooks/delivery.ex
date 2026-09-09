defmodule Tidewake.Webhooks.Delivery do
  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Webhooks.{Endpoint, Event}

  @statuses ~w(pending processing succeeded failed)
  @fields [:status, :attempt_count, :next_attempt_at, :completed_at]

  schema "deliveries" do
    belongs_to :event, Event
    belongs_to :endpoint, Endpoint

    field :status, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @fields)
    |> validate_required([:event_id, :endpoint_id, :status, :attempt_count])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:event_id, :endpoint_id])
  end
end

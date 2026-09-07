defmodule Tidewake.Webhooks.Event do
  use Ecto.Schema

  import Ecto.Changeset

  @fields [:external_id, :event_type, :payload]
  @string_column_max_length 255

  schema "events" do
    field :external_id, :string
    field :event_type, :string
    field :payload, :map

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_non_blank(:external_id)
    |> validate_non_blank(:event_type)
    |> validate_length(:external_id, max: @string_column_max_length)
    |> validate_length(:event_type, max: @string_column_max_length)
    |> unique_constraint(:external_id)
  end

  defp validate_non_blank(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if String.trim(value) == "", do: [{field, "can't be blank"}], else: []
    end)
  end
end

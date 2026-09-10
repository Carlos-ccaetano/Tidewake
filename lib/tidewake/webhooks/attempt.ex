defmodule Tidewake.Webhooks.Attempt do
  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Webhooks.Delivery

  @results ~w(succeeded http_error transport_error)
  @http_results ~w(succeeded http_error)
  @fields [
    :attempt_number,
    :result,
    :http_status,
    :error_type,
    :duration_ms,
    :started_at,
    :completed_at,
    :response_metadata
  ]
  @required_fields [
    :delivery_id,
    :attempt_number,
    :result,
    :duration_ms,
    :started_at,
    :completed_at
  ]
  @string_column_max_length 255
  @response_metadata_keys ~w(content_type content_length request_id)a
  @allowed_response_metadata_keys @response_metadata_keys ++
                                    Enum.map(@response_metadata_keys, &Atom.to_string/1)

  schema "delivery_attempts" do
    belongs_to :delivery, Delivery

    field :attempt_number, :integer
    field :result, :string
    field :http_status, :integer
    field :error_type, :string
    field :duration_ms, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :response_metadata, :map

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:result, @results)
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:http_status, greater_than_or_equal_to: 100, less_than_or_equal_to: 599)
    |> validate_length(:error_type, max: @string_column_max_length)
    |> validate_timestamp_order()
    |> validate_http_status()
    |> validate_response_metadata()
    |> unique_constraint([:delivery_id, :attempt_number])
  end

  defp validate_timestamp_order(changeset) do
    case {get_field(changeset, :started_at), get_field(changeset, :completed_at)} do
      {%DateTime{} = started_at, %DateTime{} = completed_at} ->
        if DateTime.compare(completed_at, started_at) == :lt do
          add_error(changeset, :completed_at, "must be equal to or later than started_at")
        else
          changeset
        end

      _other ->
        changeset
    end
  end

  defp validate_http_status(changeset) do
    validate_http_status(
      changeset,
      get_field(changeset, :result),
      get_field(changeset, :http_status)
    )
  end

  defp validate_http_status(changeset, result, nil) when result in @http_results do
    add_error(changeset, :http_status, "can't be blank")
  end

  defp validate_http_status(changeset, "transport_error", http_status)
       when not is_nil(http_status) do
    add_error(changeset, :http_status, "must be absent for a transport error")
  end

  defp validate_http_status(changeset, "succeeded", http_status)
       when http_status not in 200..299 do
    add_error(changeset, :http_status, "must be between 200 and 299 for a succeeded result")
  end

  defp validate_http_status(changeset, "http_error", http_status)
       when http_status in 200..299 do
    add_error(changeset, :http_status, "must be outside 200 through 299 for an HTTP error")
  end

  defp validate_http_status(changeset, _result, _http_status), do: changeset

  defp validate_response_metadata(changeset) do
    validate_change(changeset, :response_metadata, fn :response_metadata, metadata ->
      cond do
        Enum.any?(Map.keys(metadata), &(&1 not in @allowed_response_metadata_keys)) ->
          [response_metadata: "contains unsupported keys"]

        not valid_bounded_string?(metadata_value(metadata, :content_type)) ->
          [response_metadata: "content_type must be a string of at most 255 bytes"]

        not valid_content_length?(metadata_value(metadata, :content_length)) ->
          [response_metadata: "content_length must be a non-negative integer"]

        not valid_bounded_string?(metadata_value(metadata, :request_id)) ->
          [response_metadata: "request_id must be a string of at most 255 bytes"]

        true ->
          []
      end
    end)
  end

  defp metadata_value(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp valid_bounded_string?(nil), do: true

  defp valid_bounded_string?(value) when is_binary(value) do
    byte_size(value) <= @string_column_max_length
  end

  defp valid_bounded_string?(_value), do: false

  defp valid_content_length?(nil), do: true
  defp valid_content_length?(value), do: is_integer(value) and value >= 0
end

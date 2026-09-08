defmodule TidewakeWeb.EventController do
  use TidewakeWeb, :controller

  alias Tidewake.Webhooks

  def show(conn, %{"id" => id}) do
    case fetch_event(id) do
      {:ok, event} -> json(conn, %{data: event_data(event)})
      :error -> not_found(conn)
    end
  end

  def create(conn, params) do
    attrs = %{
      external_id: params["external_id"],
      event_type: params["type"],
      payload: params["data"]
    }

    case Webhooks.create_event(attrs) do
      {:ok, event} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", "/api/events/#{event.id}")
        |> json(%{data: event_data(event)})

      {:error, changeset} ->
        if external_id_conflict?(changeset) do
          conflict(conn)
        else
          validation_error(conn, changeset)
        end
    end
  end

  defp event_data(event) do
    %{
      id: event.id,
      external_id: event.external_id,
      type: event.event_type,
      data: event.payload,
      inserted_at: DateTime.to_iso8601(event.inserted_at),
      updated_at: DateTime.to_iso8601(event.updated_at)
    }
  end

  defp fetch_event(id) do
    case Integer.parse(id) do
      {parsed_id, ""} when parsed_id > 0 ->
        case Webhooks.get_event(parsed_id) do
          nil -> :error
          event -> {:ok, event}
        end

      _other ->
        :error
    end
  end

  defp external_id_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:external_id, {_message, options}} -> options[:constraint] == :unique
      _other -> false
    end)
  end

  defp conflict(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "external_id_conflict",
        message: "An event with this external_id already exists"
      }
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Event not found"}})
  end

  defp validation_error(conn, changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(&format_error/1)
      |> Map.new(&api_error/1)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp format_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, formatted_message ->
      String.replace(formatted_message, "%{#{key}}", to_string(value))
    end)
  end

  defp api_error({:event_type, messages}), do: {:type, messages}

  defp api_error({:payload, messages}) do
    {:data, Enum.map(messages, &payload_error/1)}
  end

  defp api_error(error), do: error

  defp payload_error("is invalid"), do: "must be a JSON object"
  defp payload_error(message), do: message
end

defmodule TidewakeWeb.EndpointController do
  use TidewakeWeb, :controller

  alias Tidewake.Webhooks

  def index(conn, _params) do
    endpoints = Enum.map(Webhooks.list_endpoints(), &endpoint_data/1)

    json(conn, %{data: endpoints})
  end

  def show(conn, %{"id" => id}) do
    case fetch_endpoint(id) do
      {:ok, endpoint} -> json(conn, %{data: endpoint_data(endpoint)})
      :error -> not_found(conn)
    end
  end

  def create(conn, params) do
    case Webhooks.create_endpoint(params) do
      {:ok, endpoint} ->
        conn
        |> put_status(:created)
        |> json(%{data: endpoint_data(endpoint)})

      {:error, changeset} ->
        validation_error(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case fetch_endpoint(id) do
      {:ok, endpoint} -> update_endpoint(conn, endpoint, params)
      :error -> not_found(conn)
    end
  end

  defp update_endpoint(conn, endpoint, params) do
    case Webhooks.update_endpoint(endpoint, params) do
      {:ok, endpoint} -> json(conn, %{data: endpoint_data(endpoint)})
      {:error, changeset} -> validation_error(conn, changeset)
    end
  end

  defp fetch_endpoint(id) do
    case Integer.parse(id) do
      {parsed_id, ""} when parsed_id > 0 ->
        case Webhooks.get_endpoint(parsed_id) do
          nil -> :error
          endpoint -> {:ok, endpoint}
        end

      _other ->
        :error
    end
  end

  defp endpoint_data(endpoint) do
    %{
      id: endpoint.id,
      name: endpoint.name,
      url: endpoint.url,
      active: endpoint.active,
      inserted_at: DateTime.to_iso8601(endpoint.inserted_at),
      updated_at: DateTime.to_iso8601(endpoint.updated_at)
    }
  end

  defp validation_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, formatted_message ->
          String.replace(formatted_message, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Endpoint not found"}})
  end
end

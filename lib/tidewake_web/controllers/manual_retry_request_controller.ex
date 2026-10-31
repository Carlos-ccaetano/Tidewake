defmodule TidewakeWeb.ManualRetryRequestController do
  use TidewakeWeb, :controller

  alias Plug.Conn.Utils
  alias Tidewake.Projects.ManualRetryRateLimiter
  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.ManualRetryIdempotency

  @reasons ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached)

  def index(conn, %{"delivery_id" => id}) do
    with {:ok, delivery_id} <- delivery_id(id),
         {:ok, options} <- audit_options(conn.query_string) do
      {valid_body?, conn} = absent_body(conn)

      if valid_body?,
        do:
          audit_result(
            conn,
            Webhooks.list_manual_retry_audit(conn.assigns.current_scope, delivery_id, options)
          ),
        else: invalid_request(conn)
    else
      _invalid -> invalid_request(conn)
    end
  end

  defp audit_options(query) do
    pairs = query |> URI.query_decoder() |> Enum.to_list()
    values = Map.new(pairs)

    with true <- length(pairs) == map_size(values),
         true <- Enum.all?(pairs, fn {key, _value} -> key in ["limit", "before_id"] end),
         {:ok, limit} <- optional_audit_integer(values["limit"], 50),
         true <- limit <= 100,
         {:ok, cursor} <- optional_audit_integer(values["before_id"], nil) do
      {:ok, %{limit: limit, before_id: cursor}}
    else
      _invalid -> {:error, :invalid_request}
    end
  rescue
    ArgumentError -> {:error, :invalid_request}
  end

  defp optional_audit_integer(nil, default), do: {:ok, default}
  defp optional_audit_integer(value, _default), do: delivery_id(value)

  defp absent_body(conn) do
    case read_body(conn, length: 1, read_length: 1, read_timeout: 1000) do
      {:ok, "", conn} -> {true, conn}
      {:ok, _body, conn} -> {false, conn}
      {:more, _body, conn} -> {false, conn}
      {:error, _reason} -> {false, conn}
    end
  end

  defp audit_result(conn, {:ok, %{data: data, page: page}}) do
    data =
      Enum.map(data, fn row ->
        %{
          id: row.id,
          delivery_id: row.delivery_id,
          outcome: row.outcome,
          reason: row.reason,
          requested_at: DateTime.to_iso8601(row.requested_at),
          resulting_retry_cycle: row.resulting_retry_cycle,
          actor_type: row.actor_type,
          actor_subject: row.actor_subject,
          source: row.source
        }
      end)

    json(conn, %{data: data, page: page})
  end

  defp audit_result(conn, {:error, _reason} = result), do: command_result(conn, result)

  def create(conn, %{"delivery_id" => id}) do
    scope = conn.assigns.current_scope

    # Request-local test time leaves production on the limiter's database clock.
    case ManualRetryRateLimiter.consume(scope.service_account_id, conn.private[:manual_retry_now]) do
      :allowed ->
        admitted(conn, scope, id)

      {:denied, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> error(429, "rate_limited", "Retry request limit exceeded")

      {:error, :unavailable} ->
        unavailable(conn)
    end
  end

  defp admitted(conn, scope, id) do
    with {:ok, delivery_id} <- delivery_id(id),
         [key] <- get_req_header(conn, "idempotency-key"),
         {:ok, _prepared} <-
           ManualRetryIdempotency.prepare(scope.project_public_id, delivery_id, key) do
      {valid_body?, conn} = empty_body(conn)

      if valid_body? and conn.query_string == "" do
        command_result(conn, Webhooks.request_manual_retry(scope, delivery_id, key))
      else
        invalid_request(conn)
      end
    else
      {:error, :invalid_request} ->
        invalid_request(conn)

      _invalid_key ->
        error(conn, 400, "invalid_idempotency_key", "Valid Idempotency-Key required")
    end
  end

  defp delivery_id(id) when is_binary(id) and byte_size(id) in 1..19 do
    case Integer.parse(id) do
      {value, ""} when value > 0 and value <= 9_223_372_036_854_775_807 ->
        if Integer.to_string(value) == id, do: {:ok, value}, else: {:error, :invalid_request}

      _invalid ->
        {:error, :invalid_request}
    end
  end

  defp delivery_id(_id), do: {:error, :invalid_request}

  defp empty_body(conn) do
    case read_body(conn, length: 1024, read_length: 1024, read_timeout: 1000) do
      {:ok, "", conn} -> {true, conn}
      {:ok, body, conn} -> {json_body?(conn) and Jason.decode(body) == {:ok, %{}}, conn}
      {:more, _body, conn} -> {false, conn}
      {:error, _reason} -> {false, conn}
    end
  end

  defp json_body?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> match?({:ok, "application", "json", _params}, Utils.media_type(type))
      _other -> false
    end
  end

  defp command_result(
         conn,
         {:ok, %{request: %{outcome: "accepted", reason: nil} = request, replayed?: replayed}}
       ),
       do: decision(conn, 202, request, replayed)

  defp command_result(
         conn,
         {:ok, %{request: %{outcome: "rejected", reason: reason} = request, replayed?: replayed}}
       )
       when reason in @reasons,
       do: decision(conn, 409, request, replayed)

  defp command_result(conn, {:error, :forbidden}),
    do: error(conn, 403, "forbidden", "Permission denied")

  defp command_result(conn, {:error, :not_found}),
    do: error(conn, 404, "not_found", "Delivery not found")

  defp command_result(conn, {:error, :invalid_arguments}), do: invalid_request(conn)

  defp command_result(conn, {:error, :invalid_idempotency_key}),
    do: error(conn, 400, "invalid_idempotency_key", "Valid Idempotency-Key required")

  defp command_result(conn, {:error, :idempotency_conflict}),
    do: error(conn, 409, "idempotency_conflict", "Idempotency key conflicts with this request")

  defp command_result(conn, {:error, :active_job}),
    do: error(conn, 409, "active_job", "Delivery already has active work")

  defp command_result(conn, {:error, :persistence_error}), do: unavailable(conn)
  defp command_result(conn, _unexpected), do: unavailable(conn)

  defp decision(conn, status, request, replayed) do
    conn
    |> put_status(status)
    |> json(%{
      data: %{
        id: request.id,
        delivery_id: request.delivery_id,
        outcome: request.outcome,
        reason: request.reason,
        requested_at: DateTime.to_iso8601(request.requested_at),
        resulting_retry_cycle: request.resulting_retry_cycle,
        replayed: replayed
      }
    })
  end

  defp invalid_request(conn), do: error(conn, 400, "invalid_request", "Invalid retry request")
  defp unavailable(conn), do: error(conn, 503, "service_unavailable", "Service unavailable")

  defp error(conn, status, code, message) do
    conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
  end
end

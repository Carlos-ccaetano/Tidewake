defmodule Tidewake.Webhooks.DeliveryProcessor do
  @moduledoc """
  Processes HTTP delivery outcomes using a supplied delivery adapter.

  Returns the finalized delivery and attempt, or a controlled error. Execution
  or persistence errors after claim leave the delivery in processing; recovery
  is not implemented.
  """

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.Envelope
  alias Tidewake.Webhooks.ResponseMetadata

  @delivery_cancelled [:tidewake, :webhooks, :delivery, :cancelled]
  @delivery_processed [:tidewake, :webhooks, :delivery, :processed]
  @delivery_error [:tidewake, :webhooks, :delivery, :error]
  @outcomes ~w(succeeded http_error transport_error)

  def process(delivery_id, adapter) do
    started = System.monotonic_time(:millisecond)
    result = process_delivery(delivery_id, adapter)
    duration_ms = System.monotonic_time(:millisecond) - started

    emit_processing_telemetry(result, duration_ms)
  end

  defp process_delivery(delivery_id, adapter) do
    with {:ok, delivery} <- Webhooks.claim_delivery(delivery_id),
         {:ok, body} <- Envelope.encode(delivery.event) do
      started_at = DateTime.utc_now()
      started = System.monotonic_time(:millisecond)

      result =
        adapter.deliver(delivery.endpoint.url, body, [{"content-type", "application/json"}])

      duration_ms = System.monotonic_time(:millisecond) - started
      completed_at = DateTime.utc_now()

      finalize(delivery.id, result, %{
        started_at: started_at,
        completed_at: completed_at,
        duration_ms: duration_ms
      })
    else
      {:cancelled, delivery} -> {:ok, %{delivery: delivery, attempt: nil}}
      result -> result
    end
  end

  defp finalize(id, {:ok, %{status: status, headers: headers}}, timing)
       when is_integer(status) and status in 100..599 and is_list(headers) do
    if valid_headers?(headers) do
      Webhooks.finalize_delivery(
        id,
        Map.merge(timing, %{
          result: if(status in 200..299, do: "succeeded", else: "http_error"),
          http_status: status,
          response_metadata: ResponseMetadata.extract(headers)
        })
      )
    else
      {:error, :invalid_adapter_response}
    end
  end

  defp finalize(id, {:error, reason}, timing) when is_atom(reason) do
    Webhooks.finalize_delivery(
      id,
      Map.merge(timing, %{
        result: "transport_error",
        error_type: transport_error_type(reason)
      })
    )
  end

  defp finalize(_id, _response, _timing), do: {:error, :invalid_adapter_response}

  defp emit_processing_telemetry(
         {:ok, %{delivery: %{status: "cancelled"}, attempt: nil}} = result,
         _duration_ms
       ) do
    :telemetry.execute(
      @delivery_cancelled,
      %{count: 1},
      %{reason: "endpoint_inactive"}
    )

    result
  end

  defp emit_processing_telemetry(
         {:ok, %{attempt: %{result: outcome}}} = result,
         duration_ms
       )
       when outcome in @outcomes do
    :telemetry.execute(
      @delivery_processed,
      %{count: 1, duration_ms: duration_ms},
      %{outcome: outcome}
    )

    result
  end

  defp emit_processing_telemetry({:error, reason} = result, duration_ms) do
    :telemetry.execute(
      @delivery_error,
      %{count: 1, duration_ms: duration_ms},
      %{reason: processing_error_reason(reason)}
    )

    result
  end

  defp emit_processing_telemetry(result, _duration_ms), do: result

  defp processing_error_reason(:not_found), do: "not_found"
  defp processing_error_reason(:invalid_transition), do: "invalid_transition"
  defp processing_error_reason(:invalid_adapter_response), do: "invalid_adapter_response"
  defp processing_error_reason(:invalid_json), do: "encoding"
  defp processing_error_reason(%Ecto.Changeset{}), do: "persistence"
  defp processing_error_reason(_reason), do: "unknown"

  defp transport_error_type(:timeout), do: "timeout"
  defp transport_error_type(:dns_error), do: "dns"
  defp transport_error_type(:tls_error), do: "tls"
  defp transport_error_type(:connection_refused), do: "connection"
  defp transport_error_type(:connection_closed), do: "closed"
  defp transport_error_type(_reason), do: "unknown"

  defp valid_headers?([]), do: true

  defp valid_headers?([{name, value} | rest]) when is_binary(name) and is_binary(value),
    do: valid_headers?(rest)

  defp valid_headers?(_headers), do: false
end

defmodule Tidewake.Webhooks.DeliveryProcessor do
  @moduledoc """
  Processes HTTP delivery outcomes using a supplied delivery adapter.

  Returns the finalized delivery and attempt, or a controlled error. Unexpected
  errors after claim can leave a delivery in `processing`. Periodic stale-delivery
  recovery can return it to `pending`, so a later execution may resend a request
  whose result was not persisted. This provides at-least-once delivery semantics.
  """

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Envelope, ResponseMetadata, RetryBackoff, RetryPolicy, Signature}

  @delivery_cancelled [:tidewake, :webhooks, :delivery, :cancelled]
  @delivery_processed [:tidewake, :webhooks, :delivery, :processed]
  @delivery_error [:tidewake, :webhooks, :delivery, :error]
  @outcomes ~w(succeeded http_error transport_error)

  def process(delivery_id, adapter) do
    process(delivery_id, 1, adapter)
  end

  def process(delivery_id, attempt_number, adapter) do
    started = System.monotonic_time(:millisecond)
    result = process_delivery(delivery_id, attempt_number, adapter)
    duration_ms = System.monotonic_time(:millisecond) - started

    emit_processing_telemetry(result, duration_ms)
  end

  defp process_delivery(delivery_id, attempt_number, adapter) do
    with {:ok, secret} <- signing_secret(),
         reference_time = DateTime.utc_now(),
         {:ok, delivery} <-
           Webhooks.claim_delivery(delivery_id, attempt_number, reference_time),
         {:ok, body} <- Envelope.encode(delivery.event),
         timestamp = System.system_time(:second),
         {:ok, signature_headers} <-
           Signature.headers(delivery.event.external_id, timestamp, body, secret) do
      started_at = DateTime.utc_now()
      started = System.monotonic_time(:millisecond)
      headers = [{"content-type", "application/json"} | signature_headers]

      result = adapter.deliver(delivery.endpoint.url, body, headers)

      duration_ms = System.monotonic_time(:millisecond) - started
      completed_at = DateTime.utc_now()

      finalize(delivery.id, attempt_number, result, %{
        started_at: started_at,
        completed_at: completed_at,
        duration_ms: duration_ms
      })
    else
      {:cancelled, delivery} -> {:ok, %{delivery: delivery, attempt: nil}}
      result -> result
    end
  end

  defp finalize(delivery_id, attempt_number, response, timing) do
    with {:ok, attempt_attrs} <- normalize_outcome(response, timing) do
      persist_outcome(delivery_id, attempt_number, attempt_attrs)
    end
  end

  defp normalize_outcome({:ok, %{status: status, headers: headers}}, timing)
       when is_integer(status) and status in 100..599 and is_list(headers) do
    if valid_headers?(headers) do
      {:ok,
       Map.merge(timing, %{
         result: if(status in 200..299, do: "succeeded", else: "http_error"),
         http_status: status,
         response_metadata: ResponseMetadata.extract(headers)
       })}
    else
      {:error, :invalid_adapter_response}
    end
  end

  defp normalize_outcome({:error, reason}, timing) when is_atom(reason) do
    {:ok,
     Map.merge(timing, %{
       result: "transport_error",
       error_type: transport_error_type(reason)
     })}
  end

  defp normalize_outcome(_response, _timing), do: {:error, :invalid_adapter_response}

  defp persist_outcome(delivery_id, attempt_number, attempt_attrs) do
    case RetryPolicy.classify(attempt_attrs, attempt_number) do
      decision when decision in [:succeeded, :permanent_failure, :exhausted] ->
        Webhooks.finalize_delivery(delivery_id, attempt_attrs)

      :retry ->
        with {:ok, delay_seconds} <- RetryBackoff.delay_seconds(attempt_number) do
          retry_at = DateTime.add(attempt_attrs.completed_at, delay_seconds, :second)
          Webhooks.schedule_delivery_retry(delivery_id, attempt_attrs, retry_at)
        end
    end
  end

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
  defp processing_error_reason(:stale_attempt), do: "stale_attempt"
  defp processing_error_reason(:not_due), do: "not_due"
  defp processing_error_reason(:invalid_adapter_response), do: "invalid_adapter_response"
  defp processing_error_reason(:invalid_json), do: "encoding"
  defp processing_error_reason(:invalid_signing_configuration), do: "signing_configuration"
  defp processing_error_reason(%Ecto.Changeset{}), do: "persistence"
  defp processing_error_reason(_reason), do: "unknown"

  defp signing_secret do
    case Application.fetch_env(:tidewake, :webhook_signing_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _invalid -> {:error, :invalid_signing_configuration}
    end
  end

  defp transport_error_type(:timeout), do: "timeout"
  defp transport_error_type(:dns_error), do: "dns"
  defp transport_error_type(:tls_error), do: "tls"
  defp transport_error_type(:connection_refused), do: "connection"
  defp transport_error_type(:connection_closed), do: "closed"
  defp transport_error_type(:unsafe_destination), do: "destination"
  defp transport_error_type(:response_too_large), do: "response_limit"
  defp transport_error_type(_reason), do: "unknown"

  defp valid_headers?([]), do: true

  defp valid_headers?([{name, value} | rest]) when is_binary(name) and is_binary(value),
    do: valid_headers?(rest)

  defp valid_headers?(_headers), do: false
end

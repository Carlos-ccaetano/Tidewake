defmodule Tidewake.Webhooks.DeliveryProcessor do
  @moduledoc """
  Processes HTTP delivery outcomes using a supplied delivery adapter.

  Returns the finalized delivery and attempt, or a controlled error. Errors
  after claim leave the delivery in processing; recovery is not implemented.
  """

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.Envelope
  alias Tidewake.Webhooks.ResponseMetadata

  def process(delivery_id, adapter) do
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

  defp finalize(_id, {:error, reason}, _timing) when is_atom(reason), do: {:error, reason}
  defp finalize(_id, _response, _timing), do: {:error, :invalid_adapter_response}

  defp valid_headers?([]), do: true

  defp valid_headers?([{name, value} | rest]) when is_binary(name) and is_binary(value),
    do: valid_headers?(rest)

  defp valid_headers?(_headers), do: false
end

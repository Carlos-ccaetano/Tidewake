defmodule Tidewake.Webhooks.DeliveryProcessor do
  @moduledoc """
  Processes successful deliveries using a supplied delivery adapter.

  Returns the finalized delivery and attempt, or a controlled error. Errors
  after claim leave the delivery in processing; recovery is not implemented.
  """

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.Envelope

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

  defp finalize(id, {:ok, %{status: status}}, timing) when status in 200..299 do
    Webhooks.finalize_delivery(id, Map.merge(timing, %{result: "succeeded", http_status: status}))
  end

  defp finalize(_id, {:error, reason}, _timing) when is_atom(reason), do: {:error, reason}
  defp finalize(_id, {:ok, _response}, _timing), do: {:error, :unexpected_http_status}
end

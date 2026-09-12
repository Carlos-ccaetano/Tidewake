defmodule Tidewake.Webhooks.Envelope do
  @moduledoc """
  Encodes an event as an outbound webhook envelope without changing its payload.
  """

  alias Tidewake.Webhooks.Event

  @doc """
  Returns JSON containing the external ID, event type and payload.

  Returns `{:error, :invalid_json}` when the envelope cannot be encoded.
  """
  def encode(%Event{} = event) do
    case Jason.encode(%{id: event.external_id, type: event.event_type, data: event.payload}) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end
end

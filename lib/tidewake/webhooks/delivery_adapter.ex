defmodule Tidewake.Webhooks.DeliveryAdapter do
  @moduledoc """
  Contract for sending an already serialized body to an endpoint URL with prepared headers.

  Adapters return transport outcomes only. Delivery state, retry decisions and
  attempt persistence belong to the caller. Adapters do not access the database
  or depend on event structures or consumer-specific rules.
  """

  @type headers :: [{String.t(), String.t()}]
  @type response :: %{status: pos_integer(), headers: headers()}
  @type result :: {:ok, response()} | {:error, atom()}

  @doc """
  Sends the binary body with the supplied headers.

  Any HTTP response, including a non-2xx response, returns `{:ok, response}`.
  Failures without an HTTP response return `{:error, reason}` with an atom reason.
  """
  @callback deliver(url :: String.t(), body :: binary(), headers :: headers()) :: result()
end

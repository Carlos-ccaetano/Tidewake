defmodule Tidewake.Webhooks.DeliveryAdapters.Deterministic do
  @moduledoc """
  Local adapter for flow validation; not a production transport.

  Always returns a simulated HTTP 204 response with no headers, regardless of
  the supplied URL, serialized body or prepared headers. Performs no I/O.
  """

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(_url, _body, _headers), do: {:ok, %{status: 204, headers: []}}
end

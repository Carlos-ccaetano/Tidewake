defmodule Tidewake.Webhooks.OutboundResolver do
  @moduledoc """
  Defines the replaceable boundary for resolving outbound destination hostnames.
  """

  @type address :: :inet.ip_address()
  @type result :: {:ok, [address()]} | {:error, :dns_error}

  @callback resolve(String.t()) :: result()
end

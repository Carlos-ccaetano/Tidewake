defmodule Tidewake.Webhooks.OutboundResolvers.System do
  @moduledoc """
  Resolves both IP families through the Erlang runtime without caching results.
  """

  @behaviour Tidewake.Webhooks.OutboundResolver

  alias Tidewake.Webhooks.OutboundResolver

  @type lookup :: (:inet.hostname(), :inet | :inet6 -> {:ok, [term()]} | {:error, term()})

  @impl OutboundResolver
  def resolve(hostname) when is_binary(hostname) do
    resolve(hostname, &:inet.getaddrs/2)
  end

  def resolve(_hostname), do: {:error, :dns_error}

  @doc false
  @spec resolve(String.t(), lookup()) :: OutboundResolver.result()
  def resolve(hostname, lookup) when is_binary(hostname) and is_function(lookup, 2) do
    hostname = String.to_charlist(hostname)

    addresses =
      hostname
      |> resolve_families(lookup)
      |> Enum.uniq()
      |> Enum.sort()

    case addresses do
      [] -> {:error, :dns_error}
      addresses -> {:ok, addresses}
    end
  end

  defp resolve_families(hostname, lookup) do
    ipv4 = hostname |> lookup.(:inet) |> addresses_for(:inet)
    ipv6 = hostname |> lookup.(:inet6) |> addresses_for(:inet6)

    ipv4 ++ ipv6
  end

  defp addresses_for({:ok, addresses}, family) when is_list(addresses) do
    Enum.filter(addresses, &address_for_family?(&1, family))
  end

  defp addresses_for(_result, _family), do: []

  defp address_for_family?({a, b, c, d}, :inet) do
    Enum.all?([a, b, c, d], &valid_segment?(&1, 0xFF))
  end

  defp address_for_family?({a, b, c, d, e, f, g, h}, :inet6) do
    Enum.all?([a, b, c, d, e, f, g, h], &valid_segment?(&1, 0xFFFF))
  end

  defp address_for_family?(_address, _family), do: false

  defp valid_segment?(segment, maximum) do
    is_integer(segment) and segment >= 0 and segment <= maximum
  end
end

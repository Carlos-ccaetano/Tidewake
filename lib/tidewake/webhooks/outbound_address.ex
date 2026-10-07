defmodule Tidewake.Webhooks.OutboundAddress do
  @moduledoc """
  Classifies runtime IPv4 and IPv6 address tuples without resolving a hostname.
  """

  import Bitwise

  @type category :: :global | :private | :loopback | :link_local | :special

  @ipv4_private_prefixes [
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16}
  ]

  @ipv4_loopback_prefixes [{{127, 0, 0, 0}, 8}]
  @ipv4_link_local_prefixes [{{169, 254, 0, 0}, 16}]

  @ipv4_special_prefixes [
    {{0, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @ipv4_global_exceptions [{192, 0, 0, 9}, {192, 0, 0, 10}]

  @ipv6_private_prefixes [{{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7}]
  @ipv6_link_local_prefixes [{{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10}]

  @ipv6_special_prefixes [
    {{0x0064, 0xFF9B, 0x0001, 0, 0, 0, 0, 0}, 48},
    {{0x0100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x0100, 0, 0, 0x0001, 0, 0, 0, 0}, 64},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20},
    {{0x5F00, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @ipv6_global_exceptions [
    {{0x2001, 0x0001, 0, 0, 0, 0, 0, 0x0001}, 128},
    {{0x2001, 0x0001, 0, 0, 0, 0, 0, 0x0002}, 128},
    {{0x2001, 0x0001, 0, 0, 0, 0, 0, 0x0003}, 128},
    {{0x2001, 0x0003, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2001, 0x0004, 0x0112, 0, 0, 0, 0, 0}, 48},
    {{0x2001, 0x0020, 0, 0, 0, 0, 0, 0}, 28},
    {{0x2001, 0x0030, 0, 0, 0, 0, 0, 0}, 28}
  ]

  @spec classify(term()) :: category() | {:error, :invalid_address}
  def classify({_, _, _, _} = address) do
    if valid_segments?(address, 0xFF), do: classify_ipv4(address), else: invalid_address()
  end

  def classify({_, _, _, _, _, _, _, _} = address) do
    if valid_segments?(address, 0xFFFF), do: classify_ipv6(address), else: invalid_address()
  end

  def classify(_address), do: invalid_address()

  defp classify_ipv4(address) do
    cond do
      address in @ipv4_global_exceptions -> :global
      in_ipv4_prefixes?(address, @ipv4_private_prefixes) -> :private
      in_ipv4_prefixes?(address, @ipv4_loopback_prefixes) -> :loopback
      in_ipv4_prefixes?(address, @ipv4_link_local_prefixes) -> :link_local
      in_ipv4_prefixes?(address, @ipv4_special_prefixes) -> :special
      true -> :global
    end
  end

  defp classify_ipv6({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    classify_ipv4({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp classify_ipv6({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback
  defp classify_ipv6({0, 0, 0, 0, 0, 0, 0, 0}), do: :special

  defp classify_ipv6(address) do
    cond do
      in_ipv6_prefixes?(address, @ipv6_global_exceptions) -> :global
      in_ipv6_prefixes?(address, @ipv6_private_prefixes) -> :private
      in_ipv6_prefixes?(address, @ipv6_link_local_prefixes) -> :link_local
      in_ipv6_prefixes?(address, @ipv6_special_prefixes) -> :special
      true -> :global
    end
  end

  defp in_ipv4_prefixes?(address, prefixes) do
    address = ipv4_to_integer(address)

    Enum.any?(prefixes, fn {network, prefix_length} ->
      in_prefix?(address, ipv4_to_integer(network), prefix_length, 32)
    end)
  end

  defp in_ipv6_prefixes?(address, prefixes) do
    address = ipv6_to_integer(address)

    Enum.any?(prefixes, fn {network, prefix_length} ->
      in_prefix?(address, ipv6_to_integer(network), prefix_length, 128)
    end)
  end

  defp in_prefix?(address, network, prefix_length, width) do
    shift = width - prefix_length
    address >>> shift == network >>> shift
  end

  defp valid_segments?(address, maximum) do
    address
    |> Tuple.to_list()
    |> Enum.all?(fn segment ->
      is_integer(segment) and segment >= 0 and segment <= maximum
    end)
  end

  defp invalid_address, do: {:error, :invalid_address}

  defp ipv4_to_integer({a, b, c, d}) do
    a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  end

  defp ipv6_to_integer({a, b, c, d, e, f, g, h}) do
    a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 |||
      f <<< 32 ||| g <<< 16 ||| h
  end
end

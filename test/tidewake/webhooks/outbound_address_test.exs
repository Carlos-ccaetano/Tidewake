defmodule Tidewake.Webhooks.OutboundAddressTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Tidewake.Webhooks.OutboundAddress

  describe "classify/1 with IPv4 addresses" do
    test "classifies private-use ranges and their boundaries" do
      assert_ipv4_range(:private, {10, 0, 0, 0}, {10, 255, 255, 255})
      assert OutboundAddress.classify({9, 255, 255, 255}) == :global
      assert OutboundAddress.classify({11, 0, 0, 0}) == :global

      assert_ipv4_range(:private, {172, 16, 0, 0}, {172, 31, 255, 255})
      assert OutboundAddress.classify({172, 15, 255, 255}) == :global
      assert OutboundAddress.classify({172, 32, 0, 0}) == :global

      assert_ipv4_range(:private, {192, 168, 0, 0}, {192, 168, 255, 255})
      assert OutboundAddress.classify({192, 167, 255, 255}) == :global
      assert OutboundAddress.classify({192, 169, 0, 0}) == :global
    end

    test "classifies loopback and link-local ranges and their boundaries" do
      assert_ipv4_range(:loopback, {127, 0, 0, 0}, {127, 255, 255, 255})
      assert OutboundAddress.classify({126, 255, 255, 255}) == :global
      assert OutboundAddress.classify({128, 0, 0, 0}) == :global

      assert_ipv4_range(:link_local, {169, 254, 0, 0}, {169, 254, 255, 255})
      assert OutboundAddress.classify({169, 253, 255, 255}) == :global
      assert OutboundAddress.classify({169, 255, 0, 0}) == :global
    end

    test "classifies shared CGNAT and benchmarking ranges and their boundaries" do
      assert_ipv4_range(:special, {100, 64, 0, 0}, {100, 127, 255, 255})
      assert OutboundAddress.classify({100, 63, 255, 255}) == :global
      assert OutboundAddress.classify({100, 128, 0, 0}) == :global

      assert_ipv4_range(:special, {198, 18, 0, 0}, {198, 19, 255, 255})
      assert OutboundAddress.classify({198, 17, 255, 255}) == :global
      assert OutboundAddress.classify({198, 20, 0, 0}) == :global
    end

    test "classifies documentation ranges" do
      assert_ipv4_range(:special, {192, 0, 2, 0}, {192, 0, 2, 255})
      assert OutboundAddress.classify({192, 0, 1, 255}) == :global
      assert OutboundAddress.classify({192, 0, 3, 0}) == :global

      assert_ipv4_range(:special, {198, 51, 100, 0}, {198, 51, 100, 255})
      assert OutboundAddress.classify({198, 51, 99, 255}) == :global
      assert OutboundAddress.classify({198, 51, 101, 0}) == :global

      assert_ipv4_range(:special, {203, 0, 113, 0}, {203, 0, 113, 255})
      assert OutboundAddress.classify({203, 0, 112, 255}) == :global
      assert OutboundAddress.classify({203, 0, 114, 0}) == :global
    end

    test "classifies unspecified, protocol-assignment, and deprecated ranges" do
      assert_ipv4_range(:special, {0, 0, 0, 0}, {0, 255, 255, 255})
      assert OutboundAddress.classify({1, 0, 0, 0}) == :global

      assert OutboundAddress.classify({192, 0, 0, 8}) == :special
      assert OutboundAddress.classify({192, 0, 0, 9}) == :global
      assert OutboundAddress.classify({192, 0, 0, 10}) == :global
      assert OutboundAddress.classify({192, 0, 0, 11}) == :special

      assert_ipv4_range(:special, {192, 88, 99, 0}, {192, 88, 99, 255})
      assert OutboundAddress.classify({192, 88, 98, 255}) == :global
      assert OutboundAddress.classify({192, 88, 100, 0}) == :global
    end

    test "classifies multicast, reserved, and broadcast addresses" do
      assert_ipv4_range(:special, {224, 0, 0, 0}, {239, 255, 255, 255})
      assert OutboundAddress.classify({223, 255, 255, 255}) == :global

      assert_ipv4_range(:special, {240, 0, 0, 0}, {255, 255, 255, 255})
      assert OutboundAddress.classify({255, 255, 255, 255}) == :special
    end

    test "classifies ordinary and globally reachable special-purpose addresses as global" do
      assert OutboundAddress.classify({1, 1, 1, 1}) == :global
      assert OutboundAddress.classify({8, 8, 8, 8}) == :global
      assert OutboundAddress.classify({192, 31, 196, 1}) == :global
      assert OutboundAddress.classify({192, 52, 193, 1}) == :global
      assert OutboundAddress.classify({192, 175, 48, 1}) == :global
    end
  end

  describe "classify/1 with IPv6 addresses" do
    test "classifies loopback and unspecified addresses" do
      assert OutboundAddress.classify({0, 0, 0, 0, 0, 0, 0, 1}) == :loopback
      assert OutboundAddress.classify({0, 0, 0, 0, 0, 0, 0, 0}) == :special
    end

    test "classifies unique-local ranges and their boundaries" do
      assert_ipv6_range(
        :private,
        {0xFC00, 0, 0, 0, 0, 0, 0, 0},
        {0xFDFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify(
               {0xFBFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :global

      assert OutboundAddress.classify({0xFE00, 0, 0, 0, 0, 0, 0, 0}) == :global
    end

    test "classifies link-local ranges and their boundaries" do
      assert_ipv6_range(
        :link_local,
        {0xFE80, 0, 0, 0, 0, 0, 0, 0},
        {0xFEBF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify(
               {0xFE7F, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :global

      assert OutboundAddress.classify({0xFEC0, 0, 0, 0, 0, 0, 0, 0}) == :global
    end

    test "classifies multicast addresses and the preceding boundary" do
      assert_ipv6_range(
        :special,
        {0xFF00, 0, 0, 0, 0, 0, 0, 0},
        {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify(
               {0xFEFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :global
    end

    test "classifies translation, discard-only, and dummy prefixes" do
      assert OutboundAddress.classify({0x0064, 0xFF9B, 0, 0, 0, 0, 0, 1}) == :global

      assert_ipv6_range(
        :special,
        {0x0064, 0xFF9B, 0x0001, 0, 0, 0, 0, 0},
        {0x0064, 0xFF9B, 0x0001, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify({0x0064, 0xFF9B, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}) ==
               :global

      assert OutboundAddress.classify({0x0064, 0xFF9B, 0x0002, 0, 0, 0, 0, 0}) == :global

      assert_ipv6_range(
        :special,
        {0x0100, 0, 0, 0, 0, 0, 0, 0},
        {0x0100, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert_ipv6_range(
        :special,
        {0x0100, 0, 0, 1, 0, 0, 0, 0},
        {0x0100, 0, 0, 1, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify({0x0100, 0, 0, 2, 0, 0, 0, 0}) == :global
    end

    test "classifies IETF protocol assignments and their global exceptions" do
      assert OutboundAddress.classify({0x2000, 0xFFFF, 0, 0, 0, 0, 0, 0}) == :global
      assert OutboundAddress.classify({0x2001, 0, 0, 0, 0, 0, 0, 0}) == :special
      assert OutboundAddress.classify({0x2001, 0x0001, 0, 0, 0, 0, 0, 1}) == :global
      assert OutboundAddress.classify({0x2001, 0x0001, 0, 0, 0, 0, 0, 2}) == :global
      assert OutboundAddress.classify({0x2001, 0x0001, 0, 0, 0, 0, 0, 3}) == :global
      assert OutboundAddress.classify({0x2001, 0x0001, 0, 0, 0, 0, 0, 4}) == :special
      assert OutboundAddress.classify({0x2001, 0x0002, 0, 0, 0, 0, 0, 0}) == :special
      assert OutboundAddress.classify({0x2001, 0x0003, 0, 0, 0, 0, 0, 0}) == :global
      assert OutboundAddress.classify({0x2001, 0x0004, 0x0112, 0, 0, 0, 0, 0}) == :global
      assert OutboundAddress.classify({0x2001, 0x0010, 0, 0, 0, 0, 0, 0}) == :special
      assert OutboundAddress.classify({0x2001, 0x0020, 0, 0, 0, 0, 0, 0}) == :global
      assert OutboundAddress.classify({0x2001, 0x0030, 0, 0, 0, 0, 0, 0}) == :global

      assert OutboundAddress.classify(
               {0x2001, 0x01FF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :special

      assert OutboundAddress.classify({0x2001, 0x0200, 0, 0, 0, 0, 0, 0}) == :global
    end

    test "classifies documentation, 6to4, and segment-routing special ranges" do
      assert_ipv6_range(
        :special,
        {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0},
        {0x2001, 0x0DB8, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify(
               {0x2001, 0x0DB7, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :global

      assert OutboundAddress.classify({0x2001, 0x0DB9, 0, 0, 0, 0, 0, 0}) == :global

      assert_ipv6_range(
        :special,
        {0x2002, 0, 0, 0, 0, 0, 0, 0},
        {0x2002, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify({0x2001, 0xFFFF, 0, 0, 0, 0, 0, 0}) == :global
      assert OutboundAddress.classify({0x2003, 0, 0, 0, 0, 0, 0, 0}) == :global

      assert_ipv6_range(
        :special,
        {0x3FFF, 0, 0, 0, 0, 0, 0, 0},
        {0x3FFF, 0x0FFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify(
               {0x3FFE, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :global

      assert OutboundAddress.classify({0x3FFF, 0x1000, 0, 0, 0, 0, 0, 0}) == :global

      assert_ipv6_range(
        :special,
        {0x5F00, 0, 0, 0, 0, 0, 0, 0},
        {0x5F00, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      )

      assert OutboundAddress.classify(
               {0x5EFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             ) == :global

      assert OutboundAddress.classify({0x5F01, 0, 0, 0, 0, 0, 0, 0}) == :global
    end

    test "classifies globally reachable IPv6 addresses" do
      assert OutboundAddress.classify({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}) == :global
      assert OutboundAddress.classify({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}) == :global
      assert OutboundAddress.classify({0x2620, 0x004F, 0x8000, 0, 0, 0, 0, 1}) == :global
    end

    test "classifies IPv4-mapped IPv6 addresses by the embedded IPv4 address" do
      assert OutboundAddress.classify(mapped_ipv4({8, 8, 8, 8})) == :global
      assert OutboundAddress.classify(mapped_ipv4({10, 0, 0, 1})) == :private
      assert OutboundAddress.classify(mapped_ipv4({127, 0, 0, 1})) == :loopback
      assert OutboundAddress.classify(mapped_ipv4({169, 254, 1, 1})) == :link_local
      assert OutboundAddress.classify(mapped_ipv4({192, 0, 2, 1})) == :special
    end
  end

  describe "classify/1 with invalid input" do
    test "returns a controlled error for non-address values and malformed tuples" do
      assert OutboundAddress.classify(nil) == {:error, :invalid_address}
      assert OutboundAddress.classify("127.0.0.1") == {:error, :invalid_address}
      assert OutboundAddress.classify({127, 0, 0}) == {:error, :invalid_address}
      assert OutboundAddress.classify({256, 0, 0, 1}) == {:error, :invalid_address}
      assert OutboundAddress.classify({127, 0, 0, :one}) == {:error, :invalid_address}

      assert OutboundAddress.classify({0, 0, 0, 0, 0, 0, 0}) ==
               {:error, :invalid_address}

      assert OutboundAddress.classify({0, 0, 0, 0, 0, 0, 0, 0x1_0000}) ==
               {:error, :invalid_address}
    end
  end

  defp assert_ipv4_range(category, first, last) do
    assert OutboundAddress.classify(first) == category
    assert OutboundAddress.classify(last) == category
  end

  defp assert_ipv6_range(category, first, last) do
    assert OutboundAddress.classify(first) == category
    assert OutboundAddress.classify(last) == category
  end

  defp mapped_ipv4({a, b, c, d}) do
    {0, 0, 0, 0, 0, 0xFFFF, (a <<< 8) + b, (c <<< 8) + d}
  end
end

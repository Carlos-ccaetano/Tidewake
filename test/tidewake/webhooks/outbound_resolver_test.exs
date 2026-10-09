defmodule Tidewake.Webhooks.OutboundResolverTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.OutboundResolvers.System

  @hostname "webhook.example"
  @runtime_hostname ~c"webhook.example"
  @ipv4_a {203, 0, 113, 10}
  @ipv4_b {198, 51, 100, 20}
  @ipv6_a {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
  @ipv6_b {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 2}

  describe "System.resolve/2" do
    test "returns only IPv4 addresses" do
      lookup = lookup(ipv4: {:ok, [@ipv4_a]}, ipv6: {:ok, []})

      assert System.resolve(@hostname, lookup) == {:ok, [@ipv4_a]}
    end

    test "returns only IPv6 addresses" do
      lookup = lookup(ipv4: {:ok, []}, ipv6: {:ok, [@ipv6_a]})

      assert System.resolve(@hostname, lookup) == {:ok, [@ipv6_a]}
    end

    test "returns both families in deterministic tuple order" do
      lookup = lookup(ipv4: {:ok, [@ipv4_a, @ipv4_b]}, ipv6: {:ok, [@ipv6_b, @ipv6_a]})

      assert System.resolve(@hostname, lookup) ==
               {:ok, [@ipv4_b, @ipv4_a, @ipv6_a, @ipv6_b]}
    end

    test "removes duplicate addresses" do
      lookup =
        lookup(
          ipv4: {:ok, [@ipv4_a, @ipv4_a]},
          ipv6: {:ok, [@ipv6_a, @ipv6_a]}
        )

      assert System.resolve(@hostname, lookup) == {:ok, [@ipv4_a, @ipv6_a]}
    end

    test "accepts IPv6 results when IPv4 resolution fails" do
      lookup = lookup(ipv4: {:error, :nxdomain}, ipv6: {:ok, [@ipv6_a]})

      assert System.resolve(@hostname, lookup) == {:ok, [@ipv6_a]}
    end

    test "accepts IPv4 results when IPv6 resolution fails" do
      lookup = lookup(ipv4: {:ok, [@ipv4_a]}, ipv6: {:error, :timeout})

      assert System.resolve(@hostname, lookup) == {:ok, [@ipv4_a]}
    end

    test "returns a DNS error when both families fail" do
      lookup = lookup(ipv4: {:error, :nxdomain}, ipv6: {:error, :timeout})

      assert System.resolve(@hostname, lookup) == {:error, :dns_error}
    end

    test "returns a DNS error when both families are empty" do
      lookup = lookup(ipv4: {:ok, []}, ipv6: {:ok, []})

      assert System.resolve(@hostname, lookup) == {:error, :dns_error}
    end

    test "normalizes unexpected resolver errors and results" do
      lookup = lookup(ipv4: {:error, {:resolver, :refused}}, ipv6: {:ok, :invalid})

      assert System.resolve(@hostname, lookup) == {:error, :dns_error}
    end

    test "queries each runtime family once with a charlist hostname" do
      test_pid = self()

      lookup = fn hostname, family ->
        send(test_pid, {:lookup, hostname, family})
        {:ok, []}
      end

      assert System.resolve(@hostname, lookup) == {:error, :dns_error}
      assert_received {:lookup, @runtime_hostname, :inet}
      assert_received {:lookup, @runtime_hostname, :inet6}
      refute_received {:lookup, _, _}
    end

    test "ignores values that are not address tuples for the requested family" do
      lookup =
        lookup(
          ipv4: {:ok, [@ipv4_a, @ipv6_a, {256, 0, 0, 1}]},
          ipv6: {:ok, [@ipv6_a, @ipv4_a, {0, 0, 0, 0, 0, 0, 0, 0x1_0000}]}
        )

      assert System.resolve(@hostname, lookup) == {:ok, [@ipv4_a, @ipv6_a]}
    end

    test "returns a controlled error for a non-binary hostname" do
      assert System.resolve(@runtime_hostname) == {:error, :dns_error}
    end
  end

  defp lookup(results) do
    fn
      @runtime_hostname, :inet -> Keyword.fetch!(results, :ipv4)
      @runtime_hostname, :inet6 -> Keyword.fetch!(results, :ipv6)
    end
  end
end

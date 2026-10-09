defmodule Tidewake.Webhooks.OutboundTargetTest do
  use ExUnit.Case, async: true

  @behaviour Tidewake.Webhooks.OutboundResolver

  alias Tidewake.Webhooks.OutboundTarget

  @public_ipv4 {93, 184, 216, 34}
  @public_ipv6 {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

  @impl true
  def resolve(hostname) do
    send(self(), {:resolved, hostname})
    Process.get(:resolver_result, {:error, :dns_error})
  end

  test "prepares a public hostname and preserves its connection identity" do
    resolve_to([@public_ipv4])

    assert {:ok, target} =
             OutboundTarget.prepare(
               "https://webhook.example:8443/hooks/orders?tenant=123",
               __MODULE__,
               :public
             )

    assert target == %OutboundTarget{
             connection_url: "https://93.184.216.34:8443/hooks/orders?tenant=123",
             hostname: "webhook.example",
             address: @public_ipv4,
             scheme: "https",
             port: 8443
           }

    assert_received {:resolved, "webhook.example"}
    refute_received {:resolved, _hostname}
  end

  test "prepares a public IPv4 literal without resolving DNS" do
    assert {:ok, target} =
             OutboundTarget.prepare("http://8.8.8.8/hooks", __MODULE__, :public)

    assert target.connection_url == "http://8.8.8.8:80/hooks"
    assert target.hostname == "8.8.8.8"
    assert target.address == {8, 8, 8, 8}
    assert target.scheme == "http"
    assert target.port == 80
    refute_received {:resolved, _hostname}
  end

  test "prepares a public IPv6 literal without resolving DNS" do
    assert {:ok, target} =
             OutboundTarget.prepare(
               "https://[2606:4700:4700::1111]/hooks?source=v6",
               __MODULE__,
               :public
             )

    assert target.connection_url ==
             "https://[2606:4700:4700::1111]:443/hooks?source=v6"

    assert target.hostname == "2606:4700:4700::1111"
    assert target.address == @public_ipv6
    refute_received {:resolved, _hostname}
  end

  for {label, address} <- [
        {"loopback", {127, 0, 0, 1}},
        {"private", {10, 0, 0, 1}}
      ] do
    test "blocks #{label} addresses in public mode" do
      resolve_to([unquote(Macro.escape(address))])

      assert OutboundTarget.prepare("https://webhook.example/hooks", __MODULE__, :public) ==
               {:error, :unsafe_destination}
    end

    test "allows #{label} addresses in local mode" do
      address = unquote(Macro.escape(address))
      resolve_to([address])

      assert {:ok, target} =
               OutboundTarget.prepare("http://webhook.local/hooks", __MODULE__, :local)

      assert target.address == address
    end
  end

  test "blocks link-local addresses in both modes" do
    for mode <- [:public, :local] do
      resolve_to([{169, 254, 10, 20}])

      assert OutboundTarget.prepare("http://webhook.local/hooks", __MODULE__, mode) ==
               {:error, :unsafe_destination}
    end
  end

  test "rejects the complete DNS answer when public and private addresses are mixed" do
    resolve_to([@public_ipv4, {192, 168, 1, 20}])

    assert OutboundTarget.prepare("https://webhook.example/hooks", __MODULE__, :public) ==
             {:error, :unsafe_destination}
  end

  test "returns a DNS error when the hostname has no addresses" do
    resolve_to([])

    assert OutboundTarget.prepare("https://missing.example/hooks", __MODULE__, :public) ==
             {:error, :dns_error}

    assert_received {:resolved, "missing.example"}
    refute_received {:resolved, _hostname}
  end

  test "normalizes resolver failures and unexpected results" do
    for result <- [{:error, :dns_error}, {:error, :raw_reason}, {:ok, :invalid}, :invalid] do
      Process.put(:resolver_result, result)

      assert OutboundTarget.prepare("https://missing.example/hooks", __MODULE__, :public) ==
               {:error, :dns_error}
    end
  end

  test "rejects credentials, fragments and unsupported schemes" do
    for url <- [
          "https://user:password@webhook.example/hooks",
          "https://webhook.example/hooks#fragment",
          "ftp://webhook.example/hooks"
        ] do
      assert OutboundTarget.prepare(url, __MODULE__, :public) ==
               {:error, :unsafe_destination}
    end

    refute_received {:resolved, _hostname}
  end

  test "rejects invalid ports, modes and oversized URLs before resolution" do
    oversized_url = "https://webhook.example/" <> String.duplicate("a", 2_100)

    for {url, mode} <- [
          {"https://webhook.example:0/hooks", :public},
          {"https://webhook.example:65536/hooks", :public},
          {"https://webhook.example/hooks", :invalid},
          {oversized_url, :public}
        ] do
      assert OutboundTarget.prepare(url, __MODULE__, mode) ==
               {:error, :unsafe_destination}
    end

    refute_received {:resolved, _hostname}
  end

  test "blocks alternate loopback notation without a DNS bypass" do
    assert OutboundTarget.prepare("http://2130706433/hooks", __MODULE__, :public) ==
             {:error, :unsafe_destination}

    refute_received {:resolved, _hostname}
  end

  test "rejects an invalid address returned by the resolver" do
    resolve_to([@public_ipv4, {999, 0, 0, 1}])

    assert OutboundTarget.prepare("https://webhook.example/hooks", __MODULE__, :public) ==
             {:error, :unsafe_destination}
  end

  test "calls the resolver once per preparation" do
    resolve_to([@public_ipv4])

    assert {:ok, _target} =
             OutboundTarget.prepare("https://webhook.example/hooks", __MODULE__, :public)

    assert_received {:resolved, "webhook.example"}
    refute_received {:resolved, _hostname}
  end

  defp resolve_to(addresses), do: Process.put(:resolver_result, {:ok, addresses})
end

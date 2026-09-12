defmodule Tidewake.Webhooks.DeliveryAdapters.DeterministicTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.DeliveryAdapters.Deterministic

  test "returns a simulated 204 response with empty headers" do
    assert Deterministic.deliver(
             "https://endpoint.invalid/webhooks",
             ~s({"id":"evt_123"}),
             [{"content-type", "application/json"}]
           ) == {:ok, %{status: 204, headers: []}}
  end

  test "returns the same result across repeated calls and different inputs" do
    inputs = [
      {"https://first.invalid/webhooks", "", []},
      {"http://second.invalid/events", <<0, 255>>, [{"x-request-id", "local-test"}]}
    ]

    for _call <- 1..3, {url, body, headers} <- inputs do
      assert Deterministic.deliver(url, body, headers) ==
               {:ok, %{status: 204, headers: []}}
    end
  end
end

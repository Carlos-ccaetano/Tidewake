defmodule Tidewake.Webhooks.ManualRetryPolicyTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.{Delivery, ManualRetryPolicy}

  test "exposes the lifetime limit of three manual cycles" do
    assert ManualRetryPolicy.max_manual_cycles() == 3
  end

  test "allows a failed delivery to advance from cycles 0, 1, and 2" do
    for cycle <- 0..2 do
      assert ManualRetryPolicy.evaluate(%Delivery{status: "failed", retry_cycle: cycle}, true) ==
               :ok
    end
  end

  test "rejects a failed delivery at or beyond cycle 3" do
    for cycle <- [3, 4, 100] do
      assert ManualRetryPolicy.evaluate(%Delivery{status: "failed", retry_cycle: cycle}, true) ==
               {:error, :manual_cycle_limit_reached}
    end
  end

  test "rejects an inactive endpoint before checking the cycle limit" do
    for cycle <- [0, 2, 3] do
      assert ManualRetryPolicy.evaluate(%Delivery{status: "failed", retry_cycle: cycle}, false) ==
               {:error, :endpoint_inactive}
    end
  end

  test "rejects every known non-failed status before checking endpoint or cycle" do
    for status <- ~w(pending processing succeeded cancelled) do
      assert ManualRetryPolicy.evaluate(%Delivery{status: status, retry_cycle: 0}, true) ==
               {:error, :state_not_failed}

      assert ManualRetryPolicy.evaluate(%Delivery{status: status, retry_cycle: 3}, false) ==
               {:error, :state_not_failed}
    end
  end

  test "fails closed for unknown or malformed status" do
    for status <- [nil, :failed, "FAILED", "unknown"] do
      assert ManualRetryPolicy.evaluate(%Delivery{status: status, retry_cycle: 0}, true) ==
               {:error, :invalid_input}
    end
  end

  test "fails closed for invalid retry cycle values" do
    for cycle <- [-1, nil, "0", 1.0, true] do
      assert ManualRetryPolicy.evaluate(%Delivery{status: "failed", retry_cycle: cycle}, true) ==
               {:error, :invalid_input}
    end
  end

  test "fails closed for invalid endpoint activity" do
    for endpoint_active <- [nil, 1, "true"] do
      assert ManualRetryPolicy.evaluate(
               %Delivery{status: "failed", retry_cycle: 0},
               endpoint_active
             ) == {:error, :invalid_input}
    end
  end

  test "fails closed for incomplete or malformed state" do
    for state <- [
          %{},
          %{status: "failed"},
          %{retry_cycle: 0},
          %Delivery{status: "failed", retry_cycle: nil},
          nil,
          "failed"
        ] do
      assert ManualRetryPolicy.evaluate(state, true) == {:error, :invalid_input}
    end
  end

  test "rejects the old current_cycle field without retry_cycle" do
    assert ManualRetryPolicy.evaluate(%{status: "failed", current_cycle: 0}, true) ==
             {:error, :invalid_input}
  end
end

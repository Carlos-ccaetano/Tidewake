defmodule Tidewake.Webhooks.RetryBackoffTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.RetryBackoff

  describe "delay_seconds/2" do
    for {attempt_number, lower_bound, upper_bound} <- [
          {1, 5, 10},
          {2, 10, 20},
          {3, 20, 40},
          {4, 40, 80},
          {5, 80, 160},
          {6, 150, 300}
        ] do
      test "attempt #{attempt_number} uses the inclusive #{lower_bound}..#{upper_bound} range" do
        attempt_number = unquote(attempt_number)
        lower_bound = unquote(lower_bound)
        upper_bound = unquote(upper_bound)

        assert RetryBackoff.delay_seconds(attempt_number, &Enum.min/1) == {:ok, lower_bound}
        assert RetryBackoff.delay_seconds(attempt_number, &Enum.max/1) == {:ok, upper_bound}
      end
    end

    test "high attempt numbers remain capped at the 150..300 range" do
      for attempt_number <- [7, 20, 1_000_000] do
        assert RetryBackoff.delay_seconds(attempt_number, &Enum.min/1) == {:ok, 150}
        assert RetryBackoff.delay_seconds(attempt_number, &Enum.max/1) == {:ok, 300}
      end
    end

    test "passes the complete inclusive range to a deterministic selector" do
      selector = fn range ->
        assert range.first == 5
        assert range.last == 10
        assert range.step == 1
        7
      end

      assert RetryBackoff.delay_seconds(1, selector) == {:ok, 7}
    end

    test "rejects selections outside the calculated range" do
      assert RetryBackoff.delay_seconds(1, fn _range -> 4 end) ==
               {:error, :invalid_selection}

      assert RetryBackoff.delay_seconds(1, fn _range -> 11 end) ==
               {:error, :invalid_selection}

      assert RetryBackoff.delay_seconds(1, fn _range -> 5.0 end) ==
               {:error, :invalid_selection}
    end

    test "rejects a selector with the wrong shape" do
      assert RetryBackoff.delay_seconds(1, :not_a_function) == {:error, :invalid_selector}
    end
  end

  describe "delay_seconds/1" do
    test "uses the standard random selector within the calculated range" do
      for _iteration <- 1..20 do
        assert {:ok, delay} = RetryBackoff.delay_seconds(3)
        assert delay in 20..40
      end
    end

    test "rejects non-positive and non-integer attempt numbers" do
      for attempt_number <- [0, -1, 1.0, "1", nil] do
        assert RetryBackoff.delay_seconds(attempt_number) ==
                 {:error, :invalid_attempt_number}
      end
    end
  end
end

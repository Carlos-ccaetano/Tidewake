defmodule Tidewake.Webhooks.RetryBackoff do
  @moduledoc """
  Calculates bounded exponential retry delays with equal jitter.

  The attempt number is the positive number of the attempt that just failed.
  Delay selection is injectable so callers can test the inclusive jitter range
  without changing global randomness.
  """

  @base_delay_seconds 10
  @maximum_delay_seconds 300

  @type error :: :invalid_attempt_number | :invalid_selector | :invalid_selection
  @type selector :: (Range.t() -> term())

  @doc """
  Selects a delay in seconds for the attempt that just failed.

  The default selector chooses a random integer from the inclusive equal-jitter
  range. A one-argument selector can be supplied for deterministic tests.
  """
  @spec delay_seconds(term(), selector()) :: {:ok, pos_integer()} | {:error, error()}
  def delay_seconds(attempt_number, selector \\ &Enum.random/1)

  def delay_seconds(attempt_number, selector)
      when is_integer(attempt_number) and attempt_number > 0 and is_function(selector, 1) do
    ceiling = raw_ceiling(attempt_number)
    range = div(ceiling + 1, 2)..ceiling

    selection = selector.(range)

    if is_integer(selection) and selection >= range.first and selection <= range.last do
      {:ok, selection}
    else
      {:error, :invalid_selection}
    end
  end

  def delay_seconds(attempt_number, _selector)
      when is_integer(attempt_number) and attempt_number > 0 do
    {:error, :invalid_selector}
  end

  def delay_seconds(_attempt_number, _selector), do: {:error, :invalid_attempt_number}

  defp raw_ceiling(attempt_number) do
    grow_ceiling(@base_delay_seconds, attempt_number - 1)
  end

  defp grow_ceiling(@maximum_delay_seconds, _remaining_doublings),
    do: @maximum_delay_seconds

  defp grow_ceiling(delay, 0), do: delay

  defp grow_ceiling(delay, remaining_doublings) do
    grow_ceiling(min(delay * 2, @maximum_delay_seconds), remaining_doublings - 1)
  end
end

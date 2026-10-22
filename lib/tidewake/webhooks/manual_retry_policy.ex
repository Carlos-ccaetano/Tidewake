defmodule Tidewake.Webhooks.ManualRetryPolicy do
  @moduledoc """
  Evaluates manual retry eligibility from a delivery's current state.

  The caller must supply the delivery state observed under its lock. This
  policy performs no persistence, scheduling, or authorization.
  """

  @max_manual_cycles 3
  @ineligible_statuses ~w(pending processing succeeded cancelled)

  @type reason ::
          :state_not_failed
          | :endpoint_inactive
          | :manual_cycle_limit_reached
          | :invalid_input

  @doc "Returns the maximum number of manual retry cycles for one delivery."
  @spec max_manual_cycles() :: pos_integer()
  def max_manual_cycles, do: @max_manual_cycles

  @doc """
  Evaluates the current delivery status and cycle against endpoint activity.

  Known non-failed states take precedence over the other rejection reasons.
  Unknown or malformed inputs fail closed.
  """
  @spec evaluate(term(), term()) :: :ok | {:error, reason()}
  def evaluate(%{status: status}, _endpoint_active) when status in @ineligible_statuses,
    do: {:error, :state_not_failed}

  def evaluate(%{status: "failed", retry_cycle: cycle}, endpoint_active)
      when is_integer(cycle) and cycle >= 0 and is_boolean(endpoint_active) do
    cond do
      not endpoint_active -> {:error, :endpoint_inactive}
      cycle >= @max_manual_cycles -> {:error, :manual_cycle_limit_reached}
      true -> :ok
    end
  end

  def evaluate(_delivery_state, _endpoint_active), do: {:error, :invalid_input}
end

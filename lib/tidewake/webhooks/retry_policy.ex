defmodule Tidewake.Webhooks.RetryPolicy do
  @moduledoc """
  Classifies normalized delivery outcomes without performing retry side effects.

  Unknown or malformed outcomes fail closed as permanent failures.
  """

  @max_attempts 6
  @retryable_http_statuses [408, 425, 429, 500, 502, 503, 504]
  @retryable_transport_errors ~w(timeout dns connection closed)

  @type decision :: :succeeded | :retry | :permanent_failure | :exhausted

  @doc "Returns the maximum number of persisted attempts for one delivery."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Classifies a normalized delivery outcome for a positive attempt number.

  Retryable outcomes become exhausted at the configured attempt limit. All
  unknown, incomplete, or otherwise invalid inputs are permanent failures.
  """
  @spec classify(map(), pos_integer()) :: decision()
  def classify(%{result: "succeeded", http_status: status}, attempt_number)
      when status in 200..299 and is_integer(attempt_number) and attempt_number > 0 do
    :succeeded
  end

  def classify(%{result: "http_error", http_status: status}, attempt_number)
      when status in @retryable_http_statuses and is_integer(attempt_number) and
             attempt_number > 0 do
    retry_decision(attempt_number)
  end

  def classify(%{result: "transport_error", error_type: error_type}, attempt_number)
      when error_type in @retryable_transport_errors and is_integer(attempt_number) and
             attempt_number > 0 do
    retry_decision(attempt_number)
  end

  def classify(_outcome, _attempt_number), do: :permanent_failure

  defp retry_decision(attempt_number) when attempt_number < @max_attempts, do: :retry
  defp retry_decision(_attempt_number), do: :exhausted
end

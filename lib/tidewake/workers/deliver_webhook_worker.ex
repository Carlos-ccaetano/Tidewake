defmodule Tidewake.Workers.DeliverWebhookWorker do
  @moduledoc """
  Delegates a single delivery processing attempt to the configured adapter.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Tidewake.Webhooks.DeliveryProcessor

  @delivery_job_unique [
    fields: [:worker, :args],
    keys: [:delivery_id, :attempt_number],
    period: :infinity,
    states: :incomplete
  ]

  @cycle_delivery_job_unique [
    fields: [:worker, :args],
    keys: [:delivery_id, :attempt_number, :retry_cycle, :cycle_attempt_number],
    period: :infinity,
    states: :incomplete
  ]

  @doc """
  Builds a unique job for one persisted delivery.
  """
  def new_for_delivery(delivery_id) when is_integer(delivery_id) and delivery_id > 0 do
    new_for_delivery(delivery_id, 1)
  end

  @doc """
  Builds an immediate unique job for one logical delivery attempt.
  """
  def new_for_delivery(delivery_id, attempt_number)
      when is_integer(delivery_id) and delivery_id > 0 and is_integer(attempt_number) and
             attempt_number > 0 do
    new(job_args(delivery_id, attempt_number), unique: @delivery_job_unique)
  end

  @doc """
  Builds an immediate unique job for a complete delivery attempt identity.
  """
  def new_for_delivery(delivery_id, attempt_number, retry_cycle, cycle_attempt_number)
      when is_integer(delivery_id) and delivery_id > 0 and is_integer(attempt_number) and
             attempt_number > 0 and is_integer(retry_cycle) and retry_cycle >= 0 and
             is_integer(cycle_attempt_number) and cycle_attempt_number > 0 do
    new(job_args(delivery_id, attempt_number, retry_cycle, cycle_attempt_number),
      unique: @cycle_delivery_job_unique
    )
  end

  @doc """
  Builds a scheduled unique job for one logical delivery attempt.
  """
  def new_scheduled_for_delivery(
        delivery_id,
        attempt_number,
        %DateTime{utc_offset: 0, std_offset: 0} = scheduled_at
      )
      when is_integer(delivery_id) and delivery_id > 0 and is_integer(attempt_number) and
             attempt_number > 0 do
    new(job_args(delivery_id, attempt_number),
      scheduled_at: scheduled_at,
      unique: @delivery_job_unique
    )
  end

  @doc """
  Builds a scheduled unique job for a complete delivery attempt identity.
  """
  def new_scheduled_for_delivery(
        delivery_id,
        attempt_number,
        retry_cycle,
        cycle_attempt_number,
        %DateTime{utc_offset: 0, std_offset: 0} = scheduled_at
      )
      when is_integer(delivery_id) and delivery_id > 0 and is_integer(attempt_number) and
             attempt_number > 0 and is_integer(retry_cycle) and retry_cycle >= 0 and
             is_integer(cycle_attempt_number) and cycle_attempt_number > 0 do
    new(job_args(delivery_id, attempt_number, retry_cycle, cycle_attempt_number),
      scheduled_at: scheduled_at,
      unique: @cycle_delivery_job_unique
    )
  end

  @impl true
  def perform(%Oban.Job{
        args:
          %{
            "delivery_id" => id,
            "attempt_number" => attempt_number,
            "retry_cycle" => retry_cycle,
            "cycle_attempt_number" => cycle_attempt_number
          } = args
      })
      when is_integer(id) and id > 0 and is_integer(attempt_number) and attempt_number > 0 and
             is_integer(retry_cycle) and retry_cycle >= 0 and is_integer(cycle_attempt_number) and
             cycle_attempt_number > 0 and map_size(args) == 4 do
    process_delivery(id, %{
      attempt_number: attempt_number,
      retry_cycle: retry_cycle,
      cycle_attempt_number: cycle_attempt_number
    })
  end

  def perform(%Oban.Job{
        args: %{"delivery_id" => id, "attempt_number" => attempt_number} = args
      })
      when is_integer(id) and id > 0 and is_integer(attempt_number) and attempt_number > 0 and
             map_size(args) == 2 do
    process_delivery(id, attempt_number)
  end

  def perform(%Oban.Job{args: %{"delivery_id" => id} = args})
      when is_integer(id) and id > 0 and map_size(args) == 1 do
    process_delivery(id, 1)
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp process_delivery(id, expected_attempt) do
    with {:ok, adapter} <- Application.fetch_env(:tidewake, :delivery_adapter),
         {:ok, _result} <- DeliveryProcessor.process(id, expected_attempt, adapter) do
      :ok
    else
      :error -> {:cancel, :adapter_not_configured}
      {:error, :invalid_arguments} -> {:cancel, :invalid_args}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, :stale_attempt} -> {:cancel, :stale_attempt}
      {:error, :not_due} -> {:cancel, :not_due}
      {:error, reason} -> {:error, reason}
    end
  end

  defp job_args(delivery_id, attempt_number) do
    %{"delivery_id" => delivery_id, "attempt_number" => attempt_number}
  end

  defp job_args(delivery_id, attempt_number, retry_cycle, cycle_attempt_number) do
    Map.merge(job_args(delivery_id, attempt_number), %{
      "retry_cycle" => retry_cycle,
      "cycle_attempt_number" => cycle_attempt_number
    })
  end
end

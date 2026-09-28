defmodule Tidewake.Workers.RecoverStaleDeliveriesWorker do
  @moduledoc """
  Recovers a bounded batch of deliveries abandoned in processing.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [fields: [:worker, :args], period: :infinity, states: :incomplete]

  alias Tidewake.Webhooks

  @stale_after_seconds 5 * 60
  @batch_size 100
  @ignored_recovery_errors [:not_found, :invalid_transition, :not_stale, :active_job]

  @impl true
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    stale_before = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    with {:ok, delivery_ids} <-
           Webhooks.list_stale_delivery_ids(stale_before, @batch_size) do
      recover_candidates(delivery_ids, stale_before)
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp recover_candidates(delivery_ids, stale_before) do
    Enum.reduce_while(delivery_ids, :ok, fn delivery_id, :ok ->
      case Webhooks.recover_stale_delivery(delivery_id, stale_before) do
        {:ok, _result} ->
          {:cont, :ok}

        {:error, reason} when reason in @ignored_recovery_errors ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end

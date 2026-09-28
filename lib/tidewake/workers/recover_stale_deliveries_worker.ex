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
  @recovery_event [:tidewake, :webhooks, :delivery, :recovery]
  @initial_measurements %{recovered_count: 0, skipped_count: 0, error_count: 0}

  @impl true
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    started_at = System.monotonic_time()
    stale_before = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    stale_before
    |> recover_batch()
    |> emit_recovery_telemetry(started_at)
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp recover_batch(stale_before) do
    case Webhooks.list_stale_delivery_ids(stale_before, @batch_size) do
      {:ok, delivery_ids} ->
        recover_candidates(delivery_ids, stale_before)

      {:error, reason} ->
        {{:error, reason}, increment(@initial_measurements, :error_count)}
    end
  end

  defp recover_candidates(delivery_ids, stale_before) do
    Enum.reduce_while(delivery_ids, {:ok, @initial_measurements}, fn delivery_id,
                                                                     {:ok, measurements} ->
      case Webhooks.recover_stale_delivery(delivery_id, stale_before) do
        {:ok, _result} ->
          {:cont, {:ok, increment(measurements, :recovered_count)}}

        {:error, reason} when reason in @ignored_recovery_errors ->
          {:cont, {:ok, increment(measurements, :skipped_count)}}

        {:error, reason} ->
          {:halt, {{:error, reason}, increment(measurements, :error_count)}}
      end
    end)
  end

  defp emit_recovery_telemetry({result, measurements}, started_at) do
    duration_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :millisecond)

    :telemetry.execute(@recovery_event, Map.put(measurements, :duration_ms, duration_ms), %{})

    result
  end

  defp increment(measurements, key), do: Map.update!(measurements, key, &(&1 + 1))
end

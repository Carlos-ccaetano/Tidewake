defmodule Tidewake.Workers.DeliverWebhookWorker do
  @moduledoc """
  Delegates a single delivery processing attempt to the configured adapter.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Tidewake.Webhooks.DeliveryProcessor

  @impl true
  def perform(%Oban.Job{args: %{"delivery_id" => id} = args})
      when is_integer(id) and id > 0 and map_size(args) == 1 do
    with {:ok, adapter} <- Application.fetch_env(:tidewake, :delivery_adapter),
         {:ok, _result} <- DeliveryProcessor.process(id, adapter) do
      :ok
    else
      :error -> {:cancel, :adapter_not_configured}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}
end

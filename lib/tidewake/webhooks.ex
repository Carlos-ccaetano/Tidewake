defmodule Tidewake.Webhooks do
  @moduledoc """
  Manages webhook events, destination endpoints, and their persistence.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Tidewake.Repo
  alias Tidewake.Webhooks.{Attempt, Delivery, Endpoint, Event}
  alias Tidewake.Workers.DeliverWebhookWorker

  @event_ingested [:tidewake, :webhooks, :event, :ingested]
  @event_rejected [:tidewake, :webhooks, :event, :rejected]

  def create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  def ingest_event(attrs) do
    Multi.new()
    |> Multi.insert(:event, Event.changeset(%Event{}, attrs))
    |> Multi.all(:endpoints, active_endpoints_query())
    |> Multi.merge(&fanout_multi/1)
    |> Repo.transaction()
    |> normalize_ingest_result()
    |> emit_ingest_telemetry()
  end

  def get_event(id) do
    Repo.get(Event, id)
  end

  def get_event_by_external_id(external_id) do
    Repo.get_by(Event, external_id: external_id)
  end

  def create_delivery(%Event{} = event, %Endpoint{active: true} = endpoint) do
    event
    |> delivery_changeset(endpoint)
    |> Repo.insert()
  end

  def create_delivery(%Event{}, %Endpoint{active: false}) do
    {:error, :endpoint_inactive}
  end

  def schedule_delivery(%Event{} = event, %Endpoint{} = endpoint) do
    Multi.new()
    |> Multi.run(:delivery, fn _repo, _changes -> create_delivery(event, endpoint) end)
    |> Oban.insert(:job, fn %{delivery: delivery} ->
      initial_delivery_job(delivery)
    end)
    |> Repo.transaction()
  end

  def get_delivery(id) do
    Repo.get(Delivery, id)
  end

  def list_deliveries_for_event(%Event{} = event) do
    from(delivery in Delivery,
      where: delivery.event_id == ^event.id,
      order_by: [asc: delivery.id]
    )
    |> Repo.all()
  end

  def get_delivery_by_event_and_endpoint(%Event{} = event, %Endpoint{} = endpoint) do
    Repo.get_by(Delivery, event_id: event.id, endpoint_id: endpoint.id)
  end

  def claim_delivery(id) do
    now = DateTime.utc_now()

    query =
      from(delivery in Delivery,
        where: delivery.id == ^id and delivery.status == "pending",
        select: delivery
      )

    case Repo.update_all(query, set: [status: "processing", updated_at: now]) do
      {1, [delivery]} -> {:ok, Repo.preload(delivery, [:event, :endpoint])}
      {0, []} -> claim_delivery_error(id)
    end
  end

  def finalize_delivery(delivery_id, attempt_attrs) do
    Repo.transaction(fn ->
      query = from(delivery in Delivery, where: delivery.id == ^delivery_id, lock: "FOR UPDATE")

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Delivery{status: "processing"} = delivery ->
          finalize_processing_delivery(delivery, attempt_attrs)

        %Delivery{} ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  def create_attempt(%Delivery{} = delivery, attrs) do
    %Attempt{delivery_id: delivery.id}
    |> Attempt.changeset(attrs)
    |> Repo.insert()
  end

  def get_attempt(id) do
    Repo.get(Attempt, id)
  end

  def list_attempts(%Delivery{} = delivery) do
    from(attempt in Attempt,
      where: attempt.delivery_id == ^delivery.id,
      order_by: [asc: attempt.attempt_number]
    )
    |> Repo.all()
  end

  def list_endpoints do
    Repo.all(Endpoint)
  end

  def list_active_endpoints do
    active_endpoints_query()
    |> Repo.all()
  end

  def get_endpoint(id) do
    Repo.get(Endpoint, id)
  end

  def create_endpoint(attrs \\ %{}) do
    %Endpoint{}
    |> Endpoint.changeset(attrs)
    |> Repo.insert()
  end

  def update_endpoint(%Endpoint{} = endpoint, attrs) do
    endpoint
    |> Endpoint.changeset(attrs)
    |> Repo.update()
  end

  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end

  defp active_endpoints_query do
    from(endpoint in Endpoint,
      where: endpoint.active == true,
      order_by: [asc: endpoint.id]
    )
  end

  defp fanout_multi(%{event: event, endpoints: endpoints}) do
    Enum.reduce(endpoints, Multi.new(), fn endpoint, multi ->
      delivery_operation = {:delivery, endpoint.id}
      job_operation = {:job, endpoint.id}

      multi
      |> Multi.insert(delivery_operation, delivery_changeset(event, endpoint))
      |> Oban.insert(job_operation, fn changes ->
        changes
        |> Map.fetch!(delivery_operation)
        |> initial_delivery_job()
      end)
    end)
  end

  defp normalize_ingest_result({:ok, %{event: event, endpoints: endpoints} = changes}) do
    deliveries = Enum.map(endpoints, &Map.fetch!(changes, {:delivery, &1.id}))
    jobs = Enum.map(endpoints, &Map.fetch!(changes, {:job, &1.id}))

    {:ok, %{event: event, deliveries: deliveries, jobs: jobs}}
  end

  defp normalize_ingest_result({:error, :event, %Ecto.Changeset{} = changeset, _changes}) do
    {:error, changeset}
  end

  defp normalize_ingest_result(error), do: error

  defp emit_ingest_telemetry({:ok, %{deliveries: deliveries}} = result) do
    :telemetry.execute(
      @event_ingested,
      %{count: 1, delivery_count: length(deliveries)},
      %{}
    )

    result
  end

  defp emit_ingest_telemetry({:error, %Ecto.Changeset{} = changeset} = result) do
    :telemetry.execute(
      @event_rejected,
      %{count: 1},
      %{reason: ingest_rejection_reason(changeset)}
    )

    result
  end

  defp emit_ingest_telemetry(result), do: result

  defp ingest_rejection_reason(changeset) do
    if Enum.any?(changeset.errors, &external_id_conflict?/1), do: "conflict", else: "validation"
  end

  defp external_id_conflict?({:external_id, {_message, options}}),
    do: options[:constraint] == :unique

  defp external_id_conflict?(_error), do: false

  defp delivery_changeset(%Event{} = event, %Endpoint{} = endpoint) do
    Delivery.changeset(%Delivery{event_id: event.id, endpoint_id: endpoint.id}, %{})
  end

  defp initial_delivery_job(%Delivery{} = delivery) do
    DeliverWebhookWorker.new(%{"delivery_id" => delivery.id},
      unique: [fields: [:worker, :args], keys: [:delivery_id], period: :infinity, states: :all]
    )
  end

  defp finalize_processing_delivery(delivery, attrs) do
    attempt_changeset =
      %Attempt{delivery_id: delivery.id, attempt_number: delivery.attempt_count + 1}
      |> Attempt.changeset(Map.drop(attrs, [:attempt_number, "attempt_number"]))

    with {:ok, attempt} <- Repo.insert(attempt_changeset),
         {:ok, finalized} <-
           delivery
           |> Delivery.changeset(%{
             status: if(attempt.result == "succeeded", do: "succeeded", else: "failed"),
             attempt_count: delivery.attempt_count + 1,
             completed_at: attempt.completed_at
           })
           |> Repo.update() do
      %{delivery: finalized, attempt: attempt}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp claim_delivery_error(id) do
    case Repo.get(Delivery, id) do
      nil -> {:error, :not_found}
      %Delivery{} -> {:error, :invalid_transition}
    end
  end
end

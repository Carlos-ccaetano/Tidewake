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
  @max_stale_delivery_batch_size 100
  @attempt_identity_keys [
    :delivery_id,
    "delivery_id",
    :retry_cycle,
    "retry_cycle",
    :cycle_attempt_number,
    "cycle_attempt_number"
  ]

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
      DeliverWebhookWorker.new_for_delivery(delivery.id)
    end)
    |> Repo.transaction()
  end

  def get_delivery(id) do
    Repo.get(Delivery, id)
  end

  def list_stale_delivery_ids(%DateTime{} = stale_before, limit)
      when is_integer(limit) and limit > 0 and limit <= @max_stale_delivery_batch_size do
    ids =
      from(delivery in Delivery,
        where: delivery.status == "processing" and delivery.updated_at <= ^stale_before,
        order_by: [asc: delivery.updated_at, asc: delivery.id],
        limit: ^limit,
        select: delivery.id
      )
      |> Repo.all()

    {:ok, ids}
  end

  def list_stale_delivery_ids(_stale_before, _limit), do: {:error, :invalid_arguments}

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

  def claim_delivery(delivery_id) when is_integer(delivery_id) do
    claim_delivery_with_guard(delivery_id, :current_attempt, DateTime.utc_now())
  end

  def claim_delivery(_delivery_id), do: {:error, :invalid_arguments}

  def claim_delivery(delivery_id, expected_attempt_number)
      when is_integer(delivery_id) and delivery_id > 0 and is_integer(expected_attempt_number) and
             expected_attempt_number > 0 do
    claim_delivery(delivery_id, expected_attempt_number, DateTime.utc_now())
  end

  def claim_delivery(_delivery_id, _expected_attempt_number),
    do: {:error, :invalid_arguments}

  def claim_delivery(
        delivery_id,
        expected_attempt_number,
        %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = reference_time
      )
      when is_integer(delivery_id) and delivery_id > 0 and is_integer(expected_attempt_number) and
             expected_attempt_number > 0 do
    claim_delivery_with_guard(delivery_id, expected_attempt_number, reference_time)
  end

  def claim_delivery(_delivery_id, _expected_attempt_number, _reference_time),
    do: {:error, :invalid_arguments}

  defp claim_delivery_with_guard(delivery_id, expected_attempt_number, reference_time) do
    Repo.transaction(fn ->
      query =
        from(delivery in Delivery,
          where: delivery.id == ^delivery_id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Delivery{status: "pending"} = delivery ->
          claim_pending_delivery(delivery, expected_attempt_number, reference_time)

        %Delivery{} ->
          Repo.rollback(:invalid_transition)
      end
    end)
    |> normalize_claim_result()
  end

  def recover_stale_delivery(delivery_id, %DateTime{} = stale_before)
      when is_integer(delivery_id) and delivery_id > 0 do
    Repo.transaction(fn ->
      query =
        from(delivery in Delivery,
          where: delivery.id == ^delivery_id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Delivery{status: "processing"} = delivery ->
          recover_if_stale(delivery, stale_before)

        %Delivery{} ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  def recover_stale_delivery(_delivery_id, _stale_before), do: {:error, :invalid_arguments}

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

  def schedule_delivery_retry(
        delivery_id,
        attempt_attrs,
        %DateTime{utc_offset: 0, std_offset: 0} = retry_at
      )
      when is_integer(delivery_id) and delivery_id > 0 and is_map(attempt_attrs) do
    Repo.transaction(fn ->
      query = from(delivery in Delivery, where: delivery.id == ^delivery_id, lock: "FOR UPDATE")

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Delivery{status: "processing"} = delivery ->
          schedule_processing_delivery_retry(delivery, attempt_attrs, retry_at)

        %Delivery{} ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  def schedule_delivery_retry(_delivery_id, _attempt_attrs, _retry_at),
    do: {:error, :invalid_arguments}

  def create_attempt(%Delivery{} = delivery, attrs) do
    %Attempt{
      delivery_id: delivery.id,
      retry_cycle: delivery.retry_cycle,
      cycle_attempt_number: delivery.cycle_attempt_count + 1
    }
    |> Attempt.changeset(Map.drop(attrs, @attempt_identity_keys))
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
        |> then(&DeliverWebhookWorker.new_for_delivery(&1.id))
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
    if Enum.any?(changeset.errors, &external_id_conflict?/1),
      do: "duplicate_external_id",
      else: "validation"
  end

  defp external_id_conflict?({:external_id, {_message, options}}),
    do: options[:constraint] == :unique

  defp external_id_conflict?(_error), do: false

  defp delivery_changeset(%Event{} = event, %Endpoint{} = endpoint) do
    Delivery.changeset(%Delivery{event_id: event.id, endpoint_id: endpoint.id}, %{})
  end

  defp recover_if_stale(delivery, stale_before) do
    if DateTime.compare(delivery.updated_at, stale_before) in [:lt, :eq] do
      recover_processing_delivery(delivery)
    else
      Repo.rollback(:not_stale)
    end
  end

  defp recover_processing_delivery(delivery) do
    with {:ok, recovered} <-
           delivery
           |> Delivery.changeset(%{
             status: "pending",
             completed_at: nil,
             next_attempt_at: nil
           })
           |> Repo.update(),
         {:ok, job} <-
           DeliverWebhookWorker.new_for_delivery(
             delivery.id,
             delivery.attempt_count + 1
           )
           |> Oban.insert() do
      if job.conflict? do
        Repo.rollback(:active_job)
      else
        %{delivery: recovered, job: job}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp finalize_processing_delivery(delivery, attrs) do
    attempt_changeset =
      %Attempt{
        delivery_id: delivery.id,
        attempt_number: delivery.attempt_count + 1,
        retry_cycle: delivery.retry_cycle,
        cycle_attempt_number: delivery.cycle_attempt_count + 1
      }
      |> Attempt.changeset(
        Map.drop(attrs, @attempt_identity_keys ++ [:attempt_number, "attempt_number"])
      )

    with {:ok, attempt} <- Repo.insert(attempt_changeset),
         {:ok, finalized} <-
           delivery
           |> Delivery.changeset(%{
             status: if(attempt.result == "succeeded", do: "succeeded", else: "failed"),
             attempt_count: delivery.attempt_count + 1,
             cycle_attempt_count: delivery.cycle_attempt_count + 1,
             completed_at: attempt.completed_at
           })
           |> Repo.update() do
      %{delivery: finalized, attempt: attempt}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp schedule_processing_delivery_retry(delivery, attrs, retry_at) do
    attempt_number = delivery.attempt_count + 1

    attempt_changeset =
      %Attempt{
        delivery_id: delivery.id,
        attempt_number: attempt_number,
        retry_cycle: delivery.retry_cycle,
        cycle_attempt_number: delivery.cycle_attempt_count + 1,
        next_attempt_at: retry_at
      }
      |> Attempt.changeset(
        Map.drop(
          attrs,
          @attempt_identity_keys ++
            [:attempt_number, "attempt_number", :next_attempt_at, "next_attempt_at"]
        )
      )

    with {:ok, attempt} <- Repo.insert(attempt_changeset),
         {:ok, pending} <-
           delivery
           |> Delivery.changeset(%{
             status: "pending",
             attempt_count: attempt_number,
             cycle_attempt_count: delivery.cycle_attempt_count + 1,
             next_attempt_at: retry_at,
             completed_at: nil
           })
           |> Repo.update(),
         {:ok, job} <-
           DeliverWebhookWorker.new_scheduled_for_delivery(
             pending.id,
             pending.attempt_count + 1,
             retry_at
           )
           |> Oban.insert() do
      if job.conflict? do
        Repo.rollback(:active_job)
      else
        %{delivery: pending, attempt: attempt, job: job}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_pending_delivery(delivery) do
    endpoint =
      from(endpoint in Endpoint,
        where: endpoint.id == ^delivery.endpoint_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one!()

    event = Repo.get!(Event, delivery.event_id)
    delivery = %{delivery | endpoint: endpoint, event: event}

    if endpoint.active do
      persist_claim_transition(
        delivery,
        %{status: "processing", next_attempt_at: nil},
        :ok
      )
    else
      persist_claim_transition(
        delivery,
        %{status: "cancelled", completed_at: DateTime.utc_now(), next_attempt_at: nil},
        :cancelled
      )
    end
  end

  defp claim_pending_delivery(delivery, expected_attempt_number, reference_time) do
    with :ok <- validate_expected_attempt(delivery, expected_attempt_number),
         :ok <- validate_claim_time(delivery, reference_time) do
      prepare_pending_delivery(delivery)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_expected_attempt(_delivery, :current_attempt), do: :ok

  defp validate_expected_attempt(delivery, expected_attempt_number) do
    if expected_attempt_number == delivery.attempt_count + 1,
      do: :ok,
      else: {:error, :stale_attempt}
  end

  defp validate_claim_time(%Delivery{next_attempt_at: nil}, _reference_time), do: :ok

  defp validate_claim_time(%Delivery{next_attempt_at: next_attempt_at}, reference_time) do
    if DateTime.compare(next_attempt_at, reference_time) == :gt,
      do: {:error, :not_due},
      else: :ok
  end

  defp persist_claim_transition(delivery, attrs, result) do
    case delivery |> Delivery.changeset(attrs) |> Repo.update() do
      {:ok, delivery} -> {result, delivery}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp normalize_claim_result({:ok, {:ok, delivery}}), do: {:ok, delivery}
  defp normalize_claim_result({:ok, {:cancelled, delivery}}), do: {:cancelled, delivery}
  defp normalize_claim_result({:error, reason}), do: {:error, reason}
end

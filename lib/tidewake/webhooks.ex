defmodule Tidewake.Webhooks do
  @moduledoc """
  Manages webhook events, destination endpoints, and their persistence.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.{Changeset, Multi}
  alias Tidewake.Projects.{Authorization, Project, Scope}
  alias Tidewake.Repo
  alias Tidewake.Webhooks.{Attempt, Delivery, Endpoint, Event}

  alias Tidewake.Webhooks.{
    ManualRetryActor,
    ManualRetryIdempotency,
    ManualRetryPolicy,
    ManualRetryRequest
  }

  alias Tidewake.Workers.DeliverWebhookWorker

  @event_ingested [:tidewake, :webhooks, :event, :ingested]
  @event_rejected [:tidewake, :webhooks, :event, :rejected]
  @manual_retry_completed [:tidewake, :webhooks, :manual_retry, :completed]
  @manual_retry_rejection_reasons ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached)
  @max_stale_delivery_batch_size 100
  @repo_opts [log: false, telemetry_event: nil]
  @attempt_identity_keys [
    :delivery_id,
    "delivery_id",
    :retry_cycle,
    "retry_cycle",
    :cycle_attempt_number,
    "cycle_attempt_number"
  ]

  def create_event(project, attrs) do
    %Event{project_id: project_id!(project)}
    |> Event.changeset(attrs)
    |> Repo.insert(@repo_opts)
  end

  def ingest_event(project, attrs) do
    project_id = project_id!(project)

    Multi.new()
    |> Multi.insert(:event, Event.changeset(%Event{project_id: project_id}, attrs), @repo_opts)
    |> Multi.all(:endpoints, active_endpoints_query(project_id), @repo_opts)
    |> Multi.merge(&fanout_multi/1)
    |> Repo.transaction(@repo_opts)
    |> normalize_ingest_result()
    |> emit_ingest_telemetry()
  end

  def get_event(project, id) do
    Repo.get_by(Event, [id: id, project_id: project_id!(project)], @repo_opts)
  end

  def get_event_by_external_id(project, external_id) do
    Repo.get_by(Event, [external_id: external_id, project_id: project_id!(project)], @repo_opts)
  end

  def create_delivery(%Event{} = event, %Endpoint{active: true} = endpoint) do
    event
    |> delivery_changeset(endpoint)
    |> Repo.insert(@repo_opts)
  end

  def create_delivery(%Event{}, %Endpoint{active: false}) do
    {:error, :endpoint_inactive}
  end

  def schedule_delivery(%Event{} = event, %Endpoint{} = endpoint) do
    Multi.new()
    |> Multi.run(:delivery, fn _repo, _changes -> create_delivery(event, endpoint) end)
    |> Oban.insert(:job, fn %{delivery: delivery} ->
      new_delivery_job(delivery)
    end)
    |> Repo.transaction()
  end

  def get_delivery(project, id) do
    Repo.get_by(Delivery, [id: id, project_id: project_id!(project)], @repo_opts)
  end

  @doc "Internal ID lookup for persisted work; never an HTTP access boundary."
  def get_delivery_internal(id) do
    Repo.get(Delivery, id)
  end

  @doc """
  Records a manual retry decision and atomically schedules an accepted retry.

  Requires an authenticated Scope and admin permission on every call, including
  replay. Persisted account/project authority is revalidated in the transaction
  before locking a delivery within that project. The audit actor is derived here.
  A Scope struct's shape alone cannot prove its authentication provenance.

  Returns only bounded decision fields, never the stored digests or tenant IDs.
  Replays return the original decision without another write. New requests use
  project-bound fingerprint version 2; historical version 1 remains unchanged.

  The command must own its transaction: calls inside an explicit Repo transaction
  return `:invalid_arguments` before domain work. This keeps completion telemetry
  outside the transaction that commits or rolls back the decision. Each controlled
  result emits one event with bounded outcome and reason strings; replays use
  `"idempotent_replay"` and `"none"`. Duration is monotonic elapsed milliseconds.
  """
  @spec request_manual_retry(term(), term(), term()) ::
          {:ok, %{request: map(), replayed?: boolean()}} | {:error, atom()}
  def request_manual_retry(scope, delivery_id, idempotency_key) do
    if Repo.in_transaction?() do
      {:error, :invalid_arguments}
    else
      started = System.monotonic_time(:millisecond)
      result = prepare_manual_retry(scope, delivery_id, idempotency_key)
      duration_ms = System.monotonic_time(:millisecond) - started

      result |> emit_manual_retry_telemetry(duration_ms) |> public_manual_retry_result()
    end
  end

  defp prepare_manual_retry(scope, delivery_id, idempotency_key) do
    if Scope.valid?(scope) and Authorization.allowed?(scope, :manual_retries_write),
      do: prepare_authorized_manual_retry(scope, delivery_id, idempotency_key),
      else: {:error, :forbidden}
  end

  defp prepare_authorized_manual_retry(scope, delivery_id, idempotency_key)
       when is_integer(delivery_id) and delivery_id > 0 and
              delivery_id <= 9_223_372_036_854_775_807 do
    case ManualRetryIdempotency.prepare(scope.project_public_id, delivery_id, idempotency_key) do
      {:ok, prepared} -> persist_manual_retry(scope, delivery_id, prepared, DateTime.utc_now())
      {:error, :invalid_idempotency_key} -> {:error, :invalid_idempotency_key}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp prepare_authorized_manual_retry(_scope, _delivery_id, _idempotency_key),
    do: {:error, :invalid_arguments}

  defp public_manual_retry_result({:ok, %{request: request} = result}) do
    fields = [:id, :delivery_id, :outcome, :reason, :requested_at, :resulting_retry_cycle]
    {:ok, %{result | request: Map.take(request, fields)}}
  end

  defp public_manual_retry_result({:error, %Changeset{}}), do: {:error, :persistence_error}
  defp public_manual_retry_result(result), do: result

  defp emit_manual_retry_telemetry(result, duration_ms) do
    {outcome, reason} = manual_retry_telemetry_decision(result)

    :telemetry.execute(
      @manual_retry_completed,
      %{count: 1, duration_ms: duration_ms},
      %{outcome: outcome, reason: reason}
    )

    result
  end

  defp manual_retry_telemetry_decision({:ok, %{replayed?: true}}),
    do: {"idempotent_replay", "none"}

  defp manual_retry_telemetry_decision(
         {:ok, %{request: %ManualRetryRequest{outcome: "accepted"}, replayed?: false}}
       ),
       do: {"accepted", "none"}

  defp manual_retry_telemetry_decision(
         {:ok,
          %{request: %ManualRetryRequest{outcome: "rejected", reason: reason}, replayed?: false}}
       )
       when reason in @manual_retry_rejection_reasons,
       do: {"rejected", reason}

  defp manual_retry_telemetry_decision({:error, reason}),
    do: {"error", manual_retry_telemetry_error_reason(reason)}

  defp manual_retry_telemetry_decision(_result), do: {"error", "persistence"}

  defp manual_retry_telemetry_error_reason(:not_found), do: "not_found"
  defp manual_retry_telemetry_error_reason(:forbidden), do: "forbidden"
  defp manual_retry_telemetry_error_reason(:invalid_arguments), do: "invalid_arguments"

  defp manual_retry_telemetry_error_reason(:invalid_idempotency_key),
    do: "invalid_idempotency_key"

  defp manual_retry_telemetry_error_reason(:idempotency_conflict), do: "idempotency_conflict"
  defp manual_retry_telemetry_error_reason(:active_job), do: "active_job"
  defp manual_retry_telemetry_error_reason(_reason), do: "persistence"

  defp persist_manual_retry(scope, delivery_id, prepared, requested_at) do
    case manual_retry_transaction(scope, delivery_id, prepared, requested_at, :decide) do
      {:error, :manual_retry_key_race} ->
        # A different delivery lock cannot serialize this actor's key. Resolve
        # the unique-index winner only after the losing transaction rolled back.
        manual_retry_transaction(scope, delivery_id, prepared, requested_at, :replay_only)

      result ->
        result
    end
  rescue
    _error in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.StaleEntryError,
      DBConnection.ConnectionError
    ] ->
      {:error, :persistence_error}
  end

  defp manual_retry_transaction(scope, delivery_id, prepared, requested_at, mode) do
    Repo.transaction(
      fn ->
        if Scope.revalidate(scope) != :ok, do: Repo.rollback(:forbidden)

        delivery =
          Repo.one(
            from(delivery in Delivery,
              where: delivery.id == ^delivery_id and delivery.project_id == ^scope.project_id,
              lock: "FOR UPDATE"
            ),
            @repo_opts
          ) ||
            Repo.rollback(:not_found)

        endpoint =
          Repo.one(
            from(endpoint in Endpoint,
              where:
                endpoint.id == ^delivery.endpoint_id and endpoint.project_id == ^scope.project_id,
              lock: "FOR UPDATE"
            ),
            @repo_opts
          ) || Repo.rollback(:persistence_error)

        actor = %ManualRetryActor{
          type: "service_account",
          subject: scope.actor_subject,
          source: "api"
        }

        case prior_manual_retry(actor, prepared.idempotency_key_digest) do
          nil when mode == :replay_only -> Repo.rollback(:persistence_error)
          nil -> record_manual_retry(delivery, endpoint, actor, prepared, requested_at)
          request -> replay_manual_retry(request, prepared)
        end
      end,
      @repo_opts
    )
  end

  defp prior_manual_retry(actor, digest) do
    Repo.get_by(
      ManualRetryRequest,
      [actor_type: actor.type, actor_subject: actor.subject, idempotency_key_digest: digest],
      log: false,
      telemetry_event: nil
    )
  end

  defp replay_manual_retry(request, prepared) do
    if ManualRetryIdempotency.same_request?(request, prepared),
      do: %{request: request, replayed?: true},
      else: Repo.rollback(:idempotency_conflict)
  end

  defp record_manual_retry(delivery, endpoint, actor, prepared, requested_at) do
    decision = ManualRetryPolicy.evaluate(delivery, endpoint.active)
    {outcome, reason, resulting_cycle} = manual_retry_decision(decision, delivery)

    request = %ManualRetryRequest{
      delivery_id: delivery.id,
      actor_type: actor.type,
      actor_subject: actor.subject,
      source: actor.source,
      idempotency_key_digest: prepared.idempotency_key_digest,
      request_fingerprint: prepared.request_fingerprint,
      request_fingerprint_version: prepared.request_fingerprint_version
    }

    changeset =
      ManualRetryRequest.changeset(request, %{
        requested_at: requested_at,
        outcome: outcome,
        reason: reason,
        observed_status: delivery.status,
        observed_attempt_count: delivery.attempt_count,
        observed_retry_cycle: delivery.retry_cycle,
        observed_completed_at: delivery.completed_at,
        resulting_retry_cycle: resulting_cycle
      })

    case Repo.insert(changeset, mode: :savepoint, log: false, telemetry_event: nil) do
      {:ok, request} ->
        if outcome == "accepted", do: reopen_delivery_for_manual_retry(delivery)
        %{request: request, replayed?: false}

      {:error, changeset} ->
        if manual_retry_key_conflict?(changeset),
          do: Repo.rollback(:manual_retry_key_race),
          else: Repo.rollback(changeset)
    end
  end

  defp manual_retry_decision(:ok, delivery), do: {"accepted", nil, delivery.retry_cycle + 1}

  defp manual_retry_decision({:error, reason}, _delivery)
       when reason in [:state_not_failed, :endpoint_inactive, :manual_cycle_limit_reached],
       do: {"rejected", Atom.to_string(reason), nil}

  defp manual_retry_decision(_decision, _delivery), do: Repo.rollback(:invalid_arguments)

  defp manual_retry_key_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint] == :unique and
        options[:constraint_name] == "manual_retry_requests_actor_idempotency_key_index"
    end)
  end

  defp reopen_delivery_for_manual_retry(delivery) do
    with :ok <- ensure_no_active_manual_retry_legacy_job(delivery),
         {:ok, pending} <-
           delivery
           |> Delivery.changeset(%{
             status: "pending",
             retry_cycle: delivery.retry_cycle + 1,
             cycle_attempt_count: 0,
             completed_at: nil,
             next_attempt_at: nil
           })
           |> Repo.update(@repo_opts),
         {:ok, job} <- pending |> new_delivery_job() |> Oban.insert(@repo_opts) do
      if job.conflict?, do: Repo.rollback(:active_job)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_no_active_manual_retry_legacy_job(delivery) do
    legacy_args = [
      %{"delivery_id" => delivery.id},
      %{"delivery_id" => delivery.id, "attempt_number" => delivery.attempt_count + 1}
    ]

    active_states = Oban.Job.unique_states(:incomplete) |> Enum.map(&Atom.to_string/1)
    worker = Oban.Worker.to_string(DeliverWebhookWorker)

    query =
      from(job in Oban.Job,
        where: job.worker == ^worker and job.state in ^active_states,
        where: job.args in ^legacy_args
      )

    if Repo.exists?(query, @repo_opts), do: {:error, :active_job}, else: :ok
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

  def list_deliveries_for_event(project, %Event{} = event) do
    project_id = project_id!(project)

    from(delivery in Delivery,
      where: delivery.event_id == ^event.id and delivery.project_id == ^project_id,
      order_by: [asc: delivery.id]
    )
    |> Repo.all(@repo_opts)
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

  def claim_delivery(delivery_id, %{} = expected_identity)
      when is_integer(delivery_id) and delivery_id > 0 do
    claim_delivery(delivery_id, expected_identity, DateTime.utc_now())
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

  def claim_delivery(
        delivery_id,
        %{} = expected_identity,
        %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = reference_time
      )
      when is_integer(delivery_id) and delivery_id > 0 do
    if valid_claim_identity?(expected_identity) do
      claim_delivery_with_guard(delivery_id, expected_identity, reference_time)
    else
      {:error, :invalid_arguments}
    end
  end

  def claim_delivery(_delivery_id, _expected_attempt_number, _reference_time),
    do: {:error, :invalid_arguments}

  defp claim_delivery_with_guard(delivery_id, expected_attempt, reference_time) do
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
          claim_pending_delivery(delivery, expected_attempt, reference_time)

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

  def list_endpoints(project) do
    project_id = project_id!(project)
    Repo.all(from(endpoint in Endpoint, where: endpoint.project_id == ^project_id), @repo_opts)
  end

  def list_active_endpoints(project) do
    project |> project_id!() |> active_endpoints_query() |> Repo.all(@repo_opts)
  end

  def get_endpoint(project, id) do
    Repo.get_by(Endpoint, [id: id, project_id: project_id!(project)], @repo_opts)
  end

  def create_endpoint(project, attrs \\ %{}) do
    %Endpoint{project_id: project_id!(project)}
    |> Endpoint.changeset(attrs)
    |> Repo.insert(@repo_opts)
  end

  def update_endpoint(project, %Endpoint{id: id}, attrs) do
    case get_endpoint(project, id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        endpoint
        |> Endpoint.changeset(attrs)
        # Match immutable ownership in UPDATE as well as the preceding lookup.
        |> Changeset.optimistic_lock(:project_id, &Function.identity/1)
        |> Repo.update(@repo_opts)
    end
  end

  def delete_endpoint(project, %Endpoint{id: id}) do
    case get_endpoint(project, id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        endpoint
        |> Changeset.change()
        |> Changeset.foreign_key_constraint(:id, name: :deliveries_endpoint_id_fkey)
        |> Changeset.optimistic_lock(:project_id, &Function.identity/1)
        |> Repo.delete(@repo_opts)
    end
  end

  def change_endpoint(project, %Endpoint{id: id}, attrs \\ %{}) do
    case get_endpoint(project, id) do
      nil -> {:error, :not_found}
      endpoint -> Endpoint.changeset(endpoint, attrs)
    end
  end

  defp project_id!(%Project{id: id, status: "active"}) when is_integer(id) and id > 0, do: id
  defp project_id!(%Scope{project_id: id}) when is_integer(id) and id > 0, do: id
  defp project_id!(_context), do: raise(ArgumentError, "Trusted project context required")

  defp active_endpoints_query(project_id) do
    from(endpoint in Endpoint,
      where: endpoint.project_id == ^project_id and endpoint.active == true,
      order_by: [asc: endpoint.id]
    )
  end

  defp fanout_multi(%{event: event, endpoints: endpoints}) do
    Enum.reduce(endpoints, Multi.new(), fn endpoint, multi ->
      delivery_operation = {:delivery, endpoint.id}
      job_operation = {:job, endpoint.id}

      multi
      |> Multi.insert(delivery_operation, delivery_changeset(event, endpoint), @repo_opts)
      |> Oban.insert(job_operation, fn changes ->
        changes
        |> Map.fetch!(delivery_operation)
        |> new_delivery_job()
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
    Delivery.changeset(
      %Delivery{project_id: event.project_id, event_id: event.id, endpoint_id: endpoint.id},
      %{}
    )
  end

  defp new_delivery_job(delivery) do
    DeliverWebhookWorker.new_for_delivery(
      delivery.id,
      delivery.attempt_count + 1,
      delivery.retry_cycle,
      delivery.cycle_attempt_count + 1
    )
  end

  defp new_scheduled_delivery_job(delivery, retry_at) do
    DeliverWebhookWorker.new_scheduled_for_delivery(
      delivery.id,
      delivery.attempt_count + 1,
      delivery.retry_cycle,
      delivery.cycle_attempt_count + 1,
      retry_at
    )
  end

  defp ensure_no_active_legacy_job(delivery_id, attempt_number) do
    legacy_args = [%{"delivery_id" => delivery_id, "attempt_number" => attempt_number}]

    legacy_args =
      if attempt_number == 1,
        do: [%{"delivery_id" => delivery_id} | legacy_args],
        else: legacy_args

    active_states = Oban.Job.unique_states(:incomplete) |> Enum.map(&Atom.to_string/1)
    worker = Oban.Worker.to_string(DeliverWebhookWorker)

    query =
      from(job in Oban.Job,
        where: job.worker == ^worker and job.state in ^active_states,
        where: job.args in ^legacy_args
      )

    if Repo.exists?(query), do: {:error, :active_job}, else: :ok
  end

  defp recover_if_stale(delivery, stale_before) do
    if DateTime.compare(delivery.updated_at, stale_before) in [:lt, :eq] do
      recover_processing_delivery(delivery)
    else
      Repo.rollback(:not_stale)
    end
  end

  defp recover_processing_delivery(delivery) do
    with :ok <- ensure_no_active_legacy_job(delivery.id, delivery.attempt_count + 1),
         {:ok, recovered} <-
           delivery
           |> Delivery.changeset(%{
             status: "pending",
             completed_at: nil,
             next_attempt_at: nil
           })
           |> Repo.update(),
         {:ok, job} <- recovered |> new_delivery_job() |> Oban.insert() do
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

    with :ok <- ensure_no_active_legacy_job(delivery.id, attempt_number + 1),
         {:ok, attempt} <- Repo.insert(attempt_changeset),
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
         {:ok, job} <- pending |> new_scheduled_delivery_job(retry_at) |> Oban.insert() do
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

  defp claim_pending_delivery(delivery, expected_attempt, reference_time) do
    with :ok <- validate_expected_attempt(delivery, expected_attempt),
         :ok <- validate_claim_time(delivery, reference_time) do
      prepare_pending_delivery(delivery)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp valid_claim_identity?(
         %{
           attempt_number: attempt_number,
           retry_cycle: retry_cycle,
           cycle_attempt_number: cycle_attempt_number
         } = identity
       )
       when map_size(identity) == 3 and is_integer(attempt_number) and attempt_number > 0 and
              is_integer(retry_cycle) and retry_cycle >= 0 and is_integer(cycle_attempt_number) and
              cycle_attempt_number > 0,
       do: true

  defp valid_claim_identity?(_identity), do: false

  defp validate_expected_attempt(_delivery, :current_attempt), do: :ok

  defp validate_expected_attempt(
         delivery,
         %{
           attempt_number: attempt_number,
           retry_cycle: retry_cycle,
           cycle_attempt_number: cycle_attempt_number
         }
       ) do
    if attempt_number == delivery.attempt_count + 1 and retry_cycle == delivery.retry_cycle and
         cycle_attempt_number == delivery.cycle_attempt_count + 1,
       do: :ok,
       else: {:error, :stale_attempt}
  end

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

defmodule Tidewake.Webhooks.ManualRetryTelemetryTest do
  use ExUnit.Case, async: false

  import Tidewake.WebhooksFixtures,
    only: [legacy_project: 0, retry_scope_fixture: 1, retry_and_load_audit: 3]

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Repo
  alias Tidewake.Webhooks

  alias Tidewake.Webhooks.{
    Attempt,
    Delivery,
    Endpoint,
    Event,
    ManualRetryRequest
  }

  alias Tidewake.Workers.DeliverWebhookWorker

  @event [:tidewake, :webhooks, :manual_retry, :completed]
  @key "private-manual-retry-key-0001"
  @other_key "private-manual-retry-key-0002"
  @outcomes ~w(accepted rejected idempotent_replay error)
  @reasons ~w(none state_not_failed endpoint_inactive manual_cycle_limit_reached
    not_found forbidden invalid_arguments invalid_idempotency_key idempotency_conflict active_job persistence)
  @completed_at ~U[2026-10-20 10:00:00.123456Z]

  setup tags do
    unless tags[:unboxed], do: Tidewake.DataCase.setup_sandbox(tags)
    Process.put(:oban_testing, :manual)

    actor = retry_scope_fixture(tags)

    attach_handler(&__MODULE__.handle_completion/4, self())
    {:ok, actor: actor}
  end

  test "accepted emits exactly one bounded completion and preserves the domain return", %{
    actor: actor
  } do
    delivery = delivery_fixture()
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{request: request, replayed?: false}} =
             retry_and_load_audit(actor, delivery.id, @key)

    assert request.outcome == "accepted"
    assert request == Repo.get!(ManualRetryRequest, request.id)
    {measurements, metadata} = assert_completed("accepted", "none")
    assert measurements.duration_ms <= System.monotonic_time(:millisecond) - started
    serialized = inspect({@event, measurements, metadata}, limit: :infinity)

    for protected <- [
          "service_account",
          actor.actor_subject,
          "api",
          actor.project_public_id,
          @key,
          request.idempotency_key_digest,
          request.request_fingerprint,
          "private-payload",
          "private-endpoint",
          "authorization",
          "Bearer private-token"
        ] do
      refute serialized =~ protected
    end
  end

  for reason <- ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached) do
    @reason reason
    test "committed #{@reason} rejection has its fixed reason", %{actor: actor} do
      attrs =
        case @reason do
          "state_not_failed" -> %{status: "pending"}
          "endpoint_inactive" -> %{endpoint_active: false}
          "manual_cycle_limit_reached" -> %{retry_cycle: 3}
        end

      delivery = delivery_fixture(attrs)

      assert {:ok, %{request: request, replayed?: false}} =
               retry_and_load_audit(actor, delivery.id, @key)

      assert request.outcome == "rejected"
      assert request.reason == @reason
      assert request == Repo.get!(ManualRetryRequest, request.id)
      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Repo.all(Oban.Job) == []
      assert_completed("rejected", @reason)
    end
  end

  test "accepted replay emits once without reporting another acceptance", %{actor: actor} do
    delivery = delivery_fixture()
    assert {:ok, %{request: original}} = retry_and_load_audit(actor, delivery.id, @key)
    assert_completed("accepted", "none")
    before_replay = persisted_state()

    assert {:ok, %{request: ^original, replayed?: true}} =
             retry_and_load_audit(actor, delivery.id, @key)

    assert_completed("idempotent_replay", "none")
    assert persisted_state() == before_replay
  end

  test "rejected replay reports replay instead of another rejection", %{actor: actor} do
    delivery = delivery_fixture(%{endpoint_active: false})
    assert {:ok, %{request: original}} = retry_and_load_audit(actor, delivery.id, @key)
    assert_completed("rejected", "endpoint_inactive")
    before_replay = persisted_state()

    assert {:ok, %{request: ^original, replayed?: true}} =
             retry_and_load_audit(actor, delivery.id, @key)

    assert_completed("idempotent_replay", "none")
    assert persisted_state() == before_replay
  end

  test "idempotency conflict emits only its bounded error after rollback", %{actor: actor} do
    first = delivery_fixture()
    second = delivery_fixture()
    assert {:ok, _result} = retry_and_load_audit(actor, first.id, @key)
    assert_completed("accepted", "none")
    before_conflict = persisted_state()
    assert {:error, :idempotency_conflict} = retry_and_load_audit(actor, second.id, @key)
    assert_completed("error", "idempotency_conflict")
    assert persisted_state() == before_conflict
  end

  test "not found emits once after the read transaction rolls back", %{actor: actor} do
    assert {:error, :not_found} =
             retry_and_load_audit(actor, 9_223_372_036_854_775_807, @key)

    assert_completed("error", "not_found")
    assert Repo.all(ManualRetryRequest) == []
    assert Repo.all(Oban.Job) == []
  end

  test "invalid arguments each emit only the fixed validation reason", %{actor: actor} do
    for {id, context} <- [
          {nil, actor},
          {0, actor},
          {-1, actor},
          {"1", actor}
        ] do
      assert {:error, :invalid_arguments} = retry_and_load_audit(context, id, @key)
      assert_completed("error", "invalid_arguments")
    end

    assert Repo.all(ManualRetryRequest) == []
  end

  test "invalid keys never become metadata or dynamic reasons", %{actor: actor} do
    for key <- [nil, "private invalid key", "Bearer private-token", String.duplicate("x", 129)] do
      assert {:error, :invalid_idempotency_key} = retry_and_load_audit(actor, 1, key)
      assert_completed("error", "invalid_idempotency_key")
    end

    assert Repo.all(ManualRetryRequest) == []
  end

  test "functional denials emit only the fixed forbidden classification", %{actor: actor} do
    for scope <- [nil, Map.from_struct(actor), %{actor | role: "viewer"}] do
      assert Webhooks.request_manual_retry(scope, 1, @key) == {:error, :forbidden}
      assert_completed("error", "forbidden")
    end

    assert Repo.all(ManualRetryRequest) == []
    assert Repo.all(Oban.Job) == []
  end

  test "active job rolls back the attempted decision before reporting an error", %{actor: actor} do
    delivery = delivery_fixture()
    {:ok, _job} = DeliverWebhookWorker.new_for_delivery(delivery.id, 7, 1, 1) |> Oban.insert()
    before_conflict = persisted_state()
    assert {:error, :active_job} = retry_and_load_audit(actor, delivery.id, @key)
    assert_completed("error", "active_job")
    assert persisted_state() == before_conflict
    assert Repo.all(ManualRetryRequest) == []
  end

  for table <- ~w(manual_retry_requests deliveries oban_jobs) do
    @failure_table table
    test "#{@failure_table} persistence failure emits only error after rollback", %{actor: actor} do
      delivery = delivery_fixture()
      before_failure = persisted_state()
      constraint = "manual_retry_telemetry_#{System.unique_integer([:positive])}"

      Repo.query!(
        "ALTER TABLE #{@failure_table} ADD CONSTRAINT #{constraint} CHECK (false) NOT VALID"
      )

      try do
        assert {:error, :persistence_error} =
                 retry_and_load_audit(actor, delivery.id, @key)

        assert_completed("error", "persistence")
        assert persisted_state() == before_failure
        assert Webhooks.get_delivery_internal(delivery.id) == delivery
      after
        Repo.query!("ALTER TABLE #{@failure_table} DROP CONSTRAINT #{constraint}")
      end
    end
  end

  test "changeset persistence failures are categorized without validation details", %{
    actor: actor
  } do
    delivery = delivery_fixture()
    before_failure = persisted_state()
    constraint = "deliveries_retry_cycle_in_range"

    %{rows: [[definition]]} =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid = 'deliveries'::regclass AND conname = $1
        """,
        [constraint]
      )

    Repo.query!("ALTER TABLE deliveries DROP CONSTRAINT #{constraint}")

    Repo.query!(
      "ALTER TABLE deliveries ADD CONSTRAINT #{constraint} CHECK (retry_cycle = 0) NOT VALID"
    )

    try do
      assert {:error, :persistence_error} =
               retry_and_load_audit(actor, delivery.id, @key)

      assert_completed("error", "persistence")
      assert persisted_state() == before_failure
    after
      Repo.query!("ALTER TABLE deliveries DROP CONSTRAINT #{constraint}")
      Repo.query!("ALTER TABLE deliveries ADD CONSTRAINT #{constraint} #{definition}")
    end
  end

  test "nested invocations fail before domain work instead of announcing an uncommitted decision",
       %{actor: actor} do
    delivery = delivery_fixture()
    before_request = persisted_state()

    assert {:error, :outer_rollback} =
             Repo.transaction(fn ->
               assert {:error, :invalid_arguments} =
                        retry_and_load_audit(actor, delivery.id, @key)

               refute_received {:manual_retry_event, _, _, _}
               Repo.rollback(:outer_rollback)
             end)

    assert persisted_state() == before_request
    refute_received {:manual_retry_event, _, _, _}
  end

  @tag :unboxed
  test "independent connections see committed state when decisions and replays emit", %{
    actor: actor
  } do
    delivery = Sandbox.unboxed_run(Repo, fn -> delivery_fixture() end)
    on_exit(fn -> cleanup_committed_fixture(delivery) end)
    supervisor = start_supervised!(Task.Supervisor)
    attach_handler(&__MODULE__.observe_committed_state/4, {self(), supervisor, delivery.id})

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, %{request: accepted}} = retry_and_load_audit(actor, delivery.id, @key)
      assert_completed("accepted", "none")
      assert_committed_observation("accepted", ["accepted"])

      assert {:ok, %{request: ^accepted, replayed?: true}} =
               retry_and_load_audit(actor, delivery.id, @key)

      assert_completed("idempotent_replay", "none")
      assert_committed_observation("idempotent_replay", ["accepted"])

      assert {:ok, %{request: rejected}} =
               retry_and_load_audit(actor, delivery.id, @other_key)

      assert_completed("rejected", "state_not_failed")
      assert_committed_observation("rejected", ["accepted", "rejected"])

      assert {:ok, %{request: ^rejected, replayed?: true}} =
               retry_and_load_audit(actor, delivery.id, @other_key)

      assert_completed("idempotent_replay", "none")
      assert_committed_observation("idempotent_replay", ["accepted", "rejected"])
    end)
  end

  @doc false
  def handle_completion(_event, measurements, metadata, parent) do
    send(parent, {:manual_retry_event, measurements, metadata, Repo.in_transaction?()})
  end

  @doc false
  def observe_committed_state(_event, _measurements, metadata, {parent, supervisor, delivery_id}) do
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{
            status: Webhooks.get_delivery_internal(delivery_id).status,
            outcomes:
              Repo.all(
                from(request in ManualRetryRequest,
                  where: request.delivery_id == ^delivery_id,
                  order_by: request.id,
                  select: request.outcome
                )
              ),
            job_count:
              Repo.aggregate(
                from(job in Oban.Job,
                  where: fragment("(?->>'delivery_id')::bigint", job.args) == ^delivery_id
                ),
                :count
              )
          }
        end)
      end)

    send(parent, {:committed_observation, metadata.outcome, Task.await(task, 5_000)})
  end

  defp assert_completed(outcome, reason) do
    expected = %{outcome: outcome, reason: reason}
    assert_received {:manual_retry_event, measurements, ^expected, false}
    assert Enum.sort(Map.keys(measurements)) == [:count, :duration_ms]
    assert measurements.count == 1
    assert is_integer(measurements.duration_ms) and measurements.duration_ms >= 0
    assert outcome in @outcomes
    assert reason in @reasons
    refute_received {:manual_retry_event, _, _, _}
    {measurements, expected}
  end

  defp assert_committed_observation(outcome, outcomes) do
    assert_received {:committed_observation, ^outcome,
                     %{status: "pending", outcomes: ^outcomes, job_count: 1}}

    refute_received {:committed_observation, _, _}
  end

  defp attach_handler(handler, config) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, handler, config)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp persisted_state do
    %{
      deliveries: Repo.all(from(delivery in Delivery, order_by: delivery.id)),
      requests: Repo.all(from(request in ManualRetryRequest, order_by: request.id)),
      jobs: Repo.all(from(job in Oban.Job, order_by: job.id)),
      attempts: Repo.all(from(attempt in Attempt, order_by: attempt.id))
    }
  end

  defp delivery_fixture(attrs \\ %{}) do
    cycle = Map.get(attrs, :retry_cycle, 0)

    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{
          "secret" => "private-payload",
          "headers" => %{"authorization" => "Bearer private-token"}
        }
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "private-endpoint",
        url: "https://endpoint.invalid/webhook?token=private-endpoint"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

    for retry_cycle <- 0..cycle, ordinal <- 1..6 do
      {:ok, _attempt} =
        Webhooks.create_attempt(
          %{delivery | retry_cycle: retry_cycle, cycle_attempt_count: ordinal - 1},
          %{
            attempt_number: retry_cycle * 6 + ordinal,
            result: "http_error",
            http_status: 503,
            duration_ms: 1,
            started_at: @completed_at,
            completed_at: @completed_at
          }
        )
    end

    {:ok, _endpoint} =
      Webhooks.update_endpoint(legacy_project(), endpoint, %{
        active: Map.get(attrs, :endpoint_active, true)
      })

    delivery
    |> Delivery.changeset(%{
      status: Map.get(attrs, :status, "failed"),
      attempt_count: (cycle + 1) * 6,
      retry_cycle: cycle,
      cycle_attempt_count: 6,
      completed_at: @completed_at
    })
    |> Repo.update!()
  end

  defp cleanup_committed_fixture(delivery) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.delete_all(
          from(job in Oban.Job,
            where: fragment("(?->>'delivery_id')::bigint", job.args) == ^delivery.id
          )
        )

        Repo.delete_all(
          from(request in ManualRetryRequest, where: request.delivery_id == ^delivery.id)
        )

        Repo.delete_all(from(attempt in Attempt, where: attempt.delivery_id == ^delivery.id))
        Repo.delete!(Repo.get!(Delivery, delivery.id))
        Repo.delete!(Repo.get!(Event, delivery.event_id))
        Repo.delete!(Repo.get!(Endpoint, delivery.endpoint_id))
      end)
    end)
  end
end

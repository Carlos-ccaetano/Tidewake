defmodule Tidewake.Webhooks.ManualRetryRollbackTest do
  use Tidewake.DataCase, async: false

  import Tidewake.WebhooksFixtures,
    only: [legacy_project: 0, retry_scope_fixture: 1, retry_and_load_audit: 3]

  alias Tidewake.Webhooks

  alias Tidewake.Webhooks.{
    Attempt,
    Delivery,
    Endpoint,
    Event,
    ManualRetryRequest
  }

  alias Tidewake.Workers.DeliverWebhookWorker

  @key "manual-retry-rollback-key-0001"
  @completed_at ~U[2026-10-20 10:00:00.123456Z]

  setup do
    Process.put(:oban_testing, :manual)

    {:ok, actor: retry_scope_fixture(%{})}
  end

  test "accepted audit insertion failure preserves the complete terminal delivery", %{
    actor: actor
  } do
    delivery = delivery_fixture()
    before_failure = snapshot()
    check = "delivery_id <> #{delivery.id} OR outcome <> 'accepted'"

    with_constraint("manual_retry_requests", check, fn ->
      assert {:error, :persistence_error} =
               retry_and_load_audit(actor, delivery.id, @key)

      assert_rolled_back(delivery, before_failure)
      assert Repo.all(ManualRetryRequest) == []
      assert Repo.all(Oban.Job) == []
    end)

    assert_fresh_acceptance(delivery, actor)
  end

  test "delivery update failure rolls back an audit already inserted in the transaction", %{
    actor: actor
  } do
    delivery = delivery_fixture()
    before_failure = snapshot()

    guard_sql = """
    SELECT NOT EXISTS (
      SELECT 1 FROM manual_retry_requests
      WHERE delivery_id = #{delivery.id} AND outcome = 'accepted'
        AND observed_retry_cycle = #{delivery.retry_cycle}
        AND resulting_retry_cycle = #{delivery.retry_cycle + 1}
    )
    """

    with_write_guard(guard_sql, fn guard ->
      check = "id <> #{delivery.id} OR status <> 'pending' OR #{guard}"

      with_constraint("deliveries", check, fn ->
        # The constraint can fail only after the accepted audit is visible.
        assert {:error, :persistence_error} =
                 retry_and_load_audit(actor, delivery.id, @key)

        assert_rolled_back(delivery, before_failure)
        assert Repo.all(ManualRetryRequest) == []
        assert Repo.all(Oban.Job) == []
      end)
    end)

    assert_fresh_acceptance(delivery, actor)
  end

  test "job insertion failure rolls back both the accepted audit and pending transition", %{
    actor: actor
  } do
    delivery = delivery_fixture()
    before_failure = snapshot()

    guard_sql = """
    SELECT NOT EXISTS (
      SELECT 1 FROM manual_retry_requests request
      JOIN deliveries delivery ON delivery.id = request.delivery_id
      WHERE delivery.id = #{delivery.id} AND request.outcome = 'accepted'
        AND request.observed_retry_cycle = #{delivery.retry_cycle}
        AND request.resulting_retry_cycle = #{delivery.retry_cycle + 1}
        AND delivery.status = 'pending' AND delivery.retry_cycle = #{delivery.retry_cycle + 1}
        AND delivery.attempt_count = #{delivery.attempt_count} AND delivery.cycle_attempt_count = 0
        AND delivery.completed_at IS NULL AND delivery.next_attempt_at IS NULL
    )
    """

    with_write_guard(guard_sql, fn guard ->
      check = "(args->>'delivery_id') IS DISTINCT FROM '#{delivery.id}' OR #{guard}"

      with_constraint("oban_jobs", check, fn ->
        # Both earlier writes must be visible before this constraint rejects work.
        assert {:error, :persistence_error} =
                 retry_and_load_audit(actor, delivery.id, @key)

        assert_rolled_back(delivery, before_failure)
        assert Repo.all(ManualRetryRequest) == []
        assert Repo.all(Oban.Job) == []
      end)
    end)

    assert_fresh_acceptance(delivery, actor)
  end

  test "an equivalent active cycle-aware job survives without a partial acceptance", %{
    actor: actor
  } do
    delivery = delivery_fixture()

    {:ok, job} =
      DeliverWebhookWorker.new_for_delivery(
        delivery.id,
        delivery.attempt_count + 1,
        delivery.retry_cycle + 1,
        1
      )
      |> Oban.insert()

    persisted_job = Repo.get!(Oban.Job, job.id)
    before_failure = snapshot()

    assert {:error, :active_job} = retry_and_load_audit(actor, delivery.id, @key)
    assert_rolled_back(delivery, before_failure)
    assert Repo.all(ManualRetryRequest) == []
    assert Repo.all(Oban.Job) == [persisted_job]

    retire_job(persisted_job)
    assert_fresh_acceptance(delivery, actor)
  end

  for format <- [:delivery_only, :lifetime_attempt] do
    @legacy_format format
    test "an active #{@legacy_format} legacy job prevents a partial cycle transition", %{
      actor: actor
    } do
      delivery = delivery_fixture()

      args =
        case @legacy_format do
          :delivery_only ->
            %{"delivery_id" => delivery.id}

          :lifetime_attempt ->
            %{"delivery_id" => delivery.id, "attempt_number" => delivery.attempt_count + 1}
        end

      job =
        args |> DeliverWebhookWorker.new() |> Oban.insert!() |> then(&Repo.get!(Oban.Job, &1.id))

      before_failure = snapshot()

      assert {:error, :active_job} = retry_and_load_audit(actor, delivery.id, @key)
      assert_rolled_back(delivery, before_failure)
      assert Repo.all(ManualRetryRequest) == []
      assert Repo.all(Oban.Job) == [job]

      retire_job(job)
      assert_fresh_acceptance(delivery, actor)
    end
  end

  for reason <- ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached) do
    @rejection_reason reason
    test "failure to persist #{@rejection_reason} leaves no rejected audit or other writes", %{
      actor: actor
    } do
      attrs =
        case @rejection_reason do
          "state_not_failed" -> %{status: "pending"}
          "endpoint_inactive" -> %{endpoint_active: false}
          "manual_cycle_limit_reached" -> %{retry_cycle: 3}
        end

      delivery = delivery_fixture(attrs)
      before_failure = snapshot()
      check = "delivery_id <> #{delivery.id} OR outcome <> 'rejected'"

      with_constraint("manual_retry_requests", check, fn ->
        assert {:error, :persistence_error} =
                 retry_and_load_audit(actor, delivery.id, @key)

        assert snapshot() == before_failure
        assert Repo.all(ManualRetryRequest) == []
        assert Repo.all(Oban.Job) == []
      end)

      assert {:ok, %{request: request, replayed?: false}} =
               retry_and_load_audit(actor, delivery.id, @key)

      assert request.outcome == "rejected"
      assert request.reason == @rejection_reason
      assert request.resulting_retry_cycle == nil
      assert Repo.all(ManualRetryRequest) == [request]
      assert Webhooks.get_delivery_internal(delivery.id) == delivery
      assert Repo.all(Oban.Job) == []
      assert Webhooks.list_attempts(delivery) == before_failure.attempts
    end
  end

  for original_outcome <- ~w(accepted rejected) do
    @original_outcome original_outcome
    test "idempotency conflict preserves the original #{@original_outcome} evidence and all deliveries",
         %{actor: actor} do
      first = delivery_fixture(%{endpoint_active: @original_outcome == "accepted"})
      second = delivery_fixture()
      assert {:ok, %{request: original}} = retry_and_load_audit(actor, first.id, @key)
      assert original.outcome == @original_outcome
      before_failure = snapshot()

      assert {:error, :idempotency_conflict} =
               retry_and_load_audit(actor, second.id, @key)

      assert snapshot() == before_failure
      assert Repo.all(ManualRetryRequest) == [original]
      assert Webhooks.get_delivery_internal(second.id) == second

      assert {:ok, %{request: ^original, replayed?: true}} =
               retry_and_load_audit(actor, first.id, @key)

      assert snapshot() == before_failure
    end
  end

  defp with_constraint(table, check, fun) do
    name = "manual_retry_rollback_#{System.unique_integer([:positive])}"
    # NOT VALID skips existing rows; PostgreSQL still checks every new write.
    # DDL and fixtures remain in this test's sandbox transaction, even on failure.
    Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{check}) NOT VALID")

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{name}")

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM pg_constraint WHERE conname = $1", [name])
    end
  end

  defp with_write_guard(sql, fun) do
    name = "manual_retry_rollback_guard_#{System.unique_integer([:positive])}"
    # A VOLATILE SQL function sees writes made earlier in the same transaction.
    # It permits the write if prerequisites are absent, so an ordering regression
    # cannot pass merely because an unconditional constraint blocked everything.
    Repo.query!("""
    CREATE FUNCTION pg_temp.#{name}() RETURNS boolean
    LANGUAGE sql VOLATILE AS $$ #{sql} $$
    """)

    try do
      fun.("pg_temp.#{name}()")
    after
      Repo.query!("DROP FUNCTION pg_temp.#{name}()")

      assert %{rows: [[nil]]} =
               Repo.query!("SELECT to_regprocedure($1)::text", ["pg_temp.#{name}()"])
    end
  end

  defp assert_rolled_back(delivery, before_failure) do
    assert snapshot() == before_failure
    persisted = Webhooks.get_delivery_internal(delivery.id)
    assert persisted == delivery
    assert persisted.status == "failed"
    assert persisted.retry_cycle == delivery.retry_cycle
    assert persisted.cycle_attempt_count == delivery.cycle_attempt_count
    assert persisted.attempt_count == delivery.attempt_count
    assert persisted.completed_at == @completed_at
  end

  defp assert_fresh_acceptance(delivery, actor) do
    # Removing the failure must allow the same key's first durable decision.
    assert {:ok, %{request: request, replayed?: false}} =
             retry_and_load_audit(actor, delivery.id, @key)

    assert request.outcome == "accepted"
    assert request.observed_retry_cycle == delivery.retry_cycle
    assert request.observed_completed_at == delivery.completed_at
    assert request.resulting_retry_cycle == delivery.retry_cycle + 1
    assert Repo.all(ManualRetryRequest) == [request]
    pending = Webhooks.get_delivery_internal(delivery.id)
    assert pending.status == "pending"
    assert pending.retry_cycle == delivery.retry_cycle + 1
    assert pending.attempt_count == delivery.attempt_count
    assert pending.cycle_attempt_count == 0
    assert pending.completed_at == nil
    assert pending.next_attempt_at == nil
    assert [%{args: args}] = Repo.all(from(job in Oban.Job, where: job.state == "available"))

    assert args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => delivery.attempt_count + 1,
             "retry_cycle" => delivery.retry_cycle + 1,
             "cycle_attempt_number" => 1
           }
  end

  defp retire_job(job) do
    job |> change(state: "completed", completed_at: DateTime.utc_now()) |> Repo.update!()
  end

  defp snapshot do
    %{
      deliveries: Repo.all(from(delivery in Delivery, order_by: delivery.id)),
      requests: Repo.all(from(request in ManualRetryRequest, order_by: request.id)),
      jobs: Repo.all(from(job in Oban.Job, order_by: job.id)),
      attempts: Repo.all(from(attempt in Attempt, order_by: attempt.id)),
      events: Repo.all(from(event in Event, order_by: event.id)),
      endpoints: Repo.all(from(endpoint in Endpoint, order_by: endpoint.id))
    }
  end

  defp delivery_fixture(attrs \\ %{}) do
    cycle = Map.get(attrs, :retry_cycle, 1)
    status = Map.get(attrs, :status, "failed")

    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{"immutable" => true}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Rollback boundary",
        url: "https://endpoint.invalid/webhook"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

    for retry_cycle <- 0..cycle, ordinal <- 1..6 do
      assert {:ok, _attempt} =
               Webhooks.create_attempt(
                 %{delivery | retry_cycle: retry_cycle, cycle_attempt_count: ordinal - 1},
                 %{
                   attempt_number: retry_cycle * 6 + ordinal,
                   result: "http_error",
                   http_status: 503,
                   duration_ms: 1,
                   started_at: @completed_at,
                   completed_at: @completed_at,
                   next_attempt_at:
                     if(ordinal < 6, do: DateTime.add(@completed_at, ordinal, :second))
                 }
               )
    end

    {:ok, _endpoint} =
      Webhooks.update_endpoint(legacy_project(), endpoint, %{
        active: Map.get(attrs, :endpoint_active, true)
      })

    delivery
    |> Delivery.changeset(%{
      status: status,
      attempt_count: (cycle + 1) * 6,
      retry_cycle: cycle,
      cycle_attempt_count: 6,
      completed_at: if(status == "failed", do: @completed_at)
    })
    |> Repo.update!()
  end
end

defmodule Tidewake.WebhooksTest do
  use Tidewake.DataCase, async: false

  alias Ecto.Changeset
  alias Tidewake.Webhooks
  alias Tidewake.Workers.DeliverWebhookWorker

  describe "events" do
    test "create_event/1 persists a valid event" do
      attrs = valid_event_attrs()

      assert {:ok, event} = Webhooks.create_event(attrs)
      assert event.external_id == attrs.external_id
      assert event.event_type == attrs.event_type
      assert event.payload == attrs.payload
    end

    test "create_event/1 returns an invalid changeset for invalid attributes" do
      assert {:error, %Changeset{} = changeset} = Webhooks.create_event(%{})
      refute changeset.valid?
    end

    test "create_event/1 returns an invalid changeset for a duplicate external_id" do
      event_fixture()

      assert {:error, %Changeset{} = changeset} =
               Webhooks.create_event(valid_event_attrs())

      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).external_id
    end

    test "get_event/1 returns an event by its internal ID" do
      event = event_fixture()

      assert Webhooks.get_event(event.id) == event
    end

    test "get_event/1 returns nil for an unknown ID" do
      assert Webhooks.get_event(-1) == nil
    end

    test "get_event_by_external_id/1 returns an event by its external ID" do
      event = event_fixture()

      assert Webhooks.get_event_by_external_id(event.external_id) == event
    end

    test "get_event_by_external_id/1 returns nil for an unknown external ID" do
      assert Webhooks.get_event_by_external_id("unknown") == nil
    end
  end

  describe "ingest_event/1" do
    test "persists an event with empty fan-out when there are no active endpoints" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{event: event, deliveries: [], jobs: []}} =
                 Webhooks.ingest_event(valid_event_attrs())

        assert Webhooks.get_event(event.id) == event
        assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 0
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "persists one pending delivery and one initial job for an active endpoint" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        endpoint = endpoint_fixture()

        assert {:ok, %{event: event, deliveries: [delivery], jobs: [job]}} =
                 Webhooks.ingest_event(valid_event_attrs())

        assert delivery.event_id == event.id
        assert delivery.endpoint_id == endpoint.id
        assert delivery.status == "pending"
        assert delivery.attempt_count == 0
        assert job.args == %{"delivery_id" => delivery.id, "attempt_number" => 1}
        assert job.worker == "Tidewake.Workers.DeliverWebhookWorker"
        assert job.max_attempts == 1
        assert job.state == "available"

        assert Repo.get(Oban.Job, job.id).args == %{
                 "delivery_id" => delivery.id,
                 "attempt_number" => 1
               }

        assert Webhooks.get_delivery(delivery.id) == delivery
      end)
    end

    test "fans out to active endpoints in ID order and ignores inactive endpoints" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        first_active = endpoint_fixture(%{name: "First active"})
        inactive = endpoint_fixture(%{name: "Inactive", active: false})
        second_active = endpoint_fixture(%{name: "Second active"})
        third_active = endpoint_fixture(%{name: "Third active"})

        assert {:ok, %{event: event, deliveries: deliveries, jobs: jobs}} =
                 Webhooks.ingest_event(valid_event_attrs())

        assert Enum.map(deliveries, & &1.endpoint_id) == [
                 first_active.id,
                 second_active.id,
                 third_active.id
               ]

        assert Enum.all?(deliveries, fn delivery ->
                 delivery.event_id == event.id and delivery.status == "pending"
               end)

        assert Enum.map(jobs, & &1.args) ==
                 Enum.map(deliveries, &%{"delivery_id" => &1.id, "attempt_number" => 1})

        assert length(deliveries) == 3
        assert length(jobs) == 3
        assert Webhooks.get_delivery_by_event_and_endpoint(event, inactive) == nil
        assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 3
        assert Repo.aggregate(Oban.Job, :count) == 3
      end)
    end

    test "returns a usable changeset and creates no fan-out for an invalid event" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        _endpoint = endpoint_fixture()

        assert {:error, %Changeset{} = changeset} = Webhooks.ingest_event(%{})

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset).external_id
        assert fanout_record_counts() == %{events: 0, deliveries: 0, jobs: 0}
      end)
    end

    test "a duplicate event preserves the original fan-out and all record counts" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        _first_endpoint = endpoint_fixture(%{name: "First"})
        _second_endpoint = endpoint_fixture(%{name: "Second"})

        assert {:ok,
                %{
                  event: existing_event,
                  deliveries: existing_deliveries,
                  jobs: existing_jobs
                }} = Webhooks.ingest_event(valid_event_attrs())

        counts_before_conflict = fanout_record_counts()
        delivery_ids_before_conflict = Enum.map(existing_deliveries, & &1.id)
        job_ids_before_conflict = Enum.map(existing_jobs, & &1.id)

        assert {:error, %Changeset{} = changeset} =
                 Webhooks.ingest_event(valid_event_attrs())

        refute changeset.valid?
        assert "has already been taken" in errors_on(changeset).external_id
        assert fanout_record_counts() == counts_before_conflict
        assert counts_before_conflict == %{events: 1, deliveries: 2, jobs: 2}
        assert Webhooks.get_event_by_external_id(existing_event.external_id) == existing_event

        assert Repo.all(Tidewake.Webhooks.Delivery)
               |> Enum.map(& &1.id)
               |> Enum.sort() == Enum.sort(delivery_ids_before_conflict)

        assert Repo.all(Oban.Job)
               |> Enum.map(& &1.id)
               |> Enum.sort() == Enum.sort(job_ids_before_conflict)
      end)
    end

    test "a rejected second job rolls back the event and fan-out for two endpoints" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        _first_endpoint = endpoint_fixture(%{name: "First"})
        _second_endpoint = endpoint_fixture(%{name: "Second"})

        # Transactional DDL is reverted by the sandbox; these tests run synchronously.
        Repo.query!("""
        CREATE FUNCTION allow_only_first_ingestion_test_job()
        RETURNS boolean
        LANGUAGE sql
        VOLATILE
        AS $$
          SELECT NOT EXISTS (
            SELECT 1
            FROM oban_jobs
            WHERE worker = 'Tidewake.Workers.DeliverWebhookWorker'
          )
        $$
        """)

        Repo.query!("""
        ALTER TABLE oban_jobs ADD CONSTRAINT reject_second_ingestion_test_job
        CHECK (
          worker <> 'Tidewake.Workers.DeliverWebhookWorker'
          OR allow_only_first_ingestion_test_job()
        )
        """)

        assert_raise Ecto.ConstraintError, fn ->
          Webhooks.ingest_event(valid_event_attrs())
        end

        assert Webhooks.get_event_by_external_id(valid_event_attrs().external_id) == nil
        assert fanout_record_counts() == %{events: 0, deliveries: 0, jobs: 0}
      end)
    end
  end

  describe "schedule_delivery/2" do
    test "persists a pending delivery and the correct unique job" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        event = event_fixture()
        endpoint = endpoint_fixture()

        assert {:ok, %{delivery: delivery, job: job}} =
                 Webhooks.schedule_delivery(event, endpoint)

        assert delivery.status == "pending"
        assert delivery.attempt_count == 0
        assert job.args == %{"delivery_id" => delivery.id, "attempt_number" => 1}
        assert job.worker == "Tidewake.Workers.DeliverWebhookWorker"
        assert job.queue == "default"
        assert job.max_attempts == 1
        assert job.state == "available"
        assert Repo.get(Oban.Job, job.id).args == job.args
        assert Webhooks.get_delivery(delivery.id) == delivery
        assert job.unique.keys == [:delivery_id, :attempt_number]
        assert job.unique.period == :infinity
      end)
    end

    test "an inactive endpoint creates neither delivery nor job" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        event = event_fixture()
        endpoint = endpoint_fixture(%{active: false})

        assert {:error, :delivery, :endpoint_inactive, %{}} =
                 Webhooks.schedule_delivery(event, endpoint)

        assert Webhooks.get_delivery_by_event_and_endpoint(event, endpoint) == nil
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "duplicate scheduling does not create another job" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        event = event_fixture()
        endpoint = endpoint_fixture()
        assert {:ok, %{job: job}} = Webhooks.schedule_delivery(event, endpoint)

        assert {:error, :delivery, %Changeset{}, %{}} =
                 Webhooks.schedule_delivery(event, endpoint)

        assert Enum.map(Repo.all(Oban.Job), & &1.id) == [job.id]
      end)
    end

    test "a rejected job insertion rolls back the delivery" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        event = event_fixture()
        endpoint = endpoint_fixture()

        # Transactional DDL is reverted by the sandbox; these tests run synchronously.
        Repo.query!("""
        ALTER TABLE oban_jobs ADD CONSTRAINT reject_scheduling_test_job
        CHECK (worker <> 'Tidewake.Workers.DeliverWebhookWorker')
        """)

        assert_raise Ecto.ConstraintError, fn ->
          Webhooks.schedule_delivery(event, endpoint)
        end

        assert Webhooks.get_delivery_by_event_and_endpoint(event, endpoint) == nil
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "create_delivery still persists without scheduling a job" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, delivery} = Webhooks.create_delivery(event_fixture(), endpoint_fixture())
        assert delivery.status == "pending"
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end
  end

  describe "deliveries" do
    test "create_delivery/2 persists a pending delivery for an active endpoint" do
      event = event_fixture()
      endpoint = endpoint_fixture()

      assert {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
      assert delivery.event_id == event.id
      assert delivery.endpoint_id == endpoint.id
      assert delivery.status == "pending"
      assert delivery.attempt_count == 0
    end

    test "get_delivery/1 returns a delivery by its internal ID" do
      event = event_fixture()
      endpoint = endpoint_fixture()
      {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

      assert Webhooks.get_delivery(delivery.id) == delivery
    end

    test "get_delivery/1 returns nil for an unknown ID" do
      assert Webhooks.get_delivery(-1) == nil
    end

    test "list_deliveries_for_event/1 returns an empty list without deliveries" do
      event = event_fixture()

      assert Webhooks.list_deliveries_for_event(event) == []
      assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 0
      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "list_deliveries_for_event/1 isolates events and orders by delivery ID" do
      event = event_fixture()
      other_event = event_fixture(%{external_id: "evt_other"})
      first_endpoint = endpoint_fixture()
      second_endpoint = endpoint_fixture(%{name: "Second"})

      {:ok, first_delivery} = Webhooks.create_delivery(event, first_endpoint)
      {:ok, other_delivery} = Webhooks.create_delivery(other_event, first_endpoint)
      {:ok, second_delivery} = Webhooks.create_delivery(event, second_endpoint)

      assert first_delivery.id < other_delivery.id
      assert other_delivery.id < second_delivery.id
      assert Webhooks.list_deliveries_for_event(event) == [first_delivery, second_delivery]
      assert Webhooks.list_deliveries_for_event(other_event) == [other_delivery]
      assert Repo.aggregate(Oban.Job, :count) == 0
      assert Webhooks.get_delivery(first_delivery.id) == first_delivery
      assert Webhooks.get_delivery(second_delivery.id) == second_delivery
    end

    test "get_delivery_by_event_and_endpoint/2 returns the matching delivery" do
      event = event_fixture()
      endpoint = endpoint_fixture()
      {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

      assert Webhooks.get_delivery_by_event_and_endpoint(event, endpoint) == delivery
    end

    test "get_delivery_by_event_and_endpoint/2 returns nil without a matching delivery" do
      event = event_fixture()
      endpoint = endpoint_fixture()

      assert Webhooks.get_delivery_by_event_and_endpoint(event, endpoint) == nil
    end

    test "create_delivery/2 returns an invalid changeset for a duplicate pair" do
      event = event_fixture()
      endpoint = endpoint_fixture()
      assert {:ok, _delivery} = Webhooks.create_delivery(event, endpoint)

      assert {:error, %Changeset{} = changeset} = Webhooks.create_delivery(event, endpoint)
      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).event_id
    end

    test "create_delivery/2 refuses an inactive endpoint" do
      event = event_fixture()
      endpoint = endpoint_fixture(%{active: false})

      assert {:error, :endpoint_inactive} = Webhooks.create_delivery(event, endpoint)
      assert Webhooks.get_delivery_by_event_and_endpoint(event, endpoint) == nil
    end

    test "claim_delivery/1 atomically moves a pending delivery to processing" do
      delivery = delivery_fixture()

      assert {:ok, claimed_delivery} = Webhooks.claim_delivery(delivery.id)
      assert claimed_delivery.status == "processing"
      assert claimed_delivery.attempt_count == 0
      assert claimed_delivery.next_attempt_at == nil
      assert claimed_delivery.completed_at == nil
      assert claimed_delivery.event.id == delivery.event_id
      assert claimed_delivery.endpoint.id == delivery.endpoint_id
      assert Ecto.assoc_loaded?(claimed_delivery.event)
      assert Ecto.assoc_loaded?(claimed_delivery.endpoint)
      assert Webhooks.list_attempts(claimed_delivery) == []
    end

    test "claim_delivery/2 claims the expected first attempt using server time" do
      delivery = delivery_fixture()

      assert {:ok, claimed_delivery} = Webhooks.claim_delivery(delivery.id, 1)
      assert claimed_delivery.status == "processing"
      assert claimed_delivery.attempt_count == 0
      assert claimed_delivery.next_attempt_at == nil
    end

    test "claim_delivery/3 claims a retry exactly when it becomes due" do
      scheduled_at = ~U[2026-10-16 12:00:00.123456Z]

      delivery =
        delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-10-16 11:59:00.000000Z], %{
          attempt_count: 1,
          next_attempt_at: scheduled_at
        })

      assert {:ok, claimed_delivery} =
               Webhooks.claim_delivery(delivery.id, 2, scheduled_at)

      assert claimed_delivery.status == "processing"
      assert claimed_delivery.attempt_count == 1
      assert claimed_delivery.next_attempt_at == nil
      assert Webhooks.list_attempts(claimed_delivery) == []
    end

    test "claim_delivery/3 claims an overdue retry" do
      scheduled_at = ~U[2026-10-16 12:00:00.123456Z]
      reference_time = DateTime.add(scheduled_at, 1, :second)

      delivery =
        delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-10-16 11:59:00.000000Z], %{
          attempt_count: 2,
          next_attempt_at: scheduled_at
        })

      assert {:ok, claimed_delivery} =
               Webhooks.claim_delivery(delivery.id, 3, reference_time)

      assert claimed_delivery.status == "processing"
      assert claimed_delivery.attempt_count == 2
      assert claimed_delivery.next_attempt_at == nil
    end

    test "claim_delivery/3 rejects a retry one microsecond early without mutation" do
      scheduled_at = ~U[2026-10-16 12:00:00.123456Z]
      reference_time = DateTime.add(scheduled_at, -1, :microsecond)

      delivery =
        delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-10-16 11:59:00.000000Z], %{
          attempt_count: 1,
          next_attempt_at: scheduled_at
        })

      endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
      assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})

      assert {:error, :not_due} =
               Webhooks.claim_delivery(delivery.id, 2, reference_time)

      assert_claim_rejected_without_mutation(delivery)
    end

    test "claim_delivery/1 respects a future next_attempt_at" do
      delivery =
        delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-10-16 11:59:00.000000Z], %{
          attempt_count: 1,
          next_attempt_at: ~U[2099-01-15 12:00:00.123456Z]
        })

      assert {:error, :not_due} = Webhooks.claim_delivery(delivery.id)
      assert_claim_rejected_without_mutation(delivery)
    end

    test "claim_delivery/3 rejects previous and future attempt numbers without mutation" do
      reference_time = ~U[2026-10-16 12:00:00.123456Z]

      delivery =
        delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-10-16 11:59:00.000000Z], %{
          attempt_count: 2,
          next_attempt_at: reference_time
        })

      endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
      assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})

      for attempt_number <- [2, 4] do
        assert {:error, :stale_attempt} =
                 Webhooks.claim_delivery(delivery.id, attempt_number, reference_time)

        assert_claim_rejected_without_mutation(delivery)
      end
    end

    test "claim_delivery/3 cancels a due retry when its endpoint became inactive" do
      scheduled_at = ~U[2026-10-16 12:00:00.123456Z]

      delivery =
        delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-10-16 11:59:00.000000Z], %{
          attempt_count: 2,
          next_attempt_at: scheduled_at
        })

      endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
      assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})
      before_claim = DateTime.utc_now()

      assert {:cancelled, cancelled} =
               Webhooks.claim_delivery(delivery.id, 3, scheduled_at)

      after_claim = DateTime.utc_now()
      assert cancelled.status == "cancelled"
      assert cancelled.attempt_count == delivery.attempt_count
      assert cancelled.next_attempt_at == nil
      assert cancelled.completed_at != nil
      assert DateTime.compare(cancelled.completed_at, before_claim) in [:eq, :gt]
      assert DateTime.compare(cancelled.completed_at, after_claim) in [:eq, :lt]
      assert cancelled.event.id == delivery.event_id
      assert cancelled.endpoint.id == delivery.endpoint_id
      refute cancelled.endpoint.active
      assert Ecto.assoc_loaded?(cancelled.event)
      assert Ecto.assoc_loaded?(cancelled.endpoint)
      assert Webhooks.get_delivery(delivery.id).status == "cancelled"
      assert Webhooks.list_attempts(cancelled) == []

      assert {:error, :invalid_transition} =
               Webhooks.claim_delivery(delivery.id, 3, scheduled_at)
    end

    for status <- ~w(processing succeeded failed cancelled) do
      test "claim_delivery/3 rejects a delivery already in #{status}" do
        status = unquote(status)
        delivery = delivery_fixture()
        endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
        completed_at = ~U[2026-09-25 12:00:00.123456Z]

        attrs =
          %{status: status, attempt_count: 3}
          |> then(fn attrs ->
            if status == "processing",
              do: attrs,
              else: Map.put(attrs, :completed_at, completed_at)
          end)

        persisted =
          delivery
          |> Changeset.change(attrs)
          |> Repo.update!()

        assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})

        assert {:error, :invalid_transition} =
                 Webhooks.claim_delivery(
                   delivery.id,
                   persisted.attempt_count + 1,
                   ~U[2026-10-16 12:00:00.123456Z]
                 )

        assert Webhooks.get_delivery(delivery.id) == persisted
        assert Webhooks.list_attempts(delivery) == []
        assert Repo.aggregate(Oban.Job, :count) == 0
      end
    end

    test "claim_delivery/1 returns not_found for an unknown ID" do
      assert {:error, :not_found} = Webhooks.claim_delivery(-1)
    end

    test "validates claim arguments before querying the database" do
      handler_id = {__MODULE__, :invalid_claim_query, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:tidewake, :repo, :query],
          fn _event, _measurements, _metadata, test_pid -> send(test_pid, :claim_query) end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      reference_time = ~U[2026-10-16 12:00:00.123456Z]
      non_utc = %{reference_time | utc_offset: 3_600, time_zone: "Etc/GMT-1"}

      assert {:error, :invalid_arguments} = Webhooks.claim_delivery("1")
      assert {:error, :invalid_arguments} = Webhooks.claim_delivery(1, 0)
      assert {:error, :invalid_arguments} = Webhooks.claim_delivery(1, "1")
      assert {:error, :invalid_arguments} = Webhooks.claim_delivery(0, 1, reference_time)
      assert {:error, :invalid_arguments} = Webhooks.claim_delivery(1, 0, reference_time)
      assert {:error, :invalid_arguments} = Webhooks.claim_delivery(1, 1, non_utc)
      assert {:error, :invalid_arguments} = Webhooks.claim_delivery(1, 1, nil)

      refute_received :claim_query
    end

    test "only one of two independent guarded claims succeeds" do
      delivery = delivery_fixture()
      reference_time = ~U[2026-10-16 12:00:00.123456Z]

      first_claim = Webhooks.claim_delivery(delivery.id, 1, reference_time)
      second_claim = Webhooks.claim_delivery(delivery.id, 1, reference_time)

      assert {:ok, claimed_delivery} = first_claim
      assert claimed_delivery.status == "processing"
      assert {:error, :invalid_transition} = second_claim
      assert Webhooks.list_attempts(claimed_delivery) == []
      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  describe "recover_stale_delivery/2" do
    test "recovers a stale processing delivery and creates its replacement job atomically" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        stale_before = ~U[2026-09-28 12:00:00.000000Z]
        delivery = delivery_fixture()

        processing =
          put_delivery_state(delivery, "processing", ~U[2026-09-28 11:55:00.000000Z], %{
            attempt_count: 3,
            completed_at: ~U[2026-09-28 11:56:00.000000Z],
            next_attempt_at: ~U[2026-09-28 12:05:00.000000Z]
          })

        assert {:ok, %{delivery: recovered, job: job}} =
                 Webhooks.recover_stale_delivery(processing.id, stale_before)

        assert recovered.status == "pending"
        assert recovered.attempt_count == processing.attempt_count
        assert recovered.completed_at == nil
        assert recovered.next_attempt_at == nil
        assert job.args == %{"delivery_id" => processing.id, "attempt_number" => 4}
        assert job.worker == "Tidewake.Workers.DeliverWebhookWorker"
        assert job.state == "available"
        refute job.conflict?

        assert Repo.get!(Oban.Job, job.id).args == %{
                 "delivery_id" => processing.id,
                 "attempt_number" => 4
               }

        assert Repo.aggregate(Oban.Job, :count) == 1
        assert Webhooks.list_attempts(recovered) == []
        assert Repo.aggregate(Tidewake.Webhooks.Attempt, :count) == 0
      end)
    end

    test "treats the stale boundary as inclusive" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        stale_before = ~U[2026-09-28 12:00:00.000000Z]
        delivery = delivery_fixture()
        processing = put_delivery_state(delivery, "processing", stale_before)

        assert {:ok, %{delivery: recovered, job: job}} =
                 Webhooks.recover_stale_delivery(processing.id, stale_before)

        assert recovered.status == "pending"
        assert job.args == %{"delivery_id" => processing.id, "attempt_number" => 1}
      end)
    end

    test "rejects a processing delivery newer than the stale boundary" do
      stale_before = ~U[2026-09-28 12:00:00.000000Z]
      delivery = delivery_fixture()

      processing =
        put_delivery_state(delivery, "processing", ~U[2026-09-28 12:00:00.000001Z])

      assert {:error, :not_stale} =
               Webhooks.recover_stale_delivery(processing.id, stale_before)

      assert Webhooks.get_delivery(processing.id) == processing
      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    for status <- ~w(pending succeeded failed cancelled) do
      test "rejects a delivery in #{status}" do
        status = unquote(status)
        delivery = delivery_fixture()

        current =
          put_delivery_state(delivery, status, ~U[2026-09-28 11:55:00.000000Z], %{
            completed_at: if(status == "pending", do: nil, else: ~U[2026-09-28 11:56:00.000000Z])
          })

        assert {:error, :invalid_transition} =
                 Webhooks.recover_stale_delivery(
                   current.id,
                   ~U[2026-09-28 12:00:00.000000Z]
                 )

        assert Webhooks.get_delivery(current.id) == current
        assert Repo.aggregate(Oban.Job, :count) == 0
      end
    end

    test "returns not_found for an unknown positive ID" do
      assert {:error, :not_found} =
               Webhooks.recover_stale_delivery(
                 2_147_483_647,
                 ~U[2026-09-28 12:00:00.000000Z]
               )

      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "rolls back the state transition when an equivalent active job exists" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture()

        processing =
          put_delivery_state(delivery, "processing", ~U[2026-09-28 11:55:00.000000Z], %{
            attempt_count: 2,
            completed_at: ~U[2026-09-28 11:56:00.000000Z],
            next_attempt_at: ~U[2026-09-28 12:05:00.000000Z]
          })

        assert {:ok, active_job} =
                 DeliverWebhookWorker.new_for_delivery(
                   processing.id,
                   processing.attempt_count + 1
                 )
                 |> Oban.insert()

        assert {:error, :active_job} =
                 Webhooks.recover_stale_delivery(
                   processing.id,
                   ~U[2026-09-28 12:00:00.000000Z]
                 )

        assert Webhooks.get_delivery(processing.id) == processing
        assert Enum.map(Repo.all(Oban.Job), & &1.id) == [active_job.id]
        assert Webhooks.list_attempts(processing) == []
      end)
    end

    test "a repeated recovery does not create another job" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture()

        processing =
          put_delivery_state(delivery, "processing", ~U[2026-09-28 11:55:00.000000Z])

        stale_before = ~U[2026-09-28 12:00:00.000000Z]

        assert {:ok, %{delivery: recovered, job: job}} =
                 Webhooks.recover_stale_delivery(processing.id, stale_before)

        assert {:error, :invalid_transition} =
                 Webhooks.recover_stale_delivery(processing.id, stale_before)

        assert Webhooks.get_delivery(processing.id) == recovered
        assert Enum.map(Repo.all(Oban.Job), & &1.id) == [job.id]
      end)
    end

    test "validates the delivery ID and stale boundary" do
      stale_before = ~U[2026-09-28 12:00:00.000000Z]

      for {delivery_id, boundary} <- [
            {0, stale_before},
            {-1, stale_before},
            {"1", stale_before},
            {1, nil},
            {1, "2026-09-28T12:00:00Z"}
          ] do
        assert {:error, :invalid_arguments} =
                 Webhooks.recover_stale_delivery(delivery_id, boundary)
      end

      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  describe "list_stale_delivery_ids/2" do
    test "returns only old processing delivery IDs without loading related data" do
      stale_before = ~U[2026-09-28 12:00:00.000000Z]

      old_processing =
        "evt_old_processing"
        |> delivery_fixture()
        |> put_delivery_state("processing", ~U[2026-09-28 11:55:00.000000Z])

      _recent_processing =
        "evt_recent_processing"
        |> delivery_fixture()
        |> put_delivery_state("processing", ~U[2026-09-28 12:00:00.000001Z])

      _old_pending =
        "evt_old_pending"
        |> delivery_fixture()
        |> put_delivery_state("pending", ~U[2026-09-28 11:54:00.000000Z])

      _old_succeeded =
        "evt_old_succeeded"
        |> delivery_fixture()
        |> put_delivery_state("succeeded", ~U[2026-09-28 11:53:00.000000Z])

      handler_id = {__MODULE__, :stale_delivery_ids_query, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:tidewake, :repo, :query],
          fn _event, _measurements, metadata, test_pid ->
            send(test_pid, {:stale_delivery_ids_query, metadata.query})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, delivery_ids} = Webhooks.list_stale_delivery_ids(stale_before, 100)
      assert delivery_ids == [old_processing.id]
      assert Enum.all?(delivery_ids, &is_integer/1)

      assert_receive {:stale_delivery_ids_query, query}
      assert query =~ ~s(SELECT d0."id" FROM "deliveries" AS d0)
      refute query =~ "events"
      refute query =~ "endpoints"
      refute query =~ "payload"
    end

    test "orders candidates by updated_at and then by ID" do
      stale_before = ~U[2026-09-28 12:00:00.000000Z]

      first =
        "evt_order_first"
        |> delivery_fixture()
        |> put_delivery_state("processing", ~U[2026-09-28 11:50:00.000000Z])

      oldest =
        "evt_order_oldest"
        |> delivery_fixture()
        |> put_delivery_state("processing", ~U[2026-09-28 11:49:00.000000Z])

      second =
        "evt_order_second"
        |> delivery_fixture()
        |> put_delivery_state("processing", ~U[2026-09-28 11:50:00.000000Z])

      assert first.id < second.id

      assert {:ok, delivery_ids} = Webhooks.list_stale_delivery_ids(stale_before, 100)
      assert delivery_ids == [oldest.id, first.id, second.id]
    end

    test "requires a valid boundary and a limit between one and 100" do
      stale_before = ~U[2026-09-28 12:00:00.000000Z]

      assert {:ok, []} = Webhooks.list_stale_delivery_ids(stale_before, 100)

      for {boundary, limit} <- [
            {stale_before, 0},
            {stale_before, -1},
            {stale_before, 101},
            {stale_before, "10"},
            {nil, 10},
            {"2026-09-28T12:00:00Z", 10}
          ] do
        assert {:error, :invalid_arguments} =
                 Webhooks.list_stale_delivery_ids(boundary, limit)
      end
    end
  end

  describe "schedule_delivery_retry/3" do
    test "persists the failed attempt, pending delivery, and future job atomically" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture("evt_schedule_retry")
        assert {:ok, processing} = Webhooks.claim_delivery(delivery.id)
        retry_at = ~U[2099-01-15 12:00:00.248457Z]

        attrs =
          valid_attempt_attrs()
          |> Map.merge(%{
            result: "http_error",
            http_status: 503,
            attempt_number: 999,
            retry_cycle: 3,
            cycle_attempt_number: 6,
            next_attempt_at: ~U[2098-01-15 12:00:00.000000Z]
          })
          |> Map.put("attempt_number", 998)
          |> Map.put("retry_cycle", 2)
          |> Map.put("cycle_attempt_number", 5)
          |> Map.put("next_attempt_at", ~U[2097-01-15 12:00:00.000000Z])

        assert {:ok, %{delivery: pending, attempt: attempt, job: job}} =
                 Webhooks.schedule_delivery_retry(processing.id, attrs, retry_at)

        assert attempt.delivery_id == processing.id
        assert attempt.attempt_number == 1
        assert attempt.retry_cycle == 0
        assert attempt.cycle_attempt_number == 1
        assert attempt.result == "http_error"
        assert attempt.http_status == 503
        assert attempt.next_attempt_at == retry_at

        assert pending.status == "pending"
        assert pending.attempt_count == 1
        assert pending.retry_cycle == 0
        assert pending.cycle_attempt_count == 1
        assert pending.next_attempt_at == retry_at
        assert pending.completed_at == nil

        assert job.args == %{"delivery_id" => pending.id, "attempt_number" => 2}
        assert job.scheduled_at == retry_at
        assert job.state == "scheduled"
        assert job.max_attempts == 1
        refute job.conflict?

        assert Webhooks.get_delivery(pending.id) == pending
        assert Webhooks.list_attempts(pending) == [attempt]
        assert Repo.get!(Oban.Job, job.id).scheduled_at == retry_at
        assert Repo.aggregate(Oban.Job, :count) == 1
      end)
    end

    test "subsequent retries preserve monotonic lifetime and cycle attempt numbers" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture("evt_monotonic_attempts")
        assert {:ok, processing} = Webhooks.claim_delivery(delivery.id)

        failure_attrs =
          Map.merge(valid_attempt_attrs(), %{result: "http_error", http_status: 503})

        first_retry_at = ~U[2099-01-15 12:00:00.000000Z]

        assert {:ok, %{delivery: first_pending, attempt: first}} =
                 Webhooks.schedule_delivery_retry(processing.id, failure_attrs, first_retry_at)

        assert {:ok, second_processing} =
                 Webhooks.claim_delivery(first_pending.id, 2, first_retry_at)

        second_retry_at = DateTime.add(first_retry_at, 10, :second)

        second_attrs =
          Map.merge(failure_attrs, %{
            started_at: first_retry_at,
            completed_at: DateTime.add(first_retry_at, 1, :second)
          })

        assert {:ok, %{delivery: second_pending, attempt: second}} =
                 Webhooks.schedule_delivery_retry(
                   second_processing.id,
                   second_attrs,
                   second_retry_at
                 )

        assert {:ok, third_processing} =
                 Webhooks.claim_delivery(second_pending.id, 3, second_retry_at)

        success_attrs =
          Map.merge(valid_attempt_attrs(), %{
            started_at: second_retry_at,
            completed_at: DateTime.add(second_retry_at, 1, :second)
          })

        assert {:ok, %{delivery: finalized, attempt: third}} =
                 Webhooks.finalize_delivery(third_processing.id, success_attrs)

        assert Enum.map([first, second, third], & &1.attempt_number) == [1, 2, 3]
        assert Enum.map([first, second, third], & &1.retry_cycle) == [0, 0, 0]
        assert Enum.map([first, second, third], & &1.cycle_attempt_number) == [1, 2, 3]
        assert finalized.attempt_count == 3
        assert finalized.cycle_attempt_count == 3
        assert Webhooks.list_attempts(finalized) == [first, second, third]
      end)
    end

    test "an invalid attempt rolls back every retry effect" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture("evt_invalid_retry_attempt")
        assert {:ok, processing} = Webhooks.claim_delivery(delivery.id)
        before_retry = Webhooks.get_delivery(processing.id)

        attrs =
          valid_attempt_attrs()
          |> Map.merge(%{result: "http_error", http_status: 503, duration_ms: -1})

        assert {:error, %Changeset{} = changeset} =
                 Webhooks.schedule_delivery_retry(
                   processing.id,
                   attrs,
                   ~U[2099-01-15 12:00:00.248457Z]
                 )

        refute changeset.valid?
        assert "must be greater than or equal to 0" in errors_on(changeset).duration_ms
        assert Webhooks.get_delivery(processing.id) == before_retry
        assert before_retry.attempt_count == 0
        assert before_retry.cycle_attempt_count == 0
        assert Webhooks.list_attempts(processing) == []
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "a retry time at or before completion rolls back every retry effect" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture("evt_invalid_retry_time")
        assert {:ok, processing} = Webhooks.claim_delivery(delivery.id)
        before_retry = Webhooks.get_delivery(processing.id)
        completed_at = ~U[2026-09-10 12:00:00.248456Z]

        attrs =
          valid_attempt_attrs()
          |> Map.merge(%{result: "http_error", http_status: 503, completed_at: completed_at})

        for retry_at <- [completed_at, DateTime.add(completed_at, -1, :microsecond)] do
          assert {:error, %Changeset{} = changeset} =
                   Webhooks.schedule_delivery_retry(processing.id, attrs, retry_at)

          refute changeset.valid?
          assert "must be later than completed_at" in errors_on(changeset).next_attempt_at
          assert Webhooks.get_delivery(processing.id) == before_retry
          assert Webhooks.list_attempts(processing) == []
          assert Repo.aggregate(Oban.Job, :count) == 0
        end
      end)
    end

    test "an equivalent active job rolls back the attempt and delivery update" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        delivery = delivery_fixture("evt_retry_job_conflict")
        assert {:ok, processing} = Webhooks.claim_delivery(delivery.id)
        before_retry = Webhooks.get_delivery(processing.id)
        retry_at = ~U[2099-01-15 12:00:00.248457Z]

        assert {:ok, active_job} =
                 DeliverWebhookWorker.new_scheduled_for_delivery(processing.id, 2, retry_at)
                 |> Oban.insert()

        attrs =
          valid_attempt_attrs()
          |> Map.merge(%{result: "http_error", http_status: 503})

        assert {:error, :active_job} =
                 Webhooks.schedule_delivery_retry(processing.id, attrs, retry_at)

        assert Webhooks.get_delivery(processing.id) == before_retry
        assert before_retry.attempt_count == 0
        assert before_retry.cycle_attempt_count == 0
        assert Webhooks.list_attempts(processing) == []
        assert Enum.map(Repo.all(Oban.Job), & &1.id) == [active_job.id]
      end)
    end

    test "rejects every delivery state other than processing without partial state" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        for status <- ~w(pending succeeded failed cancelled) do
          delivery = delivery_fixture("evt_retry_status_#{status}")

          current =
            put_delivery_state(delivery, status, ~U[2026-10-16 12:00:00.000000Z], %{
              completed_at:
                if(status == "pending", do: nil, else: ~U[2026-10-16 12:00:00.000000Z])
            })

          assert {:error, :invalid_transition} =
                   Webhooks.schedule_delivery_retry(
                     current.id,
                     Map.merge(valid_attempt_attrs(), %{result: "http_error", http_status: 503}),
                     ~U[2099-01-15 12:00:00.248457Z]
                   )

          assert Webhooks.get_delivery(current.id) == current
          assert Webhooks.list_attempts(current) == []
        end

        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "validates public arguments without creating retry state" do
      retry_at = ~U[2099-01-15 12:00:00.248457Z]
      non_utc = %{retry_at | utc_offset: 3_600}

      for {delivery_id, attrs, scheduled_at} <- [
            {0, valid_attempt_attrs(), retry_at},
            {-1, valid_attempt_attrs(), retry_at},
            {"1", valid_attempt_attrs(), retry_at},
            {1, nil, retry_at},
            {1, valid_attempt_attrs(), nil},
            {1, valid_attempt_attrs(), non_utc}
          ] do
        assert {:error, :invalid_arguments} =
                 Webhooks.schedule_delivery_retry(delivery_id, attrs, scheduled_at)
      end

      assert Repo.aggregate(Tidewake.Webhooks.Attempt, :count) == 0
      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end

  describe "finalize_delivery/2" do
    test "persists a successful attempt and finalizes together" do
      delivery = delivery_fixture()
      assert {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)
      attrs = Map.put(valid_attempt_attrs(), :attempt_number, 999)

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               Webhooks.finalize_delivery(delivery.id, attrs)

      assert finalized.status == "succeeded"
      assert finalized.attempt_count == 1
      assert finalized.retry_cycle == 0
      assert finalized.cycle_attempt_count == 1
      assert finalized.completed_at == attrs.completed_at
      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == 1
      assert attempt.retry_cycle == 0
      assert attempt.cycle_attempt_number == 1
      assert Webhooks.get_delivery(delivery.id) == finalized
      assert Webhooks.list_attempts(finalized) == [attempt]
    end

    test "finalizes HTTP and transport failures" do
      for {result, status} <- [{"http_error", 503}, {"transport_error", nil}] do
        event = event_fixture(%{external_id: result})
        endpoint = endpoint_fixture()
        {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
        {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)
        attrs = Map.merge(valid_attempt_attrs(), %{result: result, http_status: status})

        assert {:ok, %{delivery: finalized, attempt: attempt}} =
                 Webhooks.finalize_delivery(delivery.id, attrs)

        assert finalized.status == "failed"
        assert finalized.attempt_count == 1
        assert finalized.cycle_attempt_count == 1
        assert finalized.completed_at == attempt.completed_at
        assert attempt.result == result
      end
    end

    test "uses the persisted counter and accepts string-keyed attributes" do
      delivery = delivery_fixture()

      {:ok, _delivery} =
        delivery
        |> change(attempt_count: 2, cycle_attempt_count: 2)
        |> Repo.update()

      {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)
      attrs = Map.new(valid_attempt_attrs(), fn {key, value} -> {Atom.to_string(key), value} end)
      attrs = Map.put(attrs, "attempt_number", 99)
      attrs = Map.put(attrs, "retry_cycle", 3)
      attrs = Map.put(attrs, "cycle_attempt_number", 6)

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               Webhooks.finalize_delivery(delivery.id, attrs)

      assert attempt.attempt_number == 3
      assert attempt.retry_cycle == 0
      assert attempt.cycle_attempt_number == 3
      assert finalized.attempt_count == 3
      assert finalized.cycle_attempt_count == 3
    end

    test "numbers the first attempt of a later cycle from both persisted counters" do
      delivery = delivery_fixture("evt_later_cycle_identity")

      {:ok, _delivery} =
        delivery
        |> change(attempt_count: 6, retry_cycle: 1, cycle_attempt_count: 0)
        |> Repo.update()

      assert {:ok, _claimed} = Webhooks.claim_delivery(delivery.id, 7)

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               Webhooks.finalize_delivery(delivery.id, valid_attempt_attrs())

      assert attempt.attempt_number == 7
      assert attempt.retry_cycle == 1
      assert attempt.cycle_attempt_number == 1
      assert finalized.attempt_count == 7
      assert finalized.retry_cycle == 1
      assert finalized.cycle_attempt_count == 1
    end

    test "invalid attempts leave the delivery and attempt history unchanged" do
      delivery = delivery_fixture()
      {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)
      before = Webhooks.get_delivery(delivery.id)

      assert {:error, %Changeset{} = changeset} =
               Webhooks.finalize_delivery(delivery.id, %{duration_ms: -1})

      refute changeset.valid?
      assert Webhooks.get_delivery(delivery.id) == before
      assert before.attempt_count == 0
      assert before.cycle_attempt_count == 0
      assert Webhooks.list_attempts(delivery) == []
    end

    test "a duplicate attempt rolls back without changing the delivery" do
      delivery = delivery_fixture()
      existing = attempt_fixture(delivery)
      {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)
      before = Webhooks.get_delivery(delivery.id)

      assert {:error, %Changeset{} = changeset} =
               Webhooks.finalize_delivery(delivery.id, valid_attempt_attrs())

      refute changeset.valid?
      assert Webhooks.get_delivery(delivery.id) == before
      assert Webhooks.list_attempts(delivery) == [existing]
    end

    test "rejects missing deliveries and every non-processing state" do
      assert {:error, :not_found} = Webhooks.finalize_delivery(-1, valid_attempt_attrs())
      delivery = delivery_fixture()

      for status <- ["pending", "succeeded", "failed"] do
        {:ok, current} = delivery |> change(status: status) |> Repo.update()

        assert {:error, :invalid_transition} =
                 Webhooks.finalize_delivery(delivery.id, valid_attempt_attrs())

        assert Webhooks.get_delivery(delivery.id) == current
        assert Webhooks.list_attempts(delivery) == []
      end
    end

    test "a second finalization cannot append another attempt" do
      delivery = delivery_fixture()
      {:ok, _claimed} = Webhooks.claim_delivery(delivery.id)

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               Webhooks.finalize_delivery(delivery.id, valid_attempt_attrs())

      assert {:error, :invalid_transition} =
               Webhooks.finalize_delivery(delivery.id, valid_attempt_attrs())

      assert Webhooks.get_delivery(delivery.id) == finalized
      assert Webhooks.list_attempts(delivery) == [attempt]
    end
  end

  describe "attempts" do
    test "create_attempt/2 persists attrs with the delivery ID set programmatically" do
      delivery = delivery_fixture()
      attrs = valid_attempt_attrs()

      assert {:ok, attempt} =
               Webhooks.create_attempt(
                 delivery,
                 attrs
                 |> Map.put(:delivery_id, -1)
                 |> Map.put(:retry_cycle, 3)
                 |> Map.put(:cycle_attempt_number, 6)
                 |> Map.put("delivery_id", -2)
                 |> Map.put("retry_cycle", 2)
                 |> Map.put("cycle_attempt_number", 5)
               )

      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == attrs.attempt_number
      assert attempt.retry_cycle == 0
      assert attempt.cycle_attempt_number == 1
      assert attempt.result == attrs.result
      assert attempt.http_status == attrs.http_status
      assert attempt.error_type == attrs.error_type
      assert attempt.duration_ms == attrs.duration_ms
      assert attempt.started_at == attrs.started_at
      assert attempt.completed_at == attrs.completed_at
      assert attempt.response_metadata == attrs.response_metadata
    end

    test "create_attempt/2 returns an invalid changeset for invalid attrs" do
      delivery = delivery_fixture()

      assert {:error, %Changeset{} = changeset} = Webhooks.create_attempt(delivery, %{})
      refute changeset.valid?
    end

    test "get_attempt/1 returns an attempt by its internal ID" do
      delivery = delivery_fixture()
      attempt = attempt_fixture(delivery)

      assert Webhooks.get_attempt(attempt.id) == attempt
    end

    test "get_attempt/1 returns nil for an unknown ID" do
      assert Webhooks.get_attempt(-1) == nil
    end

    test "list_attempts/1 returns only the delivery attempts ordered by attempt number" do
      event = event_fixture()
      first_endpoint = endpoint_fixture()

      second_endpoint =
        endpoint_fixture(%{
          name: "Secondary",
          url: "https://secondary.example.com/webhooks"
        })

      {:ok, delivery} = Webhooks.create_delivery(event, first_endpoint)
      {:ok, other_delivery} = Webhooks.create_delivery(event, second_endpoint)

      second_attempt = attempt_fixture(delivery, %{attempt_number: 2})
      first_attempt = attempt_fixture(delivery, %{attempt_number: 1})
      _other_attempt = attempt_fixture(other_delivery)

      assert Webhooks.list_attempts(delivery) == [first_attempt, second_attempt]
    end

    test "create_attempt/2 returns an invalid changeset for a duplicate number" do
      delivery = delivery_fixture()
      attempt_fixture(delivery)

      assert {:error, %Changeset{} = changeset} =
               Webhooks.create_attempt(delivery, valid_attempt_attrs())

      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).delivery_id
    end

    test "create_attempt/2 does not change delivery state or attempt_count" do
      delivery = delivery_fixture()

      assert {:ok, _attempt} = Webhooks.create_attempt(delivery, valid_attempt_attrs())

      persisted_delivery = Webhooks.get_delivery(delivery.id)
      assert persisted_delivery.status == "pending"
      assert persisted_delivery.attempt_count == 0
      assert persisted_delivery.cycle_attempt_count == 0
      assert persisted_delivery.updated_at == delivery.updated_at
    end
  end

  describe "endpoints" do
    test "create_endpoint/1 creates a valid endpoint" do
      assert {:ok, endpoint} = Webhooks.create_endpoint(valid_attrs())
      assert endpoint.name == "Ironhold"
      assert endpoint.url == "https://ironhold.example.com/api/webhooks"
      assert endpoint.active
    end

    test "create_endpoint/1 returns an error for invalid attributes" do
      assert {:error, changeset} = Webhooks.create_endpoint(%{name: "", url: "not-a-url"})
      refute changeset.valid?
    end

    test "list_endpoints/0 returns persisted endpoints" do
      endpoint = endpoint_fixture()

      assert Webhooks.list_endpoints() == [endpoint]
    end

    test "list_active_endpoints/0 returns only active endpoints ordered by ID" do
      event = event_fixture()
      first_active = endpoint_fixture(%{name: "First active"})
      _inactive = endpoint_fixture(%{name: "Inactive", active: false})
      second_active = endpoint_fixture(%{name: "Second active"})

      assert Webhooks.list_active_endpoints() == [first_active, second_active]
      assert Webhooks.get_event(event.id) == event
      assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 0
      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "list_active_endpoints/0 returns an empty list without active endpoints" do
      _inactive = endpoint_fixture(%{active: false})

      assert Webhooks.list_active_endpoints() == []
    end

    test "get_endpoint/1 returns an existing endpoint" do
      endpoint = endpoint_fixture()

      assert Webhooks.get_endpoint(endpoint.id) == endpoint
    end

    test "get_endpoint/1 returns nil for an unknown ID" do
      assert Webhooks.get_endpoint(-1) == nil
    end

    test "update_endpoint/2 updates the name" do
      endpoint = endpoint_fixture()

      assert {:ok, updated_endpoint} =
               Webhooks.update_endpoint(endpoint, %{name: "Primary Ironhold"})

      assert updated_endpoint.name == "Primary Ironhold"
    end

    test "update_endpoint/2 updates the URL" do
      endpoint = endpoint_fixture()

      assert {:ok, updated_endpoint} =
               Webhooks.update_endpoint(endpoint, %{
                 url: "https://secondary.ironhold.example.com/webhooks"
               })

      assert updated_endpoint.url == "https://secondary.ironhold.example.com/webhooks"
    end

    test "update_endpoint/2 deactivates an endpoint" do
      endpoint = endpoint_fixture()

      assert {:ok, updated_endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})
      refute updated_endpoint.active
    end

    test "update_endpoint/2 returns an error for invalid attributes" do
      endpoint = endpoint_fixture()

      assert {:error, changeset} = Webhooks.update_endpoint(endpoint, %{url: "not-a-url"})
      refute changeset.valid?
    end

    test "update_endpoint/2 does not persist an invalid URL" do
      endpoint = endpoint_fixture()

      assert {:error, changeset} = Webhooks.update_endpoint(endpoint, %{url: "not-a-url"})
      refute changeset.valid?

      persisted_endpoint = Webhooks.get_endpoint(endpoint.id)
      assert persisted_endpoint.url == endpoint.url
    end

    test "change_endpoint/2 returns a changeset without persisting" do
      endpoint = endpoint_fixture()

      assert %Changeset{} = changeset = Webhooks.change_endpoint(endpoint, %{name: "Changed"})
      assert changeset.changes.name == "Changed"
      assert Webhooks.get_endpoint(endpoint.id).name == "Ironhold"
    end
  end

  defp event_fixture(attrs \\ %{}) do
    attrs = Map.merge(valid_event_attrs(), attrs)
    {:ok, event} = Webhooks.create_event(attrs)
    event
  end

  defp valid_event_attrs do
    %{
      external_id: "evt_123",
      event_type: "order.created",
      payload: %{"order_id" => "123"}
    }
  end

  defp endpoint_fixture(attrs \\ %{}) do
    attrs = Map.merge(valid_attrs(), attrs)
    {:ok, endpoint} = Webhooks.create_endpoint(attrs)
    endpoint
  end

  defp fanout_record_counts do
    %{
      events: Repo.aggregate(Tidewake.Webhooks.Event, :count),
      deliveries: Repo.aggregate(Tidewake.Webhooks.Delivery, :count),
      jobs: Repo.aggregate(Oban.Job, :count)
    }
  end

  defp delivery_fixture(external_id \\ "evt_123") do
    event = event_fixture(%{external_id: external_id})
    endpoint = endpoint_fixture()
    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end

  defp put_delivery_state(delivery, status, updated_at, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{status: status, updated_at: updated_at})

    delivery
    |> Changeset.change(attrs)
    |> Repo.update!()
  end

  defp assert_claim_rejected_without_mutation(delivery) do
    assert Webhooks.get_delivery(delivery.id) == delivery
    assert Webhooks.list_attempts(delivery) == []
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp attempt_fixture(delivery, attrs \\ %{}) do
    attrs = Map.merge(valid_attempt_attrs(), attrs)
    {:ok, attempt} = Webhooks.create_attempt(delivery, attrs)
    attempt
  end

  defp valid_attempt_attrs do
    %{
      attempt_number: 1,
      result: "succeeded",
      http_status: 200,
      error_type: nil,
      duration_ms: 125,
      started_at: ~U[2026-09-10 12:00:00.123456Z],
      completed_at: ~U[2026-09-10 12:00:00.248456Z],
      response_metadata: %{
        "content_type" => "application/json",
        "content_length" => 42,
        "request_id" => "req_123"
      }
    }
  end

  defp valid_attrs do
    %{name: "Ironhold", url: "https://ironhold.example.com/api/webhooks"}
  end
end

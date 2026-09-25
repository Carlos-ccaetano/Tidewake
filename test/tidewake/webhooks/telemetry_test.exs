defmodule Tidewake.Webhooks.TelemetryTest do
  use Tidewake.DataCase, async: false

  alias Ecto.Changeset
  alias Tidewake.Webhooks

  @event_ingested [:tidewake, :webhooks, :event, :ingested]
  @event_rejected [:tidewake, :webhooks, :event, :rejected]

  describe "ingest_event/1 telemetry" do
    test "emits ingested after committing the event and complete fan-out" do
      attach_telemetry(@event_ingested)

      Oban.Testing.with_testing_mode(:manual, fn ->
        _first_endpoint = endpoint_fixture(%{name: "First"})

        _second_endpoint =
          endpoint_fixture(%{
            name: "Second",
            url: "https://example.com/webhooks?token=endpoint-secret"
          })

        attrs =
          valid_event_attrs(%{
            external_id: "external-secret",
            payload: %{
              "order_id" => "123",
              "secret" => "payload-secret",
              "headers" => %{"authorization" => "Bearer secret"}
            }
          })

        assert {:ok, %{event: event, deliveries: deliveries, jobs: jobs}} =
                 Webhooks.ingest_event(attrs)

        assert_received {:telemetry_event, @event_ingested,
                         %{count: 1, delivery_count: 2} = measurements, %{}}

        assert Webhooks.get_event(event.id) == event
        assert length(deliveries) == 2
        assert length(jobs) == 2
        assert Enum.all?(deliveries, &(Webhooks.get_delivery(&1.id) == &1))
        assert Repo.aggregate(Oban.Job, :count) == 2

        telemetry_data = inspect(measurements)
        refute telemetry_data =~ "external-secret"
        refute telemetry_data =~ "payload-secret"
        refute telemetry_data =~ "endpoint-secret"
        refute telemetry_data =~ "authorization"
        refute_received {:telemetry_event, @event_ingested, _, _}
      end)
    end

    test "emits ingested with zero deliveries when no endpoint is active" do
      attach_telemetry(@event_ingested)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{deliveries: [], jobs: []}} =
                 Webhooks.ingest_event(valid_event_attrs())

        assert_received {:telemetry_event, @event_ingested, %{count: 1, delivery_count: 0}, %{}}
      end)
    end

    test "emits rejected with validation and preserves the changeset return" do
      attach_telemetry(@event_ingested)
      attach_telemetry(@event_rejected)

      assert {:error, %Changeset{} = changeset} = Webhooks.ingest_event(%{})

      refute changeset.valid?

      assert_received {:telemetry_event, @event_rejected, %{count: 1},
                       %{reason: "validation"} = metadata}

      refute Map.has_key?(metadata, :changeset)
      refute Map.has_key?(metadata, :payload)
      refute_received {:telemetry_event, @event_ingested, _, _}
    end

    test "emits rejected with duplicate_external_id without another success event" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        attrs = valid_event_attrs()
        assert {:ok, original_result} = Webhooks.ingest_event(attrs)

        attach_telemetry(@event_ingested)
        attach_telemetry(@event_rejected)

        assert {:error, %Changeset{} = changeset} = Webhooks.ingest_event(attrs)

        refute changeset.valid?
        assert Webhooks.get_event_by_external_id(attrs.external_id) == original_result.event

        assert_received {:telemetry_event, @event_rejected, %{count: 1}, metadata}
        assert metadata == %{reason: "duplicate_external_id"}

        refute_received {:telemetry_event, @event_ingested, _, _}
      end)
    end

    test "does not catch an unexpected transaction exception to emit telemetry" do
      attach_telemetry(@event_ingested)
      attach_telemetry(@event_rejected)

      Oban.Testing.with_testing_mode(:manual, fn ->
        _endpoint = endpoint_fixture()

        Repo.query!("""
        ALTER TABLE oban_jobs ADD CONSTRAINT reject_telemetry_test_job
        CHECK (worker <> 'Tidewake.Workers.DeliverWebhookWorker')
        """)

        assert_raise Ecto.ConstraintError, fn ->
          Webhooks.ingest_event(valid_event_attrs())
        end

        assert Repo.aggregate(Tidewake.Webhooks.Event, :count) == 0
        assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 0
        assert Repo.aggregate(Oban.Job, :count) == 0
        refute_received {:telemetry_event, @event_ingested, _, _}
        refute_received {:telemetry_event, @event_rejected, _, _}
      end)
    end
  end

  @doc false
  def handle_telemetry(event_name, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry(event_name) do
    handler_id = {__MODULE__, event_name, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{name: "Endpoint", url: "https://example.com/webhooks"},
        attrs
      )

    {:ok, endpoint} = Webhooks.create_endpoint(attrs)
    endpoint
  end

  defp valid_event_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        external_id: "evt_telemetry",
        event_type: "order.created",
        payload: %{"order_id" => "123"}
      },
      overrides
    )
  end
end

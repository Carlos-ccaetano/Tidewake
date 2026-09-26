defmodule Tidewake.Webhooks.DeliveryProcessorTest do
  use Tidewake.DataCase, async: false

  @delivery_cancelled [:tidewake, :webhooks, :delivery, :cancelled]
  @delivery_processed [:tidewake, :webhooks, :delivery, :processed]
  @delivery_error [:tidewake, :webhooks, :delivery, :error]

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.DeliveryAdapters.Deterministic
  alias Tidewake.Webhooks.DeliveryProcessor

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(url, body, headers) do
    send(self(), {:delivered, url, body, headers})
    Process.get(:adapter_response, {:ok, %{status: 204, headers: [{"set-cookie", "secret"}]}})
  end

  describe "telemetry" do
    for {label, response, outcome} <- [
          {"success", {:ok, %{status: 204, headers: [{"set-cookie", "header-secret"}]}},
           "succeeded"},
          {"HTTP error",
           {:ok,
            %{
              status: 503,
              headers: [
                {"x-request-id", "secret-request-id"},
                {"authorization", "Bearer secret"}
              ],
              body: "secret-response-body"
            }}, "http_error"},
          {"transport error", {:error, :internal_adapter_detail}, "transport_error"}
        ] do
      test "emits processed with a safe #{label} outcome after finalization" do
        attach_telemetry(@delivery_processed)
        attach_telemetry(@delivery_error)

        response = unquote(Macro.escape(response))
        outcome = unquote(outcome)
        delivery = delivery_fixture()
        Process.put(:adapter_response, response)

        assert {:ok, %{delivery: finalized, attempt: attempt}} =
                 DeliveryProcessor.process(delivery.id, __MODULE__)

        assert attempt.result == outcome
        assert Webhooks.get_delivery(delivery.id) == finalized
        assert Webhooks.list_attempts(delivery) == [attempt]

        assert_received {:telemetry_event, @delivery_processed,
                         %{count: 1, duration_ms: duration_ms} = measurements,
                         %{outcome: ^outcome} = metadata}

        assert is_integer(duration_ms)
        assert duration_ms >= 0
        assert Map.keys(measurements) |> Enum.sort() == [:count, :duration_ms]
        assert Map.keys(metadata) == [:outcome]

        telemetry_data = inspect({measurements, metadata})
        refute Map.has_key?(measurements, :delivery_id)
        refute Map.has_key?(metadata, :delivery_id)
        refute telemetry_data =~ "endpoint.invalid"
        refute telemetry_data =~ "evt_processor"
        refute telemetry_data =~ "header-secret"
        refute telemetry_data =~ "secret-request-id"
        refute telemetry_data =~ "secret-response-body"
        refute telemetry_data =~ "internal_adapter_detail"
        refute_received {:telemetry_event, @delivery_error, _, _}
      end
    end

    test "emits a bounded not_found error and preserves the return" do
      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      assert {:error, :not_found} = DeliveryProcessor.process(-1, __MODULE__)

      assert_received {:telemetry_event, @delivery_error, %{count: 1, duration_ms: duration_ms},
                       %{reason: "not_found"}}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute_received {:telemetry_event, @delivery_processed, _, _}
      refute_received {:delivered, _, _, _}
    end

    test "emits a bounded invalid_transition error and preserves the return" do
      delivery = delivery_fixture()
      assert {:ok, _result} = DeliveryProcessor.process(delivery.id, Deterministic)

      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      assert {:error, :invalid_transition} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:telemetry_event, @delivery_error, %{count: 1, duration_ms: duration_ms},
                       %{reason: "invalid_transition"}}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute_received {:telemetry_event, @delivery_processed, _, _}
      refute_received {:delivered, _, _, _}
    end

    test "normalizes a malformed adapter response without exposing its raw error" do
      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      delivery = delivery_fixture()
      Process.put(:adapter_response, {:error, "raw-secret-error"})

      assert {:error, :invalid_adapter_response} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:telemetry_event, @delivery_error,
                       %{count: 1, duration_ms: duration_ms} = measurements,
                       %{reason: "invalid_adapter_response"} = metadata}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute inspect({measurements, metadata}) =~ "raw-secret-error"
      refute_received {:telemetry_event, @delivery_processed, _, _}
    end
  end

  test "processes a deterministic delivery and persists its successful attempt" do
    delivery = delivery_fixture()

    assert {:ok, %{delivery: finalized, attempt: attempt}} =
             DeliveryProcessor.process(delivery.id, Deterministic)

    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1
    assert finalized.completed_at == attempt.completed_at
    assert Webhooks.get_delivery(delivery.id) == finalized
    assert Webhooks.list_attempts(finalized) == [attempt]
    assert attempt.delivery_id == delivery.id
    assert attempt.attempt_number == 1
    assert attempt.result == "succeeded"
    assert attempt.http_status == 204
    assert attempt.duration_ms >= 0
    assert attempt.started_at.time_zone == "Etc/UTC"
    assert attempt.completed_at.time_zone == "Etc/UTC"
    assert DateTime.compare(attempt.completed_at, attempt.started_at) in [:eq, :gt]
    assert attempt.error_type == nil
    assert attempt.response_metadata == nil
  end

  test "passes the associated endpoint, envelope and content type without persisting headers" do
    delivery = delivery_fixture()
    event = Webhooks.get_event(delivery.event_id)
    endpoint = Webhooks.get_endpoint(delivery.endpoint_id)

    assert {:ok, %{attempt: attempt}} = DeliveryProcessor.process(delivery.id, __MODULE__)

    assert_received {:delivered, url, body, [{"content-type", "application/json"}]}
    assert url == endpoint.url

    assert Jason.decode!(body) == %{
             "id" => event.external_id,
             "type" => event.event_type,
             "data" => event.payload
           }

    assert attempt.response_metadata == nil
    assert Webhooks.get_event(event.id) == event
  end

  test "cancels an inactive endpoint without encoding, delivering or creating an attempt" do
    attach_telemetry(@delivery_processed)
    attach_telemetry(@delivery_error)

    delivery = delivery_fixture()
    attach_cancelled_telemetry(delivery.id)
    endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
    assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})
    before_processing = DateTime.utc_now()

    assert {:ok, %{delivery: cancelled, attempt: nil}} =
             result =
             DeliveryProcessor.process(delivery.id, __MODULE__)

    after_processing = DateTime.utc_now()
    assert cancelled.status == "cancelled"
    assert cancelled.attempt_count == 0
    assert cancelled.completed_at != nil
    assert DateTime.compare(cancelled.completed_at, before_processing) in [:eq, :gt]
    assert DateTime.compare(cancelled.completed_at, after_processing) in [:eq, :lt]
    assert Webhooks.get_delivery(delivery.id).status == "cancelled"
    assert Webhooks.list_attempts(cancelled) == []
    assert result == {:ok, %{delivery: cancelled, attempt: nil}}
    refute_received {:delivered, _, _, _}

    assert_received {:cancelled_telemetry, @delivery_cancelled, measurements, metadata,
                     persisted_at_emission}

    assert measurements == %{count: 1}
    assert metadata == %{reason: "endpoint_inactive"}
    assert persisted_at_emission.status == "cancelled"
    assert persisted_at_emission.completed_at == cancelled.completed_at
    assert persisted_at_emission.attempt_count == 0

    for prohibited_key <- [
          :id,
          :delivery_id,
          :endpoint,
          :endpoint_id,
          :url,
          :payload,
          :headers
        ] do
      refute Map.has_key?(measurements, prohibited_key)
      refute Map.has_key?(metadata, prohibited_key)
    end

    refute Enum.any?(Map.values(measurements) ++ Map.values(metadata), &is_struct/1)
    refute_received {:cancelled_telemetry, @delivery_cancelled, _, _, _}
    refute_received {:telemetry_event, @delivery_processed, _, _}
    refute_received {:telemetry_event, @delivery_error, _, _}

    assert {:error, :invalid_transition} =
             DeliveryProcessor.process(delivery.id, __MODULE__)

    refute_received {:delivered, _, _, _}
    assert Webhooks.list_attempts(cancelled) == []
  end

  test "propagates not found without calling the adapter" do
    assert {:error, :not_found} = DeliveryProcessor.process(-1, __MODULE__)
    refute_received {:delivered, _, _, _}
  end

  for status <- [100, 199, 200, 204, 299, 300, 400, 429, 503, 599] do
    test "persists HTTP #{status} with safe metadata and timing" do
      status = unquote(status)
      delivery = delivery_fixture()

      Process.put(:adapter_response, {
        :ok,
        %{
          status: status,
          headers: [
            {"Content-Type", "application/json"},
            {"CONTENT-LENGTH", "0042"},
            {"X-Request-ID", "req_processor"},
            {"Authorization", "Bearer secret"},
            {"Cookie", "session=secret"},
            {"Set-Cookie", "session=secret"},
            {"X-API-Key", "secret"},
            {"X-Webhook-Signature", "secret"},
            {"X-Access-Token", "secret"},
            {"Server", "private"}
          ],
          body: "secret response body"
        }
      })

      before_processing = DateTime.utc_now()

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      after_processing = DateTime.utc_now()
      assert_received {:delivered, _, _, _}
      assert finalized.status == if(status in 200..299, do: "succeeded", else: "failed")
      assert finalized.attempt_count == 1
      assert finalized.completed_at == attempt.completed_at
      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == 1
      assert attempt.result == if(status in 200..299, do: "succeeded", else: "http_error")
      assert attempt.http_status == status
      assert attempt.error_type == nil
      assert is_integer(attempt.duration_ms)
      assert attempt.duration_ms >= 0
      assert attempt.started_at.time_zone == "Etc/UTC"
      assert attempt.completed_at.time_zone == "Etc/UTC"
      assert elem(attempt.started_at.microsecond, 1) == 6
      assert elem(attempt.completed_at.microsecond, 1) == 6
      assert DateTime.compare(attempt.started_at, before_processing) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, attempt.started_at) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, after_processing) in [:eq, :lt]

      assert attempt.response_metadata == %{
               "content_type" => "application/json",
               "content_length" => 42,
               "request_id" => "req_processor"
             }

      assert Webhooks.get_delivery(delivery.id) == finalized
      assert Webhooks.list_attempts(delivery) == [attempt]

      assert {:error, :invalid_transition} = DeliveryProcessor.process(delivery.id, __MODULE__)
      refute_received {:delivered, _, _, _}
      assert Webhooks.get_delivery(delivery.id) == finalized
      assert Webhooks.list_attempts(delivery) == [attempt]
    end
  end

  test "discards invalid metadata values from a valid HTTP error response" do
    delivery = delivery_fixture()

    Process.put(:adapter_response, {
      :ok,
      %{
        status: 503,
        headers: [
          {"content-type", String.duplicate("a", 256)},
          {"content-length", "42bytes"},
          {"x-request-id", <<255>>},
          {"set-cookie", "secret"}
        ]
      }
    })

    assert {:ok, %{delivery: finalized, attempt: attempt}} =
             DeliveryProcessor.process(delivery.id, __MODULE__)

    assert finalized.status == "failed"
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert attempt.response_metadata == nil
    assert Webhooks.list_attempts(delivery) == [attempt]
  end

  for {label, response} <- [
        {"status below range", {:ok, %{status: 99, headers: []}}},
        {"status above range", {:ok, %{status: 600, headers: []}}},
        {"string status", {:ok, %{status: "204", headers: []}}},
        {"float status", {:ok, %{status: 204.0, headers: []}}},
        {"missing status", {:ok, %{headers: []}}},
        {"missing headers", {:ok, %{status: 204}}},
        {"nil headers", {:ok, %{status: 400, headers: nil}}},
        {"map headers", {:ok, %{status: 503, headers: %{"content-type" => "text/plain"}}}},
        {"atom header name", {:ok, %{status: 204, headers: [{:authorization, "secret"}]}}},
        {"non-string header value", {:ok, %{status: 429, headers: [{"content-length", 42}]}}},
        {"invalid header entry", {:ok, %{status: 503, headers: [nil]}}},
        {"improper headers", {:ok, %{status: 204, headers: [{"x-request-id", "id"} | nil]}}},
        {"non-map response", {:ok, nil}},
        {"invalid error reason", {:error, "secret"}},
        {"unexpected return", :invalid}
      ] do
    test "rejects malformed adapter response: #{label}" do
      delivery = delivery_fixture()
      Process.put(:adapter_response, unquote(Macro.escape(response)))

      assert {:error, :invalid_adapter_response} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:delivered, _, _, _}
      persisted = Webhooks.get_delivery(delivery.id)
      assert persisted.status == "processing"
      assert persisted.attempt_count == 0
      assert persisted.completed_at == nil
      assert Webhooks.list_attempts(delivery) == []
    end
  end

  test "rejects repeated processing without sending or adding another attempt" do
    delivery = delivery_fixture()
    assert {:ok, result} = DeliveryProcessor.process(delivery.id, Deterministic)

    assert {:error, :invalid_transition} = DeliveryProcessor.process(delivery.id, __MODULE__)
    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == result.delivery
    assert Webhooks.list_attempts(delivery) == [result.attempt]
  end

  for {reason, error_type} <- [
        timeout: "timeout",
        dns_error: "dns",
        tls_error: "tls",
        connection_refused: "connection",
        connection_closed: "closed",
        internal_adapter_detail: "unknown"
      ] do
    test "persists transport failure #{reason} as #{error_type}" do
      reason = unquote(reason)
      error_type = unquote(error_type)
      delivery = delivery_fixture()
      Process.put(:adapter_response, {:error, reason})
      before_processing = DateTime.utc_now()

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      after_processing = DateTime.utc_now()
      assert_received {:delivered, _, _, _}
      assert finalized.status == "failed"
      assert finalized.attempt_count == 1
      assert finalized.completed_at == attempt.completed_at
      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == 1
      assert attempt.result == "transport_error"
      assert attempt.http_status == nil
      assert attempt.error_type == error_type

      if error_type == "unknown" do
        refute attempt.error_type == Atom.to_string(reason)
      end

      assert attempt.response_metadata == nil
      assert is_integer(attempt.duration_ms)
      assert attempt.duration_ms >= 0
      assert attempt.started_at.time_zone == "Etc/UTC"
      assert attempt.completed_at.time_zone == "Etc/UTC"
      assert elem(attempt.started_at.microsecond, 1) == 6
      assert elem(attempt.completed_at.microsecond, 1) == 6
      assert DateTime.compare(attempt.started_at, before_processing) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, attempt.started_at) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, after_processing) in [:eq, :lt]
      assert Webhooks.get_delivery(delivery.id) == finalized
      assert Webhooks.list_attempts(delivery) == [attempt]
    end
  end

  test "returns a changeset error when transport failure finalization cannot insert the attempt" do
    attach_telemetry(@delivery_processed)
    attach_telemetry(@delivery_error)

    delivery = delivery_fixture()
    timestamp = DateTime.utc_now()

    assert {:ok, existing_attempt} =
             Webhooks.create_attempt(delivery, %{
               attempt_number: 1,
               result: "transport_error",
               error_type: "timeout",
               duration_ms: 0,
               started_at: timestamp,
               completed_at: timestamp
             })

    Process.put(:adapter_response, {:error, :timeout})

    assert {:error, %Ecto.Changeset{}} = DeliveryProcessor.process(delivery.id, __MODULE__)
    assert_received {:delivered, _, _, _}
    persisted = Webhooks.get_delivery(delivery.id)
    assert persisted.status == "processing"
    assert persisted.attempt_count == 0
    assert persisted.completed_at == nil
    assert Webhooks.list_attempts(delivery) == [existing_attempt]

    assert_received {:telemetry_event, @delivery_error, %{count: 1, duration_ms: duration_ms},
                     %{reason: "persistence"}}

    assert is_integer(duration_ms)
    assert duration_ms >= 0
    refute_received {:telemetry_event, @delivery_processed, _, _}
  end

  @doc false
  def handle_telemetry(event_name, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event_name, measurements, metadata})
  end

  @doc false
  def handle_cancelled_telemetry(event_name, measurements, metadata, {test_pid, delivery_id}) do
    send(
      test_pid,
      {:cancelled_telemetry, event_name, measurements, metadata,
       Webhooks.get_delivery(delivery_id)}
    )
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

  defp attach_cancelled_telemetry(delivery_id) do
    handler_id = {__MODULE__, @delivery_cancelled, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @delivery_cancelled,
        &__MODULE__.handle_cancelled_telemetry/4,
        {self(), delivery_id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp delivery_fixture do
    {:ok, event} =
      Webhooks.create_event(%{
        external_id: "evt_processor",
        event_type: "order.created",
        payload: %{"order" => %{"id" => "123"}}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Local validation",
        url: "https://endpoint.invalid/webhooks"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end
end

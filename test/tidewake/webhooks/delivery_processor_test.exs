defmodule Tidewake.Webhooks.DeliveryProcessorTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.DeliveryAdapters.Deterministic
  alias Tidewake.Webhooks.DeliveryProcessor

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver("https://endpoint.invalid/timeout", _body, _headers), do: {:error, :timeout}

  def deliver(url, body, headers) do
    send(self(), {:delivered, url, body, headers})
    Process.get(:adapter_response, {:ok, %{status: 204, headers: [{"set-cookie", "secret"}]}})
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

  test "propagates adapter errors without recording a successful attempt" do
    delivery = delivery_fixture()
    endpoint = Webhooks.get_endpoint(delivery.endpoint_id)

    {:ok, _endpoint} =
      Webhooks.update_endpoint(endpoint, %{url: "https://endpoint.invalid/timeout"})

    assert {:error, :timeout} = DeliveryProcessor.process(delivery.id, __MODULE__)
    persisted = Webhooks.get_delivery(delivery.id)
    assert persisted.status == "processing"
    assert persisted.attempt_count == 0
    assert persisted.completed_at == nil
    assert Webhooks.list_attempts(delivery) == []
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

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
    {:ok, %{status: 204, headers: [{"set-cookie", "secret"}]}}
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

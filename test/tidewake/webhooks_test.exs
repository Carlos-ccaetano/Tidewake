defmodule Tidewake.WebhooksTest do
  use Tidewake.DataCase, async: true

  alias Ecto.Changeset
  alias Tidewake.Webhooks

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
  end

  describe "attempts" do
    test "create_attempt/2 persists attrs with the delivery ID set programmatically" do
      delivery = delivery_fixture()
      attrs = valid_attempt_attrs()

      assert {:ok, attempt} =
               Webhooks.create_attempt(delivery, Map.put(attrs, :delivery_id, -1))

      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == attrs.attempt_number
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

  defp delivery_fixture do
    event = event_fixture()
    endpoint = endpoint_fixture()
    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
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

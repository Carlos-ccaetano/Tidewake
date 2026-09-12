defmodule Tidewake.Webhooks.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.{Envelope, Event}

  test "encodes an empty payload using the external ID and only envelope fields" do
    event = %Event{id: 42, external_id: "evt_123", event_type: "order.created", payload: %{}}

    assert {:ok, json} = Envelope.encode(event)
    assert is_binary(json)

    assert Jason.decode!(json) == %{
             "id" => "evt_123",
             "type" => "order.created",
             "data" => %{}
           }
  end

  test "preserves nested JSON values" do
    payload = %{
      "order" => %{
        "items" => [%{"name" => "Café", "quantity" => 2, "price" => 3.5}],
        "paid" => true,
        "note" => nil,
        "metadata" => %{},
        "tags" => []
      }
    }

    event = %Event{external_id: "evt_nested", event_type: "order.created", payload: payload}

    assert {:ok, json} = Envelope.encode(event)

    assert Jason.decode!(json) == %{
             "id" => "evt_nested",
             "type" => "order.created",
             "data" => payload
           }
  end

  test "returns a controlled error for values that cannot be encoded" do
    for value <- [<<255>>, self()] do
      event = %Event{
        external_id: "evt_invalid",
        event_type: "order.created",
        payload: %{"invalid" => value}
      }

      assert Envelope.encode(event) == {:error, :invalid_json}
    end
  end
end

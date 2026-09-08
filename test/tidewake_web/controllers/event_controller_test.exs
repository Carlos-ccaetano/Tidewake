defmodule TidewakeWeb.EventControllerTest do
  use TidewakeWeb.ConnCase, async: true

  alias Tidewake.Webhooks

  describe "POST /api/events" do
    test "creates and serializes an event from an unwrapped payload", %{conn: conn} do
      payload = %{
        "order_id" => "123",
        "items" => [%{"sku" => "ABC", "quantity" => 2}]
      }

      conn = post(conn, ~p"/api/events", valid_params(%{data: payload}))

      assert %{"data" => data} = json_response(conn, 201)
      event = Webhooks.get_event(data["id"])

      assert data == event_data(event)
      assert event.event_type == "order.created"
      assert event.payload == payload
      assert get_resp_header(conn, "location") == []
    end

    test "returns public field errors when required fields are missing", %{conn: conn} do
      conn = post(conn, ~p"/api/events", %{})

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "external_id" => ["can't be blank"],
                 "type" => ["can't be blank"],
                 "data" => ["can't be blank"]
               }
             }
    end

    test "rejects blank external_id and type values", %{conn: conn} do
      conn = post(conn, ~p"/api/events", valid_params(%{external_id: "   ", type: "   "}))

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "external_id" => ["can't be blank"],
                 "type" => ["can't be blank"]
               }
             }
    end

    test "rejects fields with invalid JSON types", %{conn: conn} do
      conn =
        post(conn, ~p"/api/events", %{
          external_id: 123,
          type: true,
          data: ["not", "an", "object"]
        })

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "external_id" => ["is invalid"],
                 "type" => ["is invalid"],
                 "data" => ["must be a JSON object"]
               }
             }
    end

    test "rejects values longer than their database columns", %{conn: conn} do
      too_long = String.duplicate("a", 256)
      conn = post(conn, ~p"/api/events", valid_params(%{external_id: too_long, type: too_long}))

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "external_id" => ["should be at most 255 character(s)"],
                 "type" => ["should be at most 255 character(s)"]
               }
             }
    end

    test "returns a conflict for a duplicate external_id", %{conn: conn} do
      {:ok, original_event} =
        Webhooks.create_event(%{
          external_id: "evt_123",
          event_type: "order.created",
          payload: %{"order_id" => "123"}
        })

      conn = post(conn, ~p"/api/events", valid_params(%{type: "order.updated"}))

      assert json_response(conn, 409) == %{
               "error" => %{
                 "code" => "external_id_conflict",
                 "message" => "An event with this external_id already exists"
               }
             }

      assert Webhooks.get_event_by_external_id("evt_123") == original_event
    end
  end

  describe "unsupported event routes" do
    test "does not expose event listing", %{conn: conn} do
      conn = get(conn, ~p"/api/events")

      assert response(conn, 404)
    end

    test "does not expose event retrieval", %{conn: conn} do
      conn = get(conn, "/api/events/1")

      assert response(conn, 404)
    end
  end

  defp valid_params(overrides) do
    Map.merge(
      %{
        external_id: "evt_123",
        type: "order.created",
        data: %{"order_id" => "123"}
      },
      overrides
    )
  end

  defp event_data(event) do
    %{
      "id" => event.id,
      "external_id" => event.external_id,
      "type" => event.event_type,
      "data" => event.payload,
      "inserted_at" => DateTime.to_iso8601(event.inserted_at),
      "updated_at" => DateTime.to_iso8601(event.updated_at)
    }
  end
end

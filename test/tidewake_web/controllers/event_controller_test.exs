defmodule TidewakeWeb.EventControllerTest do
  use TidewakeWeb.ConnCase, async: false

  alias Tidewake.{Repo, Webhooks}

  describe "POST /api/events" do
    test "creates and serializes an event without active endpoints or jobs", %{conn: conn} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        payload = %{
          "order_id" => "123",
          "items" => [%{"sku" => "ABC", "quantity" => 2}]
        }

        conn = post(conn, ~p"/api/events", valid_params(%{data: payload}))

        assert %{"data" => data} = response = json_response(conn, 201)
        event = Webhooks.get_event(data["id"])

        assert response == %{"data" => event_data(event)}
        assert event.event_type == "order.created"
        assert event.payload == payload
        assert get_resp_header(conn, "location") == [~p"/api/events/#{event.id}"]
        assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 0
        assert Repo.aggregate(Oban.Job, :count) == 0
      end)
    end

    test "creates one delivery and one job for each active endpoint", %{conn: conn} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        first_endpoint = endpoint_fixture(%{name: "First"})
        second_endpoint = endpoint_fixture(%{name: "Second"})

        conn = post(conn, ~p"/api/events", valid_params(%{}))

        assert %{"data" => data} = json_response(conn, 201)
        deliveries = Repo.all(Tidewake.Webhooks.Delivery)
        jobs = Repo.all(Oban.Job)

        assert Enum.sort(Enum.map(deliveries, & &1.endpoint_id)) ==
                 Enum.sort([first_endpoint.id, second_endpoint.id])

        assert Enum.all?(deliveries, &(&1.event_id == data["id"]))

        assert Enum.sort(Enum.map(jobs, & &1.args["delivery_id"])) ==
                 Enum.sort(Enum.map(deliveries, & &1.id))

        assert length(deliveries) == 2
        assert length(jobs) == 2
      end)
    end

    test "ignores inactive endpoints during HTTP ingestion", %{conn: conn} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        active_endpoint = endpoint_fixture(%{name: "Active"})
        inactive_endpoint = endpoint_fixture(%{name: "Inactive", active: false})

        conn = post(conn, ~p"/api/events", valid_params(%{}))

        assert %{"data" => data} = json_response(conn, 201)
        assert [delivery] = Repo.all(Tidewake.Webhooks.Delivery)
        assert [_job] = Repo.all(Oban.Job)

        assert delivery.event_id == data["id"]
        assert delivery.endpoint_id == active_endpoint.id
        refute delivery.endpoint_id == inactive_endpoint.id
      end)
    end

    test "a duplicate external_id creates no additional deliveries or jobs", %{conn: conn} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        _endpoint = endpoint_fixture()

        assert {:ok, %{event: original_event}} =
                 Webhooks.ingest_event(%{
                   external_id: "evt_123",
                   event_type: "order.created",
                   payload: %{"order_id" => "123"}
                 })

        counts_before_conflict = fanout_record_counts()
        conn = post(conn, ~p"/api/events", valid_params(%{type: "order.updated"}))

        assert json_response(conn, 409) == %{
                 "error" => %{
                   "code" => "external_id_conflict",
                   "message" => "An event with this external_id already exists"
                 }
               }

        assert fanout_record_counts() == counts_before_conflict
        assert counts_before_conflict == %{events: 1, deliveries: 1, jobs: 1}
        assert Webhooks.get_event_by_external_id("evt_123") == original_event
      end)
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
  end

  describe "GET /api/events/:id" do
    test "returns an event by its internal ID", %{conn: conn} do
      event = event_fixture()

      conn = get(conn, ~p"/api/events/#{event.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data == event_data(event)
    end

    test "returns not found for an unknown ID", %{conn: conn} do
      conn = get(conn, ~p"/api/events/999999999")

      assert_not_found(conn)
    end

    test "returns not found for an invalid ID", %{conn: conn} do
      conn = get(conn, ~p"/api/events/not-an-id")

      assert_not_found(conn)
    end

    test "returns not found for a negative ID", %{conn: conn} do
      conn = get(conn, ~p"/api/events/-1")

      assert_not_found(conn)
    end

    test "returns not found for zero", %{conn: conn} do
      conn = get(conn, ~p"/api/events/0")

      assert_not_found(conn)
    end
  end

  describe "GET /api/events/:id/deliveries" do
    test "returns an empty list for an existing event without deliveries", %{conn: conn} do
      event = event_fixture()

      conn = get(conn, ~p"/api/events/#{event.id}/deliveries")

      assert json_response(conn, 200) == %{"data" => []}
      assert Repo.aggregate(Tidewake.Webhooks.Delivery, :count) == 0
      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "returns only the event deliveries ordered by ID with the public fields", %{conn: conn} do
      event = event_fixture()
      other_event = event_fixture(%{external_id: "evt_other"})
      first_endpoint = endpoint_fixture(%{name: "First"})
      second_endpoint = endpoint_fixture(%{name: "Second"})

      {:ok, first_delivery} = Webhooks.create_delivery(event, first_endpoint)
      {:ok, _other_delivery} = Webhooks.create_delivery(other_event, first_endpoint)
      {:ok, second_delivery} = Webhooks.create_delivery(event, second_endpoint)
      {:ok, _claimed_delivery} = Webhooks.claim_delivery(first_delivery.id)

      assert {:ok, %{delivery: finalized_delivery, attempt: attempt}} =
               Webhooks.finalize_delivery(first_delivery.id, %{
                 result: "succeeded",
                 http_status: 200,
                 duration_ms: 15,
                 started_at: ~U[2026-09-17 10:00:00.000000Z],
                 completed_at: ~U[2026-09-17 10:00:00.015000Z],
                 response_metadata: %{}
               })

      deliveries_before = [finalized_delivery, second_delivery]
      job_count_before = Repo.aggregate(Oban.Job, :count)
      attempt_count_before = Repo.aggregate(Tidewake.Webhooks.Attempt, :count)

      conn = get(conn, ~p"/api/events/#{event.id}/deliveries")

      assert %{"data" => data} = json_response(conn, 200)
      assert data == Enum.map(deliveries_before, &delivery_data/1)
      assert Enum.map(data, & &1["id"]) == [finalized_delivery.id, second_delivery.id]

      assert Map.keys(hd(data)) |> Enum.sort() ==
               ~w(attempt_count completed_at endpoint_id id inserted_at next_attempt_at status updated_at)

      refute Map.has_key?(hd(data), "url")
      refute Map.has_key?(hd(data), "payload")
      refute Map.has_key?(hd(data), "attempts")
      assert hd(data)["completed_at"] == "2026-09-17T10:00:00.015000Z"
      assert List.last(data)["completed_at"] == nil
      assert Webhooks.list_deliveries_for_event(event) == deliveries_before
      assert Repo.aggregate(Oban.Job, :count) == job_count_before
      assert Repo.aggregate(Tidewake.Webhooks.Attempt, :count) == attempt_count_before
      assert Webhooks.get_attempt(attempt.id) == attempt
    end

    test "returns the event not found response for an unknown event", %{conn: conn} do
      conn = get(conn, ~p"/api/events/999999999/deliveries")

      assert_not_found(conn)
    end

    test "returns the event not found response for invalid IDs", %{conn: conn} do
      for id <- ["not-an-id", "0", "-1"] do
        request_conn = get(recycle(conn), "/api/events/#{id}/deliveries")

        assert_not_found(request_conn)
      end
    end
  end

  describe "unsupported event routes" do
    test "does not expose event listing", %{conn: conn} do
      conn = get(conn, ~p"/api/events")

      assert response(conn, 404)
    end

    test "does not expose event updates", %{conn: conn} do
      conn = patch(conn, ~p"/api/events/1", %{type: "order.updated"})

      assert response(conn, 404)
    end

    test "does not expose event deletion", %{conn: conn} do
      conn = delete(conn, ~p"/api/events/1")

      assert response(conn, 404)
    end
  end

  defp event_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          external_id: "evt_123",
          event_type: "order.created",
          payload: %{"order_id" => "123"}
        },
        attrs
      )

    {:ok, event} = Webhooks.create_event(attrs)
    event
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

  defp fanout_record_counts do
    %{
      events: Repo.aggregate(Tidewake.Webhooks.Event, :count),
      deliveries: Repo.aggregate(Tidewake.Webhooks.Delivery, :count),
      jobs: Repo.aggregate(Oban.Job, :count)
    }
  end

  defp delivery_data(delivery) do
    %{
      "id" => delivery.id,
      "endpoint_id" => delivery.endpoint_id,
      "status" => delivery.status,
      "attempt_count" => delivery.attempt_count,
      "next_attempt_at" => timestamp_data(delivery.next_attempt_at),
      "completed_at" => timestamp_data(delivery.completed_at),
      "inserted_at" => timestamp_data(delivery.inserted_at),
      "updated_at" => timestamp_data(delivery.updated_at)
    }
  end

  defp timestamp_data(nil), do: nil

  defp timestamp_data(timestamp) do
    DateTime.to_iso8601(timestamp)
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

  defp assert_not_found(conn) do
    assert json_response(conn, 404) == %{
             "error" => %{
               "code" => "not_found",
               "message" => "Event not found"
             }
           }
  end
end

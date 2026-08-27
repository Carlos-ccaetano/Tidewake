defmodule TidewakeWeb.EndpointControllerTest do
  use TidewakeWeb.ConnCase, async: true

  alias Tidewake.Webhooks

  describe "POST /api/endpoints" do
    test "creates an endpoint from an unwrapped payload", %{conn: conn} do
      conn = post(conn, ~p"/api/endpoints", valid_attrs())

      assert %{"data" => data} = json_response(conn, 201)
      endpoint = Webhooks.get_endpoint(data["id"])

      assert_endpoint_data(data, endpoint)
    end

    test "returns validation errors when the name is missing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/endpoints", %{
          url: "https://ironhold.example.com/api/webhooks"
        })

      assert %{"errors" => %{"name" => ["can't be blank"]}} = json_response(conn, 422)
    end

    test "returns validation errors for an invalid URL", %{conn: conn} do
      conn = post(conn, ~p"/api/endpoints", %{name: "Ironhold", url: "not-a-url"})

      assert %{"errors" => %{"url" => ["must be a valid HTTP or HTTPS URL"]}} =
               json_response(conn, 422)
    end

    test "defaults active to true", %{conn: conn} do
      conn = post(conn, ~p"/api/endpoints", valid_attrs())

      assert %{"data" => %{"active" => true}} = json_response(conn, 201)
    end
  end

  describe "GET /api/endpoints" do
    test "returns an empty list", %{conn: conn} do
      conn = get(conn, ~p"/api/endpoints")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "lists persisted endpoints", %{conn: conn} do
      first_endpoint = endpoint_fixture()
      second_endpoint = endpoint_fixture(%{name: "Secondary endpoint"})

      conn = get(conn, ~p"/api/endpoints")

      assert %{"data" => data} = json_response(conn, 200)

      assert Enum.sort_by(data, & &1["id"]) ==
               Enum.sort_by(
                 [endpoint_data(first_endpoint), endpoint_data(second_endpoint)],
                 & &1["id"]
               )
    end
  end

  describe "GET /api/endpoints/:id" do
    test "returns an existing endpoint", %{conn: conn} do
      endpoint = endpoint_fixture()

      conn = get(conn, ~p"/api/endpoints/#{endpoint.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert_endpoint_data(data, endpoint)
    end

    test "returns not found for an unknown ID", %{conn: conn} do
      conn = get(conn, ~p"/api/endpoints/999999999")

      assert_not_found(conn)
    end

    test "returns not found for an invalid ID", %{conn: conn} do
      conn = get(conn, ~p"/api/endpoints/not-an-id")

      assert_not_found(conn)
    end
  end

  describe "PATCH /api/endpoints/:id" do
    test "updates the name", %{conn: conn} do
      endpoint = endpoint_fixture()

      conn = patch(conn, ~p"/api/endpoints/#{endpoint.id}", %{name: "Primary Ironhold"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "Primary Ironhold"
      assert Webhooks.get_endpoint(endpoint.id).name == "Primary Ironhold"
    end

    test "updates the URL", %{conn: conn} do
      endpoint = endpoint_fixture()
      updated_url = "https://secondary.ironhold.example.com/webhooks"

      conn = patch(conn, ~p"/api/endpoints/#{endpoint.id}", %{url: updated_url})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["url"] == updated_url
      assert Webhooks.get_endpoint(endpoint.id).url == updated_url
    end

    test "deactivates an endpoint", %{conn: conn} do
      endpoint = endpoint_fixture()

      conn = patch(conn, ~p"/api/endpoints/#{endpoint.id}", %{active: false})

      assert %{"data" => %{"active" => false}} = json_response(conn, 200)
      refute Webhooks.get_endpoint(endpoint.id).active
    end

    test "returns validation errors without persisting an invalid update", %{conn: conn} do
      endpoint = endpoint_fixture()

      conn = patch(conn, ~p"/api/endpoints/#{endpoint.id}", %{url: "not-a-url"})

      assert %{"errors" => %{"url" => ["must be a valid HTTP or HTTPS URL"]}} =
               json_response(conn, 422)

      assert Webhooks.get_endpoint(endpoint.id).url == endpoint.url
    end

    test "returns not found for an unknown endpoint", %{conn: conn} do
      conn = patch(conn, ~p"/api/endpoints/999999999", %{name: "Unknown endpoint"})

      assert_not_found(conn)
    end
  end

  describe "unsupported routes" do
    test "does not expose PUT /api/endpoints/:id", %{conn: conn} do
      conn = put(conn, ~p"/api/endpoints/1", valid_attrs())

      assert response(conn, 404)
    end

    test "does not expose DELETE /api/endpoints/:id", %{conn: conn} do
      conn = delete(conn, ~p"/api/endpoints/1")

      assert response(conn, 404)
    end
  end

  defp endpoint_fixture(attrs \\ %{}) do
    attrs = Map.merge(valid_attrs(), attrs)
    {:ok, endpoint} = Webhooks.create_endpoint(attrs)
    endpoint
  end

  defp valid_attrs do
    %{name: "Ironhold", url: "https://ironhold.example.com/api/webhooks"}
  end

  defp assert_endpoint_data(data, endpoint) do
    assert data == endpoint_data(endpoint)
  end

  defp endpoint_data(endpoint) do
    %{
      "id" => endpoint.id,
      "name" => endpoint.name,
      "url" => endpoint.url,
      "active" => endpoint.active,
      "inserted_at" => DateTime.to_iso8601(endpoint.inserted_at),
      "updated_at" => DateTime.to_iso8601(endpoint.updated_at)
    }
  end

  defp assert_not_found(conn) do
    assert %{
             "error" => %{
               "code" => "not_found",
               "message" => "Endpoint not found"
             }
           } = json_response(conn, 404)
  end
end

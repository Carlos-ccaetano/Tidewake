defmodule TidewakeWeb.ApiAuthenticationTest do
  use TidewakeWeb.ConnCase, async: true

  alias Tidewake.Repo
  alias Tidewake.Webhooks.Endpoint

  test "an API route without a token returns 401 without executing the operation", %{conn: conn} do
    endpoint_count = Repo.aggregate(Endpoint, :count)

    conn =
      post(conn, ~p"/api/endpoints", %{
        name: "Unauthenticated endpoint",
        url: "https://example.com/webhooks"
      })

    assert_unauthorized(conn)
    assert Repo.aggregate(Endpoint, :count) == endpoint_count
  end

  test "an invalid token returns 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid-token")
      |> get(~p"/api/endpoints")

    assert_unauthorized(conn)
  end

  test "a malformed authorization header returns 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Token #{api_token()}")
      |> get(~p"/api/endpoints")

    assert_unauthorized(conn)
  end

  test "a valid token reaches the API route", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_token()}")
      |> get(~p"/api/endpoints")

    assert json_response(conn, 200) == %{"data" => []}
  end

  test "browser routes remain public", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Tidewake"
  end

  defp assert_unauthorized(conn) do
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    assert json_response(conn, 401) == %{
             "error" => %{
               "code" => "unauthorized",
               "message" => "Valid API token required"
             }
           }

    refute conn.resp_body =~ api_token()
  end

  defp api_token do
    Application.fetch_env!(:tidewake, :api_token)
  end
end

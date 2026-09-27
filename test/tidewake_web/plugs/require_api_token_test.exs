defmodule TidewakeWeb.Plugs.RequireApiTokenTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias TidewakeWeb.Plugs.RequireApiToken

  @api_token "test-only-require-api-token-value"
  @incorrect_token "test-only-require-api-token-other"

  setup do
    previous_token = Application.fetch_env(:tidewake, :api_token)
    Application.put_env(:tidewake, :api_token, @api_token)

    on_exit(fn -> restore_api_token(previous_token) end)
  end

  test "init returns the supplied options" do
    options = [source: :test]

    assert RequireApiToken.init(options) == options
  end

  test "allows a connection with the configured bearer token unchanged" do
    conn = conn(:get, "/api") |> put_req_header("authorization", "Bearer #{@api_token}")

    assert RequireApiToken.call(conn, []) == conn
  end

  test "rejects a missing authorization header" do
    conn = conn(:get, "/api") |> RequireApiToken.call([])

    assert_unauthorized(conn)
  end

  test "rejects an incorrect token" do
    conn =
      conn(:get, "/api")
      |> put_req_header("authorization", "Bearer #{@incorrect_token}")
      |> RequireApiToken.call([])

    assert byte_size(@incorrect_token) == byte_size(@api_token)
    assert_unauthorized(conn, [@incorrect_token])
  end

  test "rejects an authorization scheme other than Bearer" do
    authorization = "Basic #{@api_token}"

    conn =
      conn(:get, "/api")
      |> put_req_header("authorization", authorization)
      |> RequireApiToken.call([])

    assert_unauthorized(conn, [authorization])
  end

  test "rejects an empty bearer token" do
    authorization = "Bearer "

    conn =
      conn(:get, "/api")
      |> put_req_header("authorization", authorization)
      |> RequireApiToken.call([])

    assert_unauthorized(conn, [authorization])
  end

  test "rejects multiple authorization headers" do
    authorization = "Bearer #{@api_token}"

    conn =
      conn(:get, "/api")
      |> prepend_req_headers([
        {"authorization", authorization},
        {"authorization", authorization}
      ])
      |> RequireApiToken.call([])

    assert_unauthorized(conn, [authorization])
  end

  test "raises when the API token configuration is absent" do
    Application.delete_env(:tidewake, :api_token)
    conn = conn(:get, "/api")

    assert_raise ArgumentError, fn -> RequireApiToken.call(conn, []) end
  end

  defp assert_unauthorized(conn, sensitive_values \\ []) do
    assert conn.status == 401
    assert conn.halted
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "unauthorized",
               "message" => "Valid API token required"
             }
           }

    refute conn.resp_body =~ @api_token

    Enum.each(sensitive_values, fn sensitive_value ->
      refute conn.resp_body =~ sensitive_value
    end)
  end

  defp restore_api_token({:ok, token}) do
    Application.put_env(:tidewake, :api_token, token)
  end

  defp restore_api_token(:error) do
    Application.delete_env(:tidewake, :api_token)
  end
end

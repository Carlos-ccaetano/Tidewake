defmodule TidewakeWeb.Plugs.RequireApiToken do
  @moduledoc """
  Requires the configured static API token in the Authorization header.
  """

  @behaviour Plug

  import Plug.Conn

  @unauthorized_body Jason.encode!(%{
                       error: %{
                         code: "unauthorized",
                         message: "Valid API token required"
                       }
                     })

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    expected_token = Application.fetch_env!(:tidewake, :api_token)

    with [authorization_header] <- get_req_header(conn, "authorization"),
         {:ok, presented_token} <- extract_bearer_token(authorization_header),
         true <- matching_token?(presented_token, expected_token) do
      conn
    else
      _error -> unauthorized(conn)
    end
  end

  defp extract_bearer_token("Bearer " <> token) when byte_size(token) > 0 do
    {:ok, token}
  end

  defp extract_bearer_token(_authorization_header), do: :error

  defp matching_token?(presented_token, expected_token)
       when byte_size(presented_token) == byte_size(expected_token) do
    Plug.Crypto.secure_compare(presented_token, expected_token)
  end

  defp matching_token?(_presented_token, _expected_token), do: false

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_content_type("application/json")
    |> send_resp(401, @unauthorized_body)
    |> halt()
  end
end

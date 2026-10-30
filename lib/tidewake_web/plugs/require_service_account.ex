defmodule TidewakeWeb.Plugs.RequireServiceAccount do
  @moduledoc """
  Authenticates one canonical Bearer credential into a server-derived Scope.

  Consumes Authorization so it is not retained by downstream code. This plug
  emits no authentication logs or Telemetry and is not yet wired into the router.
  """

  @behaviour Plug

  import Plug.Conn

  alias Tidewake.Projects.Scope

  @unauthorized_body Jason.encode!(%{
                       error: %{
                         code: "unauthorized",
                         message: "Valid service account credential required"
                       }
                     })

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    authorization = get_req_header(conn, "authorization")

    conn = %{
      conn
      | req_headers:
          Enum.reject(conn.req_headers, fn {name, _value} -> name == "authorization" end),
        assigns: Map.delete(conn.assigns, :current_scope)
    }

    with ["Bearer " <> token] <- authorization,
         {:ok, scope} <- Scope.authenticate(token, DateTime.utc_now()) do
      assign(conn, :current_scope, scope)
    else
      _invalid -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_content_type("application/json")
    |> send_resp(401, @unauthorized_body)
    |> halt()
  end
end

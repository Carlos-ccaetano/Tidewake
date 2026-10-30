defmodule TidewakeWeb.Plugs.RequirePermission do
  @moduledoc "Requires a route-configured permission after service-account authentication."

  @behaviour Plug

  import Plug.Conn

  alias Tidewake.Projects.Authorization

  @forbidden_body Jason.encode!(%{error: %{code: "forbidden", message: "Permission denied"}})

  @impl Plug
  def init(permission), do: permission

  @impl Plug
  def call(conn, permission) do
    if Authorization.allowed?(conn.assigns[:current_scope], permission) do
      conn
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(403, @forbidden_body)
      |> halt()
    end
  end
end

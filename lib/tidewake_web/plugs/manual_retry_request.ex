defmodule TidewakeWeb.Plugs.ManualRetryRequest do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias TidewakeWeb.{ManualRetryRequestController, Router}

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(%{method: "POST"} = conn, _options) do
    case Phoenix.Router.route_info(Router, conn.method, conn.path_info, conn.host) do
      %{plug: ManualRetryRequestController, plug_opts: :create, path_params: params} ->
        dispatch(conn, params)

      _other_route ->
        conn
    end
  end

  def call(conn, _options), do: conn

  defp dispatch(conn, params) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Router.manual_retries([])

    if conn.halted do
      conn
    else
      %{conn | params: params, path_params: params}
      |> ManualRetryRequestController.call(:create)
      |> halt()
    end
  end
end

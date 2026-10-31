defmodule TidewakeWeb.Plugs.ManualRetryRequest do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias TidewakeWeb.{ManualRetryRequestController, Router}

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(%{method: method} = conn, _options) when method in ["POST", "GET", "HEAD"] do
    method = if method == "HEAD", do: "GET", else: method

    case Phoenix.Router.route_info(Router, method, conn.path_info, conn.host) do
      %{plug: ManualRetryRequestController, plug_opts: action, path_params: params}
      when action in [:create, :index] ->
        dispatch(Plug.Head.call(conn, []), params, action)

      _other_route ->
        conn
    end
  end

  def call(conn, _options), do: conn

  defp dispatch(conn, params, action) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    conn =
      case action do
        :create -> Router.manual_retries(conn, [])
        :index -> Router.manual_retry_audit(conn, [])
      end

    if conn.halted do
      conn
    else
      %{conn | params: params, path_params: params}
      |> ManualRetryRequestController.call(action)
      |> halt()
    end
  end
end

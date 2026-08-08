defmodule TidewakeWeb.PageController do
  use TidewakeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

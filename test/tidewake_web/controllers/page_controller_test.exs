defmodule TidewakeWeb.PageControllerTest do
  use TidewakeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#tidewake-foundation") |> Enum.count() == 1
    assert document |> LazyHTML.query("#planned-flow") |> Enum.count() == 1
    assert document |> LazyHTML.query("#current-status") |> Enum.count() == 1
  end
end

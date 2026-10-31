defmodule TidewakeWeb.PageControllerTest do
  use TidewakeWeb.ConnCase

  test "GET / presents implemented delivery capabilities as pre-release", %{conn: conn} do
    conn = get(conn, ~p"/")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#tidewake-platform h1") |> Enum.count() == 1
    assert document |> LazyHTML.query("#delivery-flow ol li") |> Enum.count() == 4

    assert document |> LazyHTML.query("#tidewake-platform") |> LazyHTML.text() =~ "Pre-release"

    implemented = document |> LazyHTML.query("#current-status") |> LazyHTML.text()

    for capability <- [
          "Implemented and tested",
          "Req HTTP delivery",
          "SSRF",
          "DNS pinning",
          "jitter",
          "at-least-once",
          "Service accounts",
          "manual retry",
          "audit",
          "Telemetry"
        ] do
      assert implemented =~ capability
    end
  end

  test "GET / distinguishes future work and operational limits", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    limits = document |> LazyHTML.query("#future-work") |> LazyHTML.text()

    for limitation <- [
          "human authentication remain future work",
          "There is no retry dashboard",
          "Retry-After received from destinations",
          "retention and disposal",
          "external metrics reporting",
          "deterministic adapter by default",
          "no production deployment or end-to-end production integration"
        ] do
      assert String.replace(limits, ~r/\s+/, " ") =~ limitation
    end
  end

  test "GET / links to project documentation, source and the companion receiver", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    for {id, url} <- [
          {"architecture-link",
           "https://github.com/Carlos-ccaetano/Tidewake/blob/main/docs/architecture.md"},
          {"documentation-link",
           "https://github.com/Carlos-ccaetano/Tidewake/blob/main/README.md"},
          {"roadmap-link",
           "https://github.com/Carlos-ccaetano/Tidewake/blob/main/docs/roadmap.md"},
          {"source-link", "https://github.com/Carlos-ccaetano/Tidewake"},
          {"ironhold-link", "https://github.com/Carlos-ccaetano/Ironhold"}
        ] do
      assert document |> LazyHTML.query("a##{id}[href='#{url}']") |> Enum.count() == 1
    end
  end
end

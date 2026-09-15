defmodule Tidewake.Webhooks.DeliveryAdapters.ReqTest do
  use ExUnit.Case, async: false

  alias Tidewake.Webhooks.DeliveryAdapters.Req, as: ReqAdapter

  setup context do
    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)

    previous_options = Application.fetch_env(:tidewake, ReqAdapter)

    Application.put_env(
      :tidewake,
      ReqAdapter,
      plug: {Req.Test, context.test},
      method: :get,
      body: "configured body",
      headers: [{"content-type", "text/plain"}],
      retry: :transient,
      redirect: true,
      http_errors: :raise,
      connect_options: [timeout: 60_000],
      receive_timeout: 60_000,
      request_timeout: 60_000,
      compressed: true,
      decode_body: true
    )

    on_exit(fn -> restore_options(previous_options) end)

    {:ok, stub: context.test}
  end

  test "posts the exact body and supplied headers and returns response metadata", %{stub: stub} do
    body = ~s({ "id" : "evt_123", "values" : [1, 2] })

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert Req.Test.raw_body(conn) == body
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "x-webhook-id") == ["evt_123"]

      conn
      |> Plug.Conn.prepend_resp_headers([
        {"set-cookie", "first=1"},
        {"set-cookie", "second=2"},
        {"x-request-id", "req_123"}
      ])
      |> Plug.Conn.send_resp(202, "response body must not cross the adapter boundary")
    end)

    assert {:ok, %{status: 202, headers: response_headers} = response} =
             ReqAdapter.deliver(
               "https://example.com/webhooks",
               body,
               [
                 {"content-type", "application/json"},
                 {"x-webhook-id", "evt_123"}
               ]
             )

    assert {"x-request-id", "req_123"} in response_headers
    assert Enum.count(response_headers, &match?({"set-cookie", _value}, &1)) == 2
    refute Map.has_key?(response, :body)
  end

  test "returns a 503 as an HTTP response without retrying", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.send_resp(503, "unavailable")
    end)

    assert {:ok, %{status: 503, headers: headers}} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    assert {"retry-after", "30"} in headers
  end

  test "does not follow redirects", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example/webhooks")
      |> Plug.Conn.send_resp(307, "redirect")
    end)

    assert {:ok, %{status: 307, headers: headers}} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    assert {"location", "https://other.example/webhooks"} in headers
  end

  test "normalizes a timeout without retrying", %{stub: stub} do
    Req.Test.expect(stub, &Req.Test.transport_error(&1, :timeout))

    assert ReqAdapter.deliver("https://example.com/webhooks", "{}", []) ==
             {:error, :timeout}
  end

  defp restore_options({:ok, options}), do: Application.put_env(:tidewake, ReqAdapter, options)
  defp restore_options(:error), do: Application.delete_env(:tidewake, ReqAdapter)
end

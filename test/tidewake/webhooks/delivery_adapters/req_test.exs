defmodule Tidewake.Webhooks.DeliveryAdapters.ReqTest do
  use ExUnit.Case, async: false

  alias Req.Request
  alias Tidewake.ReqOptionsCaptureAdapter
  alias Tidewake.Webhooks.DeliveryAdapters.Req, as: ReqAdapter

  @behaviour Tidewake.Webhooks.OutboundResolver

  @max_response_bytes 65_536
  @public_address {93, 184, 216, 34}

  setup context do
    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)

    previous_options = Application.fetch_env(:tidewake, ReqAdapter)

    Application.put_env(
      :tidewake,
      ReqAdapter,
      plug: {Req.Test, context.test},
      resolver: __MODULE__,
      target_mode: :public,
      method: :get,
      body: "configured body",
      headers: [{"content-type", "text/plain"}],
      retry: :transient,
      redirect: true,
      http_errors: :raise,
      connect_options: [timeout: 60_000, hostname: "wrong.example", protocols: [:http2]],
      receive_timeout: 60_000,
      request_timeout: 60_000,
      compressed: true,
      decode_body: true,
      into: "configured response body",
      pool_max_idle_time: :infinity
    )

    Process.put(:resolver_result, {:ok, [@public_address]})

    on_exit(fn -> restore_options(previous_options) end)

    {:ok, stub: context.test}
  end

  test "posts the exact body and supplied headers and returns response metadata", %{stub: stub} do
    body = ~s({ "id" : "evt_123", "values" : [1, 2] })

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "93.184.216.34"
      assert conn.request_path == "/webhooks"
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

  test "pins the connection while preserving the original hostname", %{stub: stub} do
    options =
      Application.fetch_env!(:tidewake, ReqAdapter)
      |> Keyword.delete(:plug)
      |> Keyword.put(:adapter, ReqOptionsCaptureAdapter)

    Application.put_env(:tidewake, ReqAdapter, options)

    assert {:ok, %{status: 204}} =
             ReqAdapter.deliver(
               "https://example.com:8443/hooks/delivery?source=tidewake",
               "exact body",
               [{"x-exact", "header"}]
             )

    assert_receive {:request, request}

    assert URI.to_string(request.url) ==
             "https://93.184.216.34:8443/hooks/delivery?source=tidewake"

    assert request.body == "exact body"
    assert Request.get_header(request, "x-exact") == ["header"]
    assert request.options.finch[:protocols] == [:http1]
    assert request.options.finch[:pool_max_idle_time] == 60_000
    assert request.options.finch[:conn_opts][:hostname] == "example.com"
    assert request.options.finch[:conn_opts][:transport_opts][:timeout] == 5_000

    refute_received {:http_request, ^stub}
  end

  test "rejects loopback and private destinations before making a request", %{stub: stub} do
    Req.Test.stub(stub, fn conn ->
      send(self(), :unexpected_request)
      Plug.Conn.send_resp(conn, 204, "")
    end)

    for address <- [{127, 0, 0, 1}, {10, 0, 0, 1}] do
      Process.put(:resolver_result, {:ok, [address]})

      assert ReqAdapter.deliver("https://example.com/webhooks", "{}", []) ==
               {:error, :unsafe_destination}
    end

    refute_received :unexpected_request
  end

  test "rejects mixed public and private DNS answers without making a request", %{stub: stub} do
    Process.put(:resolver_result, {:ok, [@public_address, {10, 0, 0, 1}]})

    Req.Test.stub(stub, fn conn ->
      send(self(), :unexpected_request)
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert ReqAdapter.deliver("https://example.com/webhooks", "{}", []) ==
             {:error, :unsafe_destination}

    refute_received :unexpected_request
  end

  test "resolves the hostname on every delivery", %{stub: stub} do
    Req.Test.expect(stub, 2, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

    assert {:ok, %{status: 204}} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    assert {:ok, %{status: 204}} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    assert_receive {:resolved, "example.com"}
    assert_receive {:resolved, "example.com"}
    refute_received {:resolved, "example.com"}
  end

  test "normalizes DNS failures without exposing the destination", %{stub: stub} do
    Process.put(:resolver_result, {:error, :dns_error})

    Req.Test.stub(stub, fn conn ->
      send(self(), :unexpected_request)
      Plug.Conn.send_resp(conn, 204, "")
    end)

    result = ReqAdapter.deliver("https://sensitive.example/private", "{}", [])

    assert result == {:error, :dns_error}
    refute inspect(result) =~ "sensitive.example"
    refute inspect(result) =~ "private"
    refute_received :unexpected_request
  end

  test "accepts an empty response without returning a body", %{stub: stub} do
    Req.Test.expect(stub, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

    assert {:ok, %{status: 204} = response} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    refute Map.has_key?(response, :body)
  end

  test "accepts a response at the exact byte limit", %{stub: stub} do
    body = String.duplicate("a", @max_response_bytes)

    Req.Test.expect(stub, fn conn -> send_chunked_response(conn, 200, [body]) end)

    assert {:ok, %{status: 200} = response} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    refute Map.has_key?(response, :body)
  end

  test "rejects a response one byte above the limit and makes one request", %{stub: stub} do
    body = String.duplicate("a", @max_response_bytes + 1)

    Req.Test.expect(stub, 1, fn conn -> send_chunked_response(conn, 200, [body]) end)

    assert ReqAdapter.deliver("https://example.com/webhooks", "{}", []) ==
             {:error, :response_too_large}
  end

  test "discards a chunked response without a content-length header", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-response-kind", "chunked")
      |> send_chunked_response(206, ["first", "-", "second"])
    end)

    assert {:ok, %{status: 206, headers: headers} = response} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

    assert {"x-response-kind", "chunked"} in headers
    refute Enum.any?(headers, &match?({"content-length", _value}, &1))
    refute Map.has_key?(response, :body)
  end

  test "does not trust content-length smaller than the response", %{stub: stub} do
    body = String.duplicate("a", @max_response_bytes + 1)

    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "1")
      |> send_chunked_response(200, [body])
    end)

    assert ReqAdapter.deliver("https://example.com/webhooks", "{}", []) ==
             {:error, :response_too_large}
  end

  test "does not trust content-length larger than the response", %{stub: stub} do
    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", Integer.to_string(@max_response_bytes + 1))
      |> send_chunked_response(202, ["accepted"])
    end)

    assert {:ok, %{status: 202} = response} =
             ReqAdapter.deliver("https://example.com/webhooks", "{}", [])

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

  defp send_chunked_response(conn, status, chunks) do
    conn = Plug.Conn.send_chunked(conn, status)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  @impl true
  def resolve(hostname) do
    send(self(), {:resolved, hostname})
    Process.get(:resolver_result, {:error, :dns_error})
  end

  defp restore_options({:ok, options}), do: Application.put_env(:tidewake, ReqAdapter, options)
  defp restore_options(:error), do: Application.delete_env(:tidewake, ReqAdapter)
end

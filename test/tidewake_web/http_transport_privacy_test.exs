defmodule TidewakeWeb.HTTPTransportPrivacyTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias TidewakeWeb.{Endpoint, HTTPAdapter}

  @authorization "Bearer disposable-transport-fixture"
  @key "disposable-transport-key"

  setup do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:cowboy, :request, :start], [:cowboy, :request, :stop]],
        &__MODULE__.observe/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "the observer detects raw headers in Cowboy's default transport instrumentation" do
    assert request(:default).status == 200
    assert_receive {:transport, :start, %{authorization: true, key: true}}, 5000
    assert_receive {:transport, :stop, _observations}, 5000
  end

  test "the configured HTTP adapter serves requests without emitting raw transport metadata" do
    assert Endpoint.config(:adapter) == HTTPAdapter
    assert Application.fetch_env!(:plug_cowboy, :conn_in_exception_metadata) == false
    assert request(:configured).status == 200
    refute_received {:transport, _phase, _observations}
  end

  test "the official Cowlib fix rejects control bytes in structured header strings" do
    assert IO.iodata_to_binary(:cow_http_struct_hd.item({:item, {:string, "safe"}, []})) ==
             "\"safe\""

    for value <- ["unsafe\r\nheader", <<0>>, <<31>>, <<127>>, <<255>>] do
      assert_raise FunctionClauseError, fn ->
        :cow_http_struct_hd.item({:item, {:string, value}, []})
      end
    end
  end

  def init(options), do: options
  def call(conn, _options), do: send_resp(conn, 200, "ok")

  def observe([:cowboy, :request, phase], _measurements, metadata, parent) do
    headers = get_in(metadata, [:req, :headers]) || %{}

    send(
      parent,
      {:transport, phase,
       %{
         authorization: headers["authorization"] == @authorization,
         key: headers["idempotency-key"] == @key
       }}
    )
  end

  defp request(kind) do
    ref = if kind == :configured, do: Module.concat(__MODULE__, "HTTP"), else: make_ref()
    options = [port: 0, ip: {127, 0, 0, 1}, ref: ref]
    spec = server_spec(kind, options)
    start_supervised!(Supervisor.child_spec(spec, id: ref))

    response =
      Req.get!("http://127.0.0.1:#{:ranch.get_port(ref)}/",
        retry: false,
        headers: [
          {"authorization", @authorization},
          {"idempotency-key", @key},
          {"connection", "close"}
        ]
      )

    :ok = stop_supervised(ref)
    response
  end

  defp server_spec(:default, options),
    do: Plug.Cowboy.child_spec(scheme: :http, plug: __MODULE__, options: options)

  defp server_spec(:configured, options) do
    [spec] =
      HTTPAdapter.child_specs(__MODULE__, otp_app: :tidewake, http: options, drainer: false)

    spec
  end
end

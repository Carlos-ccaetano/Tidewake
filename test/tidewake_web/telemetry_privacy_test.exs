defmodule TidewakeWeb.TelemetryPrivacyTest do
  use TidewakeWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL
  alias ExUnit.CaptureLog
  alias TidewakeWeb.Telemetry
  @marker "f3-synthetic-private-marker"

  setup do
    parent = self()
    handler = {__MODULE__, make_ref()}
    events = Telemetry.metrics() |> Enum.map(& &1.event_name) |> Enum.uniq()

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, test_pid ->
          if self() == test_pid, do: send(test_pid, {:exportable, event, measurements, metadata})
        end,
        parent
      )

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      :telemetry.detach(handler)
      Logger.configure(level: previous_level)
    end)

    identity = Tidewake.ProjectsFixtures.service_account_fixture()
    %{token: identity.issued.token, markers: [identity.issued.token]}
  end

  for scenario <- [:accepted, :unauthorized, :invalid, :exception] do
    @tag privacy_http: true, scenario: scenario
    test "declared metric handlers and logs protect #{scenario} requests", context do
      {status, logs} = CaptureLog.with_log(fn -> request(context) end)

      assert status ==
               %{accepted: 201, unauthorized: 401, invalid: 422, exception: 400}[context.scenario]

      records = take_records()
      assert records != []
      markers = [@marker | context.markers]

      unsafe =
        Enum.any?(records, fn {_, measurements, metadata} ->
          contains_conn?(metadata) or contains_marker?({measurements, metadata}, markers)
        end)

      refute unsafe, "Private material reached a declared metric event"
      leaked_log = contains_marker?(logs, markers)
      refute leaked_log, "Private material reached captured logs"
    end
  end

  test "raw library metadata stays internal while exception metrics are allowlisted" do
    conn = private_conn()
    raw_handler = {__MODULE__, :raw, make_ref()}
    event = [:phoenix, :router_dispatch, :exception]

    :ok =
      :telemetry.attach(
        raw_handler,
        event,
        fn _, _, metadata, pid ->
          send(
            pid,
            {:raw_private, contains_conn?(metadata) and contains_marker?(metadata, [@marker])}
          )
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(raw_handler) end)

    assert_raise RuntimeError, @marker, fn ->
      :telemetry.span([:phoenix, :router_dispatch], %{conn: conn, route: "/api/events"}, fn ->
        raise @marker
      end)
    end

    assert_received {:raw_private, true}

    assert [
             {[:tidewake, :observability, :phoenix, :router_dispatch, :exception], measurements,
              %{route: "/api/events", kind: :error}}
           ] = Enum.filter(take_records(), fn {event, _, _} -> List.last(event) == :exception end)

    assert Map.keys(measurements) == [:duration]
    assert is_integer(measurements.duration) and measurements.duration >= 0
  end

  test "repo success and error keep timings without SQL, params or result objects" do
    {_, logs} =
      CaptureLog.with_log(fn ->
        assert {:ok, _} = SQL.query(Tidewake.Repo, "SELECT $1::text", [@marker])

        assert {:error, _} =
                 SQL.query(Tidewake.Repo, "SELECT 1 / 0", [], mode: :savepoint)
      end)

    records = take_records()
    assert length(records) == 2

    for {event, measurements, metadata} <- records do
      assert event == [:tidewake, :observability, :repo, :query]
      assert metadata == %{}
      assert is_integer(measurements.total_time) and measurements.total_time >= 0

      assert Map.keys(measurements) --
               [:total_time, :decode_time, :query_time, :queue_time, :idle_time] == []

      refute contains_marker?(measurements, [@marker])
    end

    refute contains_marker?(logs, [@marker])
  end

  test "foreign sources and malformed metadata cannot cross the metric boundary or detach it" do
    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{
      conn: private_conn(OtherEndpoint)
    })

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{conn: @marker})
    :telemetry.execute([:tidewake, :repo, :query], %{total_time: 1}, %{repo: OtherRepo})
    assert take_records() == []

    :telemetry.execute(
      [:phoenix, :router_dispatch, :stop],
      %{duration: 42, body: @marker, extra: private_conn()},
      %{conn: private_conn(), route: @marker, reason: RuntimeError.exception(@marker)}
    )

    assert [
             {[:tidewake, :observability, :phoenix, :router_dispatch, :stop], %{duration: 42},
              %{route: "unmatched"}}
           ] = take_records()

    :telemetry.execute(
      [:tidewake, :repo, :query],
      %{total_time: @marker, query_time: -1, queue_time: nil},
      %{repo: Tidewake.Repo, params: [@marker]}
    )

    assert [{[:tidewake, :observability, :repo, :query], %{}, %{}}] = take_records()
  end

  test "reinstalling the project handler neither duplicates metrics nor detaches other consumers" do
    raw_id = {__MODULE__, :consumer, make_ref()}

    :ok =
      :telemetry.attach(
        raw_id,
        [:phoenix, :endpoint, :stop],
        fn _, _, _, pid ->
          send(pid, :other_consumer)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(raw_id) end)
    :ok = TidewakeWeb.MetricEvents.attach()
    :ok = TidewakeWeb.MetricEvents.attach()
    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 7}, %{conn: private_conn()})
    assert_received :other_consumer

    assert [{[:tidewake, :observability, :phoenix, :endpoint, :stop], %{duration: 7}, %{}}] =
             take_records()
  end

  test "metric names, units and bounded domain events retain their existing contract" do
    metrics = Telemetry.metrics()

    for metric <- metrics do
      case metric.name do
        [:phoenix | suffix] ->
          assert metric.event_name == [
                   :tidewake,
                   :observability,
                   :phoenix | Enum.drop(suffix, -1)
                 ]

          assert metric.unit == :millisecond or metric.name == [:phoenix, :socket_drain, :count]

        [:tidewake, :repo, :query, _] ->
          assert metric.event_name == [:tidewake, :observability, :repo, :query]
          assert metric.unit == :millisecond

        _ ->
          assert metric.event_name == Enum.drop(metric.name, -1)
      end
    end

    refute Enum.any?(metrics, &(Enum.take(&1.event_name, 1) == [:phoenix]))
    refute Enum.any?(metrics, &(&1.event_name == [:tidewake, :repo, :query]))
  end

  defp private_conn(endpoint \\ TidewakeWeb.Endpoint) do
    build_conn(:post, "/" <> @marker, @marker)
    |> put_req_header("authorization", @marker)
    |> put_req_header("tidewake-signature", @marker)
    |> put_private(:phoenix_endpoint, endpoint)
  end

  test "channel labels cannot export client-selected event names or socket contents" do
    :telemetry.execute([:phoenix, :channel_handled_in], %{duration: 9, payload: @marker}, %{
      socket: %Phoenix.Socket{endpoint: TidewakeWeb.Endpoint, assigns: %{private: @marker}},
      event: @marker,
      params: %{@marker => @marker}
    })

    assert [
             {[:tidewake, :observability, :phoenix, :channel_handled_in], %{duration: 9},
              %{event: "other"}}
           ] = take_records()
  end

  test "transport diagnostics never format arbitrary Cowboy/Ranch arguments" do
    logs =
      CaptureLog.capture_log(fn ->
        TidewakeWeb.HTTPAdapter.error(~c"~p", [private_conn()])
      end)

    assert logs =~ "HTTP transport event"
    refute contains_marker?(logs, [@marker])
  end

  test "the installed LiveView logger cannot log a connected dashboard session" do
    event = [:phoenix, :live_view, :mount, :start]

    assert Enum.any?(
             :telemetry.list_handlers(event),
             &(&1.id == {Phoenix.LiveView.Logger, event})
           )

    assert Logger.get_module_level(Phoenix.LiveView.Logger) == [{Phoenix.LiveView.Logger, :none}]

    socket = %Phoenix.LiveView.Socket{
      view: Phoenix.LiveDashboard.PageLive,
      endpoint: TidewakeWeb.Endpoint,
      transport_pid: self()
    }

    logs =
      CaptureLog.capture_log(fn ->
        :telemetry.execute(event, %{system_time: System.system_time()}, %{
          socket: socket,
          params: %{@marker => @marker},
          session: %{"_csrf_token" => @marker},
          uri: "http://localhost/" <> @marker
        })
      end)

    refute contains_marker?(logs, [@marker])
    assert take_records() == []
  end

  defp request(context) do
    token = if context.scenario == :unauthorized, do: @marker, else: context.token

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", @marker)
      |> put_req_header("x-request-id", @marker)

    attrs = %{
      external_id: Ecto.UUID.generate(),
      type: "synthetic.f3",
      data: %{@marker => @marker}
    }

    case context.scenario do
      :exception ->
        {status, _, _} =
          assert_error_sent 400, fn -> post(conn, "/api/events", ~s({"#{@marker}":)) end

        status

      :invalid ->
        post(conn, "/api/events", Map.put(attrs, :data, @marker)).status

      _ ->
        post(conn, "/api/events", attrs).status
    end
  end

  defp take_records(acc \\ []) do
    receive do
      {:exportable, event, measurements, metadata} ->
        take_records([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp contains_marker?(term, markers) do
    value =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    Enum.any?(markers, &String.contains?(value, &1))
  end

  defp contains_conn?(%Plug.Conn{}), do: true

  defp contains_conn?(map) when is_map(map),
    do: map |> Map.values() |> Enum.any?(&contains_conn?/1)

  defp contains_conn?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_conn?/1)

  defp contains_conn?(list) when is_list(list), do: Enum.any?(list, &contains_conn?/1)
  defp contains_conn?(_), do: false
end

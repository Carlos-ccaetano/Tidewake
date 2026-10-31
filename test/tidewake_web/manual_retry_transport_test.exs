defmodule TidewakeWeb.ManualRetryTransportTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Projects.ApiCredential
  alias Tidewake.ProjectsFixtures
  alias Tidewake.Repo
  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Attempt, Delivery, ManualRetryRequest}
  alias TidewakeWeb.HTTPAdapter

  @key "p31-real-http-fixture-key"
  @opts [log: false, telemetry_event: nil]

  test "real HTTP acceptance and replay emit only bounded domain and queue notifications" do
    identity = Sandbox.unboxed_run(Repo, &fixture/0)
    on_exit(fn -> cleanup(identity) end)
    handler = {__MODULE__, make_ref()}

    events = [
      [:cowboy, :request, :start],
      [:cowboy, :request, :stop],
      [:cowboy, :request, :exception],
      [:cowboy, :request, :early_error],
      [:phoenix, :endpoint, :start],
      [:phoenix, :endpoint, :stop],
      [:phoenix, :router_dispatch, :start],
      [:phoenix, :router_dispatch, :stop],
      [:tidewake, :repo, :query],
      [:oban, :engine, :insert_job, :start],
      [:oban, :engine, :insert_job, :stop],
      [:tidewake, :webhooks, :manual_retry, :completed]
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.observe/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    [spec] =
      HTTPAdapter.child_specs(__MODULE__,
        otp_app: :tidewake,
        http: [port: 0, ip: {127, 0, 0, 1}],
        drainer: false
      )

    server_id = spec.id
    start_supervised!(spec)
    {:ok, {_ip, port}} = HTTPAdapter.server_info(__MODULE__, :http)
    url = "http://127.0.0.1:#{port}/api/deliveries/#{identity.delivery.id}/manual-retry-requests"
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          first = request(url, identity.issued.token)
          replay = request(url, identity.issued.token)
          invalid = request(url, identity.issued.token, ~s({"body_marker":"private"}))
          unauthorized = request(url, "invalid", "{invalid")
          assert first.status == 202
          assert replay.status == 202
          assert replay.body == put_in(first.body, ["data", "replayed"], true)
          assert invalid.status == 400
          assert unauthorized.status == 401

          for response <- [first, replay, invalid, unauthorized] do
            assert response.headers["cache-control"] == ["no-store"]
          end
        end)

      :ok = stop_supervised(server_id)
      assert_receive {:bounded_event, %{outcome: "accepted", reason: "none"}}, 5000
      assert_receive {:bounded_event, %{outcome: "idempotent_replay", reason: "none"}}, 5000
      refute_received {:unsafe_event, _event}

      for value <- [
            @key,
            identity.issued.token,
            identity.account.public_id,
            identity.project.public_id,
            "body_marker"
          ] do
        refute logs =~ value
      end
    after
      Logger.configure(level: level)
    end
  end

  def init(options), do: options

  def call(conn, _options) do
    Sandbox.unboxed_run(Repo, fn -> TidewakeWeb.Endpoint.call(conn, []) end)
  end

  def observe([:tidewake, :webhooks, :manual_retry, :completed], _measurements, metadata, parent) do
    send(parent, {:bounded_event, metadata})
  end

  def observe(event, _measurements, metadata, parent) do
    if not queue_notification?(metadata), do: send(parent, {:unsafe_event, event})
  end

  defp queue_notification?(%{
         query:
           "SELECT pg_notify($1, payload) FROM json_array_elements_text($2::json) AS payload",
         params: ["public.oban_insert", [payload]]
       }),
       do: Jason.decode(payload) == {:ok, %{"queue" => "default"}}

  defp queue_notification?(_metadata), do: false

  defp request(url, token, body \\ "") do
    Req.post!(url,
      retry: false,
      body: body,
      headers: [
        {"authorization", "Bearer " <> token},
        {"idempotency-key", @key},
        {"content-type", "application/json"},
        {"connection", "close"}
      ]
    )
  end

  defp fixture do
    identity = ProjectsFixtures.service_account_fixture()

    {:ok, event} =
      Webhooks.create_event(identity.project, %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(identity.project, %{
        name: "Real HTTP",
        url: "https://endpoint.invalid/private"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    now = DateTime.utc_now()

    {:ok, _} =
      Webhooks.create_attempt(delivery, %{
        attempt_number: 1,
        result: "transport_error",
        duration_ms: 0,
        started_at: now,
        completed_at: now
      })

    delivery =
      delivery
      |> Delivery.changeset(%{
        status: "failed",
        attempt_count: 1,
        cycle_attempt_count: 1,
        completed_at: now
      })
      |> Repo.update!(@opts)

    Map.merge(identity, %{delivery: delivery, endpoint: endpoint, event: event})
  end

  defp cleanup(identity) do
    Sandbox.unboxed_run(Repo, fn ->
      id = identity.delivery.id

      Repo.delete_all(
        from(j in Oban.Job, where: fragment("(?->>'delivery_id')::bigint", j.args) == ^id),
        @opts
      )

      Repo.delete_all(from(r in ManualRetryRequest, where: r.delivery_id == ^id), @opts)
      Repo.delete_all(from(a in Attempt, where: a.delivery_id == ^id), @opts)
      Repo.delete!(identity.delivery, @opts)
      Repo.delete!(identity.endpoint, @opts)
      Repo.delete!(identity.event, @opts)

      Repo.delete_all(
        from(c in ApiCredential, where: c.service_account_id == ^identity.account.id),
        @opts
      )

      Repo.delete!(identity.account, @opts)
      Repo.delete!(identity.project, @opts)
    end)
  end
end

# Documentation harness only. Run through run.py; never pass secrets as arguments.
Mix.Task.run("app.config")
Logger.configure(level: :warning)

try do
  [role] = System.argv()
  true = role in ["receiver", "sender"]
  true = Mix.env() == :dev
  input = IO.read(:stdio, :line) |> Jason.decode!()
  app = if role == "receiver", do: :ironhold, else: :tidewake
  repo = if role == "receiver", do: Ironhold.Repo, else: Tidewake.Repo
  endpoint = if role == "receiver", do: IronholdWeb.Endpoint, else: TidewakeWeb.Endpoint
  database = "#{app}_demo263_#{input["run"]}"
  true = Regex.match?(~r/^[a-f0-9]{12}$/, input["run"])
  secret = input["secret"]
  true = is_binary(secret) and byte_size(secret) == 64
  Application.put_env(app, :webhook_signing_secret, secret)
  config = Application.fetch_env!(app, repo)
  true = is_nil(config[:url]) and config[:hostname] in ["localhost", "127.0.0.1"]

  config =
    Keyword.merge(config,
      database: database,
      pool: DBConnection.ConnectionPool,
      show_sensitive_data_on_connection_error: false,
      stacktrace: false,
      log: false
    )

  config = Keyword.delete(config, :url)
  Application.put_env(app, repo, config)
  # Refuse reused databases: a failed rehearsal must never overwrite earlier evidence.
  Process.put(:demo_stage, :database_create)
  :ok = Ecto.Adapters.Postgres.storage_up(config)

  {:ok, _, _} =
    Ecto.Migrator.with_repo(repo, fn r ->
      Ecto.Migrator.run(r, Application.app_dir(app, "priv/repo/migrations"), :up,
        all: true,
        log: false
      )
    end)

  endpoint_config = Application.fetch_env!(app, endpoint)

  Application.put_env(
    app,
    endpoint,
    Keyword.merge(endpoint_config,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: if(role == "receiver", do: 42631, else: 42630)],
      watchers: [],
      code_reloader: false,
      debug_errors: false
    )
  )

  if role == "sender" do
    Application.put_env(:tidewake, :service_account_token_pepper, :crypto.strong_rand_bytes(32))
    oban = Application.fetch_env!(:tidewake, Oban)
    Application.put_env(:tidewake, Oban, Keyword.merge(oban, queues: false, plugins: false))
  end

  Process.put(:demo_stage, :service_start)
  {:ok, _} = Application.ensure_all_started(app)

  if role == "receiver" do
    IO.puts("DEMO receiver READY")
    IO.read(:stdio, :line)
  else
    Process.put(:demo_stage, :provision_and_http)
    alias Tidewake.{Projects, Repo, Webhooks}

    {:ok, project} =
      Projects.create_project(%{name: "Synthetic demo", slug: "demo-#{input["run"]}"})

    {:ok, account} = Projects.create_service_account(project, "admin", %{name: "Demo admin"})
    {:ok, issued} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))

    try do
      headers = [{"authorization", "Bearer " <> issued.token}]

      request = fn method, path, opts ->
        Req.request!(
          [
            method: method,
            url: "http://127.0.0.1:42630" <> path,
            headers: headers,
            retry: false,
            redirect: false
          ] ++ opts
        )
      end

      401 = Req.post!("http://127.0.0.1:42630/api/events", json: %{}, retry: false).status

      201 =
        request.(:post, "/api/endpoints",
          json: %{name: "Synthetic receiver", url: "http://127.0.0.1:42631/api/webhooks"}
        ).status

      external_id = "demo-#{input["run"]}"
      attrs = %{external_id: external_id, type: "demo.created", data: %{synthetic: true}}
      response = request.(:post, "/api/events", json: attrs)
      201 = response.status
      id = response.body["data"]["id"]
      409 = request.(:post, "/api/events", json: attrs).status
      query = fn sql -> Ecto.Adapters.SQL.query!(Repo, sql, [], log: false).rows end
      [[1]] = query.("SELECT count(*) FROM events")
      [[1]] = query.("SELECT count(*) FROM deliveries")

      [[1]] =
        query.(
          "SELECT count(*) FROM oban_jobs WHERE worker = 'Tidewake.Workers.DeliverWebhookWorker'"
        )

      IO.puts(
        "DEMO ingestion: unauthorized=401 endpoint=201 event=201 duplicate=409; event/delivery/job=1/1/1 before drain"
      )

      %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
      [["succeeded", 1]] = query.("SELECT status, attempt_count FROM deliveries")
      [[http_status]] = query.("SELECT http_status FROM delivery_attempts")
      true = is_integer(http_status) and http_status in 100..599
      expected_status = 202

      IO.puts(
        "DEMO worker_status " <>
          Jason.encode!(%{observed: http_status, expected: expected_status})
      )

      if http_status != expected_status do
        Process.put(:demo_stage, :worker_http_status_mismatch)
        raise "Unexpected persisted worker HTTP status"
      end

      200 = request.(:get, "/api/events/#{id}/deliveries", []).status
      IO.puts("DEMO worker: real HTTP=202; delivery=succeeded attempts=1; status GET=200")
      event = Webhooks.get_event(project, id)
      {:ok, body} = Tidewake.Webhooks.Envelope.encode(event)
      # Distinct timestamp without a sleep; +10s is inside Ironhold's documented +30s window.
      timestamp = System.system_time(:second) + 10
      {:ok, signed} = Tidewake.Webhooks.Signature.headers(external_id, timestamp, body, secret)

      send_signed = fn h ->
        Req.post!("http://127.0.0.1:42631/api/webhooks",
          body: body,
          headers: [{"content-type", "application/json"} | h],
          retry: false
        ).status
      end

      202 = send_signed.(signed)
      409 = send_signed.(signed)

      {:ok, stale} =
        Tidewake.Webhooks.Signature.headers(external_id, timestamp - 1000, body, secret)

      401 = send_signed.(stale)

      invalid =
        List.keyreplace(
          signed,
          "Tidewake-Signature",
          0,
          {"Tidewake-Signature", "v1=" <> String.duplicate("0", 64)}
        )

      401 = send_signed.(invalid)

      401 =
        Req.post!("http://127.0.0.1:42631/api/webhooks",
          body:
            Jason.encode!(%{id: external_id, type: "demo.created", data: %{synthetic: false}}),
          headers: [{"content-type", "application/json"} | signed],
          retry: false,
          redirect: false
        ).status

      iron_config = Keyword.merge(config, database: "ironhold_demo263_#{input["run"]}")

      {:ok, conn} =
        Postgrex.start_link(
          Keyword.take(iron_config, [:hostname, :port, :username, :password, :database])
        )

      %Postgrex.Result{rows: [[1]]} =
        Postgrex.query!(conn, "SELECT count(*) FROM received_webhooks", [])

      %Postgrex.Result{rows: [[2]]} =
        Postgrex.query!(conn, "SELECT count(*) FROM webhook_replay_claims", [])

      GenServer.stop(conn)

      IO.puts(
        "DEMO receiver: fresh=202 exact_replay=409 expired=401 invalid_HMAC=401 tampered_payload=401; events/claims=1/2"
      )
    after
      {:ok, _} =
        Projects.revoke_credential(account, issued.credential.public_id, DateTime.utc_now())

      IO.puts("DEMO credential revoked")
    end
  end

  :ok = Application.stop(app)
  IO.puts("DEMO #{role} STOPPED; retained database #{database}")
  IO.puts("DEMO #{role} COMPLETE")
rescue
  _ ->
    # Exceptions may embed request headers. Never print raw exception values.
    IO.puts(
      :stderr,
      "DEMO FAILED stage=#{Process.get(:demo_stage, :bootstrap)} (details suppressed to protect credentials); see troubleshooting"
    )

    System.halt(1)
end

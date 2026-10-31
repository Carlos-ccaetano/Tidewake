defmodule TidewakeWeb.ManualRetryRequestControllerTest do
  use TidewakeWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Tidewake.{Projects, Repo, Webhooks}
  alias Tidewake.Projects.ManualRetryRateLimit
  alias Tidewake.Webhooks.{Delivery, ManualRetryRequest}
  alias Tidewake.Workers.DeliverWebhookWorker

  @now ~U[2026-10-30 12:00:00.000000Z]
  @key "manual-retry-http-key-0001"
  @opts [log: false, telemetry_event: nil]
  @fields ~w(id delivery_id outcome reason requested_at resulting_retry_cycle replayed)

  setup tags do
    Process.put(:oban_testing, :manual)
    identity = service_account_fixture(Map.get(tags, :role, "admin"))
    Map.merge(identity, delivery_fixture(identity.project))
  end

  test "acceptance commits audit, transition and one complete job without changing attempts",
       ctx do
    attempts = Webhooks.list_attempts(ctx.delivery)
    data = request(ctx) |> json_response(202) |> Map.fetch!("data")
    assert Enum.sort(Map.keys(data)) == Enum.sort(@fields)
    assert data["delivery_id"] == ctx.delivery.id
    assert data["outcome"] == "accepted"
    assert data["reason"] == nil
    assert data["resulting_retry_cycle"] == 1
    assert data["replayed"] == false
    assert data["requested_at"] =~ ~r/\.\d{6}Z\z/
    assert [audit] = Repo.all(ManualRetryRequest, @opts)
    assert data["id"] == audit.id
    assert audit.actor_subject == ctx.account.public_id
    assert audit.actor_type == "service_account"
    assert audit.source == "api"
    assert audit.request_fingerprint_version == 2
    delivery = Repo.get!(Delivery, ctx.delivery.id, @opts)
    assert delivery.status == "pending"
    assert delivery.attempt_count == ctx.delivery.attempt_count
    assert delivery.retry_cycle == 1
    assert delivery.cycle_attempt_count == 0
    assert delivery.completed_at == nil
    assert Webhooks.list_attempts(delivery) == attempts
    assert [job] = Repo.all(Oban.Job, @opts)

    assert job.args == %{
             "delivery_id" => delivery.id,
             "attempt_number" => 2,
             "retry_cycle" => 1,
             "cycle_attempt_number" => 1
           }

    assert job.max_attempts == 1
    assert bucket(ctx).tokens == 4
  end

  test "accepted replay preserves the audited response despite changed endpoint state", ctx do
    original = request(ctx) |> json_response(202)
    state = snapshot(ctx)
    Repo.update!(Ecto.Changeset.change(ctx.endpoint, active: false), @opts)
    assert request(ctx) |> json_response(202) == put_in(original, ["data", "replayed"], true)
    assert snapshot(ctx) == state
    assert bucket(ctx).tokens == 3
  end

  for reason <- ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached) do
    test "persists and replays #{reason} with one audit and no work", ctx do
      ctx = make_ineligible(ctx, unquote(reason))
      before_delivery = Repo.get!(Delivery, ctx.delivery.id, @opts)
      original = request(ctx) |> json_response(409)
      assert original["data"]["outcome"] == "rejected"
      assert original["data"]["reason"] == unquote(reason)
      assert original["data"]["resulting_retry_cycle"] == nil
      assert original["data"]["replayed"] == false
      assert Enum.sort(Map.keys(original["data"])) == Enum.sort(@fields)
      assert request(ctx) |> json_response(409) == put_in(original, ["data", "replayed"], true)
      assert Repo.get!(Delivery, ctx.delivery.id, @opts) == before_delivery
      assert length(Repo.all(ManualRetryRequest, @opts)) == 1
      assert Repo.all(Oban.Job, @opts) == []
      assert bucket(ctx).tokens == 3
    end
  end

  test "key conflict has no partial effect or prior-record disclosure", ctx do
    assert request(ctx).status == 202
    other = delivery_fixture(ctx.project)
    state = snapshot(ctx)
    assert error_code(request(ctx, id: other.delivery.id), 409) == "idempotency_conflict"
    assert snapshot(ctx) == state
    assert Repo.get!(Delivery, other.delivery.id, @opts) == other.delivery
    assert bucket(ctx).tokens == 3
  end

  test "foreign and absent delivery are identical 404 even for an already consumed key", ctx do
    assert request(ctx).status == 202
    other = service_account_fixture()
    foreign = delivery_fixture(other.project)
    state = snapshot(ctx)
    missing = request(ctx, id: 9_223_372_036_854_775_807)
    response = request(ctx, id: foreign.delivery.id)
    assert json_response(missing, 404) == json_response(response, 404)

    assert json_response(missing, 404) == %{
             "error" => %{"code" => "not_found", "message" => "Delivery not found"}
           }

    assert snapshot(ctx) == state
    assert Repo.get!(Delivery, foreign.delivery.id, @opts) == foreign.delivery
    assert bucket(ctx).tokens == 2
  end

  for role <- ~w(producer viewer) do
    @tag role: role
    test "#{role} is forbidden before limiter, parsing or lookup", ctx do
      assert error_code(
               request(ctx, keys: [], body: "{invalid", id: 9_223_372_036_854_775_807),
               403
             ) == "forbidden"

      assert bucket(ctx) == nil
      assert_no_domain_effects(ctx)
    end
  end

  for failure <- [:missing, :invalid, :duplicate, :revoked, :expired, :disabled, :suspended] do
    test "#{failure} credential is uniform 401 before limiter and malformed JSON", ctx do
      response =
        request(ctx, auth: invalid_auth(ctx, unquote(failure)), keys: [], body: "{invalid")

      assert json_response(response, 401) == %{
               "error" => %{
                 "code" => "unauthorized",
                 "message" => "Valid service account credential required"
               }
             }

      assert get_resp_header(response, "www-authenticate") == ["Bearer"]
      assert bucket(ctx) == nil
      assert_no_domain_effects(ctx)
    end
  end

  for {name, keys} <- [
        missing: [],
        duplicated: [@key, @key],
        empty: [""],
        short: [String.duplicate("a", 15)],
        oversized: [String.duplicate("a", 129)],
        whitespace: [" invalid-key-whitespace"],
        non_ascii: ["invalid-key-acentuação"],
        combined: [@key <> "," <> @key]
      ] do
    test "#{name} Idempotency-Key is 400 after consuming admission", ctx do
      assert error_code(request(ctx, keys: unquote(keys)), 400) == "invalid_idempotency_key"
      assert bucket(ctx).tokens == 4
      assert_no_domain_effects(ctx)
    end
  end

  for key <- [String.duplicate("a", 16), String.duplicate("a", 128), "Allowed._~-KEY_123"] do
    test "accepts valid key #{byte_size(key)} #{String.slice(key, 0, 8)}", ctx do
      assert request(ctx, keys: [unquote(key)]).status == 202
      assert [audit] = Repo.all(ManualRetryRequest, @opts)

      assert audit.idempotency_key_digest ==
               Base.encode16(:crypto.hash(:sha256, unquote(key)), case: :lower)
    end
  end

  for body <- ["{}", " { } \n"] do
    test "accepts empty JSON object #{inspect(body)}", ctx do
      assert request(ctx, body: unquote(body)).status == 202
    end
  end

  for {name, body} <- [
        fields: ~s({"actor":"spoof","project_id":1,"cycle":0,"reason":"override"}),
        null: "null",
        list: "[]",
        scalar: "1",
        whitespace: " ",
        malformed: "{invalid",
        oversized: String.duplicate(" ", 1025)
      ] do
    test "#{name} body is rejected without domain effects", ctx do
      assert error_code(request(ctx, body: unquote(body)), 400) == "invalid_request"
      assert bucket(ctx).tokens == 4
      assert_no_domain_effects(ctx)
    end
  end

  for id <- ["0", "-1", "+1", "01", "1x", " 1", "9223372036854775808", String.duplicate("9", 100)] do
    test "rejects noncanonical delivery id #{inspect(id)} after admission", ctx do
      assert error_code(request(ctx, id: unquote(id)), 400) == "invalid_request"
      assert bucket(ctx).tokens == 4
      assert_no_domain_effects(ctx)
    end
  end

  test "query options and non-JSON object bodies are rejected", ctx do
    assert error_code(request(ctx, query: "?actor=spoof&actor=other"), 400) == "invalid_request"

    assert error_code(request(ctx, content_type: "text/plain", body: "{}"), 400) ==
             "invalid_request"

    assert_no_domain_effects(ctx)
    assert bucket(ctx).tokens == 3
  end

  test "five admissions include replay; sixth is 429 before validation; exact refill permits replay",
       ctx do
    original = request(ctx) |> json_response(202)
    for _ <- 1..4, do: assert(request(ctx).status == 202)
    response = request(ctx, keys: [], body: "invalid")
    assert error_code(response, 429) == "rate_limited"
    assert get_resp_header(response, "retry-after") == ["12"]
    assert bucket(ctx).tokens == 0
    assert length(Repo.all(ManualRetryRequest, @opts)) == 1
    assert length(Repo.all(Oban.Job, @opts)) == 1
    replay = request(ctx, now: DateTime.add(@now, 12, :second)) |> json_response(202)
    assert replay == put_in(original, ["data", "replayed"], true)
    assert bucket(ctx).tokens == 0
  end

  test "limiter storage failure is 503 before validation or command", ctx do
    with_constraint("manual_retry_rate_limits", "tokens <> 4", fn ->
      assert error_code(request(ctx, keys: [], body: "{invalid"), 503) == "service_unavailable"
      assert bucket(ctx) == nil
      assert_no_domain_effects(ctx)
    end)
  end

  test "domain storage failure is 503 with full rollback and no admission refund", ctx do
    with_constraint("manual_retry_requests", "outcome <> 'accepted'", fn ->
      assert error_code(request(ctx), 503) == "service_unavailable"
      assert_no_domain_effects(ctx)
      assert bucket(ctx).tokens == 4
    end)
  end

  test "active legacy job is a distinct 409 with no new audit or work", ctx do
    job = %{"delivery_id" => ctx.delivery.id} |> DeliverWebhookWorker.new() |> Oban.insert!()
    assert error_code(request(ctx), 409) == "active_job"
    assert Repo.all(ManualRetryRequest, @opts) == []
    assert Repo.get!(Delivery, ctx.delivery.id, @opts) == ctx.delivery
    assert [stored] = Repo.all(Oban.Job, @opts)
    assert stored.id == job.id
    assert bucket(ctx).tokens == 4
  end

  test "job insert failure is private 503 and rolls back audit/state while retaining admission",
       ctx do
    with_constraint("oban_jobs", "worker <> 'Tidewake.Workers.DeliverWebhookWorker'", fn ->
      logs =
        capture_log(fn ->
          assert error_code(request(ctx), 503) == "service_unavailable"
        end)

      refute logs =~ "http_retry_failure_"
      refute logs =~ @key
      refute logs =~ ctx.issued.token
      assert_no_domain_effects(ctx)
      assert bucket(ctx).tokens == 4
    end)

    assert request(ctx).status == 202
    assert bucket(ctx).tokens == 3
  end

  test "responses, debug logs and HTTP/query telemetry disclose no secrets or tenant identity",
       ctx do
    handler = {__MODULE__, make_ref()}

    events = [
      [:phoenix, :endpoint, :start],
      [:phoenix, :endpoint, :stop],
      [:phoenix, :router_dispatch, :start],
      [:phoenix, :router_dispatch, :stop],
      [:tidewake, :repo, :query],
      [:oban, :engine, :insert_job, :start],
      [:oban, :engine, :insert_job, :stop],
      [:oban, :notifier, :notify, :start],
      [:oban, :notifier, :notify, :stop]
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.query_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive {:unsafe_http_event, [:tidewake, :repo, :query], _source}
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          accepted = request(ctx)
          replay = request(ctx)
          invalid = request(ctx, body: ~s({"private_body_marker":"secret"}))
          send(self(), {:responses, [accepted.resp_body, replay.resp_body, invalid.resp_body]})
        end)

      assert_receive {:responses, bodies}

      for text <- [logs | bodies],
          sensitive <- [
            @key,
            ctx.issued.token,
            ctx.account.public_id,
            ctx.project.public_id,
            ctx.issued.credential.public_id,
            ctx.endpoint.url,
            "private_body_marker",
            "idempotency_key_digest",
            "request_fingerprint",
            "actor_subject",
            "service_account_id",
            "project_id",
            "secret_digest"
          ] do
        refute text =~ sensitive
      end

      refute_received {:unsafe_http_event, _event, _source}
      assert_received {:safe_queue_notification, :start}
      assert_received {:safe_queue_notification, :stop}
    after
      Logger.configure(level: level)
    end
  end

  test "there is no GET audit route" do
    assert Phoenix.Router.route_info(
             TidewakeWeb.Router,
             "GET",
             "/api/deliveries/1/manual-retry-requests",
             "www.example.com"
           ) == :error
  end

  def query_event(
        [:oban, :notifier, :notify, phase],
        _measurements,
        %{channel: :insert, payload: [%{queue: "default"}]},
        parent
      ) do
    if self() == parent, do: send(parent, {:safe_queue_notification, phase})
  end

  def query_event(event, _measurements, metadata, parent) do
    source =
      if metadata[:source] in ~w(deliveries manual_retry_requests oban_jobs service_accounts projects service_account_credentials),
        do: metadata[:source],
        else: "other"

    if self() == parent and not queue_notification?(metadata),
      do: send(parent, {:unsafe_http_event, event, source})
  end

  defp queue_notification?(%{
         query:
           "SELECT pg_notify($1, payload) FROM json_array_elements_text($2::json) AS payload",
         params: ["public.oban_insert", [payload]]
       }) do
    Jason.decode(payload) == {:ok, %{"queue" => "default"}}
  end

  defp queue_notification?(_metadata), do: false

  defp request(ctx, options \\ []) do
    auth = Keyword.get(options, :auth, ["Bearer " <> ctx.issued.token])
    keys = Keyword.get(options, :keys, [@key])
    headers = for(value <- auth, do: {"authorization", value})
    headers = headers ++ for(value <- keys, do: {"idempotency-key", value})

    path =
      "/api/deliveries/#{Keyword.get(options, :id, ctx.delivery.id)}/manual-retry-requests" <>
        Keyword.get(options, :query, "")

    response =
      build_conn()
      |> put_private(:manual_retry_now, Keyword.get(options, :now, @now))
      |> put_req_header("content-type", Keyword.get(options, :content_type, "application/json"))
      |> prepend_req_headers(headers)
      |> post(path, Keyword.get(options, :body, ""))

    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "application/json"
    response
  end

  defp error_code(response, status) do
    body = json_response(response, status)
    assert Map.keys(body) == ["error"]
    assert Enum.sort(Map.keys(body["error"])) == ["code", "message"]
    body["error"]["code"]
  end

  defp bucket(ctx), do: Repo.get(ManualRetryRateLimit, ctx.account.id, @opts)

  defp assert_no_domain_effects(ctx) do
    assert Repo.get!(Delivery, ctx.delivery.id, @opts) == ctx.delivery
    assert Repo.all(ManualRetryRequest, @opts) == []
    assert Repo.all(Oban.Job, @opts) == []
    assert length(Webhooks.list_attempts(ctx.delivery)) == ctx.delivery.attempt_count
  end

  defp snapshot(ctx),
    do:
      {Repo.get!(Delivery, ctx.delivery.id, @opts), Repo.all(ManualRetryRequest, @opts),
       Repo.all(Oban.Job, @opts)}

  defp delivery_fixture(project) do
    {:ok, event} =
      Webhooks.create_event(project, %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{"private_payload_marker" => true}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(project, %{
        name: "HTTP retry",
        url: "https://endpoint.invalid/private"
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)

    {:ok, _} =
      Webhooks.create_attempt(delivery, %{
        attempt_number: 1,
        result: "transport_error",
        duration_ms: 0,
        started_at: @now,
        completed_at: @now
      })

    delivery =
      delivery
      |> Delivery.changeset(%{
        status: "failed",
        attempt_count: 1,
        cycle_attempt_count: 1,
        completed_at: @now
      })
      |> Repo.update!(@opts)

    %{delivery: delivery, endpoint: endpoint}
  end

  defp make_ineligible(ctx, "state_not_failed") do
    delivery =
      ctx.delivery
      |> Delivery.changeset(%{status: "pending", completed_at: nil})
      |> Repo.update!(@opts)

    %{ctx | delivery: delivery}
  end

  defp make_ineligible(ctx, "endpoint_inactive") do
    Repo.update!(Ecto.Changeset.change(ctx.endpoint, active: false), @opts)
    ctx
  end

  defp make_ineligible(ctx, "manual_cycle_limit_reached") do
    delivery = ctx.delivery |> Delivery.changeset(%{retry_cycle: 3}) |> Repo.update!(@opts)
    %{ctx | delivery: delivery}
  end

  defp invalid_auth(ctx, reason) do
    case reason do
      :missing ->
        []

      :invalid ->
        ["Bearer invalid"]

      :duplicate ->
        ["Bearer " <> ctx.issued.token, "Bearer " <> ctx.issued.token]

      :revoked ->
        {:ok, _} =
          Projects.revoke_credential(
            ctx.account,
            ctx.issued.credential.public_id,
            DateTime.utc_now()
          )

        ["Bearer " <> ctx.issued.token]

      :expired ->
        expiry = DateTime.add(DateTime.utc_now(), -1)

        Repo.query!(
          "UPDATE service_account_credentials SET expires_at = $1, inserted_at = $2 WHERE id = $3",
          [
            DateTime.to_naive(expiry),
            DateTime.to_naive(DateTime.add(expiry, -60)),
            ctx.issued.credential.id
          ],
          @opts
        )

        ["Bearer " <> ctx.issued.token]

      :disabled ->
        {:ok, _} = Projects.disable_service_account(ctx.account, DateTime.utc_now())
        ["Bearer " <> ctx.issued.token]

      :suspended ->
        {:ok, _} = Projects.suspend_project(ctx.project, DateTime.utc_now())
        ["Bearer " <> ctx.issued.token]
    end
  end

  defp with_constraint(table, condition, fun) do
    name = "http_retry_failure_#{System.unique_integer([:positive])}"
    Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{condition})", [], @opts)

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{name}", [], @opts)
    end
  end
end

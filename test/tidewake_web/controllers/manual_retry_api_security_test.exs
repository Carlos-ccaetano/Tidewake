defmodule TidewakeWeb.ManualRetryAPISecurityTest do
  use TidewakeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Tidewake.WebhooksFixtures, only: [manual_retry_audit_fixture: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.{Projects, Repo, Webhooks}
  alias Tidewake.Projects.{ApiCredential, ManualRetryRateLimit, ServiceAccount}
  alias Tidewake.Webhooks.{Attempt, Delivery, Endpoint, Event, ManualRetryRequest}
  alias Tidewake.Workers.DeliverWebhookWorker

  @now ~U[2026-10-31 12:00:00.000000Z]
  @key "p33-integrated-retry-key-0001"
  @other_key "p33-integrated-retry-key-0002"
  @opts [log: false, telemetry_event: nil]
  @timeout 10_000
  @completion [:tidewake, :webhooks, :manual_retry, :completed]
  @decision_fields ~w(id delivery_id outcome reason requested_at resulting_retry_cycle replayed)
  @audit_fields ~w(id delivery_id outcome reason requested_at resulting_retry_cycle actor_type actor_subject source)

  setup tags do
    Process.put(:oban_testing, :manual)
    create = fn -> fixture(Map.get(tags, :role, "admin")) end

    ctx =
      if tags[:unboxed] do
        ctx = Sandbox.unboxed_run(Repo, create)
        on_exit(fn -> cleanup(ctx.project) end)
        ctx
      else
        create.()
      end

    {:ok, ctx}
  end

  for failure <- [
        :missing,
        :malformed,
        :duplicated,
        :unknown,
        :revoked,
        :expired,
        :disabled,
        :suspended,
        :legacy
      ] do
    test "#{failure} identity is the same 401 on POST and GET without side effects", ctx do
      auth = failed_auth(ctx, unquote(failure))
      before = domain_state(ctx.project)

      responses =
        for method <- [:post, :get] do
          response = request(ctx, method, auth: auth, body: "{invalid", query: "?role=admin")
          assert response.status == 401
          assert get_resp_header(response, "www-authenticate") == ["Bearer"]
          assert bucket(ctx) == nil
          assert domain_state(ctx.project) == before
          json_response(response, 401)
        end

      assert Enum.uniq(responses) == [unauthorized()]
    end
  end

  for role <- ~w(viewer producer) do
    @tag role: role
    test "#{role} cannot POST or GET even with forged admin and project attributes", ctx do
      before = domain_state(ctx.project)

      for method <- [:post, :get] do
        response =
          request(ctx, method,
            id: 9_223_372_036_854_775_807,
            body: ~s({"role":"admin","source":"admin_cli"}),
            query: "?project_id=#{ctx.project.id}",
            headers: [{"x-role", "admin"}]
          )

        assert error_code(response, 403) == "forbidden"
        assert bucket(ctx) == nil
        assert domain_state(ctx.project) == before
      end
    end
  end

  test "admin acceptance, replay and GET agree on one historical decision and job", ctx do
    original = request(ctx, :post) |> decision(202)
    assert original["replayed"] == false
    assert original["outcome"] == "accepted"
    assert original["resulting_retry_cycle"] == 1
    assert original["reason"] == nil
    state = domain_state(ctx.project)
    assert [audit] = state.audit
    assert audit.actor_subject == ctx.account.public_id
    assert audit.actor_type == "service_account"
    assert audit.source == "api"
    assert audit.request_fingerprint_version == 2
    assert_single_transition(ctx)

    Repo.update!(Ecto.Changeset.change(ctx.endpoint, active: false), @opts)
    assert request(ctx, :post) |> decision(202) == Map.put(original, "replayed", true)
    assert domain_state(ctx.project) == state
    assert bucket(ctx).tokens == 3

    {:ok, other_admin} = Projects.create_service_account(ctx.project, "admin", %{name: "Reader"})
    {:ok, issued} = Projects.issue_credential(other_admin, DateTime.add(DateTime.utc_now(), 3600))
    {:ok, _} = Projects.disable_service_account(ctx.account, DateTime.utc_now())
    reader = %{ctx | account: other_admin, issued: issued}
    assert [historical] = request(reader, :get) |> audit_page() |> Map.fetch!("data")
    assert historical["actor_subject"] == ctx.account.public_id
    assert historical["source"] == "api"
    assert historical["id"] == original["id"]
    assert bucket(reader) == nil
    assert domain_state(ctx.project) == state
  end

  test "foreign and absent targets are indistinguishable before key lookup on both methods",
       ctx do
    foreign = fixture()
    assert request(ctx, :post).status == 202
    before = domain_state(ctx.project)
    foreign_before = domain_state(foreign.project)

    for method <- [:post, :get] do
      absent = request(ctx, method, id: 9_223_372_036_854_775_807)
      other = request(ctx, method, id: foreign.delivery.id)
      assert json_response(absent, 404) == json_response(other, 404)
      assert error_code(other, 404) == "not_found"
      assert domain_state(ctx.project) == before
      assert domain_state(foreign.project) == foreign_before
    end

    assert bucket(ctx).tokens == 2
    assert bucket(foreign) == nil
  end

  for field <- ~w(project_id project_public_id actor actor_subject role source) do
    test "client #{field} cannot replace server authority through body, query or header", ctx do
      field = unquote(field)
      before = domain_state(ctx.project)

      for method <- [:post, :get] do
        assert error_code(request(ctx, method, body: Jason.encode!(%{field => "spoof"})), 400) ==
                 "invalid_request"

        assert error_code(request(ctx, method, query: "?#{field}=spoof"), 400) ==
                 "invalid_request"

        assert domain_state(ctx.project) == before
      end

      assert request(ctx, :post, headers: [{field, "spoof"}, {"x-" <> field, "spoof"}]).status ==
               202

      assert [audit] = domain_state(ctx.project).audit
      assert audit.actor_subject == ctx.account.public_id
      assert audit.actor_type == "service_account"
      assert audit.source == "api"
      assert audit.delivery_id == ctx.delivery.id
      assert request(ctx, :get, headers: [{field, "spoof"}]).status == 200
      assert bucket(ctx).tokens == 2
    end
  end

  test "actor-scoped conflict discloses no prior target and independent accounts can reuse a key",
       ctx do
    original = request(ctx, :post) |> decision(202)
    other = delivery_fixture(ctx.project)
    before = domain_state(ctx.project)
    response = request(ctx, :post, id: other.delivery.id)
    assert error_code(response, 409) == "idempotency_conflict"
    assert domain_state(ctx.project) == before

    second = service_account_fixture("admin", ctx.project) |> Map.merge(other)
    accepted = request(second, :post) |> decision(202)
    assert accepted["replayed"] == false
    refute accepted["id"] == original["id"]
    assert length(domain_state(ctx.project).audit) == 2
    assert length(domain_state(ctx.project).jobs) == 2
    assert bucket(ctx).tokens == 3
    assert bucket(second).tokens == 4
  end

  test "real foreign project identifiers in every input location cannot redirect authority",
       ctx do
    foreign = fixture()
    own_before = domain_state(ctx.project)
    foreign_before = domain_state(foreign.project)

    fields = %{
      "project_id" => foreign.project.id,
      "project_public_id" => foreign.project.public_id
    }

    for {field, value} <- fields, method <- [:post, :get] do
      assert request(ctx, method, body: Jason.encode!(%{field => value})).status == 400
      assert request(ctx, method, query: "?#{field}=#{value}").status == 400
    end

    headers = Enum.map(fields, fn {field, value} -> {field, to_string(value)} end)

    for method <- [:post, :get] do
      assert request(ctx, method, id: foreign.delivery.id, headers: headers).status == 404
    end

    assert domain_state(ctx.project) == own_before
    assert domain_state(foreign.project) == foreign_before
    assert bucket(ctx).tokens == 0
    assert bucket(foreign) == nil
  end

  for reason <- ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached) do
    test "#{reason} commits only one rejection and its replay is stable", ctx do
      make_ineligible(ctx, unquote(reason))
      before = domain_state(ctx.project)
      original = request(ctx, :post) |> decision(409)
      assert original["reason"] == unquote(reason)
      assert original["outcome"] == "rejected"
      assert original["resulting_retry_cycle"] == nil
      assert original["replayed"] == false
      state = domain_state(ctx.project)
      assert length(state.audit) == 1
      assert state.deliveries == before.deliveries
      assert state.attempts == before.attempts
      assert state.jobs == []
      assert request(ctx, :post) |> decision(409) == Map.put(original, "replayed", true)
      assert domain_state(ctx.project) == state
      assert bucket(ctx).tokens == 3
      assert [row] = request(ctx, :get) |> audit_page() |> Map.fetch!("data")
      assert row["id"] == original["id"]
      assert row["actor_subject"] == ctx.account.public_id
    end
  end

  for loss <- [:revoked, :disabled, :suspended] do
    test "#{loss} reauthorizes replay and audit GET without changing committed history", ctx do
      assert request(ctx, :post).status == 202
      state = domain_state(ctx.project)
      original_bucket = bucket(ctx)
      failed_auth(ctx, unquote(loss))

      for method <- [:post, :get] do
        assert json_response(request(ctx, method), 401) == unauthorized()
        assert domain_state(ctx.project) == state
        assert bucket(ctx) == original_bucket
      end
    end
  end

  test "all admitted result classes consume; exact clock controls denial and fractional refill",
       ctx do
    other = delivery_fixture(ctx.project)
    assert request(ctx, :post).status == 202
    assert request(ctx, :post).status == 202
    assert request(ctx, :post, key: @other_key).status == 409
    assert error_code(request(ctx, :post, id: other.delivery.id), 409) == "idempotency_conflict"
    assert error_code(request(ctx, :post, id: 9_223_372_036_854_775_807), 404) == "not_found"
    assert bucket(ctx).tokens == 0

    for {offset, seconds} <- [{0, "12"}, {1, "12"}, {11_000_001, "1"}, {11_999_999, "1"}] do
      response = request(ctx, :post, now: DateTime.add(@now, offset, :microsecond), body: "bad")
      assert error_code(response, 429) == "rate_limited"
      assert get_resp_header(response, "retry-after") == [seconds]
      assert bucket(ctx).tokens == 0
      assert bucket(ctx).refilled_at == @now
    end

    at_boundary = DateTime.add(@now, 12, :second)

    assert error_code(request(ctx, :post, now: at_boundary, body: "bad"), 400) ==
             "invalid_request"

    assert bucket(ctx).tokens == 0
    assert bucket(ctx).refilled_at == at_boundary
    assert length(domain_state(ctx.project).audit) == 2
    assert length(domain_state(ctx.project).jobs) == 1
    exhausted = bucket(ctx)
    assert request(ctx, :get).status == 200
    assert request(ctx, :get, query: "?limit=0").status == 400
    assert request(ctx, :get, id: 9_223_372_036_854_775_807).status == 404
    assert bucket(ctx) == exhausted
  end

  test "rotation shares budget, revocation does not refund it, another account starts independently",
       ctx do
    assert request(ctx, :post).status == 202

    {:ok, rotated} =
      Projects.issue_credential(ctx.account, DateTime.add(DateTime.utc_now(), 3600))

    rotated_ctx = %{ctx | issued: rotated}
    assert request(rotated_ctx, :post) |> decision(202) |> Map.fetch!("replayed")
    assert bucket(ctx).tokens == 3
    failed_auth(ctx, :revoked)
    assert request(ctx, :post).status == 401
    assert bucket(ctx).tokens == 3
    for _ <- 1..3, do: assert(request(rotated_ctx, :post).status == 202)
    assert request(rotated_ctx, :post).status == 429

    second =
      service_account_fixture("admin", ctx.project) |> Map.merge(Map.take(ctx, [:delivery]))

    assert request(second, :post).status == 409
    assert bucket(second).tokens == 4
    assert bucket(ctx).tokens == 0
  end

  for boundary <- [:audit, :delivery, :job, :limiter] do
    test "real #{boundary} constraint failure rolls back all domain effects and recovers", ctx do
      before = domain_state(ctx.project)
      attach_completion(ctx)

      {table, condition} =
        case unquote(boundary) do
          :audit -> {"manual_retry_requests", "outcome <> 'accepted'"}
          :delivery -> {"deliveries", "status <> 'pending'"}
          :job -> {"oban_jobs", "worker <> 'Tidewake.Workers.DeliverWebhookWorker'"}
          :limiter -> {"manual_retry_rate_limits", "tokens <> 4"}
        end

      with_constraint(table, condition, fn ->
        assert error_code(request(ctx, :post), 503) == "service_unavailable"
        assert domain_state(ctx.project) == before

        if unquote(boundary) == :limiter do
          assert bucket(ctx) == nil
          refute_received {:completion, _, _, _, _}
        else
          assert bucket(ctx).tokens == 4

          assert_receive {:completion, %{count: 1, duration_ms: duration},
                          %{outcome: "error", reason: "persistence"}, false, ^before}

          assert is_integer(duration) and duration >= 0
        end
      end)

      assert request(ctx, :post).status == 202
      assert_single_transition(ctx)
      assert bucket(ctx).tokens == if(unquote(boundary) == :limiter, do: 4, else: 3)
    end
  end

  test "active cycle-aware job prevents a partial HTTP acceptance", ctx do
    job =
      DeliverWebhookWorker.new_for_delivery(ctx.delivery.id, 2, 1, 1)
      |> Oban.insert!()

    before = domain_state(ctx.project)
    assert error_code(request(ctx, :post), 409) == "active_job"
    assert domain_state(ctx.project) == before
    assert [stored] = before.jobs
    assert stored.id == job.id
    assert bucket(ctx).tokens == 4
  end

  test "GET pagination isolates both project and delivery and preserves historical snapshots",
       ctx do
    foreign = fixture()
    sibling = delivery_fixture(ctx.project)

    rows =
      for version <- [1, 2, 1, 2, 2] do
        manual_retry_audit_fixture(ctx.delivery, %{
          actor_subject: ctx.account.public_id,
          source: "admin_cli",
          request_fingerprint_version: version
        })
      end

    manual_retry_audit_fixture(foreign.delivery, %{actor_subject: foreign.account.public_id})
    manual_retry_audit_fixture(sibling.delivery, %{actor_subject: ctx.account.public_id})
    before = domain_state(ctx.project)
    first = request(ctx, :get, query: "?limit=2") |> audit_page()

    assert Enum.map(first["data"], & &1["id"]) ==
             rows |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.id)

    cursor = first["page"]["next_before_id"]
    inserted = manual_retry_audit_fixture(ctx.delivery, %{actor_subject: ctx.account.public_id})
    second = request(ctx, :get, query: "?limit=2&before_id=#{cursor}") |> audit_page()
    cursor = second["page"]["next_before_id"]
    final = request(ctx, :get, query: "?limit=2&before_id=#{cursor}") |> audit_page()
    assert final["page"]["next_before_id"] == nil
    combined = first["data"] ++ second["data"] ++ final["data"]
    assert Enum.map(combined, & &1["id"]) == rows |> Enum.reverse() |> Enum.map(& &1.id)
    assert Enum.all?(combined, &(&1["actor_subject"] == ctx.account.public_id))
    assert Enum.all?(combined, &(&1["source"] == "admin_cli"))
    assert domain_state(ctx.project).audit == Enum.sort_by([inserted | before.audit], & &1.id)
    assert bucket(ctx) == nil
    assert bucket(foreign) == nil
  end

  @tag :unboxed
  test "simultaneous identical HTTP requests converge on original plus replay", ctx do
    responses = concurrent(ctx, [[], []], :delivery)
    assert Enum.map(responses, & &1.status) == [202, 202]
    data = Enum.map(responses, &decision(&1, 202))
    assert Enum.sort(Enum.map(data, & &1["replayed"])) == [false, true]
    assert data |> Enum.map(&Map.delete(&1, "replayed")) |> Enum.uniq() |> length() == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert_single_transition(ctx)
      assert bucket(ctx).tokens == 3
    end)
  end

  @tag :unboxed
  test "different simultaneous keys on one delivery advance the final cycle only once", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.update!(Ecto.Changeset.change(ctx.delivery, retry_cycle: 2), @opts)
    end)

    responses = concurrent(ctx, [[key: @key], [key: @other_key]], :delivery)
    assert Enum.sort(Enum.map(responses, & &1.status)) == [202, 409]
    accepted = responses |> Enum.find(&(&1.status == 202)) |> decision(202)
    rejected = responses |> Enum.find(&(&1.status == 409)) |> decision(409)
    assert accepted["resulting_retry_cycle"] == 3
    assert rejected["reason"] == "state_not_failed"

    Sandbox.unboxed_run(Repo, fn ->
      state = domain_state(ctx.project)
      assert length(state.audit) == 2
      assert [%{retry_cycle: 3, status: "pending"}] = state.deliveries
      assert [%{args: %{"retry_cycle" => 3}}] = state.jobs
      assert bucket(ctx).tokens == 3
    end)
  end

  @tag :unboxed
  test "actor-key race across delivery locks leaves no orphan audit or transition", ctx do
    other = Sandbox.unboxed_run(Repo, fn -> delivery_fixture(ctx.project) end)
    responses = concurrent(ctx, [[], [id: other.delivery.id]], :audit)
    assert Enum.sort(Enum.map(responses, & &1.status)) == [202, 409]
    assert error_code(Enum.find(responses, &(&1.status == 409)), 409) == "idempotency_conflict"

    Sandbox.unboxed_run(Repo, fn ->
      state = domain_state(ctx.project)
      assert [audit] = state.audit
      assert [job] = state.jobs
      assert job.args["delivery_id"] == audit.delivery_id
      assert Enum.count(state.deliveries, &(&1.status == "pending" and &1.retry_cycle == 1)) == 1
      assert Enum.count(state.deliveries, &(&1.status == "failed" and &1.retry_cycle == 0)) == 1
      assert length(state.attempts) == 2
      assert bucket(ctx).tokens == 3
    end)
  end

  @tag :unboxed
  test "six concurrent HTTP requests cannot exceed the five-token account budget", ctx do
    calls = for index <- 1..6, do: [key: "p33-concurrent-budget-key-#{index}"]
    responses = concurrent(ctx, calls, :bucket)
    assert Enum.sort(Enum.map(responses, & &1.status)) == [202, 409, 409, 409, 409, 429]
    denied = Enum.find(responses, &(&1.status == 429))
    assert get_resp_header(denied, "retry-after") == ["12"]

    Sandbox.unboxed_run(Repo, fn ->
      state = domain_state(ctx.project)
      assert length(state.audit) == 5
      assert Enum.count(state.audit, &(&1.outcome == "accepted")) == 1
      assert length(state.jobs) == 1
      assert bucket(ctx).tokens == 0
      assert bucket(ctx).refilled_at == @now
    end)
  end

  test "responses and debug observability expose only their explicit allowlists and final results",
       ctx do
    attach_completion(ctx)
    handler = {__MODULE__, make_ref()}

    events =
      for phase <- [:start, :stop, :exception],
          prefix <- [
            [:phoenix, :endpoint],
            [:phoenix, :router_dispatch],
            [:oban, :engine, :insert_job]
          ],
          do: prefix ++ [phase]

    :ok =
      :telemetry.attach_many(
        handler,
        [[:tidewake, :repo, :query] | events],
        &__MODULE__.observe_private/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive {:unsafe_event, [:tidewake, :repo, :query]}
    old_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          assert request(ctx, :post).status == 202
          state = domain_state(ctx.project)

          assert_receive {:completion, %{count: 1, duration_ms: duration},
                          %{outcome: "accepted", reason: "none"}, false, ^state}

          assert is_integer(duration) and duration >= 0
          assert request(ctx, :post).status == 202

          assert_receive {:completion, %{count: 1, duration_ms: _},
                          %{outcome: "idempotent_replay", reason: "none"}, false, ^state}

          assert request(ctx, :post, key: @other_key).status == 409
          rejected_state = domain_state(ctx.project)
          assert_receive {:completion, measurements, metadata, false, ^rejected_state}
          assert_completion_fields(measurements, metadata, "rejected", "state_not_failed")
          assert request(ctx, :post, body: ~s({"p33_body_secret":"private"})).status == 400
          assert request(ctx, :post, id: 9_223_372_036_854_775_807).status == 404
          assert_receive {:completion, measurements, metadata, false, ^rejected_state}
          assert_completion_fields(measurements, metadata, "error", "not_found")
          assert request(ctx, :post).status == 429
          assert request(ctx, :get).status == 200
          assert request(ctx, :get, auth: []).status == 401

          with_constraint("manual_retry_requests", "outcome <> 'rejected'", fn ->
            assert request(ctx, :post,
                     key: "p33-private-failure-key",
                     now: DateTime.add(@now, 12, :second)
                   ).status == 503

            assert_receive {:completion, measurements, metadata, false, ^rejected_state}
            assert_completion_fields(measurements, metadata, "error", "persistence")
          end)

          refute_received {:completion, _, _, _, _}
        end)

      [audit | _] = domain_state(ctx.project).audit
      pepper = Application.fetch_env!(:tidewake, :service_account_token_pepper)

      for protected <- [
            ctx.issued.token,
            @key,
            @other_key,
            ctx.account.public_id,
            ctx.project.public_id,
            ctx.issued.credential.public_id,
            ctx.endpoint.url,
            audit.idempotency_key_digest,
            audit.request_fingerprint,
            pepper,
            "p33_payload_secret",
            "p33_body_secret",
            "service_account_id",
            "project_id"
          ] do
        refute String.contains?(logs, protected), "protected material escaped into logs"
      end

      refute_received {:unsafe_event, _}
    after
      Logger.configure(level: old_level)
    end
  end

  def completion(_event, measurements, metadata, {parent, project}) do
    if self() == parent do
      send(
        parent,
        {:completion, measurements, metadata, Repo.in_transaction?(), domain_state(project)}
      )
    end
  end

  def observe_private(event, _measurements, metadata, parent) do
    queue_only? =
      case metadata do
        %{
          query:
            "SELECT pg_notify($1, payload) FROM json_array_elements_text($2::json) AS payload",
          params: ["public.oban_insert", [payload]]
        } ->
          Jason.decode(payload) == {:ok, %{"queue" => "default"}}

        _ ->
          false
      end

    if self() == parent and not queue_only?, do: send(parent, {:unsafe_event, event})
  end

  defp attach_completion(ctx) do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @completion, &__MODULE__.completion/4, {self(), ctx.project})
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp assert_completion_fields(measurements, metadata, outcome, reason) do
    assert Enum.sort(Map.keys(measurements)) == [:count, :duration_ms]
    assert measurements.count == 1
    assert is_integer(measurements.duration_ms) and measurements.duration_ms >= 0
    assert metadata == %{outcome: outcome, reason: reason}
  end

  defp request(ctx, method, options \\ []) do
    auth = Keyword.get(options, :auth, ["Bearer " <> ctx.issued.token])
    headers = for value <- auth, do: {"authorization", value}

    path =
      "/api/deliveries/#{Keyword.get(options, :id, ctx.delivery.id)}/manual-retry-requests" <>
        Keyword.get(options, :query, "")

    conn =
      build_conn()
      |> put_private(:manual_retry_now, Keyword.get(options, :now, @now))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", Keyword.get(options, :key, @key))
      |> prepend_req_headers(headers ++ Keyword.get(options, :headers, []))

    response = dispatch(conn, @endpoint, method, path, Keyword.get(options, :body, ""))
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert [type] = get_resp_header(response, "content-type")
    assert type =~ "application/json"

    if response.status == 429 do
      assert [delay] = get_resp_header(response, "retry-after")
      assert {seconds, ""} = Integer.parse(delay)
      assert seconds > 0
    else
      assert get_resp_header(response, "retry-after") == []
    end

    text = response.resp_body <> inspect(response.resp_headers)

    for secret <- [
          ctx.issued.token,
          @key,
          @other_key,
          ctx.project.public_id,
          ctx.issued.credential.public_id,
          Application.fetch_env!(:tidewake, :service_account_token_pepper),
          "secret_digest",
          "request_fingerprint",
          "idempotency_key_digest",
          "service_account_id",
          "project_id",
          "project_public_id",
          "p33_payload_secret",
          "p33_body_secret"
        ] do
      refute String.contains?(text, secret), "protected material escaped into HTTP response"
    end

    response
  end

  defp decision(response, status) do
    assert %{"data" => data} = body = json_response(response, status)
    assert Map.keys(body) == ["data"]
    assert Enum.sort(Map.keys(data)) == Enum.sort(@decision_fields)
    data
  end

  defp audit_page(response) do
    assert %{"data" => data, "page" => %{"next_before_id" => _}} =
             page = json_response(response, 200)

    assert Enum.sort(Map.keys(page)) == ["data", "page"]
    assert Map.keys(page["page"]) == ["next_before_id"]
    for row <- data, do: assert(Enum.sort(Map.keys(row)) == Enum.sort(@audit_fields))
    page
  end

  defp error_code(response, status) do
    assert %{"error" => %{"code" => code, "message" => message} = error} =
             body = json_response(response, status)

    assert Map.keys(body) == ["error"]
    assert Enum.sort(Map.keys(error)) == ["code", "message"]
    assert is_binary(message)
    code
  end

  defp unauthorized,
    do: %{
      "error" => %{
        "code" => "unauthorized",
        "message" => "Valid service account credential required"
      }
    }

  defp bucket(ctx), do: Repo.get(ManualRetryRateLimit, ctx.account.id, @opts)

  defp domain_state(project) do
    ids = Repo.all(from(d in Delivery, where: d.project_id == ^project.id, select: d.id), @opts)

    %{
      deliveries: Repo.all(from(d in Delivery, where: d.id in ^ids, order_by: d.id), @opts),
      attempts: Repo.all(from(a in Attempt, where: a.delivery_id in ^ids, order_by: a.id), @opts),
      audit:
        Repo.all(
          from(r in ManualRetryRequest, where: r.delivery_id in ^ids, order_by: r.id),
          @opts
        ),
      jobs:
        Repo.all(
          from(j in Oban.Job,
            where: fragment("(?->>'delivery_id')::bigint", j.args) in ^ids,
            order_by: j.id
          ),
          @opts
        )
    }
  end

  defp assert_single_transition(ctx) do
    state = domain_state(ctx.project)
    assert [audit] = state.audit
    assert audit.outcome == "accepted"

    assert [
             %{
               status: "pending",
               retry_cycle: 1,
               cycle_attempt_count: 0,
               attempt_count: 1,
               completed_at: nil,
               next_attempt_at: nil
             }
           ] = state.deliveries

    assert [%{attempt_number: 1, retry_cycle: 0}] = state.attempts
    assert [job] = state.jobs

    assert job.args == %{
             "delivery_id" => ctx.delivery.id,
             "attempt_number" => 2,
             "retry_cycle" => 1,
             "cycle_attempt_number" => 1
           }

    assert job.state == "available"
    assert job.max_attempts == 1
  end

  defp fixture(role \\ "admin") do
    identity = service_account_fixture(role)
    Map.merge(identity, delivery_fixture(identity.project))
  end

  defp delivery_fixture(project) do
    {:ok, event} =
      Webhooks.create_event(project, %{
        external_id: Ecto.UUID.generate(),
        event_type: "order.created",
        payload: %{"p33_payload_secret" => "private"}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(project, %{
        name: "P33",
        url: "https://endpoint.invalid/p33-private"
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

    %{delivery: delivery, endpoint: endpoint, event: event}
  end

  defp failed_auth(_ctx, :legacy), do: ["Bearer tidewake_test_token_not_for_production"]

  defp failed_auth(_ctx, :unknown),
    do: [
      "Bearer twk_sa.#{Ecto.UUID.generate()}.#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
    ]

  defp failed_auth(ctx, failure) do
    case failure do
      :missing ->
        []

      :malformed ->
        ["Bearer invalid"]

      :duplicated ->
        ["Bearer " <> ctx.issued.token, "Bearer " <> ctx.issued.token]

      :revoked ->
        {:ok, _} =
          Projects.revoke_credential(
            ctx.account,
            ctx.issued.credential.public_id,
            DateTime.utc_now()
          )

        ["Bearer " <> ctx.issued.token]

      :disabled ->
        {:ok, _} = Projects.disable_service_account(ctx.account, DateTime.utc_now())
        ["Bearer " <> ctx.issued.token]

      :suspended ->
        {:ok, _} = Projects.suspend_project(ctx.project, DateTime.utc_now())
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
    end
  end

  defp make_ineligible(ctx, reason) do
    case reason do
      "state_not_failed" ->
        Repo.update!(
          Ecto.Changeset.change(ctx.delivery, status: "pending", completed_at: nil),
          @opts
        )

      "endpoint_inactive" ->
        Repo.update!(Ecto.Changeset.change(ctx.endpoint, active: false), @opts)

      "manual_cycle_limit_reached" ->
        Repo.update!(Ecto.Changeset.change(ctx.delivery, retry_cycle: 3), @opts)
    end
  end

  defp with_constraint(table, condition, fun) do
    name = "p33_failure_#{System.unique_integer([:positive])}"
    # Reject new writes without rejecting the history already committed by the scenario.
    Repo.query!(
      "ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{condition}) NOT VALID",
      [],
      @opts
    )

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{name}", [], @opts)
    end
  end

  defp concurrent(ctx, calls, kind) do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    tasks =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, tasks} =
          Repo.transaction(
            fn ->
              hold_barrier(ctx, kind)
              %{rows: [[controller]]} = Repo.query!("SELECT pg_backend_pid()", [], @opts)

              tasks = start_contenders(supervisor, ctx, calls, parent, barrier)
              backends = await_ready(tasks, barrier)
              assert length(Enum.uniq([controller | backends])) == length(tasks) + 1
              Enum.each(tasks, &send(&1.pid, {barrier, :start}))
              await_waiters(backends, System.monotonic_time(:millisecond) + @timeout)
              tasks
            end,
            @opts
          )

        tasks
      end)

    Enum.map(tasks, &Task.await(&1, @timeout))
  end

  defp hold_barrier(ctx, :delivery),
    do: Repo.one!(from(d in Delivery, where: d.id == ^ctx.delivery.id, lock: "FOR UPDATE"), @opts)

  defp hold_barrier(_ctx, :audit),
    do: Repo.query!("LOCK TABLE manual_retry_requests IN SHARE MODE", [], @opts)

  defp hold_barrier(_ctx, :bucket),
    do: Repo.query!("LOCK TABLE manual_retry_rate_limits IN SHARE MODE", [], @opts)

  defp start_contenders(supervisor, ctx, calls, parent, barrier) do
    Enum.map(calls, fn options ->
      Task.Supervisor.async_nolink(supervisor, fn ->
        run_contender(ctx, options, parent, barrier)
      end)
    end)
  end

  defp run_contender(ctx, options, parent, barrier) do
    Sandbox.unboxed_run(Repo, fn ->
      Oban.Testing.with_testing_mode(:manual, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()", [], @opts)
        send(parent, {barrier, self(), backend})

        receive do
          {^barrier, :start} -> request(ctx, :post, options)
        after
          @timeout -> flunk("HTTP contender did not reach start barrier")
        end
      end)
    end)
  end

  defp await_ready(tasks, barrier) do
    Enum.map(tasks, fn task ->
      pid = task.pid
      assert_receive {^barrier, ^pid, backend}, @timeout
      backend
    end)
  end

  defp await_waiters(backends, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM unnest($1::integer[]) AS workers(pid)
        WHERE cardinality(pg_blocking_pids(pid)) > 0
        """,
        [backends],
        @opts
      )

    cond do
      waiting == length(backends) -> :ok
      System.monotonic_time(:millisecond) < deadline -> await_waiters(backends, deadline)
      true -> flunk("HTTP contenders did not reach PostgreSQL lock barrier")
    end
  end

  defp cleanup(project) do
    Sandbox.unboxed_run(Repo, fn ->
      ids = Repo.all(from(d in Delivery, where: d.project_id == ^project.id, select: d.id), @opts)

      Repo.delete_all(
        from(j in Oban.Job, where: fragment("(?->>'delivery_id')::bigint", j.args) in ^ids),
        @opts
      )

      Repo.delete_all(from(r in ManualRetryRequest, where: r.delivery_id in ^ids), @opts)
      Repo.delete_all(from(a in Attempt, where: a.delivery_id in ^ids), @opts)
      Repo.delete_all(from(d in Delivery, where: d.id in ^ids), @opts)
      Repo.delete_all(from(e in Endpoint, where: e.project_id == ^project.id), @opts)
      Repo.delete_all(from(e in Event, where: e.project_id == ^project.id), @opts)

      accounts =
        Repo.all(
          from(a in ServiceAccount, where: a.project_id == ^project.id, select: a.id),
          @opts
        )

      Repo.delete_all(from(c in ApiCredential, where: c.service_account_id in ^accounts), @opts)
      Repo.delete_all(from(a in ServiceAccount, where: a.id in ^accounts), @opts)
      Repo.delete!(project, @opts)
    end)
  end
end

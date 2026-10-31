defmodule Tidewake.Projects.ManualRetryRateLimiterTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Tidewake.ProjectsFixtures, only: [service_account_fixture: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Projects
  alias Tidewake.Projects.{ApiCredential, ManualRetryRateLimit, ManualRetryRateLimiter}
  alias Tidewake.Repo

  @now ~U[2026-10-30 12:00:00.000000Z]
  @opts [log: false, telemetry_event: nil]
  @timeout 10_000
  @admission [:tidewake, :webhooks, :manual_retry, :admission]

  setup tags do
    if tags[:admission_telemetry] do
      handler = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(handler, @admission, &__MODULE__.admission_event/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)
    end

    if tags[:unboxed] do
      identity = Sandbox.unboxed_run(Repo, &service_account_fixture/0)
      on_exit(fn -> cleanup(identity) end)
      identity
    else
      Tidewake.DataCase.setup_sandbox(tags)
      service_account_fixture()
    end
  end

  test "first admission initializes five tokens and commits exactly one consumption", %{
    account: account
  } do
    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed
    assert %ManualRetryRateLimit{tokens: 4, refilled_at: @now} = bucket(account)
    assert Repo.aggregate(ManualRetryRateLimit, :count) == 1
  end

  @tag :admission_telemetry
  test "each allowed or denied call emits exactly one count with only its bounded outcome", %{
    account: account
  } do
    for _ <- 1..5 do
      assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed
      assert_admission("allowed")
    end

    assert bucket(account).tokens == 0
    assert ManualRetryRateLimiter.consume(account.id, @now) == {:denied, 12}
    assert_admission("denied")
    assert bucket(account).tokens == 0
  end

  @tag :admission_telemetry
  test "validation, transaction and persistence failures emit only error without consumption", %{
    account: account
  } do
    for {id, now} <- [{nil, @now}, {account.id, "invalid"}, {9_223_372_036_854_775_807, @now}] do
      assert ManualRetryRateLimiter.consume(id, now) == {:error, :unavailable}
      assert_admission("error")
    end

    assert {:ok, {:error, :unavailable}} =
             Repo.transaction(fn -> ManualRetryRateLimiter.consume(account.id, @now) end)

    assert_admission("error")
    assert bucket(account) == nil

    with_rejected_balance(4, fn ->
      assert ManualRetryRateLimiter.consume(account.id, @now) == {:error, :unavailable}
      assert_admission("error")
      assert bucket(account) == nil
    end)

    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed
    assert_admission("allowed")
    before_failure = bucket(account)

    with_rejected_balance(3, fn ->
      assert ManualRetryRateLimiter.consume(account.id, @now) == {:error, :unavailable}
      assert_admission("error")
      assert bucket(account) == before_failure
    end)
  end

  test "five admissions exhaust capacity and repeated denial leaves zero and the clock intact", %{
    account: account
  } do
    exhaust(account)
    for _ <- 1..3, do: assert(ManualRetryRateLimiter.consume(account.id, @now) == {:denied, 12})
    assert %ManualRetryRateLimit{tokens: 0, refilled_at: @now} = bucket(account)
  end

  test "11.999999 seconds cannot refill a complete token", %{account: account} do
    exhaust(account)
    assert ManualRetryRateLimiter.consume(account.id, at(11_999_999)) == {:denied, 1}
    assert %ManualRetryRateLimit{tokens: 0, refilled_at: @now} = bucket(account)
  end

  test "exactly twelve seconds grants exactly one token", %{account: account} do
    exhaust(account)
    assert ManualRetryRateLimiter.consume(account.id, at(12_000_000)) == :allowed
    assert bucket(account).refilled_at == at(12_000_000)
    assert ManualRetryRateLimiter.consume(account.id, at(12_000_000)) == {:denied, 12}
    assert bucket(account).tokens == 0
  end

  test "multiple intervals preserve the fractional remainder across consumption and denial", %{
    account: account
  } do
    exhaust(account)
    assert ManualRetryRateLimiter.consume(account.id, at(25_000_000)) == :allowed
    assert bucket(account).tokens == 1
    assert bucket(account).refilled_at == at(24_000_000)
    assert ManualRetryRateLimiter.consume(account.id, at(25_000_000)) == :allowed
    assert ManualRetryRateLimiter.consume(account.id, at(35_999_999)) == {:denied, 1}
    assert bucket(account).refilled_at == at(24_000_000)
    assert ManualRetryRateLimiter.consume(account.id, at(36_000_000)) == :allowed
    assert bucket(account).refilled_at == at(36_000_000)
  end

  test "excess refill is discarded at capacity without discarding the time remainder", %{
    account: account
  } do
    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed

    for _ <- 1..5,
        do: assert(ManualRetryRateLimiter.consume(account.id, at(125_000_000)) == :allowed)

    assert bucket(account).refilled_at == at(120_000_000)
    assert bucket(account).tokens == 0
    assert ManualRetryRateLimiter.consume(account.id, at(125_000_000)) == {:denied, 7}
  end

  test "Retry-After rounds microseconds up to positive integer seconds", %{account: account} do
    exhaust(account)

    for {microseconds, seconds} <- [
          {0, 12},
          {1, 12},
          {999_999, 12},
          {1_000_000, 11},
          {10_999_999, 2},
          {11_000_000, 1},
          {11_999_999, 1}
        ] do
      assert ManualRetryRateLimiter.consume(account.id, at(microseconds)) == {:denied, seconds}
    end

    assert bucket(account).tokens == 0
    assert bucket(account).refilled_at == @now
  end

  test "a regressive clock creates no token and never moves refill time backwards", %{
    account: account
  } do
    exhaust(account)
    assert ManualRetryRateLimiter.consume(account.id, at(-1)) == {:denied, 13}
    assert ManualRetryRateLimiter.consume(account.id, at(-12_000_000)) == {:denied, 24}
    assert %ManualRetryRateLimit{tokens: 0, refilled_at: @now} = bucket(account)
    assert ManualRetryRateLimiter.consume(account.id, at(12_000_000)) == :allowed
  end

  test "accounts have independent capacity", %{account: first} do
    %{account: second} = service_account_fixture()
    exhaust(first)
    assert ManualRetryRateLimiter.consume(first.id, @now) == {:denied, 12}
    assert ManualRetryRateLimiter.consume(second.id, @now) == :allowed
    assert bucket(second).tokens == 4
    assert Repo.aggregate(ManualRetryRateLimit, :count) == 2
  end

  test "credential rotation keeps the authenticated account's exhausted bucket", %{
    account: account,
    issued: original
  } do
    {:ok, rotated} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))
    refute original.credential.public_id == rotated.credential.public_id

    for _ <- 1..5 do
      {:ok, %{service_account: identity}} =
        Projects.authenticate_credential(original.token, DateTime.utc_now())

      assert ManualRetryRateLimiter.consume(identity.id, @now) == :allowed
    end

    {:ok, %{service_account: identity}} =
      Projects.authenticate_credential(rotated.token, DateTime.utc_now())

    assert ManualRetryRateLimiter.consume(identity.id, @now) == {:denied, 12}
    assert Repo.aggregate(ManualRetryRateLimit, :count) == 1
  end

  test "default clock uses PostgreSQL UTC time", %{account: account} do
    before_call = database_now()
    assert ManualRetryRateLimiter.consume(account.id) == :allowed
    after_call = database_now()
    stored = bucket(account)
    assert DateTime.compare(stored.refilled_at, before_call) in [:eq, :gt]
    assert DateTime.compare(stored.refilled_at, after_call) in [:eq, :lt]
    assert DateTime.compare(stored.updated_at, stored.refilled_at) in [:eq, :gt]
    assert stored.tokens == 4
  end

  test "an injected UTC instant without fractional precision is stored at microsecond precision",
       %{
         account: account
       } do
    assert ManualRetryRateLimiter.consume(account.id, ~U[2026-10-30 12:00:00Z]) == :allowed
    assert bucket(account).refilled_at == @now
    assert bucket(account).updated_at == @now
  end

  test "nested transactions are refused and a later domain rollback does not refund admission", %{
    account: account
  } do
    assert {:ok, {:error, :unavailable}} =
             Repo.transaction(fn -> ManualRetryRateLimiter.consume(account.id, @now) end)

    assert bucket(account) == nil
    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed
    assert {:error, :domain_failure} = Repo.transaction(fn -> Repo.rollback(:domain_failure) end)
    assert bucket(account).tokens == 4
  end

  test "invalid internal identities and clocks fail closed without creating a bucket", %{
    account: account
  } do
    for id <- [nil, 0, -1, "1", %{}, 9_223_372_036_854_775_808] do
      assert ManualRetryRateLimiter.consume(id, @now) == {:error, :unavailable}
    end

    for now <- ["now", ~N[2026-10-30 12:00:00], %{@now | utc_offset: 3600}] do
      assert ManualRetryRateLimiter.consume(account.id, now) == {:error, :unavailable}
    end

    assert Repo.all(ManualRetryRateLimit) == []
  end

  test "missing account and insert/update persistence failures never allow consumption", %{
    account: account
  } do
    assert ManualRetryRateLimiter.consume(9_223_372_036_854_775_807, @now) ==
             {:error, :unavailable}

    with_rejected_balance(4, fn ->
      assert ManualRetryRateLimiter.consume(account.id, @now) == {:error, :unavailable}
      assert bucket(account) == nil
    end)

    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed
    before_failure = bucket(account)

    with_rejected_balance(3, fn ->
      assert ManualRetryRateLimiter.consume(account.id, @now) == {:error, :unavailable}
      assert bucket(account) == before_failure
    end)

    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed
    assert bucket(account).tokens == 3
  end

  test "database constraints enforce one row, bounded non-null tokens, clock and account FK", %{
    account: account
  } do
    sql = """
    INSERT INTO manual_retry_rate_limits
      (service_account_id, tokens, refilled_at, inserted_at, updated_at)
    VALUES ($1, $2, $3, timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
    """

    for {id, tokens, now, code, constraint} <- [
          {account.id, -1, @now, :check_violation, "manual_retry_rate_limits_tokens_in_range"},
          {account.id, 6, @now, :check_violation, "manual_retry_rate_limits_tokens_in_range"},
          {account.id, nil, @now, :not_null_violation, nil},
          {account.id, 5, nil, :not_null_violation, nil},
          {nil, 5, @now, :not_null_violation, nil},
          {9_223_372_036_854_775_807, 5, @now, :foreign_key_violation,
           "manual_retry_rate_limits_service_account_id_fkey"}
        ] do
      assert {:error, %Postgrex.Error{postgres: error}} =
               Repo.query(sql, [id, tokens, if(now, do: DateTime.to_naive(now))],
                 mode: :savepoint,
                 log: false,
                 telemetry_event: nil
               )

      assert error.code == code
      assert error[:constraint] == constraint
    end

    assert ManualRetryRateLimiter.consume(account.id, @now) == :allowed

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, [account.id, 5, DateTime.to_naive(@now)], mode: :savepoint)

    Repo.delete_all(
      from(credential in ApiCredential, where: credential.service_account_id == ^account.id)
    )

    Repo.delete!(account)
    assert bucket(account) == nil
  end

  test "admission, denial and failure emit no account-correlating logs or query Telemetry", %{
    account: account,
    project: project,
    issued: issued
  } do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:tidewake, :repo, :query], &__MODULE__.query_event/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive :limiter_query_event
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          exhaust(account)
          assert ManualRetryRateLimiter.consume(account.id, @now) == {:denied, 12}

          assert ManualRetryRateLimiter.consume(9_223_372_036_854_775_807) ==
                   {:error, :unavailable}
        end)

      for sensitive <- [
            "manual_retry_rate_limits",
            "service_account_id",
            account.public_id,
            project.public_id,
            issued.token,
            issued.credential.public_id,
            "9223372036854775807"
          ] do
        refute logs =~ sensitive
      end

      refute_received :limiter_query_event
    after
      Logger.configure(level: level)
    end
  end

  @tag :unboxed
  test "concurrent initialization creates one bucket and admits only five of six callers", %{
    account: account
  } do
    results = concurrent_consumption(account, :creation)
    assert Enum.count(results, &(&1 == :allowed)) == 5
    assert Enum.count(results, &(&1 == {:denied, 12})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert bucket(account).tokens == 0
      assert bucket(account).refilled_at == @now
      assert Repo.aggregate(ManualRetryRateLimit, :count, :service_account_id) == 1
    end)
  end

  @tag :unboxed
  test "an existing bucket serializes concurrent refill and decrement under its row lock", %{
    account: account
  } do
    Sandbox.unboxed_run(Repo, fn -> exhaust(account) end)
    results = concurrent_consumption(account, :existing, at(60_000_000))
    assert Enum.count(results, &(&1 == :allowed)) == 5
    assert Enum.count(results, &(&1 == {:denied, 12})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert bucket(account).tokens == 0
      assert bucket(account).refilled_at == at(60_000_000)
    end)
  end

  def query_event(_event, _measurements, _metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, :limiter_query_event)
  end

  def admission_event(_event, measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:admission, measurements, metadata})
  end

  defp assert_admission(outcome) do
    measurements = %{count: 1}
    metadata = %{outcome: outcome}
    assert_received {:admission, ^measurements, ^metadata}
    refute_received {:admission, _, _}
  end

  defp exhaust(account) do
    for _ <- 1..5, do: assert(ManualRetryRateLimiter.consume(account.id, @now) == :allowed)
  end

  defp bucket(account), do: Repo.get(ManualRetryRateLimit, account.id, @opts)
  defp at(microseconds), do: DateTime.add(@now, microseconds, :microsecond)

  defp database_now do
    %{rows: [[now]]} = Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], @opts)
    DateTime.from_naive!(now, "Etc/UTC")
  end

  defp with_rejected_balance(tokens, fun) do
    name = "limiter_failure_#{System.unique_integer([:positive])}"

    Repo.query!(
      "ALTER TABLE manual_retry_rate_limits ADD CONSTRAINT #{name} CHECK (tokens <> #{tokens})"
    )

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE manual_retry_rate_limits DROP CONSTRAINT #{name}")
    end
  end

  defp concurrent_consumption(account, kind, now \\ @now) do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    tasks =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            hold_barrier(account, kind)
            %{rows: [[controller]]} = Repo.query!("SELECT pg_backend_pid()")
            tasks = start_contenders(supervisor, account, now, parent, barrier)
            backends = await_ready(tasks, barrier)
            assert length(Enum.uniq([controller | backends])) == 7
            Enum.each(tasks, &send(&1.pid, {barrier, :start}))
            await_waiters(backends, System.monotonic_time(:millisecond) + @timeout)
            tasks
          end)

        tasks
      end)

    Enum.map(tasks, &Task.await(&1, @timeout))
  end

  defp hold_barrier(_account, :creation) do
    Repo.query!("LOCK TABLE manual_retry_rate_limits IN SHARE MODE")
  end

  defp hold_barrier(account, :existing) do
    Repo.one!(
      from(b in ManualRetryRateLimit,
        where: b.service_account_id == ^account.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp start_contenders(supervisor, account, now, parent, barrier) do
    for _ <- 1..6 do
      Task.Supervisor.async_nolink(supervisor, fn ->
        run_consumption(account, now, parent, barrier)
      end)
    end
  end

  defp run_consumption(account, now, parent, barrier) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(parent, {barrier, :ready, self(), backend})

      receive do
        {^barrier, :start} -> ManualRetryRateLimiter.consume(account.id, now)
      after
        @timeout -> flunk("limiter contender did not reach start barrier")
      end
    end)
  end

  defp await_ready(tasks, barrier) do
    Enum.map(tasks, fn task ->
      pid = task.pid
      assert_receive {^barrier, :ready, ^pid, backend}, @timeout
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
        [backends]
      )

    cond do
      waiting == length(backends) -> :ok
      System.monotonic_time(:millisecond) < deadline -> await_waiters(backends, deadline)
      true -> flunk("limiter contenders did not reach the PostgreSQL lock barrier")
    end
  end

  defp cleanup(%{account: account, project: project}) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(c in ApiCredential, where: c.service_account_id == ^account.id))
      Repo.delete!(account)
      Repo.delete!(project)
    end)
  end
end

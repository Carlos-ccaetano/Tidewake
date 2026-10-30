defmodule Tidewake.Webhooks.ProjectOwnershipMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Postgres
  alias Tidewake.{Projects, Repo, Webhooks}

  @version 20_261_030_074_028
  @previous_version 20_261_027_071_753
  @opts [log: false, telemetry_event: nil]
  @tables ~w(projects endpoints events deliveries delivery_attempts manual_retry_requests oban_jobs)

  @tag timeout: 120_000
  test "isolated PostgreSQL up/down/up preserves history and unsafe down never changes data" do
    database =
      "tidewake_ownership_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"

    config =
      Repo.config() |> Keyword.drop([:url, :pool, :name]) |> Keyword.put(:database, database)

    assert :ok = Postgres.storage_up(config)

    try do
      pid =
        start_supervised!(
          {Repo, [name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 4]}
        )

      previous = Repo.put_dynamic_repo(pid)

      try do
        migrations = migration_modules()

        assert @previous_version in Ecto.Migrator.run(Repo, migrations, :up,
                 to: @previous_version,
                 log: false
               )

        seed_legacy_history()
        before = snapshot()

        assert [@version] == Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
        assert snapshot() == before
        assert_legacy_backfill()
        assert_composite_constraints()

        assert [@version] == Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)
        assert snapshot() == before

        assert %{rows: [[true]]} =
                 Repo.query!(
                   """
                   SELECT to_regclass('events_external_id_index') IS NOT NULL
                   """,
                   [],
                   @opts
                 )

        assert %{rows: [[0]]} =
                 Repo.query!(
                   """
                   SELECT count(*) FROM information_schema.columns
                   WHERE table_schema = 'public' AND column_name = 'project_id'
                     AND table_name IN ('endpoints','events','deliveries')
                   """,
                   [],
                   @opts
                 )

        assert [@version] == Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
        assert snapshot() == before
        assert_legacy_backfill()
        assert_composite_constraints()

        {:ok, project} = Projects.create_project(%{name: "New owner", slug: "new-owner"})

        {:ok, _} =
          Webhooks.create_endpoint(project, %{
            name: "New consumer",
            url: "https://endpoint.invalid/webhook"
          })

        before_unsafe_down = snapshot()

        error =
          assert_raise Postgrex.Error, fn ->
            Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)
          end

        assert error.postgres.message =~ "non-legacy resources would lose ownership"
        assert snapshot() == before_unsafe_down
        assert_composite_constraints()

        {:ok, _} =
          Webhooks.create_event(project, %{
            external_id: "preserved-event",
            event_type: "order.created",
            payload: %{}
          })

        before_duplicate_down = snapshot()

        error =
          assert_raise Postgrex.Error, fn ->
            Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)
          end

        assert error.postgres.message =~ "duplicate external_id across projects"
        assert snapshot() == before_duplicate_down
        assert_composite_constraints()
        assert @version in Ecto.Migrator.migrated_versions(Repo)
      after
        Repo.put_dynamic_repo(previous)
        :ok = stop_supervised(Repo)
      end
    after
      # This exact database was created above solely for this test.
      assert :ok = Postgres.storage_down(config)
    end
  end

  defp migration_modules do
    for path <- Path.wildcard("priv/repo/migrations/*.exs") do
      [version, _name] = path |> Path.basename() |> String.split("_", parts: 2)

      {:defmodule, _, [{:__aliases__, _, parts}, _body]} =
        path |> File.read!() |> Code.string_to_quoted!()

      module = Module.concat(parts)
      unless Code.ensure_loaded?(module), do: Code.require_file(path)
      {String.to_integer(version), module}
    end
  end

  defp seed_legacy_history do
    endpoint =
      insert_id("""
      INSERT INTO endpoints (name, url, active, inserted_at, updated_at)
      VALUES ('Preserved consumer','https://endpoint.invalid/',true,now(),now()) RETURNING id
      """)

    event =
      insert_id("""
      INSERT INTO events (external_id,event_type,payload,inserted_at,updated_at)
      VALUES ('preserved-event','order.created','{"order":42}',now(),now()) RETURNING id
      """)

    delivery =
      insert_id(
        """
        INSERT INTO deliveries
          (event_id,endpoint_id,status,attempt_count,cycle_attempt_count,completed_at,inserted_at,updated_at)
        VALUES ($1,$2,'failed',1,1,now(),now(),now()) RETURNING id
        """,
        [event, endpoint]
      )

    Repo.query!(
      """
      INSERT INTO delivery_attempts
        (delivery_id,attempt_number,retry_cycle,cycle_attempt_number,result,duration_ms,
         started_at,completed_at,inserted_at,updated_at)
      VALUES ($1,1,0,1,'transport_error',0,now(),now(),now(),now())
      """,
      [delivery],
      @opts
    )

    Repo.query!(
      """
      INSERT INTO manual_retry_requests
        (delivery_id,actor_type,actor_subject,source,idempotency_key_digest,request_fingerprint,
         requested_at,outcome,reason,observed_status,observed_attempt_count,observed_retry_cycle,inserted_at)
      VALUES ($1,'service_account','preserved-actor','admin_cli',repeat('1',64),repeat('2',64),
        now(),'rejected','endpoint_inactive','failed',1,0,now())
      """,
      [delivery],
      @opts
    )

    Repo.query!(
      """
      INSERT INTO oban_jobs (queue,worker,args)
      VALUES ('webhooks','Tidewake.Workers.DeliverWebhookWorker',
        jsonb_build_object('delivery_id',$1::bigint,'attempt_number',2,'retry_cycle',0,'cycle_attempt_number',2))
      """,
      [delivery],
      @opts
    )
  end

  defp insert_id(sql, params \\ []) do
    %{rows: [[id]]} = Repo.query!(sql, params, @opts)
    id
  end

  defp snapshot do
    Map.new(@tables, fn table ->
      result =
        Repo.query!(
          "SELECT to_jsonb(row) - 'project_id' FROM #{table} row ORDER BY id",
          [],
          @opts
        )

      {table, result.rows}
    end)
  end

  defp assert_legacy_backfill do
    for table <- ~w(endpoints events deliveries) do
      assert %{rows: [[1, 1]]} =
               Repo.query!("SELECT count(*), min(project_id) FROM #{table}", [], @opts)
    end
  end

  defp assert_composite_constraints do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT conrelid::regclass::text, conname, pg_get_constraintdef(oid)
        FROM pg_constraint WHERE conname IN
          ('deliveries_event_id_fkey','deliveries_endpoint_id_fkey',
           'endpoints_project_id_fkey','events_project_id_fkey','deliveries_project_id_fkey')
        ORDER BY conname
        """,
        [],
        @opts
      )

    assert length(rows) == 5
    for [_table, _name, definition] <- rows, do: assert(definition =~ "ON DELETE RESTRICT")

    assert [
             "deliveries",
             "deliveries_event_id_fkey",
             "FOREIGN KEY (event_id, project_id) REFERENCES events(id, project_id) ON UPDATE RESTRICT ON DELETE RESTRICT"
           ] in rows

    assert [
             "deliveries",
             "deliveries_endpoint_id_fkey",
             "FOREIGN KEY (endpoint_id, project_id) REFERENCES endpoints(id, project_id) ON UPDATE RESTRICT ON DELETE RESTRICT"
           ] in rows
  end
end

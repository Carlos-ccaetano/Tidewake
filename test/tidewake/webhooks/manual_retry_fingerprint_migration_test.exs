defmodule Tidewake.Webhooks.ManualRetryFingerprintMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Postgres
  alias Tidewake.Repo

  @version 20_261_030_102_400
  @previous_version 20_261_030_074_028
  @opts [log: false, telemetry_event: nil]
  @key_digest "9f9f5111f7b27a781f1f1ddde5ebc2dd2b796bfc7365c9c28b548e564176929f"
  @fingerprint "0fe2dcd3794dfdea5de12991a804a28827e350fa34d97f4af8dd0cf7f25aee86"

  @tag timeout: 120_000
  test "isolated up/down/up labels v1 without rewriting history and guards v2 rollback" do
    database =
      "tidewake_fingerprint_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"

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

        seed_history()
        before = history()
        index = actor_index()
        assert length(before) == 2

        for _pass <- [1, 2] do
          assert [@version] == Ecto.Migrator.run(Repo, migrations, :up, to: @version, log: false)
          assert history() == before
          assert actor_index() == index

          assert %{rows: [[1], [1]]} =
                   Repo.query!(
                     "SELECT request_fingerprint_version FROM manual_retry_requests ORDER BY id",
                     [],
                     @opts
                   )

          assert %{rows: [["smallint", "NO", nil]]} =
                   Repo.query!(
                     """
                     SELECT data_type, is_nullable, column_default FROM information_schema.columns
                     WHERE table_schema = 'public' AND table_name = 'manual_retry_requests'
                       AND column_name = 'request_fingerprint_version'
                     """,
                     [],
                     @opts
                   )

          assert [@version] == Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)
          assert history() == before
        end

        assert [@version] == Ecto.Migrator.run(Repo, migrations, :up, to: @version, log: false)

        for {value, expected_code} <- [
              {nil, :not_null_violation},
              {0, :check_violation},
              {3, :check_violation}
            ] do
          error =
            assert_raise Postgrex.Error, fn ->
              Repo.query!(
                "UPDATE manual_retry_requests SET request_fingerprint_version = $1",
                [value],
                @opts
              )
            end

          assert error.postgres.code == expected_code

          if value,
            do:
              assert(
                error.postgres.constraint ==
                  "manual_retry_requests_request_fingerprint_version_allowed"
              )

          assert history() == before
        end

        # No default may let an old writer silently create new unversioned evidence.
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.query!(
              """
              INSERT INTO manual_retry_requests
                (delivery_id,actor_type,actor_subject,source,idempotency_key_digest,request_fingerprint,
                 requested_at,outcome,reason,observed_status,observed_attempt_count,
                 observed_retry_cycle,inserted_at)
              SELECT delivery_id,actor_type,'unversioned-writer',source,idempotency_key_digest,
                request_fingerprint,requested_at,outcome,reason,observed_status,observed_attempt_count,
                observed_retry_cycle,inserted_at FROM manual_retry_requests ORDER BY id LIMIT 1
              """,
              [],
              @opts
            )
          end

        assert error.postgres.code == :not_null_violation
        assert history() == before

        Repo.query!(
          """
          INSERT INTO manual_retry_requests
            (delivery_id,actor_type,actor_subject,source,idempotency_key_digest,request_fingerprint,
             request_fingerprint_version,requested_at,outcome,reason,observed_status,
             observed_attempt_count,observed_retry_cycle,inserted_at)
          SELECT delivery_id,actor_type,'v2-writer',source,idempotency_key_digest,repeat('3',64),
            2,requested_at,outcome,reason,observed_status,observed_attempt_count,
            observed_retry_cycle,inserted_at FROM manual_retry_requests ORDER BY id LIMIT 1
          """,
          [],
          @opts
        )

        after_v2 = history()

        error =
          assert_raise Postgrex.Error, fn ->
            Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)
          end

        assert error.postgres.message =~ "version 2 audit evidence exists"
        assert history() == after_v2
        assert actor_index() == index
        assert @version in Ecto.Migrator.migrated_versions(Repo)

        assert %{rows: [[1], [1], [2]]} =
                 Repo.query!(
                   "SELECT request_fingerprint_version FROM manual_retry_requests ORDER BY id",
                   [],
                   @opts
                 )
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

  defp seed_history do
    Repo.query!(
      """
      INSERT INTO endpoints (project_id,name,url,active,inserted_at,updated_at)
      VALUES (1,'Preserved consumer','https://endpoint.invalid/',true,now(),now())
      """,
      [],
      @opts
    )

    Repo.query!(
      """
      INSERT INTO events (project_id,external_id,event_type,payload,inserted_at,updated_at)
      VALUES (1,'preserved-event','order.created','{}',now(),now())
      """,
      [],
      @opts
    )

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO deliveries
          (project_id,event_id,endpoint_id,status,attempt_count,completed_at,inserted_at,updated_at)
        VALUES (1,1,1,'failed',0,now(),now(),now()) RETURNING id
        """,
        [],
        @opts
      )

    assert id == 1

    for digest <- [@key_digest, String.duplicate("a", 64)] do
      Repo.query!(
        """
        INSERT INTO manual_retry_requests
          (delivery_id,actor_type,actor_subject,source,idempotency_key_digest,request_fingerprint,
           requested_at,outcome,reason,observed_status,observed_attempt_count,
           observed_retry_cycle,inserted_at)
        VALUES ($1,'service_account','historical-actor','admin_cli',$2,$3,
          now(),'rejected','endpoint_inactive','failed',0,0,now())
        """,
        [id, digest, @fingerprint],
        @opts
      )
    end
  end

  defp history do
    Repo.query!(
      """
      SELECT to_jsonb(row) - 'request_fingerprint_version'
      FROM manual_retry_requests row ORDER BY id
      """,
      [],
      @opts
    ).rows
  end

  defp actor_index do
    Repo.query!(
      """
      SELECT indexdef FROM pg_indexes WHERE schemaname = 'public'
        AND indexname = 'manual_retry_requests_actor_idempotency_key_index'
      """,
      [],
      @opts
    ).rows
  end
end

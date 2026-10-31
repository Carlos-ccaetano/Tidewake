# Authenticated API migration and cutover

This is an operator checklist and a local recovery rehearsal, not evidence of a production rollout. Read the [authentication/rotation workflow](../api/authentication.md) and [manual retry contract](../api/manual-retries.md) first. Keep deployment approval, secrets and private backup locations outside GitHub.

## Entry and stop conditions

- Record the reviewed commit, successful CI, PostgreSQL/client versions, current migration status, responsible operator, maintenance window, recovery objective and decision owner. Rehearse against the actual pre-upgrade schema before approving a production change.
- Approve the deployment topology, API TLS including proxy hops, database transport, network access, secret-manager versions and database roles. `config/runtime.exs` does not itself enable database SSL; an HTTPS public URL does not establish TLS on every hop.
- Verify independent backups, encrypted storage, access controls and a successful isolated restore. A custom-format archive is compressed, **not encrypted**. Payloads, identity, credential digests and audit history remain sensitive.
- Keep the original credential pepper available through the secret manager separately from the database backup. Restored digests require the matching pepper; they cannot recover a client token. Verify the distinct webhook signing secret and `SECRET_KEY_BASE` too. Do not print credentials or paste database URLs, payloads, raw idempotency keys or digests into evidence.
- Stop on an unknown source/target, failed restore, missing secret, unexpected migration, unresolved lock, ownership mismatch or failed authorization check. Set environment-specific lock/time budgets and abort criteria before the window; do not guess universal values.

**Repo-only provisioning:** the [shared runner](../../lib/mix/tasks/tidewake.provisioning.ex) loads runtime configuration and uses `Ecto.Migrator.with_repo` instead of starting the Tidewake application. The six operational tasks do not start HTTP, Oban queues or recovery cron. A temporary Repo is stopped after success/failure; an existing Repo is reused and left running. This isolates the CLI process, not other deployments: operators must still quiesce every existing writer and verify the deployment-specific execution path. The test configuration used in the recovery rehearsal below disables queues/plugins and the HTTP server.

## Cutover order

1. Inventory schema versions, projects/accounts/credentials, ownership, events/endpoints/deliveries, attempts, audit versions, rate-limit rows and Oban work. Record counts and invariant results privately; use synthetic markers for smoke tests.
2. Quiesce API writes and all old/new worker instances, recovery cron and other writers. Drain or reconcile in-flight work before taking the cutover snapshot. An outbound request with an unrecorded result may already have affected its receiver: database recovery cannot undo it. Preserve at-least-once expectations.
3. Take a full database archive and restore it into a **new, distinct, empty** database with workers and HTTP stopped. Compare data, sequence values, migration versions, constraints and application reads. Plan roles/extensions/privileges separately: a single-database dump does not include cluster roles. The local example below deliberately skips ownership/ACL restoration; production permissions need explicit verification.
4. In the approved maintenance environment, inspect `mix help ecto.migrations` and `mix help ecto.migrate`, then capture `mix ecto.migrations`, run `mix ecto.migrate`, and inspect status again. These are Mix source-checkout commands, not a release deployment wrapper. Never run `ecto.reset` against retained data. Ownership and fingerprint migrations take `ACCESS EXCLUSIVE` locks; keep writers stopped and inspect blockers within the approved budget.
5. Verify the recorded legacy project (`id=1`, slug `legacy`, public UUID `00000000-0000-4000-8000-000000000001`) and preserved history. Existing resources belong to it; creating a new project does not move them. Confirm required ownership references, composite cross-project constraints and project-local event identity. Historical audit fingerprints stay byte-for-byte v1; new API decisions use v2.
6. Through the approved isolated provisioning path, follow the existing authentication workflow: provision the intended project/account/role, issue an expiring credential, transfer it through the secret channel, verify it, then rotate/revoke or disable deliberately. Credential overlap preserves account identity and bucket capacity. Do not change the pepper as ordinary token rotation or reintroduce `TIDEWAKE_API_TOKEN`.
7. Before admitting ordinary writes, verify uniform invalid/missing-token 401, role 403, indistinguishable foreign/absent-resource 404, project-local ingestion/reads and admin retry POST/replay/GET. Check `no-store`, unchanged historical attempts, one accepted audit/job, v1/v2 coexistence and account admission. Use disposable synthetic resources; a retry POST is a durable command, not a harmless connectivity probe.
8. Resume approved instances and traffic gradually. Check application/queue health, bounded delivery/recovery metrics, error rates and receiver outcomes against the agreed thresholds. Stop admission if they fail. Record observations and owner sign-off without sensitive identifiers. This document does not install a metrics reporter or external alerts.

## Failure and recovery decisions

Prefer a reviewed forward fix with writers held. Do not assume an older binary can safely write the migrated schema. The [ownership migration](../../priv/repo/migrations/20261030074028_scope_webhook_resources_by_project.exs) refuses unsafe down migration with non-legacy resources or conflicting cross-project external IDs. The [fingerprint migration](../../priv/repo/migrations/20261030102400_version_manual_retry_fingerprints.exs) refuses down migration when v2 rows exist. Do not remove those guards, rewrite v1 evidence, delete audit/job history or restore static authentication to make rollback succeed.

If recovery requires a backup, restore to a new isolated database first. The decision owner must reconcile all writes and possible outbound effects since the snapshot before approving a database switch. A restore can lose accepted events, credential revocations and audit decisions; validate current access authority before resuming. Keep the failed database for investigation under the approved data policy. No automatic destructive rollback or retention cleanup is supplied here.

## Local disposable rehearsal

Use PostgreSQL 16 clients, the repository's Elixir/OTP versions and existing dependencies. These POSIX-shell examples are **local only**; supply the local password from your environment, not shell history. Run in the repository with no other process using these generated names. Read `mix help ecto.create` before creating storage.

```sh
set -eu
unset PHX_SERVER
unset PGSERVICE PGOPTIONS
export MIX_ENV=test
export POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 POSTGRES_USER=postgres
: "${POSTGRES_PASSWORD:?supply the local disposable database password}"
export POSTGRES_PASSWORD
export PGHOST="$POSTGRES_HOST" PGPORT="$POSTGRES_PORT"
export PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"
run_id=$(date +%Y%m%d%H%M%S)
export MIX_TEST_PARTITION="_rollout_source_$run_id"
source_db="tidewake_test$MIX_TEST_PARTITION"
restore_db="tidewake_test_rollout_restore_$run_id"
existing=$(psql -X -v ON_ERROR_STOP=1 -At --dbname=postgres \
  -c "SELECT count(*) FROM pg_database WHERE datname IN ('$source_db', '$restore_db')")
test "$existing" = 0
mix ecto.create
mix ecto.migrate
mix ecto.migrations
```

Populate only that source with synthetic fixtures in `MIX_ENV=test`, asserting the configured database and disabled server/Oban queues/plugins first. Use manual Oban testing mode so accepted jobs remain persisted. The [HTTP regressions](../../test/tidewake_web/controllers/manual_retry_request_controller_test.exs) show the fixture, acceptance and replay assertions; [fixtures](../../test/support/webhooks_fixtures.ex) provide a historical v1 record. Keep issued tokens in memory. Close the source application before copying. An empty database restore alone does not exercise recovery of business data.

```sh
umask 077
backup_dir=$(mktemp -d)
archive="$backup_dir/tidewake.dump"
pg_dump --version
pg_restore --version
pg_dump --format=custom --file="$archive" --dbname="$source_db"
pg_restore --list "$archive" >"$backup_dir/contents.txt"
createdb --template=template0 "$restore_db"
pg_restore --exit-on-error --single-transaction --no-owner --no-privileges \
  --dbname="$restore_db" "$archive"
export MIX_TEST_PARTITION="_rollout_restore_$run_id"
mix ecto.migrations
```

Before further writes, compare every application table and sequence privately against the held source. Confirm constraints/indexes and v1/v2 bytes as well as counts; a table-of-contents listing is not a full integrity check. Against the restored database, issue a **new** synthetic credential in memory, verify authentication, read historical audit and replay the same account's key without another audit/job. Verify GET does not spend the POST bucket. Exercise authorization and non-disclosure checks without starting a listener or network delivery. This does not establish real TLS/proxy behavior or recovery-time performance.

Run `mix test test/tidewake/webhooks/project_ownership_migration_test.exs test/tidewake/webhooks/manual_retry_fingerprint_migration_test.exs` for the existing isolated pre-upgrade up/down/up and refusal checks. Afterward, unset `MIX_TEST_PARTITION` and run the required `mix precommit`. Remove only the two verified disposable databases and the rehearsal's own local artifacts after recording results; never apply cleanup to an existing user database.

Archive/restore flags and limitations: [PostgreSQL 16 pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html) and [pg_restore](https://www.postgresql.org/docs/16/app-pgrestore.html).

## Recorded local evidence (2026-10-31)

- Application baseline `80452dc19b13dac3dd34377253bc2b5736831ada`; native Elixir 1.19.5/OTP 28, local PostgreSQL/client 16.15. Two previously absent databases, `tidewake_test_rollout_source_20261031` and `tidewake_test_rollout_restore_20261031`, were created for synthetic data only. No production or Ironhold data was used.
- All 16 migrations were up through `20261031080259`. Custom dump, archive listing and single-transaction restore completed without warnings. Private canonical row comparisons matched across all 12 public tables; all public sequence values matched too.
- All 61 constraint identities and index definitions were preserved. Twelve CHECK definitions deparsed differently after restore: array casts became element casts, or nested AND expressions were flattened. These representations were reviewed; do not mistake their text for byte-identical schema output.
- Before post-restore writes: 2 projects (including legacy), 1 account, 2 overlapping credentials, 1 endpoint/event/delivery/attempt each, 2 audit rows (v1/v2), 1 bucket and 1 pending job. Source POST/replay/GET and authentication passed. Restored checks passed with a newly issued credential: 401/403/scoped 404, no-store, historical GET without admission, replay without new audit/job and preserved lifetime/cycle counters. The original raw tokens were not retained or authenticated after restore.
- The first post-restore harness attempt omitted the content-type required by Phoenix test dispatch; adding it to the temporary harness made the checks pass. No application correction was needed. Synthetic assertion harnesses are not a production load, failover or deployment test.
- Migration regressions: 2 tests, 0 failures (seed 455504). Required `mix precommit`: 1,011 tests, 0 failures (seed 71542), format/compile/unused-lock/Credo checks passed. Sobelow retained 49 quoted-keyword parser warnings and the previously recorded low-confidence CSP finding; compilation produced no warnings. Final PR CI evidence belongs in the PR, since it is available only after publication.
- Relative links, shell-example syntax and diff whitespace checks passed. Both disposable databases and their private backup/comparison artifacts were removed after verification; the existing development/test databases were not used for the rehearsal.

This rehearsal establishes a small local recovery baseline. Production-wide quiescence, deployment-specific restore permissions/TLS, recovery objectives under real load, monitoring/alerts and a pre-upgrade production-like rehearsal remain separate gates.

# Local Tidewake–Ironhold demonstration

This is a synthetic development rehearsal with two real HTTP servers and two separate PostgreSQL databases. It is not a production deployment, load test or availability claim. See the [architecture diagram](../architecture.md#tidewakeironhold-delivery-and-trust-boundaries) and [receiver contract](https://github.com/Carlos-ccaetano/Ironhold/blob/main/docs/api/webhooks.md).

## Prerequisites

- Tidewake main including PR #276; a separate clean Ironhold checkout. Record both revisions with `git rev-parse HEAD` before presenting.
- Python 3.10+, Git, PostgreSQL 16 on localhost, and Elixir/Mix on PATH. Tidewake pins Elixir 1.19.5 / OTP 28.4; Ironhold pins Elixir 1.18 / OTP 27.3. The evidence below states the actual shared runtime used, rather than claiming both pinned combinations were exercised.
- A disposable local PostgreSQL role able to create databases. The harness uses each application's local development connection settings. It refuses DATABASE_URL configuration and non-loopback hosts. Never supply production credentials. A local native PostgreSQL or Linux/WSL service is sufficient; Docker Desktop is not required.
- Free loopback ports **42630** (Tidewake) and **42631** (Ironhold). No external HTTP receiver, paid service or cloud account is required. Dependency installation still needs network access unless cached.

Install locked dependencies once in each checkout:

```sh
# In Tidewake, then repeat inside Ironhold.
mix deps.get --check-locked
```

Do not run `mix setup`: this rehearsal creates and migrates new databases itself and does not need browser assets. Do not run both projects against an existing shared development database. Keep populated .env files outside Git; this procedure creates none.

## One command, two services

From the Tidewake checkout, run:

```sh
python3 docs/demo/run.py /absolute/path/to/Ironhold
```

On Windows, use `python` instead of `python3` if appropriate. Paths containing spaces are supported. On a Windows/OneDrive host, use separate writable temporary caches if dependency updates/builds cannot write to the checkout:

```powershell
$env:MIX_DEPS_PATH = Join-Path $env:TEMP 'tidewake-demo-deps'
$env:MIX_BUILD_PATH = Join-Path $env:TEMP 'tidewake-demo-build'
$env:IRONHOLD_MIX_DEPS_PATH = Join-Path $env:TEMP 'ironhold-demo-deps'
$env:IRONHOLD_MIX_BUILD_PATH = Join-Path $env:TEMP 'ironhold-demo-build'
```

Install locked dependencies using the matching cache for each repository before running the command. These are per-shell overrides, not global settings. Alternatively use clean checkouts in a Linux/WSL home directory, PostgreSQL 16 and the same Python command. The Windows evidence below and the Linux CI gate described below are distinct validation records.

The [driver](run.py) starts `mix run --no-start docs/demo/local.exs receiver` in Ironhold and the same [documentation harness](local.exs) with role `sender` in Tidewake, using the absolute script path. There is no copied Ironhold code or versioned Ironhold modification. Both services run in `MIX_ENV=dev`, on loopback only. Runtime overrides apply only inside these child processes; source configuration is unchanged.

The driver generates one random disposable signing secret and sends it over stdin pipes to both children. The Tidewake process generates its own random credential pepper and issues a one-hour admin credential through the existing Projects functions. Tokens and signing material remain in memory: no secret is passed as a process argument, written to a file, printed or placed in OS environment variables. Never enable shell tracing, dump environments, inspect process command lines, print raw exception/request objects or use curl verbose/trace output while presenting.

Application output is redacted; harness `DEMO` records and sanitized warning notifications are displayed. Failures report a bounded stage instead of exceptions that might contain headers. Warnings are counted without printing potentially sensitive text. CI compiles both projects with `--warnings-as-errors` before starting the harness; the filtered transcript alone does not establish a warning-free build.

## What the command verifies

Each run uses a random suffix and creates `tidewake_demo263_<suffix>` and `ironhold_demo263_<suffix>`. An existing database causes failure instead of reuse. The harness starts Ironhold first, waits for explicit readiness over its output pipe, then starts Tidewake. There are no arbitrary synchronization sleeps.

| Step | Real operation and assertion |
| --- | --- |
| Provision | Create a synthetic project and admin account using Projects; issue a disposable credential only after commit. No credential-management HTTP API is invented. |
| Authentication | POST `/api/events` without a credential returns `401`. |
| Destination | Authenticated POST `/api/endpoints` registers `http://127.0.0.1:42631/api/webhooks`, returning `201`. The existing development-only outbound HTTP and local-target options are enabled. |
| Ingest | Authenticated POST `/api/events` with synthetic ID/type/data returns `201`; duplicate ingestion returns `409`. |
| Durable work | Before execution, SQL observes exactly one event, delivery and DeliverWebhookWorker job. The existing ingestion Ecto.Multi commits these together. Duplicate ingestion adds no work. |
| Execute | Automatic queue execution/plugins are disabled **only for this isolated rehearsal**, so the pre-delivery records can be inspected. `Oban.drain_queue(queue: :default)` runs the real worker, processor, signer, resolver and Req adapter over an actual TCP/HTTP connection. No Req.Test stub or deterministic adapter is used. |
| Acknowledge | Tidewake records HTTP `202`, one attempt and `succeeded`; authenticated delivery-status GET returns `200`. Ironhold's accepted response follows HMAC/timestamp/ID verification and its database transaction. |
| Legitimate resend | Encode the same immutable event with Envelope, sign with Signature and POST the exact bytes directly to Ironhold: `202`. The explicit timestamp is current time +10 seconds, within the documented +30-second window, to guarantee distinct signing material without sleeping. This is a contract exercise, not the production worker's clock policy. |
| Exact replay | Send that same body and signing headers again: `409`. |
| Negative verification | A correctly signed expired timestamp, an invalid HMAC and a payload altered after signing each return `401`. |
| Persisted result | SQL against Ironhold confirms **one received event and two replay claims**, with no extra claims for rejected requests. |
| Retirement | Revoke the disposable Tidewake credential in an `after` block, then stop both applications. |

The additional signed resend is **not** an administrative Delivery manual retry. It creates no Tidewake attempt, job, cycle or manual retry audit row. Manual retry POST requires current project/admin authority, admission, an Idempotency-Key and an eligible failed delivery with an active endpoint and remaining manual cycle budget. This demo's delivery has succeeded and must not be forced into eligibility. See [manual retry and audit](../api/manual-retries.md).

## Evidence

Executed on 2026-11-02 from Tidewake base `907b86f20dca8e107d56a78053030ad95bdedbff` (PR #275 integrated), with read-only Ironhold checkout `def10d875b0acdb9a88f8fefef3e18c704f2d9f8`. Native Windows Elixir 1.19.5 / OTP 28 (ERTS 16.2.2) connected to PostgreSQL 16 in WSL; separate temporary dependency/build caches avoided OneDrive writes. Both checkouts retained clean versioned Ironhold files. This shared runtime is newer than Ironhold's pinned OTP 27 runtime.

Command executed from Tidewake (with the documented cache overrides pointing to existing locked caches):

```powershell
python docs/demo/run.py '..\Ironhold'
```

The first launcher attempt failed before readiness because Windows `.bat` paths needed command wrapping. The corrected driver completed twice, with independently created database pairs ending `936a7f847597` and `1e6fb0a85311`. The final run printed this allowlisted transcript:

```text
DEMO receiver READY
DEMO ingestion: unauthorized=401 endpoint=201 event=201 duplicate=409; event/delivery/job=1/1/1 before drain
DEMO worker: real HTTP=202; delivery=succeeded attempts=1; status GET=200
DEMO receiver: fresh=202 exact_replay=409 expired=401 invalid_HMAC=401; events/claims=1/2
DEMO credential revoked
DEMO sender STOPPED; retained database tidewake_demo263_1e6fb0a85311
DEMO receiver STOPPED; retained database ironhold_demo263_1e6fb0a85311
DEMO PASS: isolated rehearsal; databases retained; no secrets printed
```

Each line after readiness is emitted only after the corresponding assertions pass. The helper is an assert-based self-check, not a simulated output generator. The observed first receiver `202` is persisted in Tidewake's attempt, and the final receiver counts are queried directly from PostgreSQL. No screenshot/video, automatic transient-failure retry, stale recovery, manual retry execution, concurrent load, TLS or production behavior is claimed. The queues are drained explicitly to make the pre-execution persistence inspection reproducible. Existing unit/integration tests remain complementary evidence, not a substitute for this real run.

## Continuous integration

The separate `ironhold-integration` job in [CI](../../.github/workflows/ci.yml) runs on Linux with its own PostgreSQL 16 service container. It checks out Ironhold at **`4c97c8e91f3a04a57e6cd5c6ebd7686c03f08363`**, with Git credentials not persisted, and verifies HEAD matches that complete SHA. Each project installs its own locked dependencies. No production environment or personal credential is used.

The integration intentionally uses one shared **Elixir 1.19.5 / OTP 28.4** runtime. Tidewake requires `~> 1.19`; Ironhold declares `~> 1.18` (which admits 1.19), but its `.tool-versions` pins Elixir 1.18 / OTP 27.3. Compatibility is checked by compiling Ironhold without warnings, running its complete test suite on the shared runtime and executing the real HTTP contract. This job does **not** certify every permitted Elixir version or replace Ironhold's own OTP 27 CI. Runtime and dependency upgrades require rerunning these gates.

After precompilation, CI runs:

```sh
python3 -O docs/demo/test_run.py RunnerTests
python3 -O docs/demo/run.py .integration/ironhold
IRONHOLD_CHECKOUT=.integration/ironhold python3 -O docs/demo/test_run.py ContractFailureTest
```

To reproduce, substitute your prepared Ironhold checkout path. `-O` deliberately disables Python assertions; critical path, runtime and completion checks use explicit failures and remain effective. Elixir pattern-match checks verify the HTTP and database contract.

The runner requires zero exit codes from **both** processes, their final completion records (after checks and application shutdown), and released listeners before printing PASS. Readiness uses a monotonic deadline, not a timeout renewed by each log line. Graceful shutdown has bounded waits; Linux escalates from SIGTERM to SIGKILL for the owned process group, including leftover descendants. The Python entry point also unwinds cleanup on interruption. The CI service container is discarded by GitHub Actions on success, failure or job termination; local runs retain their synthetic databases.

Runner tests use real lightweight subprocesses to cover successful shutdown, zero exit without completed checks, a success record followed by nonzero exit, receiver failure/early exit, readiness timeout, sender timeout and (on Linux) a child ignoring SIGTERM. Windows uses bounded taskkill of the owned tree and reports failure if tree cleanup cannot be verified; it never reports PASS after such an error.

The negative control runs the **real** worker and receiver using a temporary copy of `local.exs` whose expected persisted HTTP status is deliberately changed from 202 to 201. Immediately before comparison, the harness emits `DEMO worker_status` with a JSON object containing only the observed persisted HTTP status and expected status. Only a mismatch sets the exclusive `worker_http_status_mismatch` error stage. The control requires exactly one observation of 202 against expected 201 and that specific failure stage; exit 1 alone is insufficient.

Two additional real-service regressions inject a failure before the status observation and an actual Oban worker error caused by removing the disposable sender's signing configuration. Both must be rejected as invalid negative controls. Every failure case must revoke the credential, complete receiver shutdown, omit PASS and release both listeners; the generated signing secret is checked for absence from the displayed transcript. Changes stay in temporary harness copies and process-local test configuration; neither service source is changed. The same checks run with Python `-O`.

To update Ironhold, review its public contract, lockfile and runtime changes, then change the single full `IRONHOLD_REVISION` SHA in the workflow and this documented revision in a reviewed PR. Require the receiver suite, positive integration, negative control and runner lifecycle tests to pass. Do not track a moving branch or silently update the pin.

The existing quality job is unchanged. This integration covers the synthetic single-event contract, including post-signing payload tampering, with actual loopback HTTP and PostgreSQL. Automatic transient retry schedules, stale recovery, admin manual retry, TLS, load, multi-node operation and deployment remain outside this gate.
## Troubleshooting

- **Launcher or missing dependency:** check `mix --version`, Python and locked dependency installation in each checkout. Use temporary caches or Linux/WSL when OneDrive denies writes. The driver applies a five-minute deadline to readiness and sender execution (overridable with `--timeout`); cold builds may require precompilation. Do not fix this with sleeps.
- **Database stage:** ensure localhost PostgreSQL is accepting connections and the disposable role can create databases. Refused host/URL, an existing run database or failed migrations are blockers, not permission to reuse production settings.
- **Service start:** check only the named local ports for occupancy. Stop the process you own, or use another isolated environment. Never enumerate all process arguments or environments.
- **HTTP stage:** check the existing development flags, clock synchronization and the public contract. `409` is terminal for Tidewake and is not a request to retry automatically. Do not disable signature verification or replay claims.
- **Failure with withheld details:** retain the printed stage and exit status; inspect code and safe dependency diagnostics. Do not publish raw child output. A failed run is not evidence of completion.

## Safe shutdown

Normal execution revokes the credential and stops both services, retaining both synthetic databases for inspection. The signing secret and pepper disappear with their processes, and no raw credential can be recovered from the database. On interruption, let the driver stop its own children; verify those two ports are no longer listening without reading command-line arguments. If the process was forcibly terminated before revocation, the credential expires after one hour and has no usable secret retained by this procedure.

Database removal is intentionally not automated. Record the exact database names printed by this run and review them before any separately authorized removal. Never use broad database deletion, `docker compose down -v`, Git cleanup, reset, restore or stash. Restore per-shell cache overrides by closing the dedicated shell; no global environment or source configuration was changed.

## Two-minute technical interview outline

1. **0:00–0:25:** Explain the durability problem, separate service ownership and the architecture diagram. This is a local pre-release demonstration.
2. **0:25–0:55:** Run the command. Explain the project-bound opaque credential and why `201` acknowledges durable work rather than completed delivery.
3. **0:55–1:20:** Point to the event/delivery/job counts and real worker `202`. Explain exact-byte HMAC, destination validation and transaction boundaries.
4. **1:20–1:45:** Compare freshly signed `202`, exact replay `409` and negative `401` results. Explain one event versus two replay claims, and distinguish this from admin manual retry.
5. **1:45–2:00:** State at-least-once semantics, receiver-wide ID uniqueness, shared-key limitations and the missing production rollout/operational evidence. Show retirement and shutdown.

No screenshots or video are claimed by this guide. If recording a real session, show only the allowlisted transcript and public diagram. Never record terminal history, secrets, environment dumps or raw request headers.
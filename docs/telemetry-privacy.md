# Telemetry privacy

## Scope and trust boundary

`TidewakeWeb.Telemetry.metrics/0` is the contract for project-controlled metric reporters,
including LiveDashboard where enabled. Library metric names, units and measurements
remain stable; their `event_name` now points to `[:tidewake, :observability, ...]`.
Bounded webhook-domain events keep their existing names and labels.

`TidewakeWeb.MetricEvents` synchronously projects only allowlisted measurements and labels
from this application's Endpoint/Repo. It never forwards a connection, socket, headers,
body, params, query, query result, exception reason/stacktrace, URL, identifier,
idempotency key, signature, secret or fingerprint. Route labels must equal a compiled
router template; otherwise they become `"unmatched"`. Exception kind is one of
`:error`, `:exit`, `:throw`, `:unknown`. Numeric measurements must be nonnegative integers.

A reporter must use **these metric definitions**, not subscribe to raw Phoenix, Plug,
Ecto, transport or worker-library prefixes or inspect arbitrary metadata. Metric tag
selection alone is not a privacy boundary: a handler still receives the full event.
No external metrics reporter or alert integration is configured in this repository.
There is no evidence here of an external data leak.

## Inventory

The inventory combines source inspection with synthetic HTTP/SQL/exception tests and
`:telemetry.list_handlers([])` in an isolated test runtime. Test-only observer handlers
are detached after each test. It does not enumerate every event that future library
versions or custom integrations might emit.

| Source | Internal metadata / registered consumers | Exportable projection |
| --- | --- | --- |
| `[:phoenix, :endpoint, :start/:stop]` (Plug.Telemetry) | Full `Plug.Conn`, options; project `MetricEvents` handler | System time / duration, no metadata |
| `[:phoenix, :router_dispatch, :start/:stop/:exception]` | Conn, route, plug/options; exception also includes kind/reason/stacktrace; project handler | System time / duration, bounded route and exception kind |
| `[:tidewake, :repo, :query]` (Ecto) | SQL, params, result/error, repo, source, options; project handler | Timings only, empty metadata |
| `[:tidewake, :webhooks, ...]` | Ingestion, manual retry, processing, cancellation, error, retry scheduling/exhaustion and recovery | Existing counts, durations and bounded reason/outcome/cause labels |
| `[:vm, ...]` (telemetry_poller) | Numeric memory / run queue values | Existing VM metrics unchanged |
| Phoenix socket/channel events | Endpoint, socket/assigns, client event and params; project handler | Duration/count only; channel event is `phx_join`, `phx_leave`, `heartbeat` or `other` |
| Cowboy request events | The default stream handler can expose request headers; this project already excludes `cowboy_telemetry_h` | No raw transport export |
| Oban / Req / Finch internal events | Jobs/args, request URLs or other internal objects may be present; no project exporter subscribes | Not part of the metric allowlist |
| Phoenix LiveView lifecycle events | Socket/session/params in memory; LiveView.Logger is installed by the dependency | No direct export; module-specific logging is disabled at app startup |

Registered at test application startup: the project `MetricEvents` callbacks and
Phoenix.LiveView.Logger lifecycle callbacks. Phoenix.Logger callbacks are disabled
through Phoenix's supported `:logger` setting. No reporter is started in the Telemetry
supervision tree; domain events have no permanent consumer until a reporter is added.
Dashboard listeners, test observers and dynamically installed integrations may add
handlers after this snapshot. Installation replaces only the project's handler ID;
normal application stop detaches it, and supervisor restart installs it again.

## Logging

Generic Phoenix request logging and Repo SQL debug logging are disabled. Those loggers
can stringify request paths, parameter **keys**, query arguments and exception objects;
filtering selected secret values is insufficient. Numeric request/query metrics remain.
Console formatting no longer includes the caller-controlled request ID. Domain logs
remain bounded operational messages. Do not re-enable raw diagnostic logging with real
data or forward unreviewed custom Logger metadata.

Cowboy/Ranch use the configured HTTPAdapter as a logger: severity is retained but arbitrary format arguments become a fixed `HTTP transport event` message. This intentionally loses transport exception text. The unrestricted LiveDashboard RequestLogger plug is removed; dashboard metric listeners continue using the metric contract.

Phoenix.LiveView.Logger is independent of Phoenix.Logger and can stringify an entire dashboard session. Application startup sets its module log level to `:none`, using the supported Logger API; this node-wide privacy policy remains until node shutdown and is reapplied on app startup. Handlers and LiveDashboard metrics remain installed. Future project LiveViews should also declare `log: false`.

## Limits and operational work

Raw library events still contain sensitive metadata **in node memory**. Any trusted
Telemetry handler can subscribe to them; this boundary does not isolate untrusted code
running in the BEAM. Framework exception pages, developer tools, process/crash reports,
custom Logger handlers and future exporters need their own review. Development is not
safe for real credentials or production data.

These changes do not claim to sanitize the entire Phoenix ecosystem. Internal transport,
LiveView and worker events outside the declared metric boundary must not be exported.
Reporter selection, retention, dashboards, alert thresholds and operational deployment
remain pending (Refs #267, which this work does not close). No HMAC, HTTP response,
replay/idempotency, domain retry, database schema or production deployment changes are made.

## Regression evidence

On 2026-11-05, the same four synthetic HTTP privacy tests failed on the base code:
success, authentication rejection, validation rejection and malformed-JSON exception.
They observed private material at declared metric handlers or captured logs. No test
prints the connection, token, secret or signature: observations are reduced to booleans.

The corrected tests exercise real Telemetry handlers, request pipelines, database queries,
errors and exceptions. They assert entire projected maps, origin isolation, unknown
labels, invalid measurements, idempotent handler installation and preservation of metric
names/units/domain events. Real loopback HTTP listeners exercise `raise`, `throw` and
`exit`, with supervised cleanup and no synchronization sleeps. A raw-event observer
also confirms that internal Conn metadata remains available, rather than claiming its
removal.

Run on the runtime pinned by `.github/workflows/ci.yml`, with disposable PostgreSQL 16:

```sh
mix deps.get --check-locked
mix test test/tidewake_web/telemetry_privacy_test.exs test/tidewake_web/http_transport_privacy_test.exs --seed 0
mix precommit
mix hex.audit
mix assets.setup
mix assets.deploy
```

Official local runtime: Elixir 1.19.5 / OTP 28.4 / PostgreSQL 16.15. The targeted
privacy/transport run passed **16 tests, 0 failures**. `mix precommit` passed the full
**1,030 tests, 0 failures** (seed 440373), with **0 compiler warnings**, no Credo findings
and no Sobelow findings. `mix hex.audit` reported no retired/advisory packages; static
assets built successfully. The pinned Cowlib OSV query returned `{}` (no vulnerabilities). The lockfile includes the identical Ecto 3.14.3 update already
proposed in #279, to keep the existing security gate green; merge that dependency PR first.

# Tidewake

Tidewake is an early-stage platform for reliable webhook delivery. It is intended to accept events, persist them, schedule asynchronous deliveries, sign outbound requests, record every attempt, and make delivery history observable.

The project is still early-stage, but it is no longer only a foundation. The Phoenix application, PostgreSQL integration, Oban infrastructure, local environment, quality tooling, and CI are present. Endpoint management and immutable event ingestion are implemented. `POST /api/events` atomically persists an event, one pending delivery for every active endpoint, and one initial Oban job per delivery; `201 Created` acknowledges durable ingestion, not completed delivery. `GET /api/events/:id/deliveries` exposes the ordered status of that fan-out. A pending delivery is cancelled without an outbound request or recorded attempt if its endpoint is inactive when processing begins. The worker and processor record delivery outcomes and schedule bounded automatic retries for allowlisted transient failures. Periodic maintenance recovers abandoned processing work, bounded Telemetry events cover ingestion, processing, retries, cancellation, and recovery, and declarative domain metrics are available.

Every minute, a maintenance worker considers at most 100 deliveries whose status is still `processing` and whose `updated_at` is at least five minutes old. Each candidate is locked and rechecked before a transaction returns it to `pending` and creates a replacement job. Recovery preserves `attempt_count` and creates no attempt because no outbound result was confirmed. The transaction rolls back if the replacement job is not inserted. This provides at-least-once semantics: a request whose result was not persisted may be sent again. Recovery Telemetry sums recovered, skipped, and controlled-error counts and summarizes batch duration without event or endpoint data.

For an active delivery, the processor validates the configured signing secret before claiming the record, serializes the envelope once per actual attempt, and signs those exact bytes with a fresh timestamp. It prepares `Tidewake-Id`, `Tidewake-Timestamp`, and `Tidewake-Signature` alongside `content-type: application/json`. The secret, signature, and signing timestamp are not persisted.

Production configures the Req adapter with the system resolver and public-only destination policy. Each attempt validates the target again, resolves both IP families, rejects the complete destination when any answer is unsafe, and connects to one approved IP while retaining the original hostname for Host, SNI, and TLS verification. Redirects and Req retries are disabled, idle dynamic pools expire after 60 seconds, and at most 65,536 response bytes are consumed and discarded. Development and tests remain deterministic by default; development requires explicit flags to enable HTTP and to admit private-use or loopback targets, while other special-purpose ranges remain blocked. Every `/api` route requires a configured static Bearer token.

Automatic retries use explicit transient and permanent classifications, a six-attempt budget, bounded exponential backoff with equal jitter, guarded attempt-aware claims, and transactional successor scheduling. Manual retry with its own audit record, `Retry-After`, retention and payload policy, project ownership and authorization, users and token rotation, rate limiting, secret rotation, the operational LiveView, a metrics reporter, external alerts, and production deployment remain pending.

## Relationship with Ironhold

Tidewake and Ironhold are separate systems and separate repositories. In the intended integration, Ironhold is one possible webhook consumer:

    Client -> Tidewake -> signed webhook -> Ironhold

This repository does not contain or modify Ironhold.

Each Tidewake attempt uses a fresh timestamp and signature. Ironhold acknowledges a freshly signed retry of an identical stored envelope with the same generic `202 Accepted` response, while exact signature reuse and conflicting content under the same event ID remain conflicts.

## Planned architecture

    Client -> Tidewake API -> PostgreSQL -> Oban -> external endpoint

Tidewake accepts and retrieves individual events through its HTTP API, manages destination endpoints, and persists each accepted event with initial delivery work for active endpoints in one transaction. With no active endpoints, the event is still accepted without deliveries or jobs. The production adapter can deliver signed requests through the guarded Req transport when deployed and configured. Automatic retries already classify transient outcomes, apply bounded exponential backoff with equal jitter, reject stale or duplicate jobs during claim, and persist each failed attempt, pending delivery state, and successor job atomically. The broader architecture will eventually:

- expose manual retry with a dedicated audit record and support `Retry-After` where appropriate;
- define retention and payload policy and add project-scoped authorization and rate limiting;
- expose operational history through Phoenix LiveView;
- publish the available domain metrics through a reporter;
- emit structured logs, external alerts, and broader audit information;
- provide production deployment and rollback guidance.

See [architecture.md](docs/architecture.md) for boundaries and future entities.

See the [endpoint management API contract](docs/api/endpoints.md) for the endpoint representation and operations.

See the [event ingestion API contract](docs/api/events.md) for event creation, retrieval, validation, and idempotency behavior.

## Stack

- Elixir 1.19 and Erlang/OTP 28
- Phoenix 1.8 and Phoenix LiveView 1.2
- Ecto with PostgreSQL 16
- Oban for durable background jobs
- Req for outbound HTTP
- ExUnit for tests
- Telemetry for instrumentation
- Credo and Sobelow for static quality and security checks
- Docker Compose for the local database
- GitHub Actions for continuous integration

The exact resolved library versions are recorded in mix.lock.

## Requirements

- Git
- Elixir and Erlang versions from .tool-versions, preferably managed with ASDF
- Docker with Docker Compose

PostgreSQL does not need to be installed on the host when Docker Compose is available.

## Local setup

Start PostgreSQL:

    docker compose up -d db

Optionally copy the safe local defaults and load them with your preferred environment manager:

    cp .env.example .env

Mix does not load .env automatically. The application already uses the same safe defaults when variables are absent.

Install dependencies, create the database, run migrations, and build assets:

    mix setup

Start the application:

    mix phx.server

Open [http://localhost:4000](http://localhost:4000).

All current `/api` routes require the configured static token in an `Authorization: Bearer <token>` header. Development defaults to the recognizable non-production value below:

    export TIDEWAKE_API_TOKEN=dev-only-api-token-not-for-production

This local value is public, disposable, and must never be used in production. Production must provide its own `TIDEWAKE_API_TOKEN` containing at least 32 bytes. Missing, malformed, duplicated, or invalid credentials return `401 Unauthorized`, include `WWW-Authenticate: Bearer`, and use this public response:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Valid API token required"
  }
}
```

This shared token provides only an initial authentication boundary. Users, login sessions, OAuth, JWT, project-level authorization, and automatic token rotation remain pending.

The endpoint API supports `POST /api/endpoints`, `GET /api/endpoints`, `GET /api/endpoints/:id`, and `PATCH /api/endpoints/:id`. For example, create a persisted endpoint with:

    curl --fail-with-body -X POST http://localhost:4000/api/endpoints \
      -H 'Authorization: Bearer dev-only-api-token-not-for-production' \
      -H 'content-type: application/json' \
      -d '{"name":"Ironhold","url":"https://ironhold.example.com/api/webhooks"}'

The event API supports `POST /api/events`, `GET /api/events/:id`, and `GET /api/events/:id/deliveries`. Event listing, updates, deletion, and attempt detail are not implemented.

## Local Tidewake to Ironhold delivery

Use the same public, local-only signing value in both applications. Neither project loads `.env` automatically, so export the variables in the shell that starts each server.

In the Ironhold repository, start the receiver on port 4001:

    export IRONHOLD_WEBHOOK_SIGNING_SECRET=dev-only-webhook-signing-secret-not-for-production
    PORT=4001 mix phx.server

In this repository, explicitly enable outbound HTTP and local targets for development:

    export TIDEWAKE_WEBHOOK_SIGNING_SECRET=dev-only-webhook-signing-secret-not-for-production
    export TIDEWAKE_ENABLE_OUTBOUND_HTTP=true
    export TIDEWAKE_ALLOW_LOCAL_WEBHOOK_TARGETS=true
    mix phx.server

Register Ironhold as an active endpoint:

    curl --fail-with-body -X POST http://localhost:4000/api/endpoints \
      -H 'Authorization: Bearer dev-only-api-token-not-for-production' \
      -H 'content-type: application/json' \
      -d '{"name":"Local Ironhold","url":"http://127.0.0.1:4001/api/webhooks"}'

Send an event with a unique external ID:

    EVENT_EXTERNAL_ID="evt_local_$(date +%s)"
    curl --fail-with-body -X POST http://localhost:4000/api/events \
      -H 'Authorization: Bearer dev-only-api-token-not-for-production' \
      -H 'content-type: application/json' \
      -d "{\"external_id\":\"${EVENT_EXTERNAL_ID}\",\"type\":\"order.created\",\"data\":{\"order_id\":\"local-123\"}}"

Read the internal event `id` from that response and check its delivery:

    curl --fail-with-body \
      -H 'Authorization: Bearer dev-only-api-token-not-for-production' \
      http://localhost:4000/api/events/<event-id>/deliveries

The delivery should reach `succeeded` with `attempt_count` equal to 1. The Ironhold terminal should show `POST /api/webhooks` completing with `202`, confirming that the authenticated webhook reached the receiver.

Stop the database when finished:

    docker compose down

The named Docker volume preserves local database data. Use docker compose down -v only when you intentionally want to delete it.

## Environment variables

Local configuration supports:

| Variable | Local default | Purpose |
| --- | --- | --- |
| TIDEWAKE_API_TOKEN | dev-only-api-token-not-for-production | Static Bearer token for `/api`; this public local value is not for production. |
| TIDEWAKE_WEBHOOK_SIGNING_SECRET | dev-only-webhook-signing-secret-not-for-production | Secret used to prepare webhook signing headers; this public local value is not for production. |
| TIDEWAKE_ENABLE_OUTBOUND_HTTP | false | Enables the Req delivery adapter only in development when set to `true`. |
| TIDEWAKE_ALLOW_LOCAL_WEBHOOK_TARGETS | false | Allows private-use and loopback targets only in development when set to `true`. |
| POSTGRES_USER | postgres | PostgreSQL user |
| POSTGRES_PASSWORD | postgres | Local-only PostgreSQL password |
| POSTGRES_DB | tidewake_dev | Development database |
| POSTGRES_HOST | localhost | Database host |
| POSTGRES_PORT | 5432 | Database port |

Production additionally requires DATABASE_URL, SECRET_KEY_BASE, a `TIDEWAKE_API_TOKEN` of at least 32 bytes, and a `TIDEWAKE_WEBHOOK_SIGNING_SECRET` of at least 32 bytes. PHX_HOST and PORT configure the public endpoint. Never commit a populated .env file or real credentials.

## Quality checks

Run the code quality checks:

    mix quality

Or run the dependency and code checks separately:

    mix deps.get --check-locked
    mix deps.unlock --check-unused
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix credo --strict
    mix sobelow
    mix test

The `mix quality` alias runs the code checks above. The `mix precommit` alias also rejects unused dependencies recorded in `mix.lock`.

## Project organization

    assets/                  Browser assets
    config/                  Compile-time and runtime configuration
    docs/                    Architecture, roadmap, and decisions
    lib/tidewake/            Domain and infrastructure code
    lib/tidewake_web/        Phoenix web boundary
    priv/repo/migrations/    Database migrations
    test/                    ExUnit tests and support

Implemented endpoint, event, delivery, attempt, transactional fan-out, attempt-aware retry scheduling, stale-delivery recovery, envelope encoding, signature generation, safe target preparation, and bounded response consumption live in `Tidewake.Webhooks`. Ingestion, processing, retry scheduling and exhaustion, and recovery emit bounded Telemetry events, while `TidewakeWeb.Telemetry` declares the corresponding metrics without configuring a reporter. Future responsibilities may grow into focused contexts such as `Tidewake.Projects` and `Tidewake.Observability`. Those modules will be introduced only when real behavior requires them.

## Roadmap

1. Foundation: Phoenix, PostgreSQL, Oban, Req, quality tools, CI, and documentation.
2. First vertical slice: event ingestion, persistence, an Oban job, a recorded attempt, API authentication, and stale-delivery recovery. Complete for the deterministic local path.
3. Outbound HTTP delivery and bounded automatic retries are implemented. The reliability milestone remains in progress while manual retry, `Retry-After`, retention and payload policy, and related hardening remain pending.
4. LiveView history, metrics, logs, and audit capabilities.
5. Operational hardening and production deployment guidance.

The roadmap is directional and distinguishes implemented behavior from remaining work. See [roadmap.md](docs/roadmap.md) for acceptance goals.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report suspected vulnerabilities using the private process in [SECURITY.md](SECURITY.md).

## License

Tidewake is available under the [MIT License](LICENSE).

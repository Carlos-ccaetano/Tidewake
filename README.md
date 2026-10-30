# Tidewake

Tidewake is an early-stage platform for reliable webhook delivery. It is intended to accept events, persist them, schedule asynchronous deliveries, sign outbound requests, record every attempt, and make delivery history observable.

The project is still early-stage, but it is no longer only a foundation. The Phoenix application, PostgreSQL integration, Oban infrastructure, local environment, quality tooling, and CI are present. Endpoint management and immutable event ingestion are implemented. `POST /api/events` atomically persists an event, one pending delivery for every active endpoint in its project, and one initial Oban job per delivery; `201 Created` acknowledges durable ingestion, not completed delivery. `GET /api/events/:id/deliveries` exposes the ordered status of that fan-out. A pending delivery is cancelled without an outbound request or recorded attempt if its endpoint is inactive when processing begins. The worker and processor record delivery outcomes and schedule bounded automatic retries for allowlisted transient failures. Periodic maintenance recovers abandoned processing work, bounded Telemetry events cover ingestion, processing, retries, cancellation, and recovery, and declarative domain metrics are available.

Every minute, a maintenance worker considers at most 100 deliveries whose status is still `processing` and whose `updated_at` is at least five minutes old. Each candidate is locked and rechecked before a transaction returns it to `pending` and creates a replacement job. Recovery preserves `attempt_count` and creates no attempt because no outbound result was confirmed. The transaction rolls back if the replacement job is not inserted. This provides at-least-once semantics: a request whose result was not persisted may be sent again. Recovery Telemetry sums recovered, skipped, and controlled-error counts and summarizes batch duration without event or endpoint data.

For an active delivery, the processor validates the configured signing secret before claiming the record, serializes the envelope once per actual attempt, and signs those exact bytes with a fresh timestamp. It prepares `Tidewake-Id`, `Tidewake-Timestamp`, and `Tidewake-Signature` alongside `content-type: application/json`. The secret, signature, and signing timestamp are not persisted.

Production configures the Req adapter with the system resolver and public-only destination policy. Each attempt validates the target again, resolves both IP families, rejects the complete destination when any answer is unsafe, and connects to one approved IP while retaining the original hostname for Host, SNI, and TLS verification. Redirects and Req retries are disabled, idle dynamic pools expire after 60 seconds, and at most 65,536 response bytes are consumed and discarded. Development and tests remain deterministic by default; development requires explicit flags to enable HTTP and to admit private-use or loopback targets, while other special-purpose ranges remain blocked. Every `/api` route requires a project-bound service-account credential and an explicit route permission.

Automatic retries use explicit transient and permanent classifications, a six-attempt budget per cycle, bounded exponential backoff with equal jitter, guarded attempt-aware claims, and transactional successor scheduling.

The manual retry command requires an authenticated project Scope and current admin authority, including on replay. `Tidewake.Webhooks.request_manual_retry/3` uses project-bound version-2 fingerprints and digest-only actor-scoped idempotency. Acceptance atomically commits its audit record, delivery transition and immediate cycle-aware job; rejection records only its decision, and replay creates no additional work. PostgreSQL locks and uniqueness arbitrate concurrent requests. Lifetime attempt history is preserved, with at most three manual cycles after the original automatic cycle.

Admins can use `POST /api/deliveries/:delivery_id/manual-retry-requests` with one Idempotency-Key and an absent body or empty JSON object. A durable account bucket allows five requests and refills one token every 12 seconds; replays and admitted input errors also consume capacity. Every response is JSON with `Cache-Control: no-store`, and foreign/absent deliveries share one 404. [The POST contract](docs/api/manual-retries.md) documents the minimal response and errors. Audit GET remains pending until P32; retry UI, receiver `Retry-After` handling, retention and payload policy, human users, secret rotation, metrics reporting, external alerts and production deployment remain future work.

## Relationship with Ironhold

Tidewake and Ironhold are separate systems and separate repositories. In the intended integration, Ironhold is one possible webhook consumer:

    Client -> Tidewake -> signed webhook -> Ironhold

This repository does not contain or modify Ironhold.

Each Tidewake attempt uses a fresh timestamp and signature. Ironhold acknowledges a freshly signed retry of an identical stored envelope with the same generic `202 Accepted` response, while exact signature reuse and conflicting content under the same event ID remain conflicts.

## Planned architecture

    Client -> Tidewake API -> PostgreSQL -> Oban -> external endpoint

Tidewake accepts and retrieves individual events through its HTTP API, manages destination endpoints, and persists each accepted event with initial delivery work for active endpoints in the authenticated project in one transaction. With no active endpoints, the event is still accepted without deliveries or jobs. The production adapter can deliver signed requests through the guarded Req transport when deployed and configured. Automatic retries already classify transient outcomes, apply bounded exponential backoff with equal jitter, reject stale or duplicate jobs during claim, and persist each failed attempt, pending delivery state, and successor job atomically. The broader architecture will eventually:

- expose authorized retrieval of the existing manual retry audit records;
- support delivery `Retry-After` where appropriate;
- define retention and payload policy;
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

All current `/api` routes require exactly one `Authorization: Bearer <credential>` header containing an opaque service-account credential. Its account's project determines ownership; request parameters and headers cannot select tenancy. Admins manage endpoints and ingest events, producers ingest events and read resources, and viewers read resources.

Production requires `TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER` from a secret manager with at least 32 independently generated random bytes and no fallback. Development/test values are explicitly non-production. Changing the pepper invalidates existing credentials and requires planned reissuance.

Provision in the intended environment (use `MIX_ENV=prod` with production configuration when operating production):

    mix tidewake.projects.create --name Local --slug local
    mix tidewake.service_accounts.provision --project <project-public-id> --name LocalAdmin --role admin --expires-in-days 30

The task prints account/credential public IDs and the raw credential exactly once after commit. Store it in a secret manager; it cannot be recovered from the database. The curl examples expect `TIDEWAKE_SERVICE_ACCOUNT_TOKEN` loaded from that manager into the client shell. Existing data retains legacy-project ownership and requires an explicitly provisioned account for that recorded project; creating a project does not transfer data.

To retire a credential, use its printed public ID:

    mix tidewake.service_accounts.revoke_credential --project <project-public-id> --credential <credential-public-id>

Missing, malformed, duplicated, unknown, expired or revoked credentials, disabled accounts and suspended projects return the same `401 Unauthorized`, `WWW-Authenticate: Bearer` and `Cache-Control: no-store`:

```json
{"error":{"code":"unauthorized","message":"Valid service account credential required"}}
```

A valid account lacking permission receives a fixed `403 Forbidden` with `Cache-Control: no-store`. Foreign and absent resources share the same `404`. The former shared credential is no longer accepted. Human users, login sessions, OAuth, JWT and automatic credential rotation remain pending.

The endpoint API supports `POST /api/endpoints`, `GET /api/endpoints`, `GET /api/endpoints/:id`, and `PATCH /api/endpoints/:id`. For example, create a persisted endpoint with:

    curl --fail-with-body -X POST http://localhost:4000/api/endpoints \
      -H "Authorization: Bearer ${TIDEWAKE_SERVICE_ACCOUNT_TOKEN}" \
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
      -H "Authorization: Bearer ${TIDEWAKE_SERVICE_ACCOUNT_TOKEN}" \
      -H 'content-type: application/json' \
      -d '{"name":"Local Ironhold","url":"http://127.0.0.1:4001/api/webhooks"}'

Send an event with a unique external ID:

    EVENT_EXTERNAL_ID="evt_local_$(date +%s)"
    curl --fail-with-body -X POST http://localhost:4000/api/events \
      -H "Authorization: Bearer ${TIDEWAKE_SERVICE_ACCOUNT_TOKEN}" \
      -H 'content-type: application/json' \
      -d "{\"external_id\":\"${EVENT_EXTERNAL_ID}\",\"type\":\"order.created\",\"data\":{\"order_id\":\"local-123\"}}"

Read the internal event `id` from that response and check its delivery:

    curl --fail-with-body \
      -H "Authorization: Bearer ${TIDEWAKE_SERVICE_ACCOUNT_TOKEN}" \
      http://localhost:4000/api/events/<event-id>/deliveries

The delivery should reach `succeeded` with `attempt_count` equal to 1. The Ironhold terminal should show `POST /api/webhooks` completing with `202`, confirming that the authenticated webhook reached the receiver.

Stop the database when finished:

    docker compose down

The named Docker volume preserves local database data. Use docker compose down -v only when you intentionally want to delete it.

## Environment variables

Local configuration supports:

| Variable | Local default | Purpose |
| --- | --- | --- |
| TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER | Explicit non-production dev/test value | Server-side credential verification secret; production requires at least 32 random bytes from a secret manager. |
| TIDEWAKE_WEBHOOK_SIGNING_SECRET | dev-only-webhook-signing-secret-not-for-production | Secret used to prepare webhook signing headers; this public local value is not for production. |
| TIDEWAKE_ENABLE_OUTBOUND_HTTP | false | Enables the Req delivery adapter only in development when set to `true`. |
| TIDEWAKE_ALLOW_LOCAL_WEBHOOK_TARGETS | false | Allows private-use and loopback targets only in development when set to `true`. |
| POSTGRES_USER | postgres | PostgreSQL user |
| POSTGRES_PASSWORD | postgres | Local-only PostgreSQL password |
| POSTGRES_DB | tidewake_dev | Development database |
| POSTGRES_HOST | localhost | Database host |
| POSTGRES_PORT | 5432 | Database port |

Production additionally requires DATABASE_URL, SECRET_KEY_BASE, TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER of at least 32 bytes, and TIDEWAKE_WEBHOOK_SIGNING_SECRET of at least 32 bytes. PHX_HOST and PORT configure the public endpoint. Never commit a populated .env file or real credentials.

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

Implemented endpoint, event, delivery, attempt, transactional fan-out, attempt-aware retry scheduling, the internal manual retry command and audit persistence, stale-delivery recovery, envelope encoding, signature generation, safe target preparation, and bounded response consumption live in `Tidewake.Webhooks`. Ingestion, processing, retry scheduling and exhaustion, internal manual retry completion, and recovery emit bounded Telemetry events, while `TidewakeWeb.Telemetry` declares the corresponding metrics without configuring a reporter. `Tidewake.Projects` owns projects, service accounts and credentials; its Scope and Authorization policy support the API boundary. A broader observability context remains future work.

## Roadmap

1. Foundation: Phoenix, PostgreSQL, Oban, Req, quality tools, CI, and documentation.
2. First vertical slice: event ingestion, persistence, an Oban job, a recorded attempt, API authentication, and stale-delivery recovery. Complete for the deterministic local path.
3. Outbound HTTP delivery, bounded automatic retries, authenticated admin manual retry POST, per-account retry admission, service-account identity, project ownership and route authorization are implemented. The reliability milestone remains in progress while audit retrieval, receiver `Retry-After` handling, retention and payload policy, and related hardening remain pending.
4. LiveView history, metrics, logs, and audit capabilities.
5. Operational hardening and production deployment guidance.

The roadmap is directional and distinguishes implemented behavior from remaining work. See [roadmap.md](docs/roadmap.md) for acceptance goals.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report suspected vulnerabilities using the private process in [SECURITY.md](SECURITY.md).

## License

Tidewake is available under the [MIT License](LICENSE).

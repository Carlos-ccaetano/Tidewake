# Tidewake

Tidewake is an early-stage platform for reliable webhook delivery. It is intended to accept events, persist them, schedule asynchronous deliveries, sign outbound requests, record every attempt, and make delivery history observable.

The project is still early-stage, but it is no longer only a foundation. The Phoenix application, PostgreSQL integration, Oban infrastructure, local environment, quality tooling, and CI are present. Endpoint persistence and the endpoint management HTTP API are implemented through the `Tidewake.Webhooks` context and explicit Phoenix routes. Authentication, event ingestion, webhook delivery, retries, idempotency, HMAC signing, audit records, and the operational LiveView remain planned and are not implemented.

## Relationship with Ironhold

Tidewake and Ironhold are separate systems and separate repositories. In the intended integration, Ironhold is one possible webhook consumer:

    Client -> Tidewake -> signed webhook -> Ironhold

This repository does not contain or modify Ironhold.

## Planned architecture

    Client -> Tidewake API -> PostgreSQL -> Oban -> external endpoint

Tidewake will eventually:

- receive events through an HTTP API;
- persist events and delivery state in PostgreSQL;
- enqueue asynchronous work with Oban;
- send signed webhook requests with Req;
- record attempts, status, latency, and response metadata;
- retry transient failures with exponential backoff;
- enforce idempotency at ingestion and delivery boundaries;
- expose operational history through Phoenix LiveView;
- emit logs, metrics, and basic audit information.

See [architecture.md](docs/architecture.md) for boundaries and future entities.

See the [endpoint management API contract](docs/api/endpoints.md) for the endpoint representation and operations.

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

The endpoint API supports `POST /api/endpoints`, `GET /api/endpoints`, `GET /api/endpoints/:id`, and `PATCH /api/endpoints/:id`. For example, create a persisted endpoint with:

    curl --fail-with-body -X POST http://localhost:4000/api/endpoints \
      -H 'content-type: application/json' \
      -d '{"name":"Ironhold","url":"https://ironhold.example.com/api/webhooks"}'

Authentication is not implemented yet, so do not expose this API to untrusted networks.

Stop the database when finished:

    docker compose down

The named Docker volume preserves local database data. Use docker compose down -v only when you intentionally want to delete it.

## Environment variables

Local database configuration supports:

| Variable | Local default | Purpose |
| --- | --- | --- |
| POSTGRES_USER | postgres | PostgreSQL user |
| POSTGRES_PASSWORD | postgres | Local-only PostgreSQL password |
| POSTGRES_DB | tidewake_dev | Development database |
| POSTGRES_HOST | localhost | Database host |
| POSTGRES_PORT | 5432 | Database port |

Production additionally requires DATABASE_URL and SECRET_KEY_BASE. PHX_HOST and PORT configure the public endpoint. Never commit a populated .env file or real credentials.

## Quality checks

Run the complete local quality suite:

    mix quality

Or run each check separately:

    mix deps.get
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix credo --strict
    mix sobelow
    mix test

The generated mix precommit alias runs the same checks and also rejects unused locked dependencies.

## Project organization

    assets/                  Browser assets
    config/                  Compile-time and runtime configuration
    docs/                    Architecture, roadmap, and decisions
    lib/tidewake/            Domain and infrastructure code
    lib/tidewake_web/        Phoenix web boundary
    priv/repo/migrations/    Database migrations
    test/                    ExUnit tests and support

Implemented endpoint persistence lives in `Tidewake.Webhooks`. Future responsibilities may grow into focused contexts such as `Tidewake.Projects`, `Tidewake.Security`, `Tidewake.Observability`, and `Tidewake.Workers`. Those modules will be introduced only when real behavior requires them.

## Roadmap

1. Foundation: Phoenix, PostgreSQL, Oban, Req, quality tools, CI, and documentation.
2. First vertical slice: event ingestion, persistence, an Oban job, and a recorded attempt.
3. Signed delivery, retries, and idempotency.
4. LiveView history, metrics, logs, and audit capabilities.
5. Operational hardening and production deployment guidance.

The roadmap is directional, not a claim that the listed delivery features already exist. See [roadmap.md](docs/roadmap.md) for acceptance goals.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report suspected vulnerabilities using the private process in [SECURITY.md](SECURITY.md).

## License

Tidewake is available under the [MIT License](LICENSE).

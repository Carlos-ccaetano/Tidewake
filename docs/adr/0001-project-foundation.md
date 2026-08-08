# ADR 0001: Project foundation

- Status: accepted
- Date: 2026-08-08

## Context

Tidewake needs a small, credible foundation for reliable webhook delivery. The first change must establish an executable application and development workflow without prematurely implementing event, endpoint, delivery, or attempt business rules.

The intended workflow requires durable persistence, asynchronous work, outbound HTTP, signing, operational visibility, and a maintainable web interface.

## Decision

Use a single Phoenix application with:

- Elixir and Erlang/OTP as the runtime;
- Phoenix and LiveView for the HTTP and operational interface;
- Ecto with PostgreSQL as the durable system of record;
- Oban for transactional, PostgreSQL-backed background work;
- Req for outbound HTTP;
- ExUnit and Telemetry from the start;
- Credo and Sobelow as development and CI checks;
- Docker Compose for a reproducible local PostgreSQL service;
- one GitHub Actions workflow for build and test feedback.

Create only the Oban infrastructure migration in the foundation. Defer domain tables and contexts until the first vertical slice.

Use environment variables for deploy-time configuration and secrets. Permit documented, local-only database defaults so a new contributor can start with:

    docker compose up -d db
    mix setup
    mix phx.server

Do not add Dialyzer yet. It provides value, but introducing PLT caching and type-spec policy before domain code would add disproportionate setup and CI complexity. Reconsider it when the first vertical slice establishes stable domain interfaces.

Do not add deployment automation, AWS infrastructure, Kafka, Kubernetes, or microservices.

## Consequences

### Positive

- The application follows current Phoenix conventions.
- PostgreSQL is the shared durability layer for both Ecto and Oban.
- The development workflow is small and reproducible.
- CI checks formatting, warnings, style, security findings, and tests.
- Future domain contexts can grow around observed responsibilities.

### Negative

- PostgreSQL is required for application startup and the test suite.
- Oban and database schema evolution are coupled to Ecto migrations.
- The monolith must maintain clear internal boundaries as behavior grows.
- Dialyzer coverage is deferred.

## Alternatives considered

### In-memory queue

Rejected because accepted events and queued work must survive process restarts.

### Separate worker service

Rejected because it adds deployment and coordination complexity before workload or scaling evidence exists.

### General HTTP abstraction

Rejected for now. Req is used directly until tests demonstrate a narrow boundary that benefits from an adapter.

### Domain skeleton modules

Rejected because empty contexts would communicate architecture without enforcing real behavior.

## Follow-up

Implement the first vertical slice as a separate change:

    event -> persistence -> Oban job -> recorded attempt

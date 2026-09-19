# Roadmap

The roadmap is incremental. Each milestone should leave the application usable, tested, and observable without pretending later capabilities already exist.

## Milestone 0: foundation

Status: complete

- Phoenix application with LiveView and Ecto
- PostgreSQL local environment
- Oban schema and supervision
- Req dependency
- ExUnit, Telemetry, Credo, and Sobelow
- Docker Compose and continuous integration
- architecture, contribution, security, and decision documentation

No webhook delivery behavior is part of this milestone.

## Milestone 1: first vertical slice

Status: in progress

Goal: prove the smallest durable workflow.

    event -> persistence -> Oban job -> recorded attempt

Implemented:

- schemas, context operations, and database persistence for events, deliveries, and attempts;
- a database-enforced unique index on `external_id` as the ingestion idempotency key;
- `POST /api/events` for validation and persistence;
- `GET /api/events/:id` for individual event retrieval;
- tests for event validation, persistence, duplicate ingestion, and the implemented HTTP operations;
- atomic creation of a delivery and its Oban job through `schedule_delivery/2`;
- an Oban worker on the `default` queue with `max_attempts: 1`, delegating to the processor;
- a deterministic local adapter returning simulated HTTP 204 without external requests;
- attempt creation for successful responses, HTTP errors, and transport errors, atomically finalized with the delivery and its counter;
- safe extraction of bounded, allowlisted response metadata without response bodies or secret headers;
- the `pending → processing → succeeded/failed` transitions, with atomic claim and finalization;
- tests for transactional scheduling, rollback, and complete success and persisted-failure cycles through the worker;
- a Req-backed adapter with explicit timeouts, redirects and internal retries disabled, implemented and tested in isolation without activation;
- deterministic lookup of active endpoints in increasing ID order for future fan-out.

Pending acceptance work:

- authenticate the event API or explicitly restrict it to development;
- implement transactional fan-out during event ingestion;
- connect `POST /api/events` to creation of deliveries and their initial jobs;
- add telemetry for event acceptance and processing outcomes.

This milestone is not complete. Complete local success and failure paths are available through explicit scheduling, but ingestion does not create deliveries or jobs. Transactional fan-out, event API integration, and acceptance/processing telemetry remain pending. No real external delivery is enabled, and retry policy remains in Milestone 3.

## Milestone 2: endpoints and signed delivery

Status: in progress

Completed:

- endpoint model and persistence, including schema validation and context operations.
- HTTP management API for endpoint creation, listing, retrieval, and updates, including deactivation with `active: false`.

The Req adapter exists and is tested, but it is not activated as the configured delivery transport.

Planned:

- associate endpoints with projects;
- implement destination protection against SSRF and a hard bound on response bytes actually received before activating the Req adapter;
- sign exact request bytes with versioned HMAC headers;
- test signatures and the safeguards required for activated external transport.

## Milestone 3: retry and idempotency hardening

- classify transient and permanent failures;
- apply bounded exponential backoff with jitter;
- prevent duplicate concurrent deliveries;
- expose manual retry with an audit record;
- define retention and payload-size limits.

## Milestone 4: operational interface

- LiveView event and delivery history;
- filters for state, endpoint, and time range;
- attempt detail without secret or payload leakage;
- queue, latency, outcome, and retry metrics;
- structured logs and basic administrative audit history.

## Milestone 5: production readiness

- threat model and security review;
- load and failure testing;
- database backup and recovery guidance;
- secret rotation;
- retention jobs;
- deployment and rollback documentation;
- service-level indicators and alert thresholds.

The order may change when evidence from earlier milestones reveals a better boundary.

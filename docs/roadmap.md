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
- attempt creation in the success path, atomically finalized with the delivery and its counter;
- the `pending → processing → succeeded` transition, with atomic claim and finalization;
- tests for transactional scheduling, rollback, and successful processing through the worker.

Pending acceptance work:

- authenticate the event API or explicitly restrict it to development;
- connect event ingestion to fan-out for active endpoints;
- process and record HTTP and transport failures;
- test the complete failure cycle through the worker;
- add telemetry for event acceptance and processing outcomes.

This milestone is not complete. The local success path is available through explicit scheduling, but ingestion does not trigger it automatically. Failure processing and acceptance/processing telemetry remain pending. No real external delivery is enabled, and retry policy remains in Milestone 3.

## Milestone 2: endpoints and signed delivery

Status: in progress

Completed:

- endpoint model and persistence, including schema validation and context operations.
- HTTP management API for endpoint creation, listing, retrieval, and updates, including deactivation with `active: false`.

Planned:

- associate endpoints with projects;
- deliver with Req using explicit timeouts;
- sign exact request bytes with versioned HMAC headers;
- integrate external delivery responses with attempt recording and safe response metadata;
- test signatures and transport classification.

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

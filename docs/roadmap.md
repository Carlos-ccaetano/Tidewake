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

Status: complete

Goal: prove the smallest durable workflow.

    event -> persistence -> Oban job -> recorded attempt

Implemented:

- schemas, context operations, and database persistence for events, deliveries, and attempts;
- a database-enforced unique index on `external_id` as the ingestion idempotency key;
- `POST /api/events` for validation and atomic persistence of the event, its fan-out deliveries, and initial jobs;
- `GET /api/events/:id` for individual event retrieval;
- `GET /api/events/:id/deliveries` for the event's ordered delivery status without endpoint configuration, payloads, or attempts;
- shared static Bearer token authentication for every `/api` route, with a recognizable non-production development value, a required production `TIDEWAKE_API_TOKEN` of at least 32 bytes, and a stable `401 Unauthorized` response with `WWW-Authenticate: Bearer`;
- tests for event validation, persistence, duplicate ingestion, rollback boundaries, fan-out, and the implemented HTTP operations;
- atomic creation of a delivery and its Oban job through `schedule_delivery/2`;
- an Oban worker on the `default` queue with `max_attempts: 1`, delegating to the processor;
- a deterministic local adapter returning simulated HTTP 204 without external requests;
- attempt creation for successful responses, HTTP errors, and transport errors, atomically finalized with the delivery and its counter;
- safe extraction of bounded, allowlisted response metadata without response bodies or secret headers;
- the `pending → processing → succeeded/failed` transitions and terminal `pending → cancelled` transition, with atomic claim and finalization;
- delivery-time endpoint re-evaluation that cancels a pending delivery for an inactive endpoint without an adapter call or attempt;
- tests for transactional scheduling, rollback, and complete success and persisted-failure cycles through the worker;
- a Req-backed adapter with explicit timeouts, redirects and internal retries disabled, implemented and tested in isolation without activation;
- transactional fan-out to active endpoints in increasing ID order, creating one delivery and one initial job per destination;
- periodic recovery, every minute, of deliveries left in `processing` for at least five minutes;
- a deterministic oldest-first recovery batch limited to 100 delivery IDs, processed serially on a dedicated maintenance queue;
- row-locked revalidation and transactional replacement-job creation while returning stale work to `pending`;
- preservation of `attempt_count` and omission of an attempt when no outbound result was confirmed, with documented at-least-once resend risk;
- bounded Telemetry events for confirmed ingestion, rejection, delivery processing, cancellation, controlled processing errors, and recovery batches;
- declarative domain metrics for ingestion, rejection reasons, deliveries created, processing outcomes and duration, cancellation, controlled error reasons and duration, and recovered, skipped, and controlled-error recovery counts plus batch duration.

This milestone is complete. Its authentication and stale-delivery recovery acceptance gaps are resolved for the durable deterministic path. Completion does not enable real external delivery: complete SSRF protection, a hard response-byte limit, and activation of the Req adapter remain in Milestone 2 alongside project ownership and HMAC signing; retries and backoff remain in Milestone 3; the operational interface and metrics reporter remain in Milestone 4; and production readiness remains in Milestone 5.

## Milestone 2: endpoints and signed delivery

Status: in progress

Completed:

- endpoint model and persistence, including schema validation and context operations.
- HTTP management API for endpoint creation, listing, retrieval, and updates, including deactivation with `active: false`.

The Req adapter exists and is tested, but it is not activated as the configured delivery transport.

Planned:

- associate endpoints with projects;
- implement complete destination protection against SSRF and a hard bound on response bytes actually received;
- activate the Req adapter only after those safeguards exist;
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
- a reporter and operational views for the available domain metrics, plus queue, latency, and retry metrics;
- structured logs and basic administrative audit history.

## Milestone 5: production readiness

- threat model and security review;
- load and failure testing;
- database backup and recovery guidance;
- automatic API token and secret rotation;
- retention jobs;
- deployment and rollback documentation;
- service-level indicators and alert thresholds.

The order may change when evidence from earlier milestones reveals a better boundary.

The implemented shared token is an authentication boundary, not complete authorization. Users, sessions, OAuth, JWT, project-level authorization, and multiple simultaneous tokens remain future identity and access work; they are not prerequisites for considering the current static token authentication implemented.

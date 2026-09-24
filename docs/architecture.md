# Architecture

## Status

This document describes the current implementation and intended direction for Tidewake. Endpoint management, event ingestion and individual retrieval, and persistence for deliveries and attempts are implemented. Atomic delivery claim and finalization, the adapter contract, a deterministic local adapter, JSON envelope encoding, success and failure processing, safe response metadata extraction, an Oban worker, and atomic delivery/job scheduling through `schedule_delivery/2` are available.

`POST /api/events` now atomically persists the event, one pending delivery per active endpoint, and exactly one initial Oban job per delivery. The delivery status API exposes the resulting records without endpoint configuration, payloads, or attempts. Ingestion and delivery processing emit bounded Telemetry events, and declarative counters, sums, and duration summaries are available in `TidewakeWeb.Telemetry`.

The Req adapter is implemented and tested, but it is not activated. The deterministic adapter simulates a 204 response without I/O and remains configured in tests. Complete destination protection against SSRF, a hard limit on response bytes actually received, a policy for endpoints disabled after scheduling, HMAC signing, retries and backoff, authentication, recovery of deliveries stuck in `processing`, and an operational LiveView remain pending. Real external deliveries are not enabled.

## System boundary

Tidewake is intended to own reliable webhook delivery between a client that publishes an event and an external HTTP endpoint that consumes it.

    Client -> Tidewake API -> PostgreSQL -> Oban -> external endpoint

Ironhold may be one external endpoint:

    Client -> Tidewake -> signed webhook -> Ironhold

Ironhold remains an independent system and repository. Tidewake must not depend on Ironhold internals.

## Intended flow

1. A client submits an event with an idempotency key.
2. Tidewake validates and persists the event.
3. Tidewake creates one delivery for each eligible endpoint.
4. An Oban job selects a pending delivery.
5. Tidewake signs and sends the webhook with Req.
6. Tidewake records an immutable attempt summary.
7. A successful response completes the delivery.
8. A transient failure schedules a bounded retry with exponential backoff.
9. Operators inspect history and status through Phoenix LiveView and telemetry.

The complete flow above remains a target, not an enabled external delivery pipeline. The implemented local delivery path is:

1. `POST /api/events` uses `ingest_event/1` to persist the event, query active endpoints by increasing ID, and insert one pending delivery and one initial job per destination in a single `Ecto.Multi` transaction. Zero active endpoints is valid, and any insertion failure rolls back the full ingestion. `schedule_delivery/2` remains available for atomic scheduling of one delivery and job.
2. `DeliverWebhookWorker` consumes a job containing only `delivery_id` on the `default` queue, with `max_attempts: 1`. It obtains the adapter from application configuration and delegates to `DeliveryProcessor`.
3. The processor atomically claims a pending delivery as `processing`, loading its event and endpoint, then encodes an envelope with `id` from `external_id`, `type` from `event_type`, and `data` from the payload.
4. The processor passes the endpoint URL, serialized body, and `content-type: application/json` to the configured adapter and measures duration with a monotonic clock. In tests, the deterministic adapter returns simulated status 204 and empty headers.
5. For any valid adapter outcome, finalization records a `succeeded`, `http_error`, or `transport_error` attempt and updates the delivery status, attempt counter, and completion timestamp atomically. HTTP outcomes include only safe allowlisted response metadata; transport failures use bounded error classifications and no synthetic HTTP status.
6. Persisted HTTP and transport failures complete the worker job successfully without retrying, while the delivery finishes as `failed` with exactly one attempt.
7. `GET /api/events/:id/deliveries` lists the event's deliveries by increasing ID using an explicit, bounded response representation.

Confirmed ingestion, rejection, processing, and controlled processing errors emit low-cardinality Telemetry events. The declared metrics count accepted and rejected events, sum deliveries created during ingestion, count processed outcomes and controlled errors, and summarize processing durations. No reporter is configured. The worker cancels missing deliveries or missing adapter configuration without retrying. Execution, malformed-response, or persistence errors after claim can still leave the delivery in `processing`; recovery remains pending. The Req transport exists as an isolated implementation but is not configured in this path, and signing is not implemented.

## Current and future entities

### Endpoint

The implemented `Endpoint` model represents a registered destination. Its current responsibilities are:

- storing a human-readable name, an HTTP or HTTPS target URL, and an active flag;
- persisting creation and update timestamps;
- supporting list, retrieve, create, and update operations through `Tidewake.Webhooks` and the HTTP API;
- listing only active endpoints in increasing ID order for transactional ingestion fan-out.

Future responsibilities may include:

- signing secret reference, never an exposed secret value;
- subscription or event filtering;
- timeout and delivery policy;
- dedicated disabled and administrative audit timestamps.

### Event

The implemented `Event` model represents an immutable fact accepted from a client. Events are persisted with an event type, structured payload, and microsecond UTC timestamps. `external_id` is the client-provided idempotency key and has a unique database index.

Current responsibilities:

- validating and persisting events through `Tidewake.Webhooks`;
- rejecting duplicate `external_id` values through the database constraint;
- supporting `POST /api/events` and individual retrieval through `GET /api/events/:id`;
- atomically creating deliveries and initial jobs for all active endpoints during ingestion;
- exposing delivery status through `GET /api/events/:id/deliveries` without exposing endpoint URLs, payloads, attempts, headers, or secrets;
- remaining immutable, with no update or delete operations.

Project ownership and additional acceptance metadata remain future responsibilities.

### Delivery

The implemented `Delivery` model represents the intention to send one event to one endpoint. Its table, schema, and minimal operations in `Tidewake.Webhooks` are available.

Current responsibilities:

- requiring event and endpoint associations with a unique database constraint on the pair;
- starting in `pending` and retaining the initial lifecycle fields;
- allowing context-level creation for an active endpoint and retrieval by ID or by the event and endpoint pair;
- scheduling a delivery and its job atomically with `schedule_delivery/2`, with job uniqueness by worker and `delivery_id` across all states while the job record exists;
- atomically claiming only a pending delivery as `processing`;
- locking a processing delivery during finalization, inserting its attempt, incrementing `attempt_count`, and setting status and `completed_at` in one transaction; invalid attempts roll back the operation.

The finalization operation and processor support `succeeded`, `http_error`, and `transport_error` attempt results, mapping the latter two to a failed delivery. Safe allowlisted response metadata is extracted for HTTP outcomes, and transport reasons are normalized before persistence. Transactional API ingestion creates one delivery and one job per active endpoint. External sending, a delivery-time policy for endpoints disabled after scheduling, retries, and recovery from `processing` remain future work.

### Attempt

`Attempt` has an implemented `delivery_attempts` table, schema, and context operations to create, retrieve, and list attempts by increasing attempt number, following ADR 0003.

Current responsibilities:

- linking to a delivery with a unique delivery/attempt-number pair;
- recording a positive attempt number, UTC start/finish timestamps, and non-negative duration;
- validating `succeeded`, `http_error`, and `transport_error` results, with HTTP status only when a response exists;
- allowing only bounded `content_type`, non-negative `content_length`, and bounded `request_id` response metadata;
- remaining append-only, with no context update or delete operations.

The processor records successful, HTTP error, and transport error attempts. `ResponseMetadata` extracts only bounded `content_type`, `content_length`, and `request_id` values from valid HTTP response headers; transport failures carry no response metadata. Response bodies are not stored. Sensitive headers and secrets must never be persisted; a hard limit on the response bytes consumed by the inactive Req transport remains pending.

## Current and future code boundaries

`Tidewake.Webhooks` owns endpoint, event, delivery, and attempt persistence, active endpoint lookup, atomic ingestion fan-out, delivery listing, atomic claim/finalization, and transactional scheduling for one delivery. `EventController` exposes event ingestion, retrieval, and the read-only delivery status route. `Envelope` serializes events. `ResponseMetadata` enforces the safe response metadata boundary. `DeliveryAdapter` defines the transport contract; `DeliveryAdapters.Deterministic` implements local simulation, while `DeliveryAdapters.Req` implements and tests the inactive real HTTP transport. `DeliveryProcessor` coordinates successful, HTTP error, and transport error outcomes, while `Tidewake.Workers.DeliverWebhookWorker` delegates to it using the configured adapter and one job attempt. `TidewakeWeb.Telemetry` declares the bounded domain metrics alongside the existing Phoenix, Ecto, and VM metrics.

Additional responsibilities and namespaces may emerge as behavior is implemented:

- Tidewake.Projects for ownership;
- delivery-time handling for an endpoint disabled after its job was scheduled;
- recovery of deliveries stuck in `processing`;
- SSRF-safe destination validation and a hard response-consumption limit before activating the Req adapter;
- Tidewake.Security for HMAC signing and secret handling;
- retry policy and orchestration, after a separate decision;
- a metrics reporter, dashboards, logs, audit reporting, and an operational LiveView.

These future namespaces are not placeholders. Modules should be introduced only with tested behavior. The first complete external delivery flow is not finished.

## Reliability principles

- Persist accepted work before acknowledging it.
- Make ingestion idempotent through database constraints.
- Make delivery scheduling idempotent through unique jobs and state transitions.
- Treat attempts as immutable records.
- Retry only failures classified as transient.
- Bound attempts, timeouts, payload sizes, and captured responses.
- Sign the exact bytes sent to the endpoint.
- Use constant-time signature comparison where verification is needed.
- Keep secrets outside logs, telemetry metadata, and source control.

## Observability

Telemetry covers confirmed event ingestion and rejection, confirmed delivery processing outcomes, and controlled processing errors. Declarative metrics expose ingestion counts, rejected-event counts by bounded reason, deliveries created, processed-delivery counts by bounded outcome, processing duration, and controlled-error counts and durations by bounded reason. They do not include IDs, URLs, external IDs, payloads, headers, secrets, or exception messages.

No metrics reporter, exporter, dashboard, retention policy, or alerting policy is configured. Queue latency, queue depth, retries, recovery, structured logs, audit records, and the operational LiveView remain future work.

## Deployment boundary

This foundation defines no AWS resources and no deployment workflow. Production topology, secret storage, TLS termination, scaling, retention, and disaster recovery require separate decisions supported by measured needs.

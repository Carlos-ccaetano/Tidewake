# Architecture

## Status

This document describes the current implementation and intended direction for Tidewake. Endpoint management, event ingestion and individual retrieval, and persistence for deliveries and attempts are implemented. Atomic delivery claim and finalization, the adapter contract, a deterministic local adapter, JSON envelope encoding, success and failure processing, safe response metadata extraction, an Oban worker, and atomic delivery/job scheduling through `schedule_delivery/2` are available.

The Req adapter is implemented and tested, but it is not activated. The deterministic adapter simulates a 204 response without I/O and remains configured in tests. ADR 0006 defines event fan-out and the context can list active endpoints deterministically, but `POST /api/events` still persists only the event and transactional fan-out is not implemented. Destination protection against SSRF, a hard limit on response bytes actually received, HMAC signing, retries, recovery of deliveries stuck in `processing`, and an operational interface remain pending. Real external deliveries are not enabled.

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

The complete flow above remains a target, not an enabled external delivery pipeline. The event API persists events without creating deliveries or performing fan-out. The implemented local delivery path is:

1. A caller explicitly invokes `schedule_delivery(event, endpoint)` for an active endpoint. `Ecto.Multi` and `Oban.insert/3` persist a pending delivery and its job in one transaction. `create_delivery/2` still creates only a delivery.
2. `DeliverWebhookWorker` consumes a job containing only `delivery_id` on the `default` queue, with `max_attempts: 1`. It obtains the adapter from application configuration and delegates to `DeliveryProcessor`.
3. The processor atomically claims a pending delivery as `processing`, loading its event and endpoint, then encodes an envelope with `id` from `external_id`, `type` from `event_type`, and `data` from the payload.
4. The processor passes the endpoint URL, serialized body, and `content-type: application/json` to the configured adapter and measures duration with a monotonic clock. In tests, the deterministic adapter returns simulated status 204 and empty headers.
5. For any valid adapter outcome, finalization records a `succeeded`, `http_error`, or `transport_error` attempt and updates the delivery status, attempt counter, and completion timestamp atomically. HTTP outcomes include only safe allowlisted response metadata; transport failures use bounded error classifications and no synthetic HTTP status.
6. Persisted HTTP and transport failures complete the worker job successfully without retrying, while the delivery finishes as `failed` with exactly one attempt.

The worker cancels missing deliveries or missing adapter configuration without retrying. Execution, malformed-response, or persistence errors after claim can still leave the delivery in `processing`; recovery remains pending. The Req transport exists as an isolated implementation but is not configured in this path, and signing is not implemented.

## Current and future entities

### Endpoint

The implemented `Endpoint` model represents a registered destination. Its current responsibilities are:

- storing a human-readable name, an HTTP or HTTPS target URL, and an active flag;
- persisting creation and update timestamps;
- supporting list, retrieve, create, and update operations through `Tidewake.Webhooks` and the HTTP API;
- listing only active endpoints in increasing ID order for the future fan-out transaction.

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

The finalization operation and processor support `succeeded`, `http_error`, and `transport_error` attempt results, mapping the latter two to a failed delivery. Safe allowlisted response metadata is extracted for HTTP outcomes, and transport reasons are normalized before persistence. No API operation creates deliveries automatically. ADR 0006 defines the fan-out boundary, but transactional fan-out, external sending, retries, and recovery from `processing` remain future work.

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

`Tidewake.Webhooks` owns endpoint, event, delivery, and attempt persistence, active endpoint lookup, atomic claim/finalization, and transactional scheduling for one delivery. `Envelope` serializes events. `ResponseMetadata` enforces the safe response metadata boundary. `DeliveryAdapter` defines the transport contract; `DeliveryAdapters.Deterministic` implements local simulation, while `DeliveryAdapters.Req` implements and tests the inactive real HTTP transport. `DeliveryProcessor` coordinates successful, HTTP error, and transport error outcomes, while `Tidewake.Workers.DeliverWebhookWorker` delegates to it using the configured adapter and one job attempt.

Additional responsibilities and namespaces may emerge as behavior is implemented:

- Tidewake.Projects for ownership;
- transactional ingestion-to-delivery linkage and fan-out to active endpoints as defined by ADR 0006;
- recovery of deliveries stuck in `processing`;
- SSRF-safe destination validation and a hard response-consumption limit before activating the Req adapter;
- Tidewake.Security for HMAC signing and secret handling;
- retry policy and orchestration, after a separate decision;
- Tidewake.Observability and an operational interface for metrics, history, and audit reporting.

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

Future telemetry should cover event acceptance, queue latency, attempt duration, outcomes, retries, and queue depth. Logs should carry stable correlation identifiers without payloads or secrets. Basic audit records should identify administrative changes to endpoints and credentials.

## Deployment boundary

This foundation defines no AWS resources and no deployment workflow. Production topology, secret storage, TLS termination, scaling, retention, and disaster recovery require separate decisions supported by measured needs.

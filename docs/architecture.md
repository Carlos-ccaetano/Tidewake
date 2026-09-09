# Architecture

## Status

This document describes the intended direction for Tidewake. The technical foundation, endpoint management, event ingestion and individual retrieval, and delivery persistence operations are implemented. Automatic delivery creation, attempt persistence, delivery jobs and processing, outbound requests with Req, HMAC signing, and retries are not implemented yet.

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

This is the intended flow, not current runtime behavior. Today, the repository persists endpoints, events, and deliveries. The HTTP API manages endpoints and supports event ingestion and individual event retrieval. `Tidewake.Webhooks` can create and retrieve a delivery when given an event and an active endpoint, but the event API does not create deliveries automatically. There are no delivery jobs, state processing, outbound requests with Req, HMAC signing, attempt persistence, external sending, or retries.

## Current and future entities

### Endpoint

The implemented `Endpoint` model represents a registered destination. Its current responsibilities are:

- storing a human-readable name, an HTTP or HTTPS target URL, and an active flag;
- persisting creation and update timestamps;
- supporting list, retrieve, create, and update operations through `Tidewake.Webhooks` and the HTTP API.

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
- allowing context-level creation for an active endpoint and retrieval by ID or by the event and endpoint pair.

No API operation creates deliveries automatically. Jobs, lifecycle processing, outbound sending, attempt recording, and retries remain future responsibilities.

### Attempt

`Attempt` currently has only the recording contract in ADR 0003. It has no table, schema, context operation, or runtime persistence.

Future responsibilities:

- attempt number and start/finish timestamps;
- HTTP status or normalized transport error;
- latency;
- safe response metadata with bounded body capture;
- signature version and request correlation metadata.

Attempts should be append-only operational evidence. Sensitive headers, secrets, and unbounded response bodies must not be stored.

## Future code boundaries

`Tidewake.Webhooks` currently manages endpoint, event, and delivery persistence operations. Additional context responsibilities and namespaces may emerge as behavior is implemented:

- Tidewake.Projects for ownership and endpoint registration;
- Tidewake.Webhooks may expand to cover attempt persistence and delivery processing;
- Tidewake.Security for signing and secret handling;
- Tidewake.Observability for metrics and audit reporting;
- Tidewake.Workers for Oban workers and retry orchestration.

These namespaces are not placeholders. Modules should be introduced only with tested behavior.

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

# Architecture

## Status

This document describes the intended direction for Tidewake. The technical foundation is available, and the `Endpoint` model, persistence, and endpoint management HTTP API are implemented. Event ingestion and the delivery workflow, including HMAC signing, attempt recording, and retries, are not implemented yet.

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

This is the intended flow, not current runtime behavior. Today, the repository provides the application and database foundation, Oban tables and supporting tooling, plus the persisted `Endpoint` model and HTTP operations to list, retrieve, create, and update endpoints. It does not ingest events or create and send deliveries; HMAC signing, delivery attempts, and retry scheduling remain future work.

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

This future entity will represent an immutable fact accepted from a client.

Expected responsibilities:

- project ownership;
- stable external identifier and idempotency key;
- event type and structured payload;
- ingestion timestamp;
- validation and acceptance metadata.

### Delivery

This future entity will represent the intention to send one event to one endpoint.

Expected responsibilities:

- event and endpoint association;
- state such as pending, processing, succeeded, exhausted, or cancelled;
- next attempt timestamp;
- retry count and terminal outcome;
- concurrency and idempotency safeguards.

### Attempt

This future entity will represent one outbound HTTP attempt for a delivery.

Expected responsibilities:

- attempt number and start/finish timestamps;
- HTTP status or normalized transport error;
- latency;
- safe response metadata with bounded body capture;
- signature version and request correlation metadata.

Attempts should be append-only operational evidence. Sensitive headers, secrets, and unbounded response bodies must not be stored.

## Future code boundaries

`Tidewake.Webhooks` currently manages endpoint persistence and operations. Additional context responsibilities and namespaces may emerge as behavior is implemented:

- Tidewake.Projects for ownership and endpoint registration;
- Tidewake.Webhooks may expand to cover events, deliveries, and attempts;
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

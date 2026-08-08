# Architecture

## Status

This document describes the intended direction for Tidewake. The repository currently provides the technical foundation, not the complete delivery workflow.

## System boundary

Tidewake owns reliable webhook delivery between a client that publishes an event and an external HTTP endpoint that consumes it.

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

Only the application, database connection, Oban tables, and supporting tooling exist today.

## Future entities

### Endpoint

Represents a destination registered by a project.

Expected responsibilities:

- target URL and enabled state;
- signing secret reference, never an exposed secret value;
- subscription or event filtering;
- timeout and delivery policy;
- created, updated, and disabled audit timestamps.

### Event

Represents an immutable fact accepted from a client.

Expected responsibilities:

- project ownership;
- stable external identifier and idempotency key;
- event type and structured payload;
- ingestion timestamp;
- validation and acceptance metadata.

### Delivery

Represents the intention to send one event to one endpoint.

Expected responsibilities:

- event and endpoint association;
- state such as pending, processing, succeeded, exhausted, or cancelled;
- next attempt timestamp;
- retry count and terminal outcome;
- concurrency and idempotency safeguards.

### Attempt

Represents one outbound HTTP attempt for a delivery.

Expected responsibilities:

- attempt number and start/finish timestamps;
- HTTP status or normalized transport error;
- latency;
- safe response metadata with bounded body capture;
- signature version and request correlation metadata.

Attempts should be append-only operational evidence. Sensitive headers, secrets, and unbounded response bodies must not be stored.

## Future code boundaries

Contexts may emerge as behavior is implemented:

- Tidewake.Projects for ownership and endpoint registration;
- Tidewake.Webhooks for events, deliveries, and attempts;
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

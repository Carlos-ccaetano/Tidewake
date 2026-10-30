# Architecture

## Status

This document describes the current implementation and intended direction for Tidewake. Endpoint management, event ingestion and individual retrieval, and persistence for deliveries and attempts are implemented. Project-bound service-account authentication and explicit route permissions protect every `/api` route. Atomic delivery claim with delivery-time endpoint re-evaluation, cancellation, and finalization, the adapter contract, a deterministic local adapter, single-pass JSON envelope encoding, HMAC signing of the exact encoded bytes, success and failure processing, safe response metadata extraction, bounded automatic retries, an Oban worker, atomic delivery/job scheduling, and periodic stale-delivery recovery are available.

`POST /api/events` now atomically persists the event, one pending delivery per active endpoint in its project, and exactly one initial Oban job per delivery. The delivery status API exposes the resulting records, including scheduled and terminal outcomes, without endpoint configuration, payloads, or attempts. Ingestion, delivery processing, retry scheduling and exhaustion, cancellation, recovery, and internal manual retry completion emit bounded Telemetry events, and declarative counters, sums, and duration summaries are available in `TidewakeWeb.Telemetry`.

Milestone 1 is complete for the durable delivery path. The processor reads the signing secret from application configuration, serializes each envelope once per attempt, signs those exact bytes with a fresh timestamp, and prepares the three versioned signature headers. The secret, signature, and signing timestamp are not persisted. Production configures the Req adapter with the system resolver and public-only targets. Development and tests remain deterministic by default; development requires explicit flags for outbound HTTP and for local targets. Secret rotation, `Retry-After`, public manual retry access, an operational LiveView, external alerting, a metrics reporter, and production deployment remain pending. Human identities and automatic credential rotation also remain future work.

The internal manual retry command and append-only audit persistence are implemented on the cycle-aware delivery pipeline. Existing API routes have attributable service identity, project ownership and authorization. The retry operation still has no authenticated route/controller, authorized audit retrieval or user interface.

## System boundary

Tidewake is intended to own reliable webhook delivery between a client that publishes an event and an external HTTP endpoint that consumes it.

    Client -> Tidewake API -> PostgreSQL -> Oban -> external endpoint

Ironhold may be one external endpoint:

    Client -> Tidewake -> signed webhook -> Ironhold

Ironhold remains an independent system and repository. Tidewake must not depend on Ironhold internals.

## API authentication boundary

Every current `/api` route runs `RequireServiceAccount` followed by a route-configured `RequirePermission`. Authentication reloads persisted credential/account/project state and constructs only the five identity fields in `Tidewake.Projects.Scope`. Controllers pass `current_scope` to project-scoped Webhooks operations. There is no shared-token fallback or implicit legacy project selection.

| Existing operation | Required permission |
| --- | --- |
| Endpoint list/show, Event show and event delivery status | `resources_read` |
| Event ingestion | `events_write` |
| Endpoint create/update | `endpoints_write` |

The pure Authorization policy grants reads to admin/producer/viewer, ingestion to admin/producer, and endpoint writes to admin. Unknown roles/actions deny. Resource queries combine the resource ID and trusted project; supplied tenancy fields cannot override ownership. Foreign and absent resources return the same 404.

Credentials are opaque, expiring and revocable. Missing/malformed/unknown, mismatched, expired/revoked credentials, disabled accounts and suspended projects receive the same 401 with a bare `WWW-Authenticate: Bearer` challenge. Valid identities lacking permission receive a fixed 403. Both failures halt before controller operations, use a fixed JSON envelope and `Cache-Control: no-store`, and reveal no identity or credential details.

Production requires the dedicated `TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER` from a secret manager, at least 32 random bytes with no fallback. Local dev/test values are non-production. Changing it requires explicit credential reissuance. Provision before using the API with `mix tidewake.projects.create` and `mix tidewake.service_accounts.provision`; retire credentials with `mix tidewake.service_accounts.revoke_credential`. Raw credentials print once after commit and belong in a secret manager.

Human users, sessions, OAuth, JWT and automatic credential rotation remain future work. Manual retry HTTP and audit retrieval are still unexposed; the internal retry command is not yet an authenticated API boundary.

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

The delivery and bounded retry path is implemented; the operational interface remains a target. The current delivery path is:

1. `POST /api/events` uses `ingest_event/2` to persist the event, query active endpoints in the trusted project's scope by increasing ID, and insert one pending delivery and one initial job per destination in a single `Ecto.Multi` transaction. Zero active endpoints is valid, and any insertion failure rolls back the full ingestion. `schedule_delivery/2` remains available for atomic scheduling of one delivery and job.
2. `DeliverWebhookWorker` consumes new jobs containing `delivery_id`, `attempt_number`, `retry_cycle`, and `cycle_attempt_number` on the `default` queue, with `max_attempts: 1`. Job uniqueness uses the worker and all four values for incomplete jobs, so later attempts can coexist with the currently executing job. The worker obtains the adapter from application configuration and delegates to `DeliveryProcessor`. For temporary legacy compatibility, jobs containing only `delivery_id` are treated as lifetime attempt 1, and jobs containing `delivery_id` and `attempt_number` retain the lifetime-number guard without a cycle identity.
3. Before the atomic claim, the processor reads and validates the configured signing secret. Missing or invalid configuration returns a controlled error without invoking the adapter or moving the delivery to `processing`. During the claim of a new job, Tidewake locks the pending delivery and validates all three identity values: `attempt_number == delivery.attempt_count + 1`, `retry_cycle == delivery.retry_cycle`, and `cycle_attempt_number == delivery.cycle_attempt_count + 1`. A delivery with `next_attempt_at` may be claimed only when that instant is due. Stale, duplicate, future-numbered, wrong-cycle, or early jobs stop before serialization, signing, an adapter call, or attempt creation. After these guards, Tidewake queries and locks the endpoint and loads the event. An active endpoint allows the delivery to transition to `processing`; an inactive endpoint instead transitions it directly from `pending` to terminal `cancelled` with `completed_at` set.
4. Cancellation returns before envelope encoding or adapter invocation and creates no attempt, so `attempt_count` and `cycle_attempt_count` remain unchanged. For an active endpoint, the envelope uses `id` from `external_id`, `type` from `event_type`, and `data` from the payload.
5. The processor serializes the envelope once for each actual attempt, generates a fresh timestamp and HMAC signature, and signs the exact serialized body with the event's public ID and configured secret. It passes that same body to the adapter with `content-type: application/json`, `Tidewake-Id`, `Tidewake-Timestamp`, and `Tidewake-Signature`, then measures duration with a monotonic clock. Signing material is never copied from the preceding attempt, placed in job arguments, or persisted. The deterministic adapter returns simulated status 204 without network I/O and remains the development and test default.
6. In production, the Req adapter validates the persisted URL again for every attempt. Hostnames are resolved through both IPv4 and IPv6, every answer is classified against the IANA special-purpose ranges, and the complete destination is rejected if any answer is not globally reachable. IP literals follow the same classification. One approved address is selected, the connection URL is pinned to it, and the original hostname remains separate for Host, SNI, and TLS verification; no second DNS resolution occurs.
7. Req redirects and internal retries are disabled. HTTP/1 pools created for pinned targets expire after 60 seconds of idleness. Response chunks are counted without trusting `content-length`, no response body is retained, and the stream is interrupted above 65,536 bytes.
8. For any valid adapter outcome, the processor records a `succeeded`, `http_error`, or `transport_error` attempt. HTTP outcomes include only safe allowlisted response metadata; transport failures use bounded error classifications without raw URLs, IPs, bodies, headers, or errors. Responses in `200..299` succeed. Only HTTP `408`, `425`, `429`, `500`, `502`, `503`, and `504`, and transport outcomes `timeout`, `dns`, `connection`, and `closed`, are retryable. Every other outcome is terminal, including HTTP `409` and transport `tls`, `destination`, `response_limit`, and `unknown`.
9. Each retry cycle has at most six persisted attempts. `RetryPolicy` and `RetryBackoff` receive the ordinal of the attempt within the current cycle, `delivery.cycle_attempt_count + 1`, independently of its lifetime `attempt_number`. A retryable failure before the cycle limit uses exponential backoff with a 10-second base and a 300-second ceiling. Equal jitter selects an integer delay from the inclusive range between half of the calculated ceiling, rounded up, and the full ceiling. For the five retries possible within a cycle, those ranges are 5–10, 10–20, 20–40, 40–80, and 80–160 seconds.
10. Scheduling a retry locks the processing delivery and, in one database transaction, inserts the failed attempt with its lifetime and cycle identity, increments both `attempt_count` and `cycle_attempt_count`, returns the delivery to `pending` with the chosen `next_attempt_at`, and inserts exactly one future Oban job. That job carries `delivery_id`, the next lifetime `attempt_number`, the unchanged `retry_cycle`, and the next `cycle_attempt_number`. An insertion failure or conflict with equivalent incomplete work, including a legacy job, rolls back the attempt, delivery update, and successor job. The current Oban job then completes successfully; the application, not Oban or Req, owns the successor schedule.
11. `Attempt.next_attempt_at` preserves the schedule chosen by that historical failure. `Delivery.next_attempt_at` represents only the currently outstanding schedule and is cleared when the due attempt is claimed or the delivery becomes terminal. Success, permanent failure, cancellation, and exhaustion finish without a successor job.
12. `GET /api/events/:id/deliveries` lists the event's deliveries by increasing ID using an explicit, bounded response representation.
13. Oban runs `RecoverStaleDeliveriesWorker` every minute on the `maintenance` queue, whose concurrency is one. The worker selects at most 100 IDs for deliveries still in `processing` with `updated_at` at or before five minutes before the scan, ordered by oldest `updated_at` and then ID.
14. Each candidate is locked and rechecked in its own transaction. Recovery returns it to `pending`, preserves `attempt_count`, `retry_cycle`, and `cycle_attempt_count`, clears completion and scheduling timestamps, and inserts a replacement job for the same unpersisted logical attempt. Its complete identity is `delivery_id: delivery.id`, `attempt_number: delivery.attempt_count + 1`, `retry_cycle: delivery.retry_cycle`, and `cycle_attempt_number: delivery.cycle_attempt_count + 1`. It creates no attempt because there is no confirmed result and rolls back if a job cannot be inserted or an active equivalent job exists, including a legacy job. The resulting at-least-once semantics may resend a request whose outcome was not persisted, with fresh signing material.

Ironhold treats a freshly signed retry of an identical event as an idempotent request and returns `202 Accepted`. Because Tidewake creates new signing material for every attempt while preserving the event's public ID and payload, that acknowledgement follows the ordinary success path. An exact signature replay or conflicting event content remains a receiver-side conflict rather than a retryable Tidewake result.

Confirmed ingestion, rejection, processing, retry scheduling and exhaustion, cancellation, recovery, and controlled processing errors emit low-cardinality Telemetry events. A committed retry emits `[:tidewake, :webhooks, :delivery, :retry_scheduled]` with a count, delay in milliseconds, and an allowlisted cause such as `http_503` or `transport_timeout`; terminal exhaustion emits `[:tidewake, :webhooks, :delivery, :retry_exhausted]` with a count and the same bounded cause vocabulary. The corresponding metrics are `tidewake.webhooks.delivery.retry_scheduled.count`, `tidewake.webhooks.delivery.retry_scheduled.delay_ms`, and `tidewake.webhooks.delivery.retry_exhausted.count`. They are emitted only after the relevant transaction commits. IDs, URLs, payloads, bodies, headers, timestamps, signatures, secrets, job IDs, changesets, raw errors, and stack traces are excluded. No reporter is configured. The delivery worker cancels missing, stale, early, or invalid work without sending HTTP.

## Internal manual retry core

`Tidewake.Webhooks.request_manual_retry(delivery_id, %ManualRetryActor{}, idempotency_key)` is an internal command following [ADR 0015](adr/0015-manual-delivery-retry.md), [ADR 0016](adr/0016-bounded-manual-retry-cycles.md), and [ADR 0017](adr/0017-manual-retry-audit-persistence.md). It returns `{:ok, %{request: manual_retry_request, replayed?: boolean}}` for a persisted decision or replay, or a controlled error. The returned audit record's `outcome` and `reason` are the decision. The command performs no authentication or authorization and has no HTTP or UI entry point.

### Trusted actor and request identity

`ManualRetryActor` carries a validated `type` (`service_account` or `user`), a nonempty stable opaque `subject` of at most 255 bytes, and a trusted `source` (`api`, `liveview`, or `admin_cli`). It accepts no missing or extra fields, and the command accepts only this struct rather than arbitrary request maps. Construction does not authenticate a principal or prove provenance. A future trusted boundary must derive the actor and source from authenticated server context and authorize the target delivery, including on replay. Tokens, email addresses, and free-form metadata are not actor subjects. Service-account identity now protects the existing API; deriving this retry actor and revalidating authority within the retry transaction remain pending.

`ManualRetryIdempotency` validates the positive delivery ID and the raw key before database work. Keys contain 16–128 bytes of ASCII letters, digits, period, underscore, tilde, or hyphen, without normalization. SHA-256 of the exact key bytes becomes the lowercase hexadecimal `idempotency_key_digest`; the raw key is not persisted or returned. A separate SHA-256 digest of exactly `manual_retry:v1:delivery:<delivery_id>`, using the canonical base-10 ID, becomes `request_fingerprint`. Both digests contain 64 lowercase hexadecimal characters. The fingerprint is independent of the key, actor, source, timestamps, and mutable delivery state.

The unique database scope is `(actor_type, actor_subject, idempotency_key_digest)`. Delivery and source do not participate in that uniqueness: a key cannot be reused by one actor for another delivery, and changing entry points does not create a new scope. Distinct actors may independently use the same key.

### Locked decisions and atomic work

The command owns its transaction. Calling it inside an explicit outer `Repo.transaction` returns `{:error, :invalid_arguments}` before domain work, so a decision cannot be announced before a caller's later commit or rollback. Within the command:

1. Lock the delivery with `FOR UPDATE`, then lock its related endpoint with `FOR UPDATE`, matching the existing claim lock order. A missing delivery returns `not_found` without audit persistence.
2. Look up the actor-scoped digest before evaluating mutable eligibility. A fixed-size constant-time fingerprint match returns the original accepted or rejected record with `replayed?: true`, without another audit row, transition, attempt, or job. It remains a replay if the delivery is now pending or its endpoint is inactive. A different fingerprint returns `idempotency_conflict` without a write or disclosure of the original record.
3. For a new key, evaluate `ManualRetryPolicy` against the locked state. A known non-failed state yields `state_not_failed`; a failed delivery with an inactive endpoint yields `endpoint_inactive`; an active failed delivery already at cycle `3` yields `manual_cycle_limit_reached`. That precedence is preserved. A rejection commits only a `rejected` audit record with its reason and null `resulting_retry_cycle`, leaving the delivery, attempts, and jobs unchanged.
4. For an eligible failed delivery, insert an `accepted` audit record with no reason, the observed terminal status, lifetime attempt count, retry cycle, prior `completed_at`, trusted actor and source, digests, server request time, and resulting cycle. Transition that same delivery from `failed` to `pending`, increment `retry_cycle`, reset only `cycle_attempt_count` to zero, preserve `attempt_count`, clear `completed_at`, and leave `next_attempt_at` null.
5. Insert exactly one immediately available `DeliverWebhookWorker` job containing `delivery_id`, `attempt_number: delivery.attempt_count + 1`, the new `retry_cycle`, and `cycle_attempt_number: 1`. The accepted audit, delivery transition, and complete cycle-aware job commit atomically. A persistence failure or equivalent active job conflict rolls back all three effects and leaves the key unconsumed.

Acceptance also rejects active legacy delivery-only jobs and legacy jobs for the next lifetime attempt, preventing work without cycle identity from crossing the new boundary. Equivalent active cycle-aware work returns `active_job` as well. Existing jobs are preserved, and general legacy-job support remains temporary. Manual requests create no `Attempt` and do not alter the event, endpoint, prior attempts or their numbers and schedules, or earlier audit records.

Cycle `0` is the original automatic cycle; at most three accepted manual cycles, `1` through `3`, are permitted. Each cycle retains six persisted attempts, for a theoretical lifetime maximum of 24. The delivery lock serializes requests for one delivery. Concurrent distinct keys cannot both reopen it: after one acceptance, the other records `state_not_failed`. For one actor's key used concurrently across different deliveries, the unique index is authoritative. A losing transaction rolls back fully, then resolves the committed winner in a fresh transaction using the same lock order and fingerprint check.

## Current and future entities

### Project and service account

`Tidewake.Projects` stores stable project/account public UUIDs and digest-only credentials. Endpoint, Event and Delivery ownership is required and immutable through supported operations. Named restrictive foreign keys and composite Delivery references prevent cross-project links in PostgreSQL; existing data retains the recorded legacy ownership. Rotation adds a credential to the same account and preserves its actor subject.

### Endpoint

The implemented `Endpoint` model represents a project-owned registered destination. Its current responsibilities are:

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

The implemented `Event` model represents an immutable fact accepted from a client. Events are persisted with an event type, structured payload, and microsecond UTC timestamps. `external_id` is the client-provided idempotency key and is unique within its project through the `(project_id, external_id)` database index.

Current responsibilities:

- validating and persisting events through `Tidewake.Webhooks`;
- rejecting duplicate `external_id` values through the database constraint;
- supporting `POST /api/events` and individual retrieval through `GET /api/events/:id`;
- atomically creating deliveries and initial jobs for active endpoints in the event's project during ingestion;
- exposing delivery status through `GET /api/events/:id/deliveries` without exposing endpoint URLs, payloads, attempts, headers, or secrets;
- remaining immutable, with no update or delete operations.

Additional acceptance metadata remains a future responsibility.

### Delivery

The implemented `Delivery` model represents the intention to send one event to one endpoint. Its table, schema, and minimal operations in `Tidewake.Webhooks` are available.

Current responsibilities:

- requiring event and endpoint associations with a unique database constraint on the pair;
- following the implemented `pending → processing → pending` scheduled-retry cycle or a terminal transition to `succeeded`, `failed`, or `cancelled`;
- keeping `attempt_count` monotonic over the delivery's lifetime, `retry_cycle` as the current cycle identity, and `cycle_attempt_count` as the number of persisted attempts in that cycle; all three start at zero, with cycle `0` representing the original automatic cycle;
- allowing context-level creation for an active endpoint and retrieval by ID or by the event and endpoint pair;
- scheduling a delivery and its initial job atomically with `schedule_delivery/2`; new delivery jobs are identified and deduplicated by worker and the complete `delivery_id`, `attempt_number`, `retry_cycle`, and `cycle_attempt_number` identity while incomplete;
- atomically claiming only the expected pending attempt when its schedule is due, validating the new job's lifetime number, cycle, and cycle ordinal under the delivery lock, then querying and locking its endpoint and transitioning to `processing` when active or terminal `cancelled` when inactive;
- setting `completed_at` without creating an attempt or incrementing either attempt counter when a delivery is cancelled;
- locking a processing delivery during terminal finalization, inserting its attempt with the identity derived from the locked counters, incrementing both `attempt_count` and `cycle_attempt_count`, and setting status and `completed_at` in one transaction; invalid attempts roll back the operation;
- transactionally inserting a retryable failed attempt, advancing both attempt counters, returning the delivery to `pending`, and inserting the next scheduled job in the same cycle; `Attempt.next_attempt_at` remains historical while `Delivery.next_attempt_at` tracks the current pending schedule;
- reopening an eligible `failed` delivery only through the internal manual retry command, preserving lifetime history while atomically committing its audit decision, new cycle, and immediate job;
- listing only stale processing-delivery IDs in deterministic oldest-first batches of at most 100;
- transactionally returning an eligible stale delivery to `pending` and inserting its replacement job with the same unpersisted lifetime and cycle identity, without creating an attempt or changing any of the three counters.

The finalization operation and processor support `succeeded`, `http_error`, and `transport_error` attempt results. Safe allowlisted response metadata is extracted for HTTP outcomes, and transport reasons are normalized before persistence. The retry policy permits only the explicit transient allowlists and fails closed for unknown outcomes, with a six-attempt budget per cycle. Transactional API ingestion creates one delivery and one job with `attempt_number: 1`, `retry_cycle: 0`, and `cycle_attempt_number: 1` per active endpoint. If that endpoint is inactive at claim time, the existing delivery is cancelled without an adapter call or attempt. Recovery provides at-least-once handling for abandoned `processing` work. Production external sending and bounded domain retries are active.

### Attempt

`Attempt` has an implemented `delivery_attempts` table, schema, and context operations to create, retrieve, and list attempts by increasing attempt number, following ADR 0003.

Current responsibilities:

- linking to a delivery with uniqueness enforced for both `(delivery_id, attempt_number)` and `(delivery_id, retry_cycle, cycle_attempt_number)`;
- recording the immutable lifetime `attempt_number`, `retry_cycle`, and `cycle_attempt_number`; lifetime numbers continue monotonically across cycles, and cycle ordinals range from 1 through 6;
- deriving cycle identity from the delivery in the context, rather than accepting it from caller attributes;
- recording UTC start/finish timestamps and non-negative duration;
- recording an optional `next_attempt_at` only when that failed attempt scheduled a successor, preserving the retry decision after the delivery advances;
- validating `succeeded`, `http_error`, and `transport_error` results, with HTTP status only when a response exists;
- allowing only bounded `content_type`, non-negative `content_length`, and bounded `request_id` response metadata;
- remaining append-only, with no context update or delete operations.

The processor records successful, HTTP error, and transport error attempts. `ResponseMetadata` extracts only bounded `content_type`, `content_length`, and `request_id` values from valid HTTP response headers; transport failures carry no response metadata. Response bodies are streamed and discarded, with consumption stopped above 65,536 bytes. Sensitive headers, destination details, raw transport errors, and secrets are not persisted.

### ManualRetryRequest

`ManualRetryRequest` maps the implemented append-only `manual_retry_requests` audit table. It records the trusted actor and source, key digest and canonical request fingerprint, server `requested_at` and `inserted_at`, observed status, lifetime attempt count, retry cycle and completion timestamp, and the accepted or rejected outcome, reason, and resulting cycle. It has no `updated_at`, and the context exposes no audit update or delete operation.

A required restrictive foreign key retains the delivery association. Named constraints enforce bounded vocabularies, counters, digest formats, and accepted/rejected consistency. The actor-scoped unique index enforces idempotency, while `(delivery_id, inserted_at)` indexes the audit timeline. Trusted identity fields are set on the struct and cannot be replaced by arbitrary changeset attributes; actor subjects and both digests are redacted from accidental inspection.

The audit stores no raw key, token, signature, secret, payload, URL, body, headers, arbitrary metadata, exception, or raw error. Audit persistence and internal replay lookup are available; audit retrieval for operators or API callers is not.

## Current and future code boundaries

`Tidewake.Webhooks` owns endpoint, event, delivery, and attempt persistence, active endpoint lookup, atomic ingestion fan-out, delivery listing, guarded claim-time endpoint re-evaluation and cancellation, terminal finalization, transactional retry scheduling, stale-candidate selection, and single-delivery recovery. `Tidewake.Projects` owns projects, service accounts, credential lifecycle, Scope and the permission policy. `RequireServiceAccount` authenticates every API route and `RequirePermission` applies its explicit permission before controller execution. Authentication remains a `TidewakeWeb` concern and does not enter the `Tidewake.Webhooks` context. `EventController` exposes event ingestion, retrieval, and the read-only delivery status route. `Envelope` serializes events, and `Signature` produces the versioned HMAC headers from the event ID, attempt timestamp, exact body bytes, and configured secret. `OutboundResolver`, `OutboundAddress`, and `OutboundTarget` resolve, classify, and pin destinations before the Req call. `ResponseLimiter` bounds and discards response bodies, while `ResponseMetadata` enforces the safe persisted metadata boundary. `DeliveryAdapter` defines the transport contract; `DeliveryAdapters.Deterministic` implements local simulation, while `DeliveryAdapters.Req` is the production transport. `RetryPolicy` classifies normalized outcomes and owns the six-attempt limit per cycle, while `RetryBackoff` calculates bounded equal-jitter delays; both receive the current cycle's attempt ordinal. `DeliveryProcessor` coordinates signing, classification, terminal finalization, and retry scheduling. `Tidewake.Workers.DeliverWebhookWorker` delegates one logical attempt to it, and `Tidewake.Workers.RecoverStaleDeliveriesWorker` performs the bounded serial maintenance scan. `TidewakeWeb.Telemetry` declares the bounded domain metrics alongside the existing Phoenix, Ecto, and VM metrics.

The context also owns the internal `request_manual_retry/3` transaction, audit persistence, and actor-scoped replay resolution. `ManualRetryActor` validates trusted actor context without authenticating it; `ManualRetryIdempotency` derives protected digests without persistence; `ManualRetryPolicy` evaluates locked eligibility without side effects; and `ManualRetryRequest` maps the bounded audit evidence. The existing delivery worker executes the newly scheduled cycle through the ordinary processing pipeline. None of these modules exposes a retry route, controller, CLI command, UI, or audit retrieval operation.

Additional responsibilities and namespaces may emerge as behavior is implemented:

- human users, sessions, OAuth, JWT and automatic credential rotation;
- a metrics reporter, dashboards, logs, audit reporting, and an operational LiveView.

These future namespaces are not placeholders. Modules should be introduced only with tested behavior. The internal manual retry command and audit persistence are implemented, but the operation remains unexposed. Public retry access, audit retrieval, `Retry-After`, rate limiting, retention, an operational UI, alerting, and production deployment remain pending.

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

Telemetry covers confirmed event ingestion and rejection, confirmed delivery processing outcomes, committed retry schedules, confirmed retry exhaustion, inactive-endpoint cancellation, stale-delivery recovery batches, and controlled processing errors. Declarative metrics expose ingestion counts, rejected-event counts by bounded reason, deliveries created, processed-delivery counts by bounded outcome, retry scheduling counts and delay summaries by bounded cause, exhaustion counts by bounded cause, cancellation counts, processing duration, controlled-error counts and durations, sums of recovered, skipped, and controlled-error recovery items, and recovery batch duration. They do not include IDs, URLs, external IDs, payloads, bodies, headers, signing timestamps, signatures, secrets, database details, stack traces, or exception messages.

Each controlled manual retry invocation emits one `[:tidewake, :webhooks, :manual_retry, :completed]` event. Measurements are exactly `count: 1` and monotonic elapsed `duration_ms`; metadata contains only fixed-vocabulary `outcome` and `reason` strings. Accepted and rejected decisions emit after commit, replays after their read transaction completes, and errors after rollback or controlled validation failure. Outcomes are `accepted`, `rejected`, `idempotent_replay`, and `error`. Acceptance and replay use reason `none`; rejection uses its persisted policy reason. Errors map to `not_found`, `invalid_arguments`, `invalid_idempotency_key`, `idempotency_conflict`, `active_job`, or the bounded fallback `persistence`, never raw error details.

`TidewakeWeb.Telemetry` declares `tidewake.webhooks.manual_retry.completed.count` and `tidewake.webhooks.manual_retry.completed.duration_ms`, with milliseconds as the duration unit and only `outcome` and `reason` as tags. Actor type or subject, source, keys or digests, fingerprints, cycle and attempt counters, delivery and job IDs, endpoint or webhook data, changesets, exceptions, and stack traces are excluded from this event. Protected audit queries also disable Ecto query logging and Telemetry to avoid copying actor identity and digests into query events.

No metrics reporter, exporter, dashboard, retention policy, or alerting policy is configured. Queue latency, queue depth, structured logs, public manual retry access, audit retrieval, and the operational LiveView remain future work; aggregate Telemetry does not expose the protected audit records.

## Deployment boundary

This foundation defines no AWS resources and no deployment workflow. Production topology, secret storage, TLS termination, scaling, retention, and disaster recovery require separate decisions supported by measured needs.

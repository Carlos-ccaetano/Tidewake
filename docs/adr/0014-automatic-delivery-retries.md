# ADR 0014: Automatic delivery retry policy

- Status: accepted
- Date: 2026-10-15

## Context

Tidewake currently processes one outbound attempt per delivery. The processor claims a pending delivery, serializes and signs its event, calls the configured adapter once, and atomically persists the resulting attempt with a terminal `succeeded` or `failed` delivery. The Req adapter disables its own retries, and `Tidewake.Workers.DeliverWebhookWorker` uses `max_attempts: 1`, so there is no competing retry mechanism today.

The delivery schema already has `attempt_count` and `next_attempt_at`, attempts are unique by `delivery_id` and `attempt_number`, and stale-delivery recovery can return abandoned `processing` work to `pending` without inventing an attempt. ADR 0012 also requires every outbound request, including a retry, to receive a fresh timestamp and HMAC signature.

Automatic retries need one policy for classification, timing, persistence, job identity, recovery, and observability before runtime behavior changes. Without that agreement, an implementation could duplicate requests, lose scheduled work, retry permanent failures, or let Oban and the domain independently retry the same attempt.

Ironhold now acknowledges a freshly signed retry of an identical persisted envelope with `202 Accepted`. It still rejects exact reuse of the same signature and conflicting reuse of an event ID. Tidewake can therefore retry a request whose first response was lost, provided every logical attempt is signed again.

## Decision

### Attempt limit and outcomes

A delivery has at most six total persisted attempts. Attempt numbers are positive, contiguous integers beginning at `1`; `delivery.attempt_count` is the number of attempts already persisted.

An HTTP response from `200` through `299`, inclusive, is successful. The attempt is persisted as `succeeded`, and the delivery becomes `succeeded` with `completed_at` set and `next_attempt_at` cleared.

Only these HTTP statuses are retryable:

- `408 Request Timeout`;
- `425 Too Early`;
- `429 Too Many Requests`;
- `500 Internal Server Error`;
- `502 Bad Gateway`;
- `503 Service Unavailable`;
- `504 Gateway Timeout`.

Only these normalized transport error types are retryable:

- `timeout`;
- `dns`;
- `connection`;
- `closed`.

Every other HTTP status is terminal. The normalized transport error types `tls`, `destination`, `response_limit`, and `unknown` are terminal. Unknown or malformed outcomes fail closed and must not become eligible merely because they were not recognized.

HTTP `409 Conflict` is terminal for a generic destination. Tidewake does not infer receiver-specific semantics from that status. Ironhold returns `202 Accepted` for a legitimate freshly signed retry of an identical event, so its idempotent acknowledgement follows the normal success path rather than requiring a special Tidewake exception.

A retryable failure becomes terminal when it is attempt number `6`. Terminal HTTP and transport failures are persisted using the existing bounded attempt representation, and the delivery becomes `failed` with `completed_at` set and `next_attempt_at` cleared.

Classification belongs in a small pure module. It accepts only a normalized HTTP status or transport error type and returns a bounded decision such as `:success`, `:retryable`, or `:terminal`; it performs no I/O, reads no application configuration, and does not inspect raw adapter errors.

### Backoff and equal jitter

The backoff base is 10 seconds and the maximum calculated delay is 300 seconds. After retryable attempt `n`, the full delay ceiling is:

```text
full_delay(n) = min(300, 10 * 2^(n - 1)) seconds
```

Equal jitter selects an integer number of seconds from the inclusive interval:

```text
floor(full_delay(n) / 2)..full_delay(n)
```

For the current six-attempt limit, retries after attempts 1 through 5 therefore use inclusive ranges `5..10`, `10..20`, `20..40`, `40..80`, and `80..160` seconds. The 300-second ceiling remains part of the policy and bounds the calculation if the attempt limit is changed by a later decision.

The next time is calculated from the completed attempt's trusted server-side completion time plus the selected delay. Client data, response headers, and wall-clock values supplied by a destination do not influence it.

Backoff range calculation and selection belong in a small pure module. Randomness is supplied explicitly by the orchestration boundary, so tests can select the lower bound, upper bound, and intermediate values deterministically without sleeping or changing a global random process.

### Atomic retry scheduling

After a retryable result before the limit, one database transaction must:

1. lock and revalidate the `processing` delivery;
2. insert attempt `n` with its normalized HTTP or transport outcome;
3. update the delivery to `pending` with `attempt_count: n`, the chosen `next_attempt_at`, and `completed_at: nil`;
4. insert exactly one Oban job scheduled for `next_attempt_at`, with arguments `delivery_id` and `attempt_number: n + 1`.

All four effects commit together. If the attempt, delivery update, or job insert fails, the transaction rolls back. Tidewake must never persist a retry decision without durable scheduled work, schedule work without the attempt that justified it, or expose a partially updated delivery.

The attempt that scheduled a retry stores its own `next_attempt_at` value for audit. Implementing this decision therefore requires a nullable `next_attempt_at` field on the attempt record. Successful attempts and terminal failures leave that attempt field empty.

After this transaction commits, the currently executing Oban job returns success. Domain retry scheduling must not be represented as an Oban job failure. `DeliverWebhookWorker` keeps `max_attempts: 1`, Req keeps its internal retry option disabled, and no lower transport layer may repeat the request. These boundaries ensure that only the persisted Tidewake policy creates a later logical attempt.

### Job identity and execution guard

Every delivery job contains exactly these domain arguments:

```json
{"delivery_id": 123, "attempt_number": 2}
```

The initial job uses `attempt_number: 1`. Job uniqueness considers the worker plus both `delivery_id` and `attempt_number` for incomplete jobs. This prevents duplicate jobs for the same logical attempt while allowing a later numbered attempt for the same delivery.

Before serialization, signing, or adapter invocation, the claim transaction locks the delivery and requires the job's `attempt_number` to equal `delivery.attempt_count + 1`. It also requires the delivery to be `pending`. When `next_attempt_at` is present, the attempt may not be claimed before that instant.

An old or duplicate job whose number is below the expected number completes as a no-op. A job whose number is above the expected number is rejected as a controlled mismatch and leaves the delivery unchanged. A correctly numbered job observed before `next_attempt_at` is deferred to that persisted instant without sending HTTP. None of these paths serializes the event, creates signing material, calls the adapter, or creates an attempt.

The database constraints, delivery row lock, job uniqueness, and expected-number check jointly enforce this boundary. Correctness must not depend on which worker process reaches it first.

### Signing and receiver idempotency

Each logical attempt serializes the immutable event envelope and generates a current timestamp and HMAC signature after it has successfully claimed the delivery. Timestamps and signatures are never copied from an earlier attempt or stored in the retry job.

The event's `external_id` remains stable across attempts. A receiver can use it for event idempotency, while the new timestamp and signature identify a distinct authenticated request. This preserves Ironhold's distinction between a legitimate freshly signed retry and exact cryptographic replay.

Tidewake still provides at-least-once delivery, not exactly-once delivery. A process can send a request and exit before persisting the outcome. Recovery may then send the same event again with fresh signing material.

### Endpoint state and stale recovery

Endpoint activity is re-evaluated when every retry is claimed. If the endpoint is inactive, the existing cancellation behavior remains authoritative: the delivery becomes `cancelled`, no HTTP request is made, no attempt is created, and no later retry job is scheduled.

Stale recovery continues to mean that no outbound outcome was persisted. It creates no attempt and does not increment `attempt_count`. Its replacement job uses the same logical attempt number that was abandoned:

```text
delivery.attempt_count + 1
```

For example, if attempt 2 was claimed and the process exited before its outcome was persisted, recovery returns the delivery to `pending` and schedules attempt 2 again, not attempt 3. Recovery remains atomic with replacement-job insertion and continues to exclude active equivalent work. The replacement request, if sent, receives a fresh timestamp and signature.

### Telemetry and confidentiality

Retry instrumentation follows the existing `[:tidewake, :webhooks]` namespace and ADR 0008's post-commit boundary. It may report only bounded counts, durations, delay measurements, attempt-limit state, and allowlisted categorical outcomes. Any reason dimension must come from a fixed set derived from this policy, such as the seven retryable HTTP statuses, four retryable transport types, terminal classification, exhausted attempts, stale job, attempt mismatch, or early execution.

Telemetry measurements, metadata, tags, and event names must not contain:

- event, delivery, endpoint, attempt, or job IDs;
- endpoint URLs or resolved addresses;
- event types, payloads, or payload fragments;
- request or response headers or bodies;
- timestamps or signatures used for HMAC;
- signing secrets or API tokens;
- raw adapter errors, exception text, changesets, or database details.

Retry scheduling telemetry is emitted only after the attempt, delivery transition, and next job commit. A rolled-back retry transaction must not emit a success signal. Exact event and metric names will be added with the implementation and must extend, rather than replace, the existing telemetry system.

## Consequences

### Positive

- Transient failures receive a bounded recovery path without retrying permanent or unknown outcomes.
- Attempt history, delivery state, audit scheduling time, and the next job remain transactionally consistent.
- Logical attempt numbers make duplicate, stale, future, and recovered work distinguishable before any network request.
- Keeping Oban and Req retries disabled leaves one authoritative retry mechanism.
- Fresh signing material makes retries compatible with Ironhold's replay protection and event idempotency contract.
- Pure classification and backoff modules permit deterministic boundary tests.

### Negative

- Retry scheduling requires coordinated changes to attempts, context transactions, worker arguments, uniqueness, recovery, and telemetry.
- A retryable outage can retain a delivery in `pending` for multiple scheduled attempts before it becomes terminal.
- Equal jitter makes the exact production delay variable even though its allowed range is deterministic.
- Generic destinations that use `409` to request a retry are not retried.
- The current six-attempt limit does not reach the 300-second ceiling, although the ceiling still bounds the policy.

## Alternatives considered

### Use Oban's automatic retries

Rejected because job failures would become a second retry state machine disconnected from persisted attempts and `next_attempt_at`. Domain scheduling must commit with the delivery and attempt, while Oban remains a one-execution carrier for each logical attempt.

### Retry every HTTP or transport failure

Rejected because authentication, TLS, destination-policy, response-limit, client, and unknown failures are not assumed transient. An explicit allowlist fails closed and prevents repeated unsafe or futile requests.

### Treat HTTP 409 as retryable for Ironhold

Rejected because status semantics must remain safe for generic destinations. Ironhold acknowledges a freshly signed idempotent retry with `202`; its `409` response represents exact replay or conflicting event content and is terminal.

### Persist the attempt before scheduling in a separate transaction

Rejected because a crash or insertion failure could leave a pending delivery without work or a job without the persisted decision that created it.

### Let a retry reuse the previous timestamp and signature

Rejected because Ironhold correctly classifies identical signing material as exact replay. Every new outbound attempt must be authenticated independently.

### Use fixed delays or full jitter

Rejected because fixed delays synchronize workers during a shared outage, while full jitter permits immediate retries. Equal jitter retains dispersion and guarantees a lower bound of half the calculated ceiling.

## Out of scope

- implementing this policy or activating automatic retries;
- honoring `Retry-After`;
- manual retry operations or audit flows;
- user interface work;
- external alerts, reporters, or dashboards;
- administrative authentication or project-scoped authorization;
- changing an accepted event payload between attempts;
- adding dependencies;
- changing Ironhold;
- changing secret rotation or multiple-key support.

## Follow-up

Implement the schema, pure policy modules, atomic context operation, numbered worker contract, stale-recovery alignment, and bounded Telemetry in separate reviewed changes. Add deterministic tests for every status and transport class, all jitter boundaries, transaction rollback, concurrency, old and early jobs, six-attempt exhaustion, fresh signing material, endpoint cancellation, and recovery of the same unpersisted attempt number before enabling automatic retries.

## References

- [ADR 0003: Delivery attempt recording](0003-delivery-attempt-recording.md)
- [ADR 0005: Outbound HTTP transport](0005-outbound-http-transport.md)
- [ADR 0008: Webhook telemetry contract](0008-webhook-telemetry.md)
- [ADR 0009: Delivery-time endpoint deactivation](0009-delivery-time-endpoint-deactivation.md)
- [ADR 0011: Stale delivery recovery](0011-stale-delivery-recovery.md)
- [ADR 0012: Signed webhook contract](0012-signed-webhook-contract.md)
- [ADR 0013: Safe outbound delivery](0013-safe-outbound-delivery.md)
- [Event ingestion API contract](../api/events.md)

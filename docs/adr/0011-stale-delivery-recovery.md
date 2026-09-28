# ADR 0011: Stale delivery recovery

- Status: accepted
- Date: 2026-09-27

## Context

Tidewake atomically claims a pending delivery by moving it to `processing` before encoding the event, calling the delivery adapter, and persisting a final attempt and delivery outcome. An unexpected runtime exit, malformed adapter response, or persistence failure after claim can therefore leave a delivery in `processing` after its job can no longer complete it.

ADR 0002 intentionally excluded retries and did not allow a delivery to return to `pending`. This decision adds one narrow recovery transition for abandoned processing work. It does not define HTTP retry eligibility or change the meaning of an attempt from ADR 0003: an attempt remains evidence of a confirmed outbound outcome.

## Decision

### Eligibility and stale threshold

A delivery is a recovery candidate only when its current status is `processing`. No `pending`, `succeeded`, `failed`, or `cancelled` delivery is eligible.

For this phase, `updated_at` is the time of the latest delivery state transition. A `processing` delivery becomes stale when its `updated_at` is at or before the recovery scan time minus the configured stale threshold. The default threshold is five minutes.

The threshold must be configurable through trusted application or deployment configuration. It must be validated as a positive duration with an operationally bounded range before use. API parameters, request bodies, headers, job arguments, or other caller-controlled request values must not select or override it.

No additional claim timestamp column will be introduced in this phase. While a delivery is in `processing`, the current model permits no other delivery updates before finalization. Consequently, `updated_at` already records the claim transition closely enough for stale detection, without adding another persisted timestamp and synchronization invariant. A dedicated timestamp may be reconsidered if future behavior can update a processing delivery for reasons other than leaving that state.

### Recovery transaction

Recovery introduces the narrowly scoped transition `processing → pending`. For each recovered delivery:

- `attempt_count` remains unchanged;
- no attempt is created, because recovery has no confirmed HTTP or transport result to record;
- `completed_at` is set to `nil`;
- `next_attempt_at` is set to `nil`;
- a new delivery job is created for the same delivery.

The state transition and new job insertion must occur in one database transaction. The delivery row must be locked and its status and staleness rechecked inside that transaction. If the replacement job cannot be inserted, the transaction must roll back so the delivery remains `processing`; Tidewake must never commit a recovered `pending` delivery without durable work scheduled for it.

The replacement job follows the existing contract: its arguments contain only `delivery_id`, and normal claim-time endpoint re-evaluation still applies when it runs.

### Concurrency and batching

An active job that can still start or continue processing a delivery makes that delivery ineligible for recovery. In particular, available, scheduled, executing, or retryable work must not coexist with a replacement job in a way that can process the same delivery concurrently. Recovery must coordinate the delivery row lock with Oban job state and uniqueness so only one runnable job exists for the delivery.

Multiple recovery processes must be safe to run concurrently. Candidate rows must be locked or skipped using database concurrency controls, and every candidate must be rechecked after locking. Losing a race means skipping that delivery, not creating another job.

Each scan processes a configurable, bounded batch. Candidates are ordered by `updated_at` ascending, with a stable delivery identifier as a tie-breaker, so the oldest stale deliveries are considered first. The batch size is trusted operational configuration and is not accepted from API requests.

### Delivery semantics

Recovery provides at-least-once delivery semantics, not exactly-once semantics. A process can send an outbound request and then fail before persisting its result. Because there is no confirmed persisted outcome, recovery creates no attempt and schedules the delivery again. The replacement job may therefore resend a request that the external endpoint already received.

Consumers must tolerate duplicate webhook requests, and future signing or idempotency mechanisms must not claim to eliminate this crash window unless a separate design proves that guarantee.

### Observability and secret handling

Recovery may emit bounded logs or Telemetry for operational counts, batch duration, and bounded outcomes such as recovered, skipped-active-job, or failed. Logs and Telemetry must not include endpoint URLs, event payloads, request or response headers, authorization values, webhook signatures, API tokens, or any other secret. Raw exceptions or job arguments must not be serialized when they could expose those values.

## Out of scope

- implementation of the recovery query, transaction, scheduler, worker, or periodic trigger;
- HTTP retry classification or eligibility;
- exponential backoff, jitter, retry limits, and `next_attempt_at` scheduling;
- recording an attempt without a confirmed HTTP or transport result;
- exactly-once delivery guarantees;
- changes to outbound transport activation, HMAC signing, or endpoint idempotency.

## Consequences

### Positive

- Deliveries abandoned after claim have a bounded path back to schedulable work.
- Atomic job creation prevents a recovered delivery from becoming pending without durable processing work.
- Preserving `attempt_count` and omitting an attempt keeps recorded history limited to confirmed outcomes.
- Row locking, active-job checks, uniqueness, and bounded oldest-first batches define the required concurrency and load boundaries.
- Reusing `updated_at` avoids a schema change while the processing state has no independent updates.

### Negative

- A five-minute default delays recovery and cannot distinguish a crashed process from legitimately slow processing without consulting job activity.
- At-least-once recovery can produce duplicate outbound requests after an unpersisted result.
- Reusing `updated_at` depends on preserving the rule that a processing delivery has no other updates.
- Job-state coordination adds implementation complexity before recovery can be enabled safely.

## Follow-up

Implement recovery in a separate change with tests for status and threshold eligibility, oldest-first bounded batches, concurrent scanners, active-job exclusion, unchanged attempt history, cleared scheduling timestamps, atomic job insertion rollback, and the at-least-once crash window. Decide HTTP retries and backoff in a separate ADR.

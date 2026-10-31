# ADR 0015: Manual delivery retry policy

- Status: accepted
- Date: 2026-10-17

## Current implementation status

The [request_manual_retry/3 command](../../lib/tidewake/webhooks.ex), append-only audit and admin-only POST/GET boundary are implemented. Project-bound service-account authentication supplies Scope; the command revalidates current admin authority and uses v2 fingerprints with digest-only actor-scoped idempotency. Acceptance commits audit, transition and immediate job together; rejection commits only its decision, and replay writes nothing. [Integrated security tests](../../test/tidewake_web/controllers/manual_retry_api_security_test.exs) cover authorization, admission, concurrent requests and rollback.

There are six automatic attempts per cycle and at most three manual cycles after the original cycle, for a theoretical maximum of 24; lifetime history is preserved. See the [current HTTP contract](../api/manual-retries.md). Human identity/UI, HTTP credential management, audit retention/deletion, receiver `Retry-After` handling and production deployment remain pending; Ironhold is unchanged. The context and decision below retain their historical wording.

## Context

The context and prospective implementation wording below describe the state when this decision was accepted.

Tidewake owns outbound delivery and currently gives each delivery one automatic retry cycle of at most six persisted attempts. Attempt numbers are positive and unique within a delivery, `delivery.attempt_count` is the number of persisted attempts, jobs are guarded by their logical attempt number, and attempts remain append-only. A delivery becomes terminal `failed` after a permanent outcome or after the sixth retryable failure. There is no manual retry operation, audit record, API, or user interface.

Operators will need a controlled way to retry a terminal delivery after correcting an external or endpoint condition. Reopening a delivery without a prior policy could erase terminal history, reuse attempt numbers, bypass the six-attempt limit, race an automatic job, or create a delivery transition without durable work. The current shared API token authenticates one credential but cannot identify an individual actor or authorize a project-scoped administrative action.

This decision defines the domain and persistence contract before any migration, schema, context function, route, or interface is implemented. It does not make manual retry available.

## Decision

### Ownership and eligibility

Manual delivery retry is a Tidewake sender-side operation. A receiver such as Ironhold continues to own authentication of received webhooks, signature verification, replay protection, event idempotency, and persistence of received requests. A receiver response, including a future `Retry-After` header, never performs or authorizes a manual Tidewake retry.

Only a delivery whose locked current status is `failed` is eligible. The failure may have been permanent or may have exhausted its automatic budget; an operator may have corrected the condition in either case. The current endpoint must also be active when the request is accepted.

Every other state is ineligible:

| Delivery state | Manual retry behavior |
| --- | --- |
| `pending` | Reject because durable work already exists or is scheduled. |
| `processing` | Reject because an attempt may be in flight. |
| `succeeded` | Reject because Tidewake has already recorded consumer acceptance. |
| `failed` | Accept only when the endpoint is active and all other guards pass. |
| `cancelled` | Reject because cancellation is an intentional terminal history, not a failed attempt. |

Reactivating an endpoint does not make a cancelled delivery eligible. A future policy for explicitly resuming cancelled work would be a distinct operation and must not be hidden inside manual retry.

If the endpoint is inactive when the manual request is evaluated, Tidewake records a rejected request and creates no job or delivery transition. If it becomes inactive after an accepted request commits, the existing claim-time rule remains authoritative: the pending delivery becomes `cancelled` without an HTTP request or attempt.

### Retry cycles and the automatic budget

An accepted manual retry starts a new retry cycle. Each cycle has its own budget of at most six persisted attempts and uses the same automatic classification, backoff, signing, destination-safety, and transactional scheduling rules as the initial cycle. Manual retry does not grant one unbounded attempt stream and does not cause Oban or Req to retry independently.

The original delivery remains the unit of work. Its lifetime `attempt_count` and `Attempt.attempt_number` continue monotonically across cycles and are never reset or reused. The implementation must add explicit persisted cycle identity and a per-cycle attempt count or ordinal so the six-attempt policy is evaluated against the current cycle rather than the lifetime attempt number. Cycle `0` is the original automatic cycle; every accepted manual request increments the delivery's cycle by one and begins that cycle with zero persisted attempts.

For example, a delivery that failed after attempts `1` through `6` may start manual cycle `1`. Its first new attempt is lifetime attempt `7`, cycle attempt `1`; at most attempts `7` through `12` may be persisted in that cycle. A later manual cycle continues with lifetime attempt `13` while again beginning at cycle attempt `1`.

Every new attempt records both its immutable lifetime number and cycle identity. Existing attempts belong to cycle `0` after migration. `Attempt.next_attempt_at` values from prior cycles remain unchanged. A manual request creates no attempt itself; an attempt is appended only after an outbound outcome is available under the existing rules.

Delivery jobs for this policy carry the delivery ID, lifetime attempt number, retry-cycle identity, and cycle attempt number. Claim requires all four values to match the locked delivery state. Job uniqueness and the claim guard include the cycle identity so work from an earlier cycle cannot cross a manual-retry boundary. The pure retry policy uses the cycle attempt number for the six-attempt decision. Oban retains `max_attempts: 1`, and Req retries remain disabled.

### Delivery transition and historical evidence

An accepted request transitions the same delivery from `failed` to `pending`, clears `completed_at`, leaves `next_attempt_at` empty for immediate work, resets only the current cycle's attempt counter, and inserts an immediately available job for the next lifetime and cycle attempt numbers.

This mutable current-state projection does not rewrite history. Existing events and attempts remain immutable and no attempt is deleted, renumbered, or modified. The accepted manual-retry record preserves the prior terminal status, prior `completed_at`, prior lifetime attempt count, and the new cycle number so clearing the delivery's current `completed_at` does not erase the earlier terminal boundary.

### Actor and audit record

Every first-seen, authenticated and authorized manual request creates one append-only `manual_retry_request` audit record, whether the domain decision is accepted or rejected. The record contains only fixed, bounded fields:

- delivery reference;
- stable actor type and actor subject supplied by the trusted authentication boundary;
- a bounded source such as `api`, `liveview`, or `admin_cli`;
- a cryptographic digest of the caller's idempotency key, not the raw key;
- trusted server request time;
- outcome `accepted` or `rejected` and a bounded reason code;
- the delivery status, lifetime attempt count, cycle identity, and terminal completion time observed under the lock;
- the resulting cycle identity when accepted.

The actor and source are derived from authenticated server context and are never accepted as caller-supplied audit fields. The current shared bearer token is insufficient because it cannot identify an actor. No public API or UI for manual retry may be exposed until Tidewake has an authenticated principal and authorization policy capable of attributing and authorizing the operation. Authorization failure is handled at the security boundary without disclosing whether the delivery exists; it does not enter the domain transaction as a spoofable actor.

The audit entity has no domain update or delete operation. It stores no event payload, endpoint URL, request or response body, HTTP headers, signature, signing secret, bearer token, raw idempotency key, exception, changeset, or arbitrary metadata map. Free-form operator notes are not part of the initial record.

### Request idempotency

Every manual retry requires a caller-generated idempotency key. Tidewake validates its bounded wire format, computes a fixed digest, and discards the raw value. A database unique constraint scopes that digest to the authenticated actor identity. When project ownership exists, the authorization scope also participates in the canonical request comparison.

The audit record stores a fingerprint of the canonical request, including the delivery and operation. Repeating the same key with the same canonical request returns the original audit outcome and creates no additional audit row, transition, cycle, attempt, or job. Reusing the key for a different delivery or canonical request returns an idempotency conflict and creates no work.

The idempotency check occurs after locking the delivery but before state eligibility is evaluated. Therefore a replay of an accepted request returns that accepted result even though the delivery is now `pending`, while a new key observes and records the current ineligible state.

### Concurrency

The operation locks the delivery row using the same lock order as delivery claim and then locks and reads its endpoint. The locked delivery is the authority for state, counters, cycle, and idempotent replay.

When a manual request races an automatic job:

- if the automatic job has already claimed the delivery, the manual request observes `processing` and is rejected;
- if the manual request locks an eligible `failed` delivery first, it creates the new cycle and job atomically;
- any stale job from an older cycle is rejected by the cycle and attempt guards before serialization, signing, adapter invocation, or attempt insertion.

When two different manual requests race for the same failed delivery, the first accepted transaction changes it to `pending`. The second request then records a bounded `state_not_failed` rejection and creates no job. Concurrent requests with the same idempotency key converge on the one audit record and return the same result. Database uniqueness is authoritative; application checks alone are not sufficient.

### Transaction boundary and rollback

For an accepted request, one database transaction must:

1. lock and revalidate the delivery and endpoint;
2. resolve the idempotency key under the authenticated actor scope;
3. insert the immutable accepted audit record;
4. increment the retry cycle and transition the delivery from `failed` to `pending` with the guarded counters and timestamps;
5. insert exactly one immediately available Oban job for cycle attempt `1` and lifetime attempt `delivery.attempt_count + 1`.

The audit record, delivery transition, and job commit together. Failure to persist any record, an unexpected job conflict, or any constraint failure rolls back all accepted effects. Tidewake must never report acceptance with no durable job, enqueue work without its audit decision, or consume the idempotency key for an accepted operation that rolled back.

An ineligible but otherwise authenticated and authorized request commits only its immutable rejected audit record under the same locked observation. An idempotent replay returns the existing record and performs no write. Transaction failures are returned as controlled errors and are not misreported as domain rejections or acceptance.

### Observability and confidentiality

Manual-retry instrumentation may emit only post-commit counts and bounded categorical metadata for outcomes such as `accepted`, `rejected`, `idempotent_replay`, and `error`, with a fixed reason vocabulary. It may also measure transaction duration. IDs, actor subjects, idempotency keys or digests, cycle numbers, attempt numbers, endpoint data, event data, URLs, payloads, bodies, headers, signing material, tokens, changesets, raw errors, database details, and stack traces are prohibited from Telemetry metadata and metric tags.

Controlled logs may use the same bounded outcome and reason vocabulary but must not duplicate protected audit fields or webhook data. The append-only audit record, subject to future project authorization and retention rules, is the authoritative place for actor attribution and delivery-specific evidence.

## Consequences

### Positive

- Operators can request recovery only from a well-defined terminal failure state.
- A new automatic budget is explicit per manual cycle without resetting or renumbering lifetime history.
- Audit, state transition, and durable work cannot diverge after a partial commit.
- Actor-scoped idempotency and row locks make duplicate and concurrent requests deterministic.
- Cycle-aware jobs prevent old automatic work from executing after a manual retry.
- Existing signing, receiver idempotency, endpoint safety, and bounded automatic retry rules remain authoritative.

### Negative

- Implementation requires new audit and cycle persistence, migrations, job arguments, uniqueness, claim guards, and policy inputs.
- A delivery can accumulate more than six lifetime attempts across operator-authorized cycles.
- Clearing the delivery's current completion timestamp requires the audit record to preserve the earlier terminal boundary.
- Cancelled deliveries cannot be recovered through this operation.
- Manual retry cannot be exposed while Tidewake has only a shared token and no attributable authorization model.

## Alternatives considered

### Reset `attempt_count` and reuse attempt numbers

Rejected because it would collide with immutable attempt uniqueness, obscure lifetime history, and allow old jobs to look current.

### Continue the original six-attempt budget

Rejected because an exhausted delivery would have no usable attempt remaining, making its manual retry nominal rather than effective.

### Create a new delivery row

Rejected because the event and endpoint pair is unique and a second delivery would split one delivery's operational history. An explicit cycle on the existing delivery preserves that identity.

### Allow retry from `succeeded` or `cancelled`

Rejected because success already records consumer acceptance and cancellation records an intentional decision not to send. Repeating either requires a distinct policy with different safety semantics.

### Enqueue outside the transaction

Rejected because a crash could leave an accepted audit and pending delivery without work, or work without the state and audit that authorized it.

### Attribute the shared API token as the actor

Rejected because one shared secret authenticates access but cannot identify which human or service requested the operation.

## Out of scope

- migrations, schemas, context functions, workers, controllers, routes, API contracts, or LiveView implementation;
- user, service-account, project, role, and permission implementation;
- retrying `pending`, `processing`, `succeeded`, or `cancelled` deliveries;
- editing an event, payload, endpoint, attempt, or historical schedule during retry;
- delayed or scheduled manual retry;
- honoring or emitting `Retry-After`;
- changing automatic failure classification, backoff, signing, destination validation, response limits, or stale recovery;
- rate limiting, lifetime manual-cycle limits, retention, audit export, dashboards, alerts, or production deployment;
- changes to Ironhold or any other receiver.

## Follow-up

Implement the required persistence in a separately reviewed change before adding any operational boundary. Tests must cover every state and endpoint condition, per-cycle six-attempt exhaustion, monotonic lifetime numbering, immutable history, same-key replay, key mismatch, two-key concurrency, automatic-job races, stale-cycle jobs, actor derivation, authorization denial, atomic rollback at every insert/update boundary, and bounded non-disclosing observability.

Only after identity and project-scoped authorization are defined should Tidewake add a manual-retry API or UI. `Retry-After`, operational presentation, rate limits, retention, and deployment remain separate decisions.

## References

- [ADR 0002: Initial delivery lifecycle](0002-delivery-lifecycle.md)
- [ADR 0003: Delivery attempt recording](0003-delivery-attempt-recording.md)
- [ADR 0008: Webhook telemetry contract](0008-webhook-telemetry.md)
- [ADR 0009: Delivery-time endpoint deactivation](0009-delivery-time-endpoint-deactivation.md)
- [ADR 0010: API token authentication](0010-api-token-authentication.md)
- [ADR 0011: Stale delivery recovery](0011-stale-delivery-recovery.md)
- [ADR 0012: Signed webhook contract](0012-signed-webhook-contract.md)
- [ADR 0013: Safe outbound delivery](0013-safe-outbound-delivery.md)
- [ADR 0014: Automatic delivery retry policy](0014-automatic-delivery-retries.md)
- [Event ingestion API contract](../api/events.md)

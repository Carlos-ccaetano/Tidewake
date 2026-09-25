# ADR 0009: Delivery-time endpoint deactivation

- Status: accepted
- Date: 2026-09-25

## Context

Tidewake creates a pending delivery and an initial Oban job for every endpoint that is active when an event is ingested. The delivery and job preserve the durable fan-out decision even if the endpoint is deactivated later.

ADR 0002 deferred the `cancelled` state and the behavior of existing deliveries after endpoint deactivation. ADR 0006 requires Tidewake to re-evaluate endpoint eligibility immediately before outbound delivery, but does not define the resulting delivery transition or job outcome. The delivery processor therefore needs a policy for a pending delivery whose endpoint becomes inactive after fan-out and before processing begins.

This decision concerns preparation for processing. It does not activate external HTTP delivery or define retry behavior.

## Decision

### Delivery-time eligibility

Tidewake must read the endpoint's current state again when a pending delivery is prepared for processing. The endpoint state captured during fan-out is not sufficient for this decision.

If the endpoint is active, the delivery may transition from `pending` to `processing`. If the endpoint is inactive, the delivery must instead transition from `pending` to `cancelled`.

Cancellation is a terminal outcome for that delivery and has these invariants:

- `completed_at` is set when the cancellation is persisted;
- `attempt_count` remains unchanged;
- no `Attempt` is created because no HTTP request occurred;
- the delivery adapter is not called;
- the Oban job completes normally and is not retried.

Reactivating the endpoint does not automatically return a cancelled delivery to `pending`, create a replacement delivery, or enqueue another job. Cancelled deliveries remain persisted and visible through the delivery status API as historical fan-out outcomes.

This decision extends the lifecycle in ADR 0002 with one transition:

| From | To | Condition |
| --- | --- | --- |
| `pending` | `cancelled` | The endpoint is inactive when the delivery is prepared for processing. |

`cancelled` is terminal. No transition out of `cancelled` is authorized by this ADR.

### Concurrency boundary

Preparation must run in a database transaction and lock the delivery row before evaluating or changing its state. Only a delivery that is still `pending` after the lock is acquired may proceed through the active or inactive branch.

The endpoint state must be read inside that transaction. Preparation must serialize that read with endpoint deactivation, for example by locking the endpoint row against concurrent updates until the delivery transition commits. This produces an unambiguous order:

- a deactivation committed before the endpoint state is read is observed, and the pending delivery is cancelled;
- if preparation commits the transition to `processing` first, a later deactivation does not change that processing cycle.

The adapter may be called only after the transition to `processing` is confirmed. Deactivating an endpoint after processing has been confirmed does not interrupt an HTTP request already in progress. Tidewake will not attempt to cancel in-flight I/O in the middle of execution.

### Observability

A future implementation will emit this terminal event for a delivery cancelled by this policy:

```elixir
[:tidewake, :webhooks, :delivery, :cancelled]
```

Its measurements and metadata are exactly:

```elixir
%{count: 1}
%{reason: "endpoint_inactive"}
```

The event may be emitted only after the transaction that persists `cancelled` and `completed_at` returns confirmed success. A rollback or failure to persist the cancellation must not emit it. The event carries no delivery, endpoint, event, attempt, or job identifier and no payload, URL, changeset, exception, or other metadata.

This cancellation event is distinct from the processed and error events defined by ADR 0008. A cancelled delivery emits neither `[:tidewake, :webhooks, :delivery, :processed]` nor `[:tidewake, :webhooks, :delivery, :error]` for the same preparation outcome.

## Consequences

### Positive

- Endpoint deactivation prevents a pending delivery from starting new work.
- Cancellation is durable and visible without inventing an HTTP attempt that never occurred.
- Normal Oban completion avoids retrying a deliberate domain outcome.
- Row locking gives concurrent workers one authoritative delivery transition.
- Endpoint reactivation cannot silently revive historical work.
- Post-persistence Telemetry cannot claim a cancellation that rolled back.

### Negative

- Endpoint deactivation does not stop work that has already entered `processing`.
- Serializing preparation with endpoint updates can briefly block a deactivation or delivery claim.
- Cancelled deliveries require status consumers to recognize an additional terminal state.
- Rescheduling a cancelled delivery, if ever supported, will require an explicit future policy.

## Alternatives considered

### Process every delivery created while the endpoint was active

Rejected because current endpoint deactivation would not prevent pending work from starting.

### Delete the delivery or its Oban job

Rejected because deletion would remove the durable fan-out history and make the outcome invisible through the status API.

### Create an attempt that records the skipped request

Rejected because attempts are evidence of processing results, and no adapter or HTTP request ran.

### Fail or retry the Oban job

Rejected because endpoint inactivity is an intentional terminal domain outcome rather than a transient processing failure.

## Out of scope

- endpoint deletion;
- manual cancellation;
- retry behavior;
- automatic reactivation or resurrection of cancelled deliveries;
- HMAC signing;
- Req activation or transport behavior;
- SSRF protection;
- recovery of deliveries in `processing`.

## Follow-up

Add the `cancelled` delivery state and implement transactional delivery preparation with the required locks, endpoint re-evaluation, terminal cancellation fields, and normal Oban completion. Add the cancellation Telemetry event only with post-persistence tests and the exact bounded metadata defined here. Extend status API tests to keep cancelled deliveries visible.

## References

- [ADR 0002: Initial delivery lifecycle](./0002-delivery-lifecycle.md)
- [ADR 0006: Event delivery fan-out](./0006-event-delivery-fanout.md)
- [ADR 0008: Webhook telemetry contract](./0008-webhook-telemetry.md)

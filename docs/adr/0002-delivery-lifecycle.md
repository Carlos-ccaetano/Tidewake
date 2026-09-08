# ADR 0002: Initial delivery lifecycle

- Status: accepted
- Date: 2026-09-08

## Context

Tidewake persists immutable events and registered webhook endpoints. The next part of the first vertical slice needs a small delivery model that records the intention to send one event to one endpoint without prematurely defining retry behavior or rules for a particular consumer.

The architecture already treats attempts as append-only operational evidence and keeps Ironhold outside the Tidewake system boundary. This decision establishes only the lifecycle and invariants needed by the initial `Delivery` cycle. Database, schema, worker, and outbound HTTP implementation remain separate work.

## Decision

A `Delivery` links exactly one `Event` to exactly one `Endpoint`. Both associations are required. The pair `event_id + endpoint_id` is unique, so Tidewake creates at most one delivery for a given event and endpoint.

An endpoint must be active when a new delivery is created. An inactive endpoint does not receive new deliveries. Deactivation does not delete events, attempts, or deliveries that already exist.

Every delivery starts in `pending`. The initial states are:

| State | Meaning |
| --- | --- |
| `pending` | The delivery exists and is waiting to be processed. |
| `processing` | Tidewake has claimed the delivery for one processing cycle. |
| `succeeded` | The external endpoint returned an HTTP `2xx` response. |
| `failed` | Processing ended without an HTTP `2xx` response. |

The only permitted transitions in this initial lifecycle are:

| From | To | Condition |
| --- | --- | --- |
| `pending` | `processing` | Tidewake claims the delivery for processing. |
| `processing` | `succeeded` | The outbound request receives an HTTP `2xx` response. |
| `processing` | `failed` | The outbound request receives a non-`2xx` response or processing cannot complete. |

No other transition is permitted in the initial lifecycle. `succeeded` and `failed` are terminal states for this cycle. A delivery cannot skip `processing`, return to `pending`, or move between terminal states.

HTTP responses in the complete `200` through `299` range represent success. All other response statuses represent failure for this initial classification. Detailed transport error classification remains part of later delivery implementation.

Events are immutable facts and are not deleted as part of delivery processing. Attempts are append-only evidence and are not deleted. State changes on a delivery must not rewrite its event or remove its attempt history.

Tidewake owns these lifecycle rules. No rule, state, transition, payload assumption, or success condition specific to Ironhold belongs in the Tidewake domain. Ironhold may be an endpoint, but it remains an independent consumer.

## Deferred decisions

Retries and their state transitions are deferred. The `exhausted` and `cancelled` states are also deferred and are not part of this lifecycle. A future ADR must define them together with attempt limits, backoff, failure classification, cancellation semantics, and concurrency safeguards.

This decision does not define Oban jobs, Req usage, HMAC signing, attempt fields, or the timing of endpoint eligibility checks beyond creation of a new delivery.

## Consequences

### Positive

- The initial lifecycle has one required starting state and a small set of explicit transitions.
- The unique event and endpoint pair prevents duplicate delivery records.
- Success has a transport-independent HTTP definition that works for any endpoint.
- Immutable events and append-only attempts preserve operational history.
- Consumer-specific behavior stays outside the Tidewake domain.

### Negative

- A failed delivery cannot be retried under this lifecycle.
- Endpoint deactivation behavior for an existing delivery requires a later decision before asynchronous processing is implemented.
- Terminal outcomes remain coarse until attempt and failure classification are defined.

## Follow-up

Implement the delivery table and domain behavior in separate changes that enforce this decision. Define retries, additional terminal states, and attempt processing in a later ADR before adding those behaviors.

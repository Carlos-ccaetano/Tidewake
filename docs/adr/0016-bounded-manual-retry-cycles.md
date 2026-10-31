# ADR 0016: Bounded manual retry cycles

- Status: accepted
- Date: 2026-10-21

## Current implementation status

The [manual retry policy](../../lib/tidewake/webhooks/manual_retry_policy.ex) and [transactional command](../../lib/tidewake/webhooks.ex) enforce this lifetime limit through the authenticated admin POST boundary. Cycle 0 plus at most three manual cycles each permit six automatic attempts, for a theoretical maximum of 24. Acceptance preserves lifetime attempt_count, resets only cycle_attempt_count and atomically commits audit, transition and job. [Concurrency tests](../../test/tidewake/webhooks/manual_retry_concurrency_test.exs) and [HTTP regressions](../../test/tidewake_web/controllers/manual_retry_api_security_test.exs) cover competing requests at the final cycle boundary.

Admin POST, per-account PostgreSQL admission and paginated audit GET are implemented; see the [current HTTP contract](../api/manual-retries.md). Human identity/UI, HTTP credential management, audit retention/deletion, receiver `Retry-After` handling and production deployment remain pending; Ironhold is unchanged. The context and decision below retain their historical wording.

## Context

The context and prospective implementation wording below describe the state when this decision was accepted.

[ADR 0015](0015-manual-delivery-retry.md) gives each accepted manual retry a new budget of at most six persisted attempts, but leaves the lifetime number of manual cycles out of scope. Repeated operator requests could therefore create an unbounded number of cycles, outbound attempts, and audit records despite the per-cycle limit. Manual retry remains unimplemented.

Deliveries persist `attempt_count`, `retry_cycle`, and `cycle_attempt_count`; attempts persist `attempt_number`, `retry_cycle`, and `cycle_attempt_number`. Database constraints bound cycle values, and unique indexes protect lifetime and cycle attempt identities. A pure `ManualRetryPolicy` evaluates eligibility. New jobs carry `delivery_id`, `attempt_number`, `retry_cycle`, and `cycle_attempt_number`, and claims for those jobs validate the complete identity under the delivery lock. Retry classification and backoff use the cycle ordinal. An integration test covers six attempts in a later cycle while preserving lifetime history. Legacy job formats with one or two fields remain temporarily accepted.

The manual-retry operation, audit record, request idempotency, project-scoped authorization, and API remain unimplemented.

This decision sets a lifetime boundary before the manual-retry operation is implemented. All eligibility, idempotency, authorization, transactional scheduling, and immutable-history rules in ADR 0015 still apply.

## Decision

### Lifetime limit

Cycle `0` is the original automatic delivery cycle. One delivery may enter at most three manual cycles, numbered `1`, `2`, and `3`. An accepted manual request advances the persisted cycle by one; cycle identity is never reset or reused. Cycle `3` is the last permitted cycle.

Each cycle retains the limit of six persisted attempts. The theoretical lifetime maximum for one delivery is therefore `(1 automatic cycle + 3 manual cycles) × 6 = 24` persisted attempts. A cycle that ends before its sixth attempt consumes fewer attempts. Lifetime attempt numbers and `delivery.attempt_count` remain monotonic, and prior attempts remain immutable as required by ADR 0015.

### Locked decision and audit

The future manual-retry transaction must check the cycle limit while holding the delivery row lock specified by ADR 0015. It resolves an idempotent replay under that lock before evaluating eligibility; a replay returns its original outcome without creating another cycle or audit record. For a first-seen, authenticated and authorized request to retry an otherwise eligible `failed` delivery whose locked cycle is `3` or greater, the domain decision is a rejection with the bounded reason code `manual_cycle_limit_reached`.

That rejection creates no delivery transition, attempt, or job. When manual retry is implemented, it must commit one append-only rejected `manual_retry_request` audit record for this valid request, using ADR 0015's bounded fields and reason vocabulary. Concurrent requests must observe the locked cycle so none can create cycle `4`. Other ineligible states and endpoint conditions retain the rejection rules of ADR 0015.

A delivery that does not exist or is not visible to the caller receives a generic response at the security boundary that does not disclose its existence. There is no domain audit record for such a request because there is no trustworthy authorized delivery reference. The domain reason `manual_cycle_limit_reached` is not used to reveal an invisible delivery.

The lifetime cap is defense in depth. It does not replace request rate limiting, which remains a separate future control. This ADR releases no manual-retry API or UI; attributable identity and project-scoped authorization remain prerequisites under ADR 0015.

## Consequences

- A delivery has a finite, auditable lifetime attempt budget while preserving the six-attempt budget and monotonic history of each cycle.
- Three manual cycles provide a conservative initial recovery allowance without permitting indefinite operator-initiated retries. Changing the cap later requires a separate policy decision.
- Implementation must persist and guard cycle identity under the delivery lock and test the transition from cycle `2` to `3`, rejection after cycle `3`, idempotent replay, concurrency, and the absence of a job or transition on rejection.
- The cap does not limit request frequency or attempts across different deliveries; rate limiting and authorization remain necessary.

## Alternatives considered

### Leave manual cycles unlimited

Rejected because the six-attempt limit would constrain only one cycle and could be bypassed indefinitely by starting another.

### Allow only one manual cycle

Rejected as an initial policy because it allows no further controlled recovery after a later, independently corrected failure. Three cycles provide a small finite allowance while operational evidence is gathered.

### Use rate limiting alone or a configurable higher cap

Rejected because rate limiting controls request frequency, not lifetime work, and a configurable cap would weaken a simple invariant before there is operational evidence for a different value.

## References

- [ADR 0014: Automatic delivery retry policy](0014-automatic-delivery-retries.md)
- [ADR 0015: Manual delivery retry policy](0015-manual-delivery-retry.md)

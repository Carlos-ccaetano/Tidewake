# ADR 0016: Bounded manual retry cycles

- Status: accepted
- Date: 2026-10-21

## Context

[ADR 0015](0015-manual-delivery-retry.md) gives each accepted manual retry a new budget of at most six persisted attempts, but leaves the lifetime number of manual cycles out of scope. Repeated operator requests could therefore create an unbounded number of cycles, outbound attempts, and audit records despite the per-cycle limit. Manual retry remains unimplemented. Deliveries persist `retry_cycle` and `cycle_attempt_count`, while attempts persist `retry_cycle` and `cycle_attempt_number`; database constraints bound these values, and a unique index protects each delivery's cycle attempt identity. A pure `ManualRetryPolicy` evaluates eligibility, but delivery jobs and claims do not yet carry or guard the full cycle identity. Manual-retry scheduling, audit records, project-scoped authorization, and an API remain pending.

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

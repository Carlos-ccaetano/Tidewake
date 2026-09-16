# ADR 0006: Event delivery fan-out

- Status: accepted
- Date: 2026-09-15

## Context

Tidewake currently accepts and persists an event through `POST /api/events`, but event ingestion does not create deliveries. A caller can separately use `Tidewake.Webhooks.schedule_delivery/2` to persist one delivery and one Oban job atomically for a specific active endpoint.

The intended first vertical slice requires an accepted event to produce durable work for every eligible destination before Tidewake acknowledges the ingestion. Projects and subscriptions do not exist yet, so there is no ownership or routing model from which to derive eligibility. This decision defines the temporary fan-out and transaction boundary without implementing it.

## Decision

### Temporary endpoint eligibility

Until projects and subscriptions exist, every endpoint whose `active` field is `true` is eligible for every newly accepted event. An inactive endpoint is not eligible and receives no new delivery.

This is a temporary system-wide rule, not a subscription model. It introduces no event-type filters, project ownership, consumer-specific routing, or other implicit selection criteria. In particular, no rule from Ironhold enters Tidewake; Ironhold remains an independent external consumer like any other endpoint.

The complete set of active endpoints must be queried inside the same database transaction that persists the event, deliveries, and jobs. Eligibility for creation is determined from the endpoint state returned by that query.

### Atomic ingestion and fan-out

One ingestion transaction will perform all of the following work:

1. insert the event;
2. query all active endpoints;
3. insert one pending delivery for each eligible endpoint;
4. insert exactly one initial `Tidewake.Workers.DeliverWebhookWorker` job for each new delivery.

Each job continues to identify only its delivery and uses the existing worker configuration. Creating initial jobs does not introduce retries or alter the delivery lifecycle.

The event, every delivery, and every initial job form one atomic persistence boundary. Failure to query endpoints or insert any event, delivery, or job rolls back the whole transaction. Tidewake must not acknowledge an accepted event while only part of its fan-out is durable.

Having no active endpoints is a valid outcome. In that case, the transaction persists the event and commits with zero deliveries and zero jobs.

### Idempotency and uniqueness

`external_id` remains the event ingestion idempotency key enforced by the existing unique database constraint. An ingestion that conflicts with an existing `external_id` does not add deliveries or jobs to the existing event and leaves no new event, delivery, or job from the rejected transaction. This also applies when concurrent requests race to insert the same `external_id`: only the transaction that inserts the event may continue to fan-out.

The existing unique constraint on `event_id + endpoint_id` remains authoritative, so each event and endpoint pair has at most one delivery. Each delivery created by fan-out has exactly one initial job. The existing Oban uniqueness by worker and `delivery_id` remains a secondary safeguard; it does not replace the transactional one-job-per-delivery construction.

### Endpoint changes after creation

Deactivating an endpoint after fan-out does not delete or rewrite deliveries or jobs that were already created. Those records preserve the durable intent established when the event was accepted.

Before real outbound delivery is enabled, Tidewake will re-evaluate the endpoint's current eligibility immediately before sending. The outcome for a delivery whose endpoint became inactive, including job completion and delivery state, requires a later decision. This ADR does not define that behavior and does not authorize an HTTP call.

## Out of scope

This decision does not define or implement:

- filters by event type;
- projects or project ownership;
- subscriptions or subscription management;
- retries, retry eligibility, backoff, or additional attempts;
- HMAC signing or secret management;
- Req calls or activation of the real HTTP adapter;
- batch processing;
- pagination of endpoints or fan-out work.

It also does not change the current delivery states, worker attempt limit, attempt recording rules, endpoint schema, or event API response format.

## Consequences

### Positive

- An accepted event and all of its initial delivery work become durable together.
- A partial fan-out cannot be exposed after an insertion failure.
- Database constraints preserve event idempotency and delivery uniqueness under concurrency.
- Events remain valid facts even when no destination is currently active.
- The temporary routing rule is explicit and can later be replaced by projects and subscriptions.

### Negative

- Every active endpoint receives every event until a subscription model replaces this rule.
- The ingestion transaction grows with the number of active endpoints.
- A large endpoint population will require a later design for bounded fan-out, because batching and pagination are intentionally deferred.
- Endpoint deactivation between ingestion and processing requires a separate delivery-time policy.

## Alternatives considered

### Persist the event before scheduling deliveries

Rejected because a later failure could leave an acknowledged event with only part of its required deliveries or jobs.

### Schedule fan-out in a separate job

Rejected for the initial slice because it moves the completeness boundary away from ingestion and requires additional idempotency, recovery, and partial-progress semantics that are not yet defined.

### Treat zero active endpoints as an ingestion error

Rejected because an event is an immutable accepted fact and remains valid without a current destination.

### Reuse Ironhold routing rules

Rejected because Tidewake owns generic webhook delivery and must not depend on a consumer's domain model or repository.

## Follow-up

Implement the transactional ingestion operation and connect `EventController` to it, with tests for active and inactive endpoints, zero eligible endpoints, duplicate and concurrent `external_id` values, one job per delivery, and rollback on every insertion boundary.

Define delivery-time endpoint re-evaluation before activating real outbound HTTP. Projects, subscriptions, bounded fan-out, retries, and signing require separate decisions.

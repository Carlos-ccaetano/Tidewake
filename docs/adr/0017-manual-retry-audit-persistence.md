# ADR 0017: Manual retry audit persistence

- Status: accepted
- Date: 2026-10-25

## Current implementation status

The [audit schema](../../lib/tidewake/webhooks/manual_retry_request.ex), actor-scoped digest-only idempotency and transactional command are implemented behind authenticated admin POST and paginated GET. Accepted decisions commit with the transition and job; rejected decisions commit only their audit, and replay writes nothing. New API requests use project-bound fingerprint v2; the [version migration](../../priv/repo/migrations/20261030102400_version_manual_retry_fingerprints.exs) labels historical records v1 without rewriting their digest or fingerprint bytes. Authorized reads select nine historical fields, excluding digests and version, without mutable actor joins; see [audit tests](../../test/tidewake/webhooks/manual_retry_audit_test.exs).

The [current API contract](../api/manual-retries.md) documents attribution, replay, PostgreSQL admission and no-store responses. Human identity/UI, HTTP credential management, audit retention/deletion, receiver `Retry-After` handling and production deployment remain pending; Ironhold is unchanged. The context and decision below retain their historical wording.

## Context

The context and prospective implementation wording below describe the state when this decision was accepted.

[ADR 0015](0015-manual-delivery-retry.md) requires an immutable record for each first-seen, authenticated and authorized manual retry request, including valid domain rejections. [ADR 0016](0016-bounded-manual-retry-cycles.md) limits a delivery to three manual cycles after its original automatic cycle, with six persisted attempts per cycle and a theoretical lifetime maximum of 24 attempts.

The cycle-aware foundation is implemented: deliveries and attempts persist cycle identity, database constraints protect its bounds and uniqueness, a pure `ManualRetryPolicy` evaluates eligibility, and new jobs and guarded claims carry the complete attempt identity. Retry classification and backoff use the cycle ordinal, with integrated coverage of a later cycle. Manual retry, its audit table, request idempotency, attributable authorization, and an API remain unimplemented.

Before adding the table, Tidewake needs an explicit contract for actor attribution, immutable evidence, key reuse, confidentiality, and atomic scheduling. A delivery lock alone cannot resolve reuse of one actor's key across different deliveries because those requests lock different rows.

## Decision

Define the future `manual_retry_requests` table as an append-only record of manual retry decisions. Each first-seen valid request for an authorized delivery records either `accepted` or `rejected`. An idempotent replay returns the original record without another write. Invalid input, a missing or unauthorized delivery, an idempotency conflict, or a transaction failure creates no audit record.

The record captures the trusted actor and source, protected request digests, and the delivery state observed under its lock. An accepted record commits with the delivery transition and exactly one new job; a valid rejection commits only its audit record. A manual request never creates an `Attempt` itself or changes historical events or attempts.

This decision specifies future persistence. It creates no table, schema, command, authentication mechanism, authorization policy, route, API, or UI. No manual-retry API will be exposed in this sequence.

## Data model

Use the repository's generated primary-key convention and a required reference to `deliveries.id` with the same database type. Timestamps use UTC with microsecond precision, matching `:utc_datetime_usec` in the existing schemas. Snapshot fields describe the delivery before any accepted transition; they never track later changes.

| Column | Type and nullability | Meaning |
| --- | --- | --- |
| `id` | Generated primary key | Stable identity of the audit record. |
| `delivery_id` | Required foreign key | Delivery evaluated by the request. |
| `actor_type` | Required bounded string | `service_account` or `user`. |
| `actor_subject` | Required string, 1–255 bytes | Stable opaque identifier from the trusted identity boundary; never an email address. |
| `source` | Required bounded string | `api`, `liveview`, or `admin_cli`, derived from the trusted entry point. |
| `idempotency_key_digest` | Required 64-byte string | Lowercase hexadecimal SHA-256 of the validated key bytes. |
| `request_fingerprint` | Required 64-byte string | Lowercase hexadecimal SHA-256 of the canonical request representation. |
| `requested_at` | Required UTC timestamp | Trusted server time of the first-seen request. |
| `outcome` | Required bounded string | `accepted` or `rejected`. |
| `reason` | Nullable bounded string | Rejection reason; null for acceptance. |
| `observed_status` | Required bounded string | Delivery status read under its lock. |
| `observed_attempt_count` | Required integer | Lifetime persisted attempt count before the decision. |
| `observed_retry_cycle` | Required integer | Cycle identity before the decision. |
| `observed_completed_at` | Nullable UTC timestamp | Exact prior completion timestamp, including null when absent. |
| `resulting_retry_cycle` | Nullable integer | New cycle after acceptance; null for rejection. |
| `inserted_at` | Required UTC timestamp | Trusted server insertion time. |

There is no `updated_at`, raw key column, arbitrary metadata map, or free-form operator note. Enumerated strings use only the fixed vocabularies below; actor subjects must be nonblank and remain within the byte bound. Their original case and bytes are preserved rather than normalized into a different actor identity.

### Database integrity

The future migration must enforce these rules with `NOT NULL`, foreign-key, check, and unique constraints, with matching changeset validation:

- Both digests have exactly 64 bytes and match `^[0-9a-f]{64}$`.
- `actor_type` is one of `service_account` and `user`; `source` is one of `api`, `liveview`, and `admin_cli`; `outcome` is one of `accepted` and `rejected`.
- `observed_status` is one of `pending`, `processing`, `succeeded`, `failed`, and `cancelled`.
- A non-null `reason` is one of `state_not_failed`, `endpoint_inactive`, and `manual_cycle_limit_reached`. `invalid_input` is a validation error, not an auditable rejection reason.
- `actor_subject` is nonblank and contains 1–255 bytes. The identity boundary is responsible for supplying an opaque identifier rather than personal or credential data.
- `observed_attempt_count >= 0`. `observed_retry_cycle` and any non-null `resulting_retry_cycle` are between `0` and `3`, inclusive.
- `accepted` requires `reason IS NULL`, `resulting_retry_cycle IS NOT NULL`, `observed_status = 'failed'`, `observed_retry_cycle < 3`, and `resulting_retry_cycle = observed_retry_cycle + 1`.
- `rejected` requires `reason IS NOT NULL` and `resulting_retry_cycle IS NULL`.
- A unique constraint covers exactly `(actor_type, actor_subject, idempotency_key_digest)`. Neither `delivery_id` nor `source` participates in that scope.
- `delivery_id` is positive and references `deliveries.id` with `on_delete: :restrict`; deletion of a delivery must not cascade to or detach its audit history.

Nullability must be explicit in the outcome checks so SQL null semantics cannot admit an incomplete accepted or rejected record. Row constraints protect stored shape; trusted actor derivation, endpoint activity, authorization, and the accuracy of the snapshot remain responsibilities of the future command and its locked transaction.

The context will expose no update or delete operation for these records. Conflict handling must not use an upsert that rewrites an existing record. Replays preserve the original outcome, reason, source, timestamps, and snapshot.

## Idempotency

### Key format and digest

Every manual retry request requires a key of 16–128 bytes, inclusive, containing only ASCII `A–Z`, `a–z`, `0–9`, period (`.`), underscore (`_`), tilde (`~`), and hyphen (`-`). Validate the entire byte sequence; whitespace, non-ASCII characters, missing keys, and other lengths are invalid. Do not trim, case-fold, truncate, or otherwise normalize a key.

The trusted command boundary computes SHA-256 over the exact validated key bytes and encodes the result as 64 lowercase hexadecimal characters. Discard the raw key immediately after hashing. Persistence receives only the digest; a caller cannot supply an arbitrary precomputed digest in place of a validated key. Raw keys must never enter jobs, logs, Telemetry, errors, or audit rows.

The key is scoped by the exact trusted `(actor_type, actor_subject)` pair. The same key from different actors has independent scopes. Changing the source does not create a new scope or permit another decision under the same key.

### Canonical request fingerprint

The version-1 canonical representation is exactly:

```text
manual_retry:v1:delivery:<positive-integer-id>
```

Replace the placeholder with the validated delivery ID in canonical base-10 decimal form, with no leading zeros, sign, whitespace, or trailing newline. For delivery `123`, hash exactly the ASCII bytes of `manual_retry:v1:delivery:123`. Store only the lowercase hexadecimal SHA-256 digest in `request_fingerprint`, never the unhashed representation.

The representation includes only the operation, version, and delivery identity. It excludes the raw key, source, timestamps, mutable delivery state, event payload, endpoint, and actor. The actor already delimits the unique key scope. Thus the fingerprint remains stable when a delivery progresses or a caller retries through another trusted entry point.

Version 1 introduces no project ownership model. Authorization must still be checked on every invocation, including replay. Any future change to canonical semantics, including the ownership scope anticipated by ADR 0015, requires an explicit new version and a replay-compatibility decision; it must not silently change the bytes hashed for version 1.

### Replay results

After validating the request and authorizing access to the target delivery, resolve the actor-scoped key before evaluating mutable eligibility:

| Existing actor-scoped key | Fingerprint comparison | Result |
| --- | --- | --- |
| Present | Same fingerprint | Return the original audit record without a new audit row, transition, cycle, attempt, or job. |
| Present | Different fingerprint | Return an idempotency conflict without exposing the original record or writing anything. |
| Absent | Not applicable | Evaluate the current locked state and record the first decision atomically. |

A replay returns the original accepted or rejected decision even when the delivery or endpoint has since changed. It does not re-run the original eligibility decision. A fresh key observes current state: after an acceptance has made the delivery `pending`, a new request may record `state_not_failed`. The original key remains consumed by its committed record; no expiry or reuse window is defined here.

An idempotency conflict is not another `rejected` audit record: the unique key already belongs to its original request, and the rejection vocabulary does not include key misuse.

## Concurrency

### Locking and decision order

The future boundary must validate the key, delivery ID, trusted actor, and source and require an authenticated principal authorized for the target delivery before domain audit persistence. A missing delivery, authorization denial, or invalid input creates no audit record. Unauthorized or invisible deliveries must receive a non-disclosing response as required by ADR 0016; an idempotency lookup must not become a way to discover another delivery or its audit history.

Within the transaction, lock the delivery before making a domain decision, then lock and read its endpoint, following the existing claim lock order. Resolve the actor-scoped key and fingerprint before mutable eligibility. A replay returns its original record even if the endpoint is now inactive. For a new key, re-evaluate the endpoint and apply the existing `ManualRetryPolicy` order: a known non-failed state yields `state_not_failed`; an otherwise eligible failed delivery with an inactive endpoint yields `endpoint_inactive`; an active failed delivery at cycle `3` yields `manual_cycle_limit_reached`.

### Atomic outcomes

An accepted transaction must commit all of the following together:

1. Insert the accepted audit record with the locked prior snapshot and resulting cycle.
2. Change that same delivery from `failed` to `pending`, advance `retry_cycle` by one, reset only `cycle_attempt_count` to zero, and clear `completed_at` and `next_attempt_at`. Preserve lifetime `attempt_count`.
3. Insert exactly one immediately available job carrying `delivery_id`, `attempt_number: observed_attempt_count + 1`, the resulting `retry_cycle`, and `cycle_attempt_number: 1`.

Failure at any insert, delivery update, constraint, or job conflict rolls back all accepted effects, including the key's audit record. Return a controlled transaction error rather than a fabricated domain rejection. A valid rejection commits only its immutable audit record and leaves the delivery, cycles, attempts, and jobs unchanged. An idempotent replay performs no write.

These transitions preserve ADRs 0015 and 0016: at most three manual cycles, six persisted attempts per cycle, a theoretical maximum of 24 lifetime attempts, and no resetting or renumbering of attempt history. Automatic jobs remain subject to cycle-aware claim guards, and endpoint activity is checked again when a delivery is claimed.

### Competing requests

The delivery lock serializes decisions for the same delivery. Two distinct keys cannot both reopen one failed delivery: after the first acceptance commits, the second request observes `pending` and records a rejection. Requests sharing a key and fingerprint converge on the original record.

Requests reusing one actor's key for different deliveries hold different delivery locks. The actor-scoped unique constraint is therefore the final authority, even after an application lookup found no record. A uniqueness loser must roll back its entire transaction, then resolve the winning committed record in a fresh authorized transaction using the same lock order. It returns that record only for the same fingerprint; otherwise it returns an idempotency conflict. It must not continue querying inside an aborted transaction, update the winning row, or leave a delivery transition or job behind.

## Security and privacy

Actor type and subject come from a trusted identity boundary. The subject must be stable, opaque, and unambiguous within its actor type; it is not an email address, display name, token, or caller-supplied label. Source comes from the trusted entry point. None of these fields grants authorization by itself. The current shared bearer token authenticates one credential and cannot create or identify an attributable actor.

Persist only the fields defined above. No signature, signing secret, bearer or session token, HTTP header, request or response body, URL, event payload, raw key, raw error, changeset, arbitrary metadata, or free-form note belongs in the record. Protected digests are correlation identifiers, not anonymization or proof of authorization.

Raw keys must never be persisted, logged, returned, or emitted in Telemetry. Actor subjects and either digest must not enter Telemetry measurements, metadata, tags, or event names, nor be copied into ordinary logs or job arguments. Follow ADR 0008 and ADR 0015 for bounded post-commit outcomes and reasons; identifiers, counters, snapshots, and webhook data remain outside Telemetry. Error handling must not serialize command attributes or audit changesets into logs or responses.

Future audit reads require authorization as well. Actor identity, snapshot fields, and digests must not be added to an existing public delivery representation. This persistence decision exposes no API or UI, and the implementation sequence must keep them unavailable until attributable authentication and authorization are defined.

## Consequences

### Positive

- Accepted and rejected decisions retain actor attribution and the exact prior terminal boundary without rewriting delivery history.
- Replays remain stable across delivery changes and entry points, while key reuse for another request is detected.
- Database uniqueness handles races that cannot be serialized by one delivery row lock.
- Audit evidence, delivery state, and outbound work cannot partially commit.
- Fixed fields and vocabularies keep protected operational evidence separate from Telemetry and webhook content.

### Negative

- Implementation must coordinate key validation, trusted identity, snapshots, constraint handling, locking, and job insertion in one command.
- Actor identity must remain stable; an identity migration cannot silently assign a different idempotency scope.
- Committed rejected requests consume keys and storage. The cycle cap does not bound rejection volume; rate limiting and retention require separate decisions.
- SHA-256 digests remain protected data, and digest-only storage cannot recover a lost raw key.
- No manual retry becomes available until the command and its security prerequisites are implemented separately.

## Alternatives considered

| Alternative | Reason for rejection |
| --- | --- |
| Persist raw keys or full request metadata | Retains unnecessary sensitive data and an unbounded input surface. |
| Use a globally unique key without actor scope | Couples independent actors and permits one actor's key to conflict with another's. |
| Include delivery or source in key uniqueness | Allows reuse of one actor's key for a different delivery or another entry point instead of detecting replay or conflict. |
| Include timestamps or mutable state in the fingerprint | Makes a legitimate replay change identity after the original request succeeds. |
| Infer an actor from the shared bearer token | A shared credential cannot attribute an individual principal or authorize an administrative operation. |
| Update the existing audit row on replay | Rewrites the original decision, source, and observed history. |
| Depend on a lookup or delivery lock without database uniqueness | Misses concurrent reuse of one actor's key across different deliveries. |
| Commit the audit record separately from the transition and job | Can consume a key without durable work or create work without its committed audit decision. |

## Out of scope

- migrations, schemas, context functions, or the manual retry command;
- authentication, actor provisioning, project ownership, roles, or authorization implementation;
- routes, public API contracts, administrative CLI commands, or UI;
- changes to automatic retry classification, backoff, signing, transport, recovery, or the accepted cycle limits;
- audit export, deletion, retention, key expiry, rate limiting, dashboards, or alerting;
- changes to Ironhold or any other receiver.

## References

- [ADR 0008: Webhook telemetry contract](0008-webhook-telemetry.md)
- [ADR 0010: API token authentication](0010-api-token-authentication.md)
- [ADR 0014: Automatic delivery retry policy](0014-automatic-delivery-retries.md)
- [ADR 0015: Manual delivery retry policy](0015-manual-delivery-retry.md)
- [ADR 0016: Bounded manual retry cycles](0016-bounded-manual-retry-cycles.md)
- [Architecture](../architecture.md)
- [Security policy](../../SECURITY.md)

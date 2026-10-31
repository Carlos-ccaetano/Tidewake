# ADR 0020: Project-scoped manual retry API

- Status: accepted
- Date: 2026-10-27

## Current implementation status

The [router](../../lib/tidewake_web/router.ex), [controller](../../lib/tidewake_web/controllers/manual_retry_request_controller.ex) and [integrated security tests](../../test/tidewake_web/controllers/manual_retry_api_security_test.exs) implement and verify admin-only POST decisions and GET audit, project-scoped reauthorization, digest-only actor keys, v2 fingerprints, atomic audit/transition/Oban persistence, bounded responses and no-store errors. Historical v1 rows retain their original bytes and remain readable through the audit allowlist; they never become v2 replays. The PostgreSQL bucket permits five POST admissions per account, refills one per complete 12-second interval and includes replay/errors after authorization; GET never touches it.

The reviewed HTTP implementation has two representation details beyond the original wording below: POST accepts an absent body **or an empty JSON object**, at most 1024 bytes with JSON content type for a nonempty body; GET uses `{"data":[...],"page":{"next_before_id":...}}`. GET still requires zero body bytes. POST's invalid-key response is `invalid_idempotency_key`; other invalid input uses `invalid_request`. These are the current [API contract](../api/manual-retries.md), covered by [controller tests](../../test/tidewake_web/controllers/manual_retry_request_controller_test.exs); this note does not rewrite the historical decision.

Human identity/UI, HTTP credential management, audit retention/deletion, receiver `Retry-After` handling and production deployment remain pending; Ironhold is unchanged. The context and decision below retain their historical wording.

## Context

The internal `request_manual_retry/3` command already commits accepted audit records, delivery transitions, and immediate cycle-aware jobs atomically. Rejections persist only their decision; replays return the original record. ADRs 0015–0017 preserve append-only history, actor-scoped idempotency, three manual cycles, and six attempts per cycle.

The current router has no retry or audit resource and still uses the shared-token pipeline. ADR 0018 defines project ownership and ADR 0019 defines attributable service accounts, trusted Scope, and administrative permissions. These decisions must be implemented before an operational retry endpoint can safely expose the internal command.

## Decision

Define two project-scoped administrative resources: `POST /api/deliveries/:delivery_id/manual-retry-requests` to request a decision and `GET` on the same path to read protected audit history. Require service-account authentication and the `admin` role for both, including replay. Deny unknown actions by default.

New authenticated requests use fingerprint version 2. Bound retry HTTP consumption with a PostgreSQL token bucket per service account and bound audit reads with cursor pagination. This ADR defines future contracts only: it activates no pipeline, route, persistence, command change, or UI. Enable the resources only after ownership, credentials, authorization, versioned idempotency, limiter, and isolation tests are implemented and reviewed.

## HTTP contract

### POST request

- Require exactly one Bearer Authorization header under ADR 0019 and exactly one `Idempotency-Key` header. Missing, duplicated, or comma-combined key values are invalid.
- Preserve ADR 0017's key rules: 16–128 bytes inclusive, only ASCII letters, digits, `.`, `_`, `~`, and `-`. Hash the exact bytes with SHA-256; never trim, case-fold, truncate, or echo the key.
- Require an empty request body: zero content bytes. JSON `{}`, `null`, whitespace, and any submitted fields are nonempty and return `400`. Actor, source, project, delivery, decision, and outcome are never accepted from the body or query parameters.
- The path selects only the target delivery. Validate `delivery_id` as a canonical positive base-10 integer within PostgreSQL signed-bigint range, without a sign, leading zeros, whitespace, or trailing bytes. Derive project and actor from trusted server context.
- No query options are defined for POST; reject supplied options with `400`. Input errors never create audit evidence or outbound work.

### POST representation and replay

A first decision or an idempotent replay returns exactly `{"data": { ... }}` with this field allowlist:

| Field | Representation |
| --- | --- |
| `id` | Positive integer audit-record ID. |
| `delivery_id` | Positive integer ID of the authorized target delivery. |
| `outcome` | `accepted` or `rejected`. |
| `reason` | Null for acceptance; `state_not_failed`, `endpoint_inactive`, or `manual_cycle_limit_reached` for rejection. |
| `requested_at` | Original trusted UTC request time, serialized as an ISO 8601 timestamp with microsecond precision. |
| `resulting_retry_cycle` | Integer `1`–`3` for acceptance; null for rejection. |
| `replayed` | Boolean: false for the first committed decision, true for a returned prior decision. |

Acceptance returns `202 Accepted`: the decision and durable job committed, not an assertion that the webhook has succeeded. A domain rejection returns `409 Conflict` with the same representation. Replay preserves the original `202` or `409`, decision, reason, timestamp, and resulting cycle, with `replayed: true`. Do not reexecute eligibility or create a new audit row, cycle, attempt, or job. Fresh keys evaluate current locked state.

Use `Content-Type: application/json` and `Cache-Control: no-store` on every response from both resources, including errors and authentication/authorization denials. Never serialize an entire schema or changeset. Neither a representation, an error, nor a response header contains a raw key, digest, fingerprint, token, credential ID, endpoint URL, or event payload.

## Fingerprint versioning

The version-2 canonical request is exactly these ASCII bytes, without a trailing newline:

```text
manual_retry:v2:project:<canonical-project-uuid>:delivery:<positive-integer-id>
```

Use the trusted project's stable `public_id` UUID in lowercase hyphenated canonical form and the validated delivery ID in canonical decimal. Persist only the 64-character lowercase hexadecimal SHA-256 digest in `request_fingerprint`. Actor identity remains outside the fingerprint because `(actor_type, actor_subject, idempotency_key_digest)` already delimits key uniqueness. Source, timestamps, credential identity, and mutable state are also excluded.

Add required `request_fingerprint_version` to audit storage, with explicit supported versions `1` and `2`. A new migration labels all existing rows `1` without recomputing or rewriting either digest. Existing version-1 bytes remain exactly those of ADR 0017. Do not infer versions from digests or attempt to convert version 1 to version 2.

New authenticated API requests write and compare only version 2. Matching an actor-scoped key requires both version and fingerprint equality; encountering a version-1 row under that key returns `idempotency_conflict`, never a version-2 replay. Historical version-1 records remain readable through the authorized audit allowlist. Any retained internal version-1 compatibility must be explicit and cannot provide an HTTP bypass. Credential rotation preserves the account subject and key scope.

## Authorization and non-disclosure

Authenticate and authorize every invocation before accessing a delivery or its audit, even when the key has already succeeded. `producer` and `viewer` receive the same functional `403` before object lookup. ADR 0019's uniform `401` covers invalid credentials, disabled accounts, and suspended projects; no static shared token is accepted after cutover.

Only a trusted `Tidewake.Projects.Scope` can construct `ManualRetryActor`: type `service_account`, subject the account's stable public UUID, source `api`. Body attributes, a caller-created map or struct, display names, and credential UUIDs supply no authority.

For POST, the command owns its domain transaction. Revalidate persisted authority at that boundary, then query and lock the delivery with both `delivery.id = requested_id` and `delivery.project_id = scope.project_id` in SQL inside the transaction. Preserve delivery-then-endpoint lock order. Authorize that scoped delivery before actor-key lookup; never globally load it and check ownership afterward. Reapply these checks when resolving a uniqueness race in a fresh transaction.

Missing and foreign deliveries share the same `404` code, message, and envelope, without a global existence probe or disclosure of a previous key's target. GET likewise resolves its parent delivery inside project scope before querying audit. Audit ownership follows the protected delivery relationship from ADR 0018; a visible cursor or record ID never grants access.

## Rate limiting

Use one PostgreSQL bucket row per service account, with a unique restrictive `service_account_id` reference, integer `tokens` constrained to `0..5`, and a UTC microsecond `refilled_at`. Capacity is **5 tokens**, replenished by **1 token per complete 12-second interval**. Credentials of the same account share the bucket; rotation cannot replenish capacity.

The limiter runs after authentication and functional admin authorization, before POST input/object/idempotency processing. Every authenticated, functionally authorized retry HTTP invocation must acquire a token, including replay, domain rejection, invalid input, and scoped `404`. Failed authentication or functional authorization does not touch a bucket. GET does not consume this retry bucket. An exhausted invocation returns `429` without entering the domain command; it cannot consume below zero.

In its own short transaction:

1. Initialize a missing row with five tokens and trusted database time, using the unique account constraint to handle competing initialization without replacing an existing row.
2. Lock that account row with `FOR UPDATE`. Sample database time after acquiring the lock, so waiting callers do not use a timestamp captured before another refill.
3. Compute `intervals = floor(max(now - refilled_at, 0) / 12 seconds)`. Set `available = min(5, tokens + intervals)` and advance `refilled_at` by **only `intervals * 12 seconds`**, preserving any fractional interval. At capacity, excess refill tokens are discarded; no stored token count exceeds five. A clock regression grants no extra tokens and never moves the timestamp backward.
4. If available is positive, persist `available - 1` and the advanced timestamp, then commit permission to proceed. Otherwise persist any refill progress and commit denial. Return a positive whole-second `Retry-After`, rounding up the remaining time until `refilled_at + 12 seconds`; never round down to zero while exhausted.

The unique row, locked refill/decrement, and commit are the authority across all application nodes. Without a refill interval elapsing, concurrent requests cannot acquire more than five tokens from a full bucket. For example, an empty bucket at 25 seconds gains two tokens and advances its refill timestamp by 24 seconds, retaining the remaining second.

Commit limiter consumption **outside and before** the manual-retry transaction. A subsequent domain rollback does not refund the token or roll back limiter state. Limiter storage/lock failure fails closed with generic `503` and creates no retry audit, delivery transition, attempt, or job; do not invoke the command, bypass the bucket, or fall back to local memory. Revocation or loss of authority detected afterward still denies domain access.

Use no identifiers in limiter Telemetry; permit only bounded outcome classifications and aggregate counts/durations. Suppress account-correlating query logs and query Telemetry. This bucket bounds retry invocations, not all ingress, storage growth, or audit reads. It does not change automatic delivery backoff or interpret receiver `Retry-After` headers.

## Audit retrieval

`GET /api/deliveries/:delivery_id/manual-retry-requests` requires an authenticated admin and the same trusted project scope on every page. It is independent of which admin originally requested a decision: project authorization permits accountability reads without exposing other projects. A scoped delivery with no audit returns `200` and an empty list; an absent or foreign delivery returns the indistinguishable `404`.

Order by audit `id DESC`. Accept optional `limit` (default **50**, range **1–100**) and optional `before_id` as a canonical positive signed-bigint decimal. Duplicate, unknown, malformed, zero, negative, or out-of-range pagination parameters return `400`; do not silently clamp a limit above 100. Require an empty GET body. Apply the scoped `delivery_id`, `id < before_id` when present, and limit in SQL, without an offset, total-count scan, or global cursor lookup.

Return `{"data": [...], "next_before_id": ...}`. Each item contains exactly the six persisted POST fields (`id`, `delivery_id`, `outcome`, `reason`, `requested_at`, `resulting_retry_cycle`) plus `actor_type`, opaque `actor_subject`, and bounded `source`. `replayed` is a POST-invocation property and is not a stored audit field. Read at most `limit + 1` scoped rows to detect a further page, return at most `limit`, and set `next_before_id` to the last returned ID only when another page exists; otherwise return null.

Never return `idempotency_key_digest`, `request_fingerprint`, fingerprint version, raw keys, credential identifiers, endpoint URLs, payloads, or unlisted snapshots. Do not incorporate this audit collection into the ordinary public delivery representation. `Cache-Control: no-store` applies to every page and error. Pagination bounds each read but does not promise a frozen multi-page snapshot while new decisions arrive.

## Error model

Errors other than committed domain rejection use exactly `{"error": {"code": "<bounded-code>", "message": "<fixed-public-message>"}}`. Messages are fixed per code and never interpolate request values, database details, raw errors, or previous audit contents.

| Condition | Status | Public code or decision |
| --- | --- | --- |
| ADR 0019 authentication failure | `401` | `unauthorized`, with a bare `WWW-Authenticate: Bearer` challenge. |
| Authenticated role lacks retry/audit permission | `403` | `forbidden`, before resource lookup. |
| Invalid key, delivery ID, body, or query parameters | `400` | `invalid_request`. |
| Absent or foreign delivery | `404` | `not_found`, same fixed `Delivery not found` message. |
| Accepted decision, including replay | `202` | Allowlisted `data` with `outcome: accepted`. |
| Rejected domain decision, including replay | `409` | Allowlisted `data` with `outcome: rejected` and its bounded reason. |
| Actor-scoped key reused for a different version/fingerprint | `409` | `idempotency_conflict`, without the original record. |
| Active job prevents atomic acceptance | `409` | `active_job`, distinct from key conflict and domain rejection. |
| Retry bucket exhausted | `429` | `rate_limited`, with integer-seconds `Retry-After`. |
| Limiter, domain persistence, or audit-read failure | `503` | `service_unavailable`, generic and without raw errors. |

Authentication and functional permission take precedence. For POST, limiter denial/failure precedes input validation; after admission, validate input, resolve the scoped delivery, resolve key/version replay or conflict, then evaluate mutable eligibility. GET checks authentication/permission, validates input, then resolves scoped data. Do not use the status table as permission to probe objects earlier.

Only first-seen valid domain decisions create audit rows. Authentication/authorization failures, invalid input, missing/foreign deliveries, key conflicts, active-job rollbacks, limiter denials/failures, and persistence failures create none. Acceptance still commits audit, delivery transition, and exactly one immediate job together; rejected audit commits without work. Preserve unique-key race recovery, rollback, six attempts per cycle, at most three manual cycles, and immutable lifetime history from ADRs 0015–0017.

## Security and privacy

TLS and ADR 0019's protected credential lookup are prerequisites. Do not place Authorization, tokens, pepper, raw keys, digests, fingerprints, account/project/credential IDs, actor subjects, delivery/audit/job IDs, URLs, payloads, changesets, or raw exceptions in ordinary logs or Telemetry. Review request logging, query instrumentation, and error serialization before activation; disabling one application log statement is insufficient. Protected audit responses deliberately disclose only their allowlisted attribution and record IDs to authorized project admins.

[OWASP API1:2023](https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/) motivates scoped object checks; [API5:2023](https://owasp.org/API-Security/editions/2023/en/0xa5-broken-function-level-authorization/) informs admin-only functions and default denial. [API4:2023](https://owasp.org/API-Security/editions/2023/en/0xa4-unrestricted-resource-consumption/) informs bounded retry consumption and audit pages. [RFC 6585 section 4](https://www.rfc-editor.org/rfc/rfc6585.html#section-4) defines 429; [RFC 9110 section 10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3) permits a decimal delay in seconds for `Retry-After`. Tidewake chooses that form for bucket denial and prevents caching; it does not claim a receiver-retry feature.

## Consequences

- Attributable admins can request bounded recovery and inspect project history without changing ordinary delivery responses or disclosing credentials.
- Versioned comparisons preserve historical evidence while preventing a legacy digest from being silently interpreted under new project semantics.
- PostgreSQL serializes bucket admission across nodes; retries and rejected decisions still consume capacity, and command rollbacks do not refund it.
- Future implementation must coordinate authorization, scoped locks, version-aware uniqueness races, limiter transactions, explicit serializers, and non-disclosing errors. This document does not prove those future behaviors implemented.
- Bucket rows and audit records require separate operational retention planning; this contract introduces no deletion policy or unlimited audit export.

## Alternatives

| Alternative | Reason for rejection |
| --- | --- |
| Expose the internal command under the shared token | Does not establish attributable identity, admin permission, or project isolation. |
| Accept actor/project/decision fields from callers | Allows spoofed attribution, ownership, or audit outcomes. |
| Rewrite old fingerprints or compare versions interchangeably | Changes historical meaning and can turn incompatible requests into replays. |
| Rate limit by credential, process, or delivery | Rotation, multiple nodes, or target changes could bypass the account boundary. |
| Reset refill time to now or refund on domain rollback | Loses fractional refill time or lets unsuccessful/replayed traffic evade consumption. |
| Return the full audit schema or unbounded history | Discloses protected correlation material and permits unbounded read work. |

## Out of scope

- Implementation, migrations, schemas, routes, controllers, plugs, command changes, limiter code, and tests of future behavior;
- credential-management HTTP APIs, human users, UI, OAuth, or JWT;
- changes to automatic retry budgets, signing, transport, recovery, or handling `Retry-After` from webhook receivers;
- retention/deletion, bulk audit export, production activation, deployment, or Ironhold changes.

## References

- [ADR 0015: Manual delivery retry policy](0015-manual-delivery-retry.md)
- [ADR 0016: Bounded manual retry cycles](0016-bounded-manual-retry-cycles.md)
- [ADR 0017: Manual retry audit persistence](0017-manual-retry-audit-persistence.md)
- [ADR 0018: Project ownership](0018-project-ownership.md)
- [ADR 0019: Service account authentication](0019-service-account-authentication.md)
- [Current router](../../lib/tidewake_web/router.ex)
- [Current manual retry command](../../lib/tidewake/webhooks.ex)
- [OWASP API1:2023 Broken Object Level Authorization](https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/)
- [OWASP API4:2023 Unrestricted Resource Consumption](https://owasp.org/API-Security/editions/2023/en/0xa4-unrestricted-resource-consumption/)
- [OWASP API5:2023 Broken Function Level Authorization](https://owasp.org/API-Security/editions/2023/en/0xa5-broken-function-level-authorization/)
- [RFC 6585 section 4: 429 Too Many Requests](https://www.rfc-editor.org/rfc/rfc6585.html#section-4)
- [RFC 9110 section 10.2.3: Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3)

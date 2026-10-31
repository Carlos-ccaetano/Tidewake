# Manual retry API

`POST /api/deliveries/:delivery_id/manual-retry-requests` is implemented. It accepts an attributable service-account admin's request for a persisted decision. A 202 acknowledges committed audit, delivery transition and durable work; it does not mean the webhook has succeeded.

Admin-only audit GET on the same path is implemented. There is no retry UI, human login or production deployment in this delivery.

## Authentication and admission

Send exactly one `Authorization: Bearer <service-account-token>` header over TLS. The angle-bracket token is an intentionally invalid placeholder. The credential must be unexpired/unrevoked, its account enabled and its project active. Only admin has `manual_retries_write`. Authentication failure is a uniform 401 with a bare `WWW-Authenticate: Bearer` challenge; role denial is 403 before object lookup. See [authentication, roles and provisioning](authentication.md).

After authentication and permission, every POST invocation consumes one account token, including replay, domain rejection, key conflict, scoped 404 and invalid input. Credentials of the same account share capacity across rotation; different accounts have independent buckets. The PostgreSQL bucket holds at most five tokens and refills one per complete 12-second interval, preserving fractional time and serializing consumption across nodes under row locks. Exhaustion returns 429 with positive integer-seconds `Retry-After`, rounded up; at an unchanged exhausted clock it is 12. No other status receives Retry-After. A limiter failure returns 503 before the command. A later domain rollback does not refund admission. Authentication/role denials never create or consume a bucket, and GET bypasses it entirely.

## POST request

- Delivery ID: canonical positive decimal within signed-bigint range, without sign, whitespace, leading zero or trailing bytes.
- Exactly one `Idempotency-Key`: 16–128 bytes containing only ASCII letters, digits, `.`, `_`, `~` and `-`. Values are never trimmed, folded or echoed. Duplicate/comma-combined values are invalid.
- Body: absent, or an empty JSON object with `Content-Type: application/json`. No application fields are accepted. JSON null/arrays/scalars, malformed JSON, whitespace alone and bodies exceeding 1024 bytes are rejected.
- No query options. Actor, project, source, cycle, attempt, outcome and reason come from trusted server state.

```sh
curl --fail-with-body -X POST https://tidewake.example/api/deliveries/42/manual-retry-requests \
  -H 'Authorization: Bearer <service-account-token>' \
  -H 'Idempotency-Key: caller-generated-key-0001'
```

## POST decision response

The response is exactly a `data` object with these fields:

| Field | Value |
| --- | --- |
| id | Positive audit ID |
| delivery_id | Authorized delivery ID |
| outcome | accepted or rejected |
| reason | null for accepted; state_not_failed, endpoint_inactive or manual_cycle_limit_reached for rejected |
| requested_at | Original UTC ISO 8601 timestamp with six fractional digits |
| resulting_retry_cycle | 1–3 for accepted; null for rejected |
| replayed | false for a first decision; true for a returned prior decision |

Accepted original/replay returns 202. Persisted rejected original/replay returns 409. The same account/key/version/fingerprint returns the original decision even if eligibility has changed, with no new audit, cycle, attempt or job. A fresh key evaluates current locked state. A key reused for another canonical request returns a separate 409 error without revealing the original record. New requests use a project-bound v2 fingerprint; historical v1 rows remain unchanged and cannot become v2 replays.

For example, an accepted first decision has this exact shape; IDs and time are illustrative, not data from a real project:

```json
{"data":{"id":123,"delivery_id":42,"outcome":"accepted","reason":null,"requested_at":"2026-10-31T12:00:00.000000Z","resulting_retry_cycle":1,"replayed":false}}
```

A replay of that decision retains every persisted field and changes only `replayed` to true. It reauthorizes the current credential/account/project and consumes another admission token. A revoked credential, disabled account or suspended project receives 401 rather than the original response.

Only terminal failed deliveries with active endpoints and fewer than three manual cycles can be accepted. `pending`, `processing`, `succeeded` and `cancelled` yield `state_not_failed`; otherwise an inactive endpoint yields `endpoint_inactive`, then an exhausted manual-cycle budget yields `manual_cycle_limit_reached`. These valid first decisions are audited once; malformed input, missing/foreign objects, key/active-job conflicts, limiter failures and domain rollback create no audit.

## Attempt and cycle limits

| Persisted Delivery field | Meaning |
| --- | --- |
| attempt_count | Monotonic lifetime count of persisted automatic attempts; never reset by manual retry |
| retry_cycle | Original automatic cycle 0, followed by at most three manual cycles 1–3 |
| cycle_attempt_count | Persisted automatic attempts in the current cycle; reset to zero only by an accepted new cycle |

Each cycle permits at most six automatic attempts. The theoretical maximum is 24 automatic attempts across the initial cycle and three manual cycles, conditioned on actual eligibility and transitions. A cycle may end sooner; a manual request creates no Attempt. Acceptance clears the current completion/schedule, preserves immutable lifetime history and enqueues the next lifetime attempt at cycle ordinal 1. Stale work and active-job conflicts remain guarded by the command.

## GET audit history

`GET /api/deliveries/:delivery_id/manual-retry-requests` requires a current admin with `manual_retry_audit_read` on the trusted project. It resolves the parent Delivery inside that project before reading audit. Foreign and absent deliveries share the same 404; a visible cursor or audit ID does not grant access. Every page rechecks authorization.

GET never creates, consumes or refills the POST bucket, even if that bucket is exhausted. Require an absent body: JSON `{}`, whitespace and any other content are invalid. No Idempotency-Key is needed.

HEAD inherits GET authentication, authorization and no-store headers, without a response body or bucket consumption.

| Query option | Contract |
| --- | --- |
| limit | Default 50; canonical positive decimal 1–100. Values above 100 are rejected, not clamped. |
| before_id | Optional exclusive positive signed-bigint ID, canonical decimal without sign, whitespace or leading zero. |

Duplicate, unknown, malformed, empty or out-of-range options return 400. Records are ordered by id DESC and filtered by id < before_id. Each page reads at most limit + 1 rows to detect continuation, without offset or total count.

The 200 response is exactly `{"data":[...],"page":{"next_before_id":123}}`. The next cursor is the smallest returned ID only when more records exist; it is null on empty/final pages. Pass it as before_id to continue. Rows inserted after page one do not shift that continuation; the API does not freeze a multi-page snapshot.

Each item contains exactly the six persisted POST decision fields (id, delivery_id, outcome, reason, requested_at, resulting_retry_cycle), plus actor_type, opaque actor_subject and bounded source. It has no replayed flag. The subject intentionally identifies the recorded actor to authorized project admins only; it is not a credential or internal account ID. Version-1 and version-2 historical snapshots remain readable without replacing their actor, reason, time or decision with mutable current state.

```sh
curl --fail-with-body 'https://tidewake.example/api/deliveries/42/manual-retry-requests?limit=50' \
  -H 'Authorization: Bearer <service-account-token>'
```

An illustrative final page containing the decision above is:

```json
{"data":[{"id":123,"delivery_id":42,"outcome":"accepted","reason":null,"requested_at":"2026-10-31T12:00:00.000000Z","resulting_retry_cycle":1,"actor_type":"service_account","actor_subject":"00000000-0000-4000-8000-000000000099","source":"api"}],"page":{"next_before_id":null}}
```

If a page instead returns a non-null `page.next_before_id`, append that exact value as `before_id` on the next GET. A scoped delivery without history returns `{"data":[],"page":{"next_before_id":null}}`.

## Errors and confidentiality

Every response, including errors, uses JSON and `Cache-Control: no-store`. Non-decision errors have exactly `{"error":{"code":"...","message":"..."}}` with fixed messages.

| Status | Method | Code / result |
| --- | --- | --- |
| 200 | GET | Allowlisted historical page |
| 202 | POST | Allowlisted accepted decision |
| 400 | Both | invalid_request; POST also uses invalid_idempotency_key |
| 401 | Both | unauthorized; uniform credential failure |
| 403 | Both | forbidden; insufficient current permission |
| 404 | Both | not_found, message Delivery not found; identical for foreign and absent deliveries |
| 409 | POST | Allowlisted rejected decision, idempotency_conflict, or active_job |
| 429 | POST | rate_limited, plus Retry-After |
| 503 | Both | service_unavailable; storage/read failure, or POST limiter failure |

POST enforces authentication → permission → limiter → input validation → scoped command. GET enforces authentication → permission → input validation → scoped audit read, without the limiter. The controller performs no global Delivery lookup. The context revalidates persisted authority; POST then locks Delivery and Endpoint within the trusted project before resolving the key or deciding eligibility. Audit, accepted state and work commit atomically; storage failures return 503 with full domain rollback.

Responses never disclose raw keys, digests, fingerprints, fingerprint version, credentials, internal account/project IDs, endpoint URLs, payloads, bucket balances, changesets, constraints or exceptions. Opaque actor_subject is intentionally returned only in authorized audit items; it is absent from POST decisions, errors, logs and instrumentation. Generic connection-bearing transport/request spans are omitted for this boundary; bounded admission and domain completion events, alongside queue-only notifications, remain. Deployment, TLS topology, secret distribution and audit retention require their separate operational work.

## Admission telemetry

Each `ManualRetryRateLimiter.consume/2` call emits exactly one `[:tidewake, :webhooks, :manual_retry, :admission]` event after its result, with measurements exactly `%{count: 1}` and metadata exactly `%{outcome: outcome}`, where outcome is one of `"allowed"`, `"denied"` or `"error"`. `allowed` follows committed admission, `denied` follows an exhausted bucket, and `error` represents an unavailable result, including invalid internal input or persistence failure. No account/project identity, token, key, balance, clock or Retry-After value is included.

`tidewake.webhooks.manual_retry.admission.count` is a counter with only the `outcome` tag and three possible values. It counts admission, not successful retry commands: admitted replays and invalid POST input also count as allowed; GET and authentication/permission denials never invoke the limiter. The existing completion metrics describe the subsequent domain command separately. These event/metric definitions do not install an exporter, reporter or alerts.

## Remaining limits and evidence

There is no human identity/login, administrative retry UI or HTTP credential-management API. Audit retention/deletion policy and support for Retry-After received from webhook destinations are pending; the 429 admission response does not implement receiver backoff. Merge and green CI prove no production deployment. Ironhold is unchanged by this sequence.

The current contract is backed by the [router](../../lib/tidewake_web/router.ex), [serializer](../../lib/tidewake_web/controllers/manual_retry_request_controller.ex), [controller regressions](../../test/tidewake_web/controllers/manual_retry_request_controller_test.exs) and [integrated security suite](../../test/tidewake_web/controllers/manual_retry_api_security_test.exs). The historical wording in [ADR 0020](../adr/0020-project-scoped-manual-retry-api.md) is preserved; its current implementation note records POST's empty-JSON-object allowance and the nested GET cursor envelope.

# Manual retry POST

`POST /api/deliveries/:delivery_id/manual-retry-requests` is implemented. It accepts an attributable service-account admin's request for a persisted decision. A 202 acknowledges committed audit, delivery transition and durable work; it does not mean the webhook has succeeded.

Audit GET remains pending until P32. There is no retry UI, human login or production deployment in this delivery.

## Authentication and admission

Send exactly one `Authorization: Bearer <service-account-token>` header over TLS. The credential must be unexpired/unrevoked, its account enabled and its project active. Only admin has `manual_retries_write`. Authentication failure is a uniform 401 with a bare `WWW-Authenticate: Bearer` challenge; role denial is 403 before object lookup.

After authentication and permission, every invocation consumes one account token, including replay, domain rejection, key conflict, scoped 404 and invalid input. Credentials of the same account share capacity across rotation. The PostgreSQL bucket holds at most five tokens and refills one per complete 12-second interval. Exhaustion returns 429 with positive integer-seconds `Retry-After`, rounded up. A limiter failure returns 503 before the command. A later domain rollback does not refund admission.

## Request

- Delivery ID: canonical positive decimal within signed-bigint range, without sign, whitespace, leading zero or trailing bytes.
- Exactly one `Idempotency-Key`: 16–128 bytes containing only ASCII letters, digits, `.`, `_`, `~` and `-`. Values are never trimmed, folded or echoed. Duplicate/comma-combined values are invalid.
- Body: absent, or an empty JSON object with `Content-Type: application/json`. No application fields are accepted. JSON null/arrays/scalars, malformed JSON, whitespace alone and bodies exceeding 1024 bytes are rejected.
- No query options. Actor, project, source, cycle, attempt, outcome and reason come from trusted server state.

```sh
curl --fail-with-body -X POST https://tidewake.example/api/deliveries/42/manual-retry-requests \
  -H 'Authorization: Bearer <service-account-token>' \
  -H 'Idempotency-Key: caller-generated-key-0001'
```

## Decision response

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

Only terminal failed deliveries with active endpoints and fewer than three manual cycles can be accepted. Lifetime attempts and history remain intact; each accepted cycle has the existing six-attempt budget. Stale work and active-job conflicts remain guarded by the domain command.

## Errors and confidentiality

Every response, including errors, uses JSON and `Cache-Control: no-store`. Non-decision errors have exactly `{"error":{"code":"...","message":"..."}}` with fixed messages.

| Status | Code / result |
| --- | --- |
| 202 | Allowlisted accepted decision |
| 400 | invalid_request, or invalid_idempotency_key |
| 401 | unauthorized; uniform credential failure |
| 403 | forbidden; insufficient current permission |
| 404 | not_found, message Delivery not found; identical for foreign and absent deliveries |
| 409 | Allowlisted rejected decision, idempotency_conflict, or active_job |
| 429 | rate_limited, plus Retry-After |
| 503 | service_unavailable; limiter or persistence failure |

Authentication → permission → limiter → input validation → scoped command is the enforced order. The controller performs no global Delivery lookup. The command revalidates authority, then locks Delivery and Endpoint within the trusted project before resolving the key or deciding eligibility. Audit, accepted state and work commit atomically; storage failures return 503 with full domain rollback.

Neither decisions, errors, ordinary logs nor route instrumentation disclose raw keys, digests, fingerprints, credentials, actor subjects, internal account/project IDs, endpoint URLs, payloads, bucket balances, changesets, constraints or exceptions. Generic connection-bearing transport/request spans are omitted for this boundary; bounded domain completion and queue-only notifications remain. Deployment, TLS topology, secret distribution and audit retention require their separate operational work.

# Event ingestion API contract

## Status

Event ingestion and the HTTP operations to create and retrieve individual events and list their persisted delivery statuses are implemented. Every `/api` route requires a project-bound service-account credential and explicit permission. Accepted events are immutable, and a unique database index on `(project_id, external_id)` enforces idempotency within the authenticated project, including for concurrent requests.

Ingestion atomically persists the event, one pending delivery for each active endpoint in its project, and one initial job per delivery. It does not itself send a webhook. During delivery processing, the configured signing secret is validated before claim, the envelope is serialized once per attempt, and its exact bytes are signed. The processor prepares `Tidewake-Id`, `Tidewake-Timestamp`, and `Tidewake-Signature` with `content-type: application/json` and passes the same body to the adapter. Every actual attempt receives a fresh timestamp and signature; the secret and signing material are not persisted.

Development and tests use the deterministic adapter by default, while production uses Req with public-destination validation, pinned DNS resolution, redirects and Req retries disabled, and a 65,536-byte response-body limit. Tidewake applies its own bounded automatic retry policy after a normalized response or transport failure. Signature verification, timestamp validation, event idempotency, and replay protection remain responsibilities of the receiver.

An Oban worker runs every minute to recover at most 100 deliveries left in `processing` for at least five minutes. Each eligible delivery returns to `pending` with a replacement job, without creating a new attempt or changing `attempt_count`. This preserves at-least-once processing semantics: work may run again when its previous outcome was not persisted. Each recovery batch emits Telemetry with recovered, skipped, and error counts plus its duration.

## Automatic delivery retries

A delivery begins in `pending`, moves to `processing` when its cycle-aware job is claimed, and then either reaches a terminal state or returns to `pending` with a future schedule. A successful `200..299` response sets the delivery to `succeeded`. A permanent failure, or a retryable failure on the sixth automatic attempt in the current cycle, sets it to `failed`. Admin manual retry may start at most three new cycles after the initial cycle, giving a theoretical maximum of 24 automatic attempts while preserving lifetime `attempt_count`. See [manual retry and audit](manual-retries.md). If the endpoint is inactive when due work is claimed, the delivery becomes `cancelled` without sending HTTP or adding an attempt.

Only these HTTP responses are retryable: `408`, `425`, `429`, `500`, `502`, `503`, and `504`. Only the normalized transport outcomes `timeout`, `dns`, `connection`, and `closed` are retryable. Other HTTP responses, including `409`, and transport outcomes such as `tls`, `destination`, `response_limit`, and `unknown` are terminal. Unknown or malformed outcomes do not become eligible for retry.

The delay uses exponential backoff with a 10-second base and a 300-second ceiling. Equal jitter selects an integer delay from the inclusive range between half of the calculated ceiling, rounded up, and the full ceiling. Within each six-attempt cycle, the five possible retry ranges are 5–10, 10–20, 20–40, 40–80, and 80–160 seconds. Tidewake does not currently honor `Retry-After` received from destinations; the manual-retry API's own 429 admission response is a separate contract.

Oban executes each logical attempt job once (`max_attempts: 1`); a retryable application outcome completes that job successfully. New successor jobs carry `delivery_id`, lifetime `attempt_number`, `retry_cycle` and `cycle_attempt_number`. Claim locks the delivery and checks the next lifetime number, current cycle and next cycle ordinal; it also refuses to run before `Delivery.next_attempt_at`. These guards prevent stale, duplicate, wrong-cycle, future-numbered and early jobs from sending HTTP. Legacy one/two-field job formats remain temporarily supported internally.

For a retry, the failed `Attempt`, the delivery's return to `pending`, and the successor Oban job are committed in one database transaction. `Attempt.next_attempt_at` is the historical record of the schedule chosen by that failure. `Delivery.next_attempt_at` is the current outstanding schedule and is cleared when the retry is claimed or the delivery becomes terminal. A rollback cannot leave a retry attempt without a job or a job without its corresponding delivery state.

The event ID, type, and payload remain unchanged across attempts, but Tidewake generates a new signing timestamp and HMAC signature after each successful claim. Ironhold returns `202 Accepted` for a freshly signed retry of an identical event, allowing it to follow the ordinary success path. Reusing the exact signing material or changing content under the same event ID remains a receiver-side conflict; Tidewake treats a generic `409 Conflict` as terminal.

Committed retry schedules emit `tidewake.webhooks.delivery.retry_scheduled.count` and `tidewake.webhooks.delivery.retry_scheduled.delay_ms`; confirmed exhaustion emits `tidewake.webhooks.delivery.retry_exhausted.count`. The only tag is an allowlisted cause such as `http_503` or `transport_timeout`. These signals exclude IDs, URLs, payloads, request and response bodies or headers, signing timestamps, signatures, secrets, job IDs, changesets, database details, stack traces, and raw adapter errors.

## Operations

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/events` | Validate and atomically persist a new event and its initial delivery work. |
| `GET` | `/api/events/:id` | Retrieve one event by its internal ID. |
| `GET` | `/api/events/:id/deliveries` | List the persisted delivery status records for one event. |

## Authentication

All routes under `/api` require exactly one project-bound service-account Bearer credential. Use the exact issued value over TLS; the placeholder below is intentionally invalid:

```http
Authorization: Bearer <service-account-token>
```

A missing, malformed, duplicated, unknown, expired or revoked credential, disabled account or suspended project returns the same `401 Unauthorized` before event operations. The response includes `Cache-Control: no-store` and:

```http
WWW-Authenticate: Bearer
```

and this JSON body:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Valid service account credential required"
  }
}
```

The static token and `TIDEWAKE_API_TOKEN` configuration have been removed. Production requires the independent server-side `TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER` of at least 32 bytes. Provision a service account and store its one-time token in a secret manager; see [authentication setup](../../README.md#local-setup). No real token or pepper belongs in source control or examples.

Admin and producer may POST events; admin, producer and viewer may GET events and their delivery status. Other actions deny by default. Functional denial returns fixed 403 before object lookup; foreign and absent events share the same 404. Project identity comes from authenticated Scope, never body/query/header fields. Multiple credentials can overlap for rotation without changing the account or project. Human users, sessions, OAuth, JWT and automated rotation remain pending.

## POST /api/events

Accepts a client-provided event as a JSON object. The token placeholder must be replaced securely with an issued credential:

```bash
curl --fail-with-body -X POST http://localhost:4000/api/events \
  -H 'Authorization: Bearer <service-account-token>' \
  -H 'content-type: application/json' \
  -d '{"external_id":"evt_123","type":"order.created","data":{"order_id":"123"}}'
```

```http
POST /api/events
Content-Type: application/json
Authorization: Bearer <service-account-token>
```

Request:

```json
{
  "external_id": "evt_123",
  "type": "order.created",
  "data": {
    "order_id": "123"
  }
}
```

### Validation

All three fields are required:

| Field | Rule |
| --- | --- |
| `external_id` | A non-empty string supplied by the client. It is the event's idempotency key. |
| `type` | A non-empty string describing the event type. |
| `data` | A JSON object containing the event payload. An empty object is valid. |

Missing fields, `null` values, empty or whitespace-only strings for `external_id` or `type`, and values of the wrong JSON type are invalid. Strings, numbers, booleans, and arrays are not valid values for `data`. The example's `order_id` is illustrative; this initial contract does not require event-specific fields inside `data`.

### Idempotency and immutability

`external_id` must be unique within the authenticated project. The `events_project_id_external_id_index` unique database index enforces `(project_id, external_id)`, including for concurrent requests; independent projects may reuse an external ID. A new valid event and its initial delivery work are committed together before returning `201 Created`.

A subsequent valid request with an existing `external_id` returns `409 Conflict`, whether its `type` and `data` match the original event or differ. It does not create another event, replace the original, add deliveries or jobs, or return a second `201 Created`.

An accepted event is an immutable fact. Its `external_id`, `type`, and `data` cannot be updated. Validation failures and conflicts leave stored events unchanged.

## Responses

Responses use `Content-Type: application/json`. Successful responses wrap the accepted event in a top-level `data` object. The nested `data.data` is the client-provided event payload. Error responses follow the `errors` and `error` formats used by the [endpoint management API](endpoints.md).

### Transactional fan-out

Only active endpoints in the authenticated event project are eligible. Inactive and other-project endpoints are excluded. For each eligible endpoint, ingestion persists one pending delivery and one initial job. Event, deliveries and jobs are confirmed in a single transaction; if any insertion fails, none of that ingestion is persisted. Composite database references prevent a delivery linking an event and endpoint from different projects.

Zero active endpoints is valid: the event is persisted and `201 Created` is returned without deliveries or jobs. Deactivating an endpoint later does not remove work already created for an accepted event.

### 201 Created

Returned after the new event, all deliveries for currently active endpoints, and their initial jobs have been persisted atomically. The response serializes only the accepted event:

The response includes a `Location: /api/events/:id` header pointing to the retrieval operation.

```json
{
  "data": {
    "id": 1,
    "external_id": "evt_123",
    "type": "order.created",
    "data": {
      "order_id": "123"
    },
    "inserted_at": "2026-09-08T08:00:00.000000Z",
    "updated_at": "2026-09-08T08:00:00.000000Z"
  }
}
```

`201 Created` acknowledges durable ingestion, not delivery execution. It does not mean a webhook was sent, a delivery succeeded, or a response was received from a consumer.

### 422 Unprocessable Entity

Returned when the payload fails the validation rules. No event, delivery, or job is created. Validation errors are grouped by request field, with arrays of readable messages:

```json
{
  "errors": {
    "external_id": ["can't be blank"],
    "type": ["can't be blank"],
    "data": ["must be a JSON object"]
  }
}
```

The example shows multiple errors; a response includes the errors applicable to the submitted payload.

### 409 Conflict

Returned when a valid payload uses an `external_id` that already exists. The original event remains unchanged; no new deliveries or jobs are added:

```json
{
  "error": {
    "code": "external_id_conflict",
    "message": "An event with this external_id already exists"
  }
}
```

Error responses must not expose database details or stack traces.

## GET /api/events/:id

Retrieves an event by its positive integer internal ID. It does not use `external_id` as the path identifier.

### 200 OK

Returns the same event representation used by the creation response:

```json
{
  "data": {
    "id": 1,
    "external_id": "evt_123",
    "type": "order.created",
    "data": {
      "order_id": "123"
    },
    "inserted_at": "2026-09-08T08:00:00.000000Z",
    "updated_at": "2026-09-08T08:00:00.000000Z"
  }
}
```

### 404 Not Found

Returned when the internal ID is absent or belongs to another project, or the path value is invalid, negative or zero. Foreign and absent events use the same response:

```json
{
  "error": {
    "code": "not_found",
    "message": "Event not found"
  }
}
```

## GET /api/events/:id/deliveries

Lists the deliveries created for an event, identified by its positive integer internal ID. This is a read-only view of persisted delivery state. It does not send a webhook, execute external delivery, create attempts, or trigger retries.

### 200 OK

Returns deliveries ordered by increasing delivery ID under the top-level `data` key:

```json
{
  "data": [
    {
      "id": 1,
      "endpoint_id": 2,
      "status": "pending",
      "attempt_count": 0,
      "next_attempt_at": null,
      "completed_at": null,
      "inserted_at": "2026-09-17T10:00:00.000000Z",
      "updated_at": "2026-09-17T10:00:00.000000Z"
    }
  ]
}
```

Each delivery contains exactly these fields:

| Field | Meaning |
| --- | --- |
| `id` | Internal delivery ID. |
| `endpoint_id` | Internal ID of the destination endpoint, without exposing its configuration. |
| `status` | Current persisted delivery state: `pending`, `processing`, `succeeded`, `failed`, or `cancelled`. `pending` does not mean that a webhook was sent. |
| `attempt_count` | Lifetime number of persisted automatic attempts across cycles; manual retry never resets it. |
| `next_attempt_at` | Current scheduled time for a future attempt as a UTC ISO 8601 string, or `null` when no retry is pending. Historical retry times remain on the attempts that scheduled them and are not exposed by this endpoint. |
| `completed_at` | Completion time as a UTC ISO 8601 string, or `null` while incomplete. |
| `inserted_at` | Creation time as a UTC ISO 8601 string. |
| `updated_at` | Last update time as a UTC ISO 8601 string. |

`cancelled` means the endpoint was inactive when the pending delivery would have been processed. Tidewake made no HTTP request and created no attempt, so `attempt_count` remains unchanged; `completed_at` records when the cancellation completed. Reactivating the endpoint does not automatically reopen the cancelled delivery.

An existing event without deliveries returns `200 OK` with an empty list:

```json
{
  "data": []
}
```

The response deliberately excludes endpoint URLs, event payloads, attempts, request and response headers, response bodies, secrets, raw transport errors, and embedded endpoint or event objects. Attempt retrieval and pagination are not available in this stage.

### 404 Not Found

Returned when the event is absent or belongs to another project, or the path value is invalid, negative or zero. It uses the same non-disclosing event error representation as `GET /api/events/:id`:

```json
{
  "error": {
    "code": "not_found",
    "message": "Event not found"
  }
}
```

## Out of scope

- Endpoint management operations, documented separately in the [endpoint management API](endpoints.md).
- Delivery mutation and attempt retrieval through this API; only delivery status listing is available.
- `Retry-After` response handling and manual retry operations.
- Retry management UI and external alerts.
- Receiver-side signature verification, timestamp validation, and replay protection.
- Human users, sessions, OAuth, JWT and automated credential rotation; project-scoped service accounts and overlapping credentials are implemented.
- Event listing, updates, and deletion.

The delivery-status API is observational only: it does not trigger a retry or expose attempt history. Automatic retries run from persisted jobs. Admin manual retry POST and audit GET are separate implemented resources documented in [manual retries](manual-retries.md); retry UI, external alerting and receiver `Retry-After` handling remain pending.

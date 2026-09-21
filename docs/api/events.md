# Event ingestion API contract

## Status

Event ingestion and the HTTP operations to create and retrieve individual events are implemented. Accepted events are immutable, and a unique database index on `external_id` enforces idempotency, including for concurrent requests.

Ingestion atomically persists the event, one pending delivery for each active endpoint, and one initial job per delivery. It does not itself send a webhook. Outbound HTTP activation, signing, and retries remain pending.

## Operations

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/events` | Validate and atomically persist a new event and its initial delivery work. |
| `GET` | `/api/events/:id` | Retrieve one event by its internal ID. |

## POST /api/events

Accepts a client-provided event as a JSON object.

```http
POST /api/events
Content-Type: application/json
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

`external_id` must be unique across accepted events. The `events_external_id_index` unique database index enforces this invariant, including for concurrent requests. A new valid event and its initial delivery work are committed together before returning `201 Created`.

A subsequent valid request with an existing `external_id` returns `409 Conflict`, whether its `type` and `data` match the original event or differ. It does not create another event, replace the original, add deliveries or jobs, or return a second `201 Created`.

An accepted event is an immutable fact. Its `external_id`, `type`, and `data` cannot be updated. Validation failures and conflicts leave stored events unchanged.

## Responses

Responses use `Content-Type: application/json`. Successful responses wrap the accepted event in a top-level `data` object. The nested `data.data` is the client-provided event payload. Error responses follow the `errors` and `error` formats used by the [endpoint management API](endpoints.md).

### Transactional fan-out

Until projects and subscriptions exist, every active endpoint is temporarily eligible for every new event. Inactive endpoints are ignored. For each eligible endpoint, ingestion persists one pending delivery and one initial job. Event, deliveries, and jobs are confirmed in a single transaction; if any insertion fails, none of that ingestion is persisted.

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

Returned when the internal ID does not exist or the path value is invalid, negative, or zero:

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
- Delivery and attempt management through this API; the response exposes only the event.
- Activation of outbound HTTP requests with Req.
- HMAC signing.
- Retries and backoff.
- Authentication and authorization.
- Event listing, updates, and deletion.

These capabilities require separate work. Durable ingestion does not complete the broader delivery workflow described in the architecture and roadmap.

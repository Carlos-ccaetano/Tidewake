# Event ingestion API contract

## Status

This document defines the initial contract before implementation. Event ingestion is not implemented yet. This stage covers only validation and persistence of an immutable event; no delivery is created, scheduled, or executed.

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

`external_id` must be unique across accepted events in this initial contract. Uniqueness must be enforced by a database constraint, including for concurrent requests. A new valid event is persisted before returning `201 Created`.

A subsequent valid request with an existing `external_id` returns `409 Conflict`, whether its `type` and `data` match the original event or differ. It does not create another event, replace the original, or return a second `201 Created`.

An accepted event is an immutable fact. Its `external_id`, `type`, and `data` cannot be updated. Validation failures and conflicts leave stored events unchanged.

## Responses

Responses use `Content-Type: application/json`. Successful responses wrap the accepted event in a top-level `data` object. The nested `data.data` is the client-provided event payload. Error responses follow the `errors` and `error` formats used by the [endpoint management API](endpoints.md).

### 201 Created

Returned after a new valid event has been persisted. The initial response includes the accepted fields:

```json
{
  "data": {
    "external_id": "evt_123",
    "type": "order.created",
    "data": {
      "order_id": "123"
    }
  }
}
```

This response acknowledges event persistence only. It does not indicate that any delivery has occurred.

### 422 Unprocessable Entity

Returned when the payload fails the validation rules. No event is created. Validation errors are grouped by request field, with arrays of readable messages:

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

Returned when a valid payload uses an `external_id` that already exists. The original event remains unchanged:

```json
{
  "error": {
    "code": "external_id_conflict",
    "message": "An event with this external_id already exists"
  }
}
```

Error responses must not expose database details or stack traces.

## Out of scope

- Destination endpoint operations or associations.
- `Delivery` and `Attempt` entities.
- Oban jobs or scheduling.
- Outbound HTTP requests with Req.
- HMAC signing.
- Retries and backoff.
- Authentication and authorization.
- Event listing and retrieval.

These capabilities require separate work. This contract does not implement code or complete the broader delivery workflow described in the architecture and roadmap.

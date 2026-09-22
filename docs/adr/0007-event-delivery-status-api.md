# ADR 0007: Event delivery status API

- Status: accepted
- Date: 2026-09-22

## Context

[ADR 0006](0006-event-delivery-fanout.md) defines atomic event ingestion and initial delivery work. `POST /api/events` now persists an event, pending deliveries for active endpoints, and their initial jobs in one transaction, but its response intentionally contains only the event. The context can list an event's deliveries by increasing ID. Clients need a minimal way to see that durable fan-out and subsequent delivery states without interpreting `201 Created` as proof that a webhook was sent.

The existing event API uses an internal positive integer ID in `GET /api/events/:id` and a top-level `data` key for successful JSON responses. The new operation should follow those conventions without exposing endpoint configuration, event content, attempts, or transport details.

## Decision

### Route and lookup

Add a read-only `GET /api/events/:id/deliveries` operation. `:id` is the event's internal positive integer ID, not its `external_id`. Look up the event before listing its deliveries, so an existing event with no deliveries is distinguishable from an unknown event.

For an existing event, return `200 OK` with `Content-Type: application/json` and a top-level `data` array. Order deliveries by increasing delivery ID. An existing event with zero deliveries returns `200 OK` with `{"data": []}`; zero active endpoints at ingestion is a valid reason for this result.

An event that does not exist, or an invalid, zero, or negative `:id`, returns `404 Not Found` using the event API's public error shape:

```json
{
  "error": {
    "code": "not_found",
    "message": "Event not found"
  }
}
```

### Response representation

Each array element contains exactly these delivery fields: `id`, `endpoint_id`, `status`, `attempt_count`, `next_attempt_at`, `completed_at`, `inserted_at`, and `updated_at`. Timestamps are UTC ISO 8601 strings when present; nullable timestamps are JSON `null` when absent.

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

The status is the persisted delivery state defined by [ADR 0002](0002-delivery-lifecycle.md). In particular, `pending` means work exists and awaits processing, not that a webhook has been sent. The listing does not report job completion as consumer acceptance.

The representation must not expose endpoint URLs, event payloads, attempts, request or response headers, response bodies, secrets, or raw transport errors. It does not include embedded endpoint or event objects. `endpoint_id` identifies the destination record without disclosing its configuration.

### Scope and security

The route only reads persisted data. It does not claim or finalize deliveries, create attempts or jobs, send requests, change states, or trigger retries. No filters, pagination, sorting options, or attempt-detail endpoint are introduced at this stage.

Authentication and authorization remain pending. The current API has no authentication boundary; therefore this status API must not be exposed to untrusted or public networks. A later security decision is required before public exposure. This ADR does not add authentication or treat omission of URLs and secrets as a substitute for access control.

## Consequences

### Positive

- Clients can distinguish a valid event with no delivery work from an unknown event.
- Clients can inspect the current states of the deliveries created by fan-out without assuming that ingestion completed outbound delivery.
- A small explicit response allowlist limits accidental disclosure of sensitive or unbounded data.

### Negative

- The unpaginated response may grow with the number of eligible endpoints; a bounded listing needs a later decision.
- `endpoint_id` and delivery states are operational information and still require access control before public exposure.
- Attempt-level diagnostics are unavailable through this route.

## Alternatives considered

### Include deliveries in the ingestion response

Rejected because `POST /api/events` already has an event-only response contract and `201 Created` must not imply delivery execution. A separate read-only route keeps ingestion acknowledgement distinct from status inspection.

### Return `404` when an event has no deliveries

Rejected because zero active endpoints is a valid ingestion outcome under ADR 0006. The event exists even when its delivery list is empty.

### Expose full delivery, endpoint, or attempt records

Rejected because those records include or can lead to sensitive and unnecessary details. This first status view needs only a bounded set of delivery fields.

## Follow-up

Implement the route and its response tests in a separate change, including existing and unknown events, invalid IDs, empty lists, ID ordering, the exact field allowlist, and read-only behavior. Decide authentication and authorization before exposing the API publicly. Consider pagination only when a concrete scale requirement exists.

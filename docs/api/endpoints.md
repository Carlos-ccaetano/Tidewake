# Endpoint management API contract

## Status

Endpoint persistence and the endpoint management HTTP API are implemented. The `endpoints` table and the `Tidewake.Webhooks.Endpoint` schema persist endpoint data, while the `Tidewake.Webhooks` context and HTTP controller provide operations to list, retrieve, create, and update endpoints. The schema validates that names are present and non-blank and that URLs are present and use HTTP or HTTPS.

Active endpoints participate in the transactional fan-out of newly ingested events. Tidewake persists a delivery and an initial Oban job for each active endpoint, and its worker and processor support deterministic local processing, persisted attempts and local results, and Telemetry.

A Req-based adapter is implemented, but it is not configured as the active transport. Tidewake therefore does not perform external HTTP webhook delivery in production yet. The HTTP API also does not require authentication yet.

An endpoint represents a registered external destination that can receive webhooks sent by Tidewake.

## Endpoint representation

An `Endpoint` has the following fields:

| Field | Description |
| --- | --- |
| `id` | Unique endpoint identifier. |
| `name` | Human-readable endpoint name. |
| `url` | Destination URL used for webhook delivery. |
| `active` | Indicates whether new deliveries may be sent. |
| `inserted_at` | Creation timestamp. |
| `updated_at` | Last update timestamp. |

Timestamps use ISO 8601 UTC values in the examples in this document.

## Operations

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/endpoints` | Register an endpoint. |
| `GET` | `/api/endpoints` | List endpoints. |
| `GET` | `/api/endpoints/:id` | Retrieve one endpoint. |
| `PATCH` | `/api/endpoints/:id` | Update an endpoint. |

Permanent deletion is not part of this initial contract. To stop new deliveries while preserving future delivery and attempt history, a client should update `active` to `false`.

### POST /api/endpoints

Registers a new webhook destination. The request includes the endpoint name and destination URL. `active` defaults to `true` when it is not provided.

Request:

```json
{
  "name": "Ironhold",
  "url": "https://ironhold.example.com/api/webhooks"
}
```

Initial validation rules:

- `name` is required and cannot be blank.
- `url` is required and must be a valid HTTP or HTTPS URL.
- `active` defaults to `true`.
- Unknown fields are ignored by the endpoint changeset.

#### 201 Created

Returns the registered endpoint in a `data` object.

```json
{
  "data": {
    "id": 1,
    "name": "Ironhold",
    "url": "https://ironhold.example.com/api/webhooks",
    "active": true,
    "inserted_at": "2026-08-11T15:00:00Z",
    "updated_at": "2026-08-11T15:00:00Z"
  }
}
```

#### 422 Unprocessable Entity

Returns validation errors grouped by request field.

```json
{
  "errors": {
    "url": ["must be a valid HTTP or HTTPS URL"]
  }
}
```

### GET /api/endpoints

Lists all registered endpoints.

#### 200 OK

Returns endpoint objects in the `data` collection.

```json
{
  "data": [
    {
      "id": 1,
      "name": "Ironhold",
      "url": "https://ironhold.example.com/api/webhooks",
      "active": true,
      "inserted_at": "2026-08-11T15:00:00Z",
      "updated_at": "2026-08-11T15:00:00Z"
    }
  ]
}
```

When no endpoints exist, the operation returns an empty collection with `200 OK`:

```json
{
  "data": []
}
```

Pagination and advanced filtering are outside the scope of the initial contract.

### GET /api/endpoints/:id

Retrieves the endpoint identified by `:id`.

#### 200 OK

Returns the endpoint in a `data` object.

```json
{
  "data": {
    "id": 1,
    "name": "Ironhold",
    "url": "https://ironhold.example.com/api/webhooks",
    "active": true,
    "inserted_at": "2026-08-11T15:00:00Z",
    "updated_at": "2026-08-11T15:00:00Z"
  }
}
```

#### 404 Not Found

Returns a resource error when no endpoint has the requested identifier or when the identifier is invalid.

```json
{
  "error": {
    "code": "not_found",
    "message": "Endpoint not found"
  }
}
```

### PATCH /api/endpoints/:id

Updates an existing endpoint. A client sends only the fields that should change. The accepted fields are `name`, `url`, and `active`.

For example, the following request deactivates the endpoint and prevents new deliveries from being sent to it:

```json
{
  "active": false
}
```

The validation rules for supplied `name` and `url` values are the same as for endpoint creation. Unknown fields are ignored by the endpoint changeset.

#### 200 OK

Returns the updated endpoint in a `data` object.

```json
{
  "data": {
    "id": 1,
    "name": "Ironhold",
    "url": "https://ironhold.example.com/api/webhooks",
    "active": false,
    "inserted_at": "2026-08-11T15:00:00Z",
    "updated_at": "2026-08-11T16:00:00Z"
  }
}
```

#### 404 Not Found

Returns the same `not_found` resource error documented for `GET /api/endpoints/:id` when no endpoint has the requested identifier.

#### 422 Unprocessable Entity

Returns the same field-based validation error format documented for endpoint creation when a supplied value is invalid.

## Error formats

Validation errors use an `errors` object whose keys match request fields and whose values are arrays of readable messages:

```json
{
  "errors": {
    "url": ["must be a valid HTTP or HTTPS URL"]
  }
}
```

Missing resources use an `error` object with a stable code and a readable message:

```json
{
  "error": {
    "code": "not_found",
    "message": "Endpoint not found"
  }
}
```

Error responses must not expose database details or stack traces.

## Current limitations

The following capabilities remain outside the current implementation:

- authentication or authorization;
- production activation and configuration of external HTTP webhook delivery through the Req adapter;
- SSRF protection for outbound destinations;
- enforcement of a real response-body byte limit;
- HMAC signing;
- retry and backoff policies;
- recovery for interrupted or stranded delivery processing;
- a policy for deliveries already scheduled when an endpoint is deactivated; deactivation prevents the endpoint from participating in new fan-outs, but does not yet define how those scheduled deliveries are handled;
- pagination;
- advanced filtering;
- endpoint health checks;
- production deployment.

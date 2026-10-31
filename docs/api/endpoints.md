# Endpoint management API contract

## Status

Endpoint persistence and the endpoint management HTTP API are implemented. The `endpoints` table and the `Tidewake.Webhooks.Endpoint` schema persist endpoint data, while the `Tidewake.Webhooks` context and HTTP controller provide operations to list, retrieve, create, and update endpoints. The schema validates that names are present and non-blank and that URLs are present, use HTTP or HTTPS, and contain at most 2,048 bytes.

Active endpoints participate in the transactional fan-out of newly ingested events. Tidewake persists a delivery and an initial Oban job for each active endpoint. For an active endpoint, the processor signs the exact serialized envelope before passing it to the configured adapter. If the endpoint is inactive when the delivery is claimed, Tidewake cancels the delivery without invoking the adapter or creating an attempt. A periodic worker returns stale deliveries left in `processing` to `pending` for another execution.

Production uses the Req adapter with the system resolver and public-only destination policy. Development remains deterministic unless outbound HTTP is explicitly enabled; private-use and loopback destinations require a second development-only opt-in, and all other special-purpose ranges remain blocked. Each delivery attempt validates the URL again, resolves IPv4 and IPv6 hostnames, rejects mixed safe and unsafe answers, and connects to one approved IP while preserving the original hostname for Host, SNI, and TLS verification. Redirects and internal retries are disabled, idle dynamic pools expire after 60 seconds, and response bodies are streamed, limited to 65,536 bytes, and discarded. Persisted transport failures contain only bounded classifications. Every `/api` route, including endpoint management, requires project-bound service-account authentication and explicit permission.

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

## Authentication

All routes under `/api` require exactly one project-bound service-account Bearer credential. Use the exact issued value over TLS; the placeholder below is intentionally invalid:

```http
Authorization: Bearer <service-account-token>
```

A missing, malformed, duplicated, unknown, expired or revoked credential, disabled account or suspended project returns the same `401 Unauthorized` before endpoint operations. The response includes `Cache-Control: no-store` and:

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

Admin, producer and viewer may list/show endpoints within their project. Only admin may create/update/deactivate them; other roles receive fixed 403 before object lookup. Foreign and absent endpoints share the same 404. Project ownership comes from authenticated Scope and cannot be selected or changed through body/query/header fields. Overlapping credentials support deliberate rotation; human users, sessions, OAuth, JWT and automated rotation remain pending.

### POST /api/endpoints

Registers a new webhook destination. The request includes the endpoint name and destination URL. `active` defaults to `true` when it is not provided.

Request:

```bash
curl --fail-with-body -X POST http://localhost:4000/api/endpoints \
  -H 'Authorization: Bearer <service-account-token>' \
  -H 'content-type: application/json' \
  -d '{"name":"Ironhold","url":"https://ironhold.example.com/api/webhooks"}'
```

The header value above is the public local development value, not a production credential.

Request body:

```json
{
  "name": "Ironhold",
  "url": "https://ironhold.example.com/api/webhooks"
}
```

Initial validation rules:

- `name` is required and cannot be blank.
- `url` is required, must be a valid HTTP or HTTPS URL, and may contain at most 2,048 bytes. The changeset enforces this application limit; the PostgreSQL column remains `text` and does not provide it.
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

- human users, sessions, OAuth, JWT and automated credential rotation;
- pagination;
- advanced filtering;
- endpoint health checks;
- general endpoint rate limiting and an operational interface (manual retry has a separate implemented per-account admission bucket);
- production deployment.

# ADR 0010: API token authentication

- Status: accepted
- Date: 2026-09-27

## Context

Tidewake exposes event and endpoint operations under `/api`, but those routes do not currently authenticate callers. The project needs a small initial boundary before the API is exposed beyond a trusted development environment.

The current stage does not justify a user model, sessions, delegated authorization, or project-specific permissions. It does require one consistent credential check for existing and future API routes, production startup validation, a stable unauthorized response, and strict secret-handling rules.

This decision defines authentication at the Phoenix HTTP boundary. It does not grant finer-grained permissions and does not change the `Tidewake.Webhooks` domain context.

## Decision

### Protected boundary

Every route under `/api` requires one configured static API token. The authentication plug belongs in the Phoenix `:api` pipeline used by the `/api` scope so the current endpoint and event routes, and future routes added to that scope, share the same check.

The client sends the credential in exactly one request header:

```http
Authorization: Bearer <token>
```

The plug reads the header with `Plug.Conn.get_req_header/2`. Authentication proceeds only when this returns a one-element list whose value has the `Bearer ` prefix and a non-empty token. Missing headers, multiple header values, an empty token, a different scheme, extra surrounding whitespace, or any other malformed value are unauthorized. This strict shape also rejects a comma-combined duplicate value.

The expected token is read from:

```elixir
Application.fetch_env(:tidewake, :api_token)
```

Authentication succeeds only when the configured value is a binary and exactly matches the presented token. If the configured token is absent or invalid, the plug fails closed and treats the request as unauthorized; it must never allow the request to continue because configuration is missing.

The comparison follows this sequence:

1. Compare the byte sizes of the presented and configured tokens.
2. Only when the sizes are equal, call `Plug.Crypto.secure_compare/2` with the two binaries.
3. Treat a size mismatch or a `false` result as unauthorized.

`Plug.Crypto.secure_compare/2` must not be called with unequal-size values. Plain equality must not be used to validate tokens.

### Runtime configuration

Production reads the token exclusively from the `TIDEWAKE_API_TOKEN` environment variable and stores it as `config :tidewake, :api_token`. Production startup must raise a clear configuration error when the variable is absent or its value is fewer than 32 bytes. No production default or fallback is permitted.

Development and test configuration may provide separate local defaults that are clearly labeled and recognizable as non-production credentials. The 32-byte production minimum does not require local values to masquerade as production secrets. Local defaults must not be reused as production fallbacks, and the production runtime check remains authoritative.

Configuration is environment-specific, but request authentication always reads the same `:tidewake, :api_token` application key. This keeps the plug independent of how the value was supplied.

### Unauthorized response

For an absent, malformed, duplicated, or invalid credential, and for missing or invalid application configuration, the plug halts the connection with status `401 Unauthorized`, adds:

```http
WWW-Authenticate: Bearer
```

and returns exactly this JSON shape:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Valid API token required"
  }
}
```

All authentication failures intentionally use the same public response. The plug does not reveal whether the header was absent, malformed, duplicated, the token had a different length, the token comparison failed, or server configuration was missing.

The plug must halt before a controller action or any `Tidewake.Webhooks` operation runs. A valid token allows the existing Phoenix pipeline and controller behavior to continue unchanged.

### Secret handling

The configured token, presented token, and complete `Authorization` header are secrets. They must never be:

- logged, including in authentication failure messages or inspected connection data;
- persisted in the database, delivery records, attempts, jobs, or audit records;
- included in Telemetry measurements, metadata, tags, exception metadata, or event names;
- returned in an HTTP response.

Internal diagnostics may record only a generic authentication failure without the header, token, token length, or other credential-derived data. Request logging and error handling must not serialize request headers. Production transport must protect the bearer token with TLS; this token scheme does not make plaintext transport safe.

### Architectural boundary

Authentication is a web-boundary concern implemented under `TidewakeWeb` and composed through the router pipeline. Controllers and the `Tidewake.Webhooks` context may rely on the pipeline having authenticated the request, but the context does not receive, compare, store, or know about the API token.

This is an initial, replaceable boundary. A later authentication or authorization system can replace the pipeline plug without moving credential handling into `Tidewake.Webhooks` or coupling webhook persistence and processing to a particular identity mechanism.

## Consequences

### Positive

- All current and future `/api` routes have one consistent default-deny check.
- Production cannot boot with a missing or short token.
- Equal-length constant-time comparison avoids ordinary secret equality checks.
- A uniform response does not disclose the reason authentication failed.
- Token material stays outside persistence, logging, Telemetry, and the webhook domain.
- The small boundary can be replaced later without redesigning `Tidewake.Webhooks`.

### Negative

- Every authorized client shares one credential, so requests cannot be attributed to individual users or projects.
- Rotation requires coordinated configuration and client updates; no overlap between old and new tokens is defined.
- A leaked token grants access to every `/api` operation until it is manually replaced.
- Strict header parsing may reject clients or intermediaries that rewrite an otherwise recognizable authorization header.
- Authentication alone does not provide project-level authorization or administrative roles.

## Alternatives considered

### Leave the API restricted only by deployment topology

Rejected because accidental exposure would leave all API operations unauthenticated and would not fail closed.

### HTTP Basic authentication

Rejected because Tidewake does not need username semantics and a bearer token expresses the current single-credential boundary more directly.

### JWT or OAuth

Rejected because issuer validation, key management, claims, expiry, scopes, and delegated flows add complexity that the current product stage does not require.

### Authenticate inside controllers or `Tidewake.Webhooks`

Rejected because controller-by-controller checks are easy to omit, while domain-level checks would couple webhook behavior to an HTTP credential and make a future replacement harder.

## Out of scope

- users;
- login;
- sessions;
- JWT;
- OAuth;
- scopes;
- automatic rotation;
- multiple simultaneous tokens;
- project-level authorization;
- an administrative panel.

## Follow-up

Implement a focused `TidewakeWeb` authentication plug, add it to the Phoenix `:api` pipeline, and configure environment-specific `:api_token` values. Add tests for successful authentication, every unauthorized header shape, equal- and unequal-size tokens, missing configuration, the exact response body and `WWW-Authenticate` header, pipeline halting, secret non-disclosure, and production runtime validation.

Update the API documentation and local setup instructions only when the authentication behavior is implemented.

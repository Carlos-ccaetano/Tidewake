# ADR 0005: Outbound HTTP transport

- Status: accepted
- Date: 2026-09-13

## Context

[ADR 0001](0001-project-foundation.md) selects Req for outbound HTTP. [ADR 0004](0004-terminal-delivery-failures.md) defines the adapter outcomes that the delivery processor accepts, but Tidewake still uses only a deterministic adapter and makes no real network request.

The version locked in `mix.lock` is Req 0.7.4. In that version, Req follows redirects by default, has a built-in retry step, accepts an already encoded request through `body:`, and uses Finch as its default transport. Finch exposes separate connection, receive, and request timeouts. Req also collects the complete response body by default when no streaming destination is configured. The first real adapter needs an explicit boundary that does not accidentally duplicate delivery policy, resend a webhook, re-encode its envelope, or retain unbounded external content.

## Decision

### Request

Implement a Req-backed module that satisfies `Tidewake.Webhooks.DeliveryAdapter`. For each call to `deliver/3`, it will make exactly one HTTP `POST` request to the supplied URL.

The adapter will pass the received binary through Req's `body:` option unchanged. It will not use `json:`, `form:`, `form_multipart:`, Jason, or any other encoder. The bytes prepared by the delivery processor are the bytes sent as the request body.

The adapter will pass the supplied header name/value pairs through Req's `headers:` option without filtering, renaming, replacing, or reconstructing them. Req may add transport-required headers such as `content-length`, but the adapter must preserve every header prepared by the processor and must not infer domain headers of its own.

Every request will set these options explicitly:

| Option | Value | Purpose |
| --- | --- | --- |
| `method` | `:post` | Send the webhook using POST. |
| `retry` | `false` | Ensure one adapter call makes one network request. |
| `redirect` | `false` | Return redirect responses without following another destination. |
| `http_errors` | `:return` | Return `4xx` and `5xx` responses normally. |
| `connect_options[:timeout]` | `5_000` ms | Limit connection establishment. |
| `receive_timeout` | `10_000` ms | Limit waiting for data from the socket. |
| `request_timeout` | `15_000` ms | Bound the request operation at the Finch adapter. |
| `compressed` | `false` | Do not request or decompress compressed response content. |
| `decode_body` | `false` | Do not decode response content. |

The three timeout values are part of this initial adapter contract and must be covered by tests. A timeout from any of these boundaries is normalized to the same bounded transport outcome; it does not select retry behavior.

### Response boundary

Every complete HTTP response, including `3xx`, `4xx`, and `5xx`, will return:

    {:ok, %{status: status, headers: headers}}

The adapter will convert Req 0.7.4 response headers into the `DeliveryAdapter` list of string name/value pairs, preserving repeated values as separate pairs. It will not decide whether the status represents success or failure. That classification belongs to `DeliveryProcessor`.

The response body will never be included in the adapter result, persisted, decoded, inspected for delivery semantics, or logged. An implementation may receive and discard a bounded body while producing the response result, but it must not expose that body across the adapter boundary.

### Bounded transport failures

Req 0.7.4 represents network failures as `Req.TransportError` and protocol failures without a complete HTTP response as `Req.HTTPError`. The adapter will translate only those expected Req failures into this closed set of atoms:

| Req failure | Adapter reason |
| --- | --- |
| `%Req.TransportError{reason: :timeout}` | `:timeout` |
| `%Req.TransportError{reason: :nxdomain}` | `:dns_error` |
| `%Req.TransportError{reason: :econnrefused}` | `:connection_refused` |
| `%Req.TransportError{reason: :closed}` | `:connection_closed` |
| Recognized TLS alerts or protocol-negotiation failures | `:tls_error` |
| Other `Req.TransportError` or `Req.HTTPError` values | `:unknown` |

The corresponding adapter result is `{:error, reason}`. The mapping will use explicit pattern matching. It will not call `String.to_atom/1`, create atoms dynamically, return raw nested reasons, use exception messages as classifications, or broadly rescue programming errors. Unexpected exceptions and malformed internal results remain execution errors rather than external transport outcomes.

### Responsibility and data boundaries

The Req adapter is infrastructure only. It does not access Ecto, the repository, database records, schemas, events, deliveries, attempts, or Oban jobs. It does not decide delivery success, failure, retry eligibility, scheduling, or terminal state. It performs no retry itself.

The adapter must not log request bodies, response bodies, URLs containing credentials, prepared request headers, response headers, raw transport reasons, or exception messages. In particular, authorization values, cookies, API keys, webhook signatures, payload data, and endpoint-specific details must not enter logs or persistence through this module. Safe response metadata remains the processor's bounded responsibility under ADRs 0003 and 0004.

### Implementation, testing, and activation

The adapter may now be implemented and tested against the existing `DeliveryAdapter` contract. Tests may use Req 0.7.4's official `Req.Test` facilities to verify the method, exact raw body, preserved headers, response mapping, disabled redirect and retry behavior, timeouts, body omission, and bounded error normalization without making external requests.

The Req adapter will not be configured as Tidewake's default yet. The deterministic adapter remains the configured delivery adapter in development and tests, and no environment will opt into real outbound delivery as part of implementing this decision.

Real activation requires two further protections:

1. A destination policy against server-side request forgery must validate the URL and every resolved connection target, including scheme, user information, host, port, private and special-use address ranges, DNS rebinding, and equivalent representations. Disabling redirects prevents redirect-based destination changes but is not a complete SSRF defense.
2. Response consumption must enforce a small hard limit against the bytes actually received. `content-length` is not sufficient because it may be absent or dishonest. The design must define streaming, early cancellation, connection reuse, and the outcome when the limit is exceeded before untrusted responses can be fetched in production.

Timeouts limit elapsed waiting; they do not bound response memory. Until both protections are decided, implemented, and tested, the real adapter must remain inactive.

HMAC signing and all retry policy, backoff, eligibility, and scheduling remain outside this decision.

## Consequences

### Positive

- One processor attempt corresponds to one outbound request, without implicit Req retries or redirects.
- The serialized envelope and prepared headers cross the transport boundary without domain reinterpretation.
- HTTP responses and failures without a response continue to match the existing processor contract.
- Explicit timeouts prevent Req or Finch defaults from silently defining Tidewake's transport behavior.
- Sensitive and unbounded response content stays outside the domain and persistence boundary.

### Negative

- The real adapter cannot be enabled until SSRF controls and bounded response consumption exist.
- Coarse error atoms intentionally discard low-level diagnostic detail.
- Fixed initial timeouts may require a future decision based on operational evidence.
- Disabling redirects rejects endpoints that rely on redirect behavior.

## Alternatives considered

### Use Req defaults

Rejected because redirects are enabled, response collection is unbounded, and some timeouts are implicit or infinite. Transport behavior that affects request count, destination, latency, and memory must be explicit.

### Pass the envelope through `json:`

Rejected because the processor already serializes the envelope. Encoding again could change the request bytes and violates the adapter contract.

### Classify delivery outcomes in the adapter

Rejected because HTTP success, terminal delivery state, attempt persistence, and retry policy belong to the Tidewake domain and processor, not the HTTP client.

### Enable the adapter immediately

Rejected because redirects and timeouts alone do not prevent SSRF or unbounded response-body consumption.

## References

- [Req 0.7.4 high-level API](https://hexdocs.pm/req/0.7.4/Req.html)
- [Req 0.7.4 built-in steps](https://hexdocs.pm/req/0.7.4/Req.Steps.html)
- [Req 0.7.4 Finch adapter options](https://hexdocs.pm/req/0.7.4/Req.Finch.html)
- [Req 0.7.4 changelog](https://hexdocs.pm/req/0.7.4/changelog.html)

## Follow-up

Implement the Req adapter and its isolated tests without changing the configured default. Define and implement destination validation and bounded response consumption in separate decisions before enabling real outbound HTTP.

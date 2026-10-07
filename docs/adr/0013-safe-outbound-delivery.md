# ADR 0013: Safe outbound delivery

- Status: accepted
- Date: 2026-10-07

## Context

[ADR 0005](0005-outbound-http-transport.md) defines the Req adapter and keeps it inactive until Tidewake can prevent server-side request forgery and bound response consumption. [ADR 0012](0012-signed-webhook-contract.md) defines the signed request that crosses that adapter, but signing does not make an endpoint safe to contact.

The locked versions are Req 0.7.4, Finch 0.23.0, and Mint 1.9.3. They support disabled redirects and retries, streaming response chunks, finite idle lifetimes for HTTP/1 pools, and connecting to one address while retaining a separate hostname for the `Host` header, SNI, and TLS certificate verification. This decision defines how Tidewake will use those capabilities before real outbound delivery can be enabled.

## Decision

### URL eligibility

Endpoint URLs are limited to 2,048 bytes. They must be absolute URLs with a non-empty host, use only the `http` or `https` scheme, and contain neither user information nor a fragment.

Passing validation when an endpoint is persisted does not make that URL permanently eligible for delivery. Every attempt must parse and validate the current stored URL again before opening a connection. A URL that no longer satisfies the policy fails closed as `:unsafe_destination`; the adapter must not make a network request.

### Resolution and address classification

For a hostname, Tidewake must resolve both IPv4 and IPv6 records for that attempt. Resolution fails closed as `:unsafe_destination` when it returns no addresses. All returned addresses must be classified before one is selected: if any resolved address is not allowed, the entire destination is rejected. Tidewake must not discard a disallowed answer and continue with an allowed one.

An IPv4 or IPv6 literal bypasses DNS resolution but is subject to the same classification. IPv4-mapped IPv6 addresses are also classified by their embedded IPv4 address so that alternate notation cannot bypass the policy.

Classification is based on the IANA IPv4 and IPv6 special-purpose address registries. The default mode, including production, accepts only globally reachable addresses. Multicast addresses are never eligible.

An explicit local mode is available only in development. It adds loopback and private-use addresses to the globally reachable set. It does not allow unspecified, link-local, multicast, documentation, benchmarking, reserved, or any other non-global special-purpose range. Production must reject configuration that attempts to enable local mode.

### Connection binding

After the complete answer set passes classification, Tidewake selects exactly one approved address for that attempt. The selection must remain fixed for that request. A failed connection is not permission to resolve again, select another address, or issue another request inside the adapter.

The transport connects directly to the selected IP address. It preserves the original URL hostname separately as Mint's `:hostname`, which is used for the HTTP `Host` header, TLS SNI, and certificate hostname verification. For an IP-literal URL, that literal remains the original hostname. No component may perform a second DNS resolution between validation and connection.

Pools for these connections must be keyed so that the scheme, port, selected IP address, and original hostname cannot share a connection with a different validated destination. The first safe implementation uses HTTP/1 only, because Finch 0.23.0 applies pool idle expiration to HTTP/1 pools and can halt an HTTP/1 response stream by closing its connection. Dynamically created pools expire after 60,000 milliseconds without activity.

Req redirects and retries remain disabled. Finch or Mint must not transparently repeat the request. One delivery attempt produces at most one network request.

### Response boundary

Response bodies are limited to 65,536 bytes. The adapter consumes the body as a stream, counts the bytes in each received data chunk, and discards the chunks instead of accumulating, decoding, decompressing, persisting, or returning them. The limit is inclusive: exactly 65,536 bytes is allowed; the first chunk that raises the total above the limit halts the stream and closes the connection.

A `content-length` value above the limit may reject a response early, but a missing, malformed, or smaller value does not relax the streamed byte count. Exceeding the actual limit is normalized to `:response_too_large`. A complete response within the limit retains only the bounded status and headers required by the existing adapter contract.

### Observability boundary

Destination-policy and response-limit outcomes may be observed only through bounded, low-cardinality classifications. URLs, resolved or selected IP addresses, request or response bodies, request or response headers, and raw resolver, socket, TLS, or HTTP errors must not appear in logs or Telemetry measurements, metadata, tags, or event names.

`:unsafe_destination` is the only public adapter reason for URL, resolution, and address-policy rejection. `:response_too_large` is the only public adapter reason for crossing the response-body limit. Neither reason exposes the rejected value or low-level error.

### Activation and testing

This ADR does not activate Req. The deterministic adapter remains the default and Tidewake still makes no external webhook requests.

Activation requires implementation and tests that cover URL syntax and byte length, both address families, every policy category used from the IANA registries, mixed allowed and disallowed DNS answers, DNS rebinding resistance, IP literals and mapped addresses, local-mode environment restrictions, direct-IP connection with the original hostname, absence of a second resolution, disabled redirects and retries, isolated pool keys and idle expiration, the exact response limit, chunk boundaries, early cancellation, and the observability restrictions above.

## Consequences

### Positive

- A persisted or signed destination cannot bypass an attempt-time network policy.
- Validating every DNS answer and binding the connection to one approved IP closes the rebinding gap between lookup and connection.
- Preserving the original hostname keeps HTTP and TLS identity checks correct while the socket uses the approved address.
- Streaming and discarding response data bounds retained external content independently of `content-length`.
- Finite, destination-specific pools do not retain an unbounded set of idle connections.

### Negative

- Rejecting a hostname when any answer is disallowed is stricter than selecting only its public answers.
- HTTP/1-only delivery gives up HTTP/2 multiplexing for the first safe implementation.
- Revalidation and DNS resolution add work to every attempt.
- The special-purpose registry classification must be reviewed when IANA changes those registries.
- Local development requires an explicit mode and cannot exercise every non-global address category.

## Alternatives considered

### Trust validation performed when the endpoint is created

Rejected because DNS answers and address classifications can change between persistence and delivery. Eligibility is a property of each attempt, not of the stored row alone.

### Accept an allowed answer when DNS also returns a disallowed answer

Rejected because an attacker could influence answer ordering or rebinding behavior. The complete answer set must satisfy the policy.

### Validate the hostname and let the HTTP client resolve it again

Rejected because the connection could use an address that was not classified. The validated IP must be the connection address.

### Rely on `content-length` or normal response collection

Rejected because the header can be absent or inaccurate and normal collection can retain an unbounded body. The actual streamed bytes are authoritative.

## References

- [ADR 0005: Outbound HTTP transport](0005-outbound-http-transport.md)
- [ADR 0012: Signed webhook contract](0012-signed-webhook-contract.md)
- [Req 0.7.4 Finch adapter](https://hexdocs.pm/req/0.7.4/Req.Finch.html)
- [Finch 0.23.0 documentation](https://hexdocs.pm/finch/0.23.0/Finch.html)
- [Mint 1.9.3 connection documentation](https://hexdocs.pm/mint/1.9.3/Mint.HTTP.html#connect/4)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [IANA IPv4 Special-Purpose Address Registry](https://www.iana.org/assignments/iana-ipv4-special-registry/)
- [IANA IPv6 Special-Purpose Address Registry](https://www.iana.org/assignments/iana-ipv6-special-registry/)

## Follow-up

Implement the destination policy, direct-IP transport binding, bounded response streaming, and their isolated tests in separate changes. Keep Req inactive until every activation requirement in this decision is implemented and verified.

# ADR 0012: Signed webhook contract

- Status: accepted
- Date: 2026-09-30

## Context

Tidewake serializes each event into a JSON envelope before passing an already encoded binary and prepared headers to a delivery adapter. The adapter contract preserves that body instead of encoding it again, but Tidewake does not yet authenticate outbound webhook requests.

Receivers need to verify both the sender and the exact request body they received. Signing a data structure before serialization would not provide that guarantee because JSON key order, whitespace, escaping, or later encoding could change the transmitted bytes. This decision defines a versioned wire contract over the final body binary without implementing signing, secret configuration, or header preparation.

## Decision

### Headers

Each signed request carries exactly one value for each of these headers:

```http
Tidewake-Id: <event_id>
Tidewake-Timestamp: <timestamp>
Tidewake-Signature: v1=<hex_digest>
```

HTTP header names are case-insensitive. Senders and receivers must therefore treat names such as `Tidewake-Id` and `tidewake-id` as the same field. The casing above is the preferred wire representation, but verification must not depend on it. Missing, duplicated, or otherwise ambiguous signing headers are invalid.

`Tidewake-Id` is the event's `external_id` exactly as used to build the signature. It is not the internal database ID, delivery ID, or attempt number.

`Tidewake-Timestamp` is the request signing time represented as base-10 Unix seconds with ASCII decimal digits and no sign, fractional part, surrounding whitespace, or other formatting.

`Tidewake-Signature` contains the lowercase hexadecimal representation of an HMAC-SHA256 digest, prefixed with `v1=`. The version prefix allows a future contract to coexist without changing the meaning of version 1.

### Canonical input and body identity

The version 1 canonical input is the byte concatenation:

```text
v1.<event_id>.<timestamp>.<exact_body_bytes>
```

Equivalently, using binary construction notation:

```elixir
<<"v1.", event_id::binary, ".", timestamp::binary, ".", body::binary>>
```

The periods shown above are literal ASCII `.` bytes. `event_id` and `timestamp` are the exact values placed in `Tidewake-Id` and `Tidewake-Timestamp`. `body` is the final serialized envelope binary. No newline, whitespace, character-set conversion, JSON normalization, re-encoding, compression, or other transformation is added for signing.

Tidewake must first serialize the envelope, then generate the timestamp, construct the canonical input, and calculate HMAC-SHA256 with the configured signing secret. The exact same `body` binary used in the canonical input must be passed to the delivery adapter. Neither the signer nor the adapter may reconstruct or re-encode it after the signature is calculated.

Each future retry is a distinct outbound request. It must generate a new current timestamp and a new signature over that timestamp and the body bytes for that request. `Tidewake-Id` remains the event's `external_id`; it provides a stable receiver-side idempotency key even when timestamp and signature change.

### Verification contract

A receiver reconstructs the canonical input from the single accepted values of `Tidewake-Id` and `Tidewake-Timestamp` plus the raw request body bytes as received. It computes HMAC-SHA256 with the shared secret, encodes the digest as lowercase hexadecimal with the `v1=` prefix, and compares the complete expected and presented signatures using a constant-time comparison suitable for equal-length binaries. Ordinary string equality is not sufficient for signature verification.

Ironhold must enforce a configured temporal acceptance window for `Tidewake-Timestamp` before accepting or persisting a request. The future verification design must reject timestamps that are too old or unreasonably far in the future, as well as malformed timestamps, before the webhook is accepted. The exact window and rejection response belong to Ironhold's implementation decision.

Passing signature verification proves possession of the configured shared secret and integrity of the canonical bytes. It does not provide exactly-once delivery. Receivers must continue to use `Tidewake-Id` for idempotency because recovery and future retries can deliver the same event more than once.

### Secret and observability boundary

The signing secret comes only from trusted application or deployment configuration. It must never come from an event payload, endpoint record, delivery record, request, job argument, or other database value. This phase defines one configured secret; rotation and multiple simultaneously valid secrets require a later decision.

The signing secret, computed HMAC or complete signature, request body, and prepared request headers must never be written to logs, delivery attempts, job arguments, exception metadata, or Telemetry measurements, metadata, tags, or event names. Existing bounded delivery outcomes may remain observable, but signing material and message content must stay outside those records.

### Test vector

This vector uses an obviously non-production secret and a fixed timestamp. The body is the exact UTF-8 byte sequence shown, with no trailing newline.

```text
secret:    tidewake_test_secret_not_for_production
event_id:  evt_test_123
timestamp: 1700000000
body:      {"data":{"ok":true},"id":"evt_test_123","type":"test.ping"}
```

The canonical input is:

```text
v1.evt_test_123.1700000000.{"data":{"ok":true},"id":"evt_test_123","type":"test.ping"}
```

The expected header value is:

```text
v1=3323d158355377e1b2d7515e31a40365a48ff11d427a8a8f62cfda1e4bf92128
```

The value was generated with code equivalent to:

```elixir
secret = "tidewake_test_secret_not_for_production"
event_id = "evt_test_123"
timestamp = "1700000000"
body = ~S({"data":{"ok":true},"id":"evt_test_123","type":"test.ping"})

canonical = IO.iodata_to_binary(["v1.", event_id, ".", timestamp, ".", body])

signature =
  :crypto.mac(:hmac, :sha256, secret, canonical)
  |> Base.encode16(case: :lower)
  |> then(&("v1=" <> &1))
```

The expected digest was also independently reproduced with .NET `HMACSHA256` over the same UTF-8 bytes.

## Consequences

### Positive

- Receivers can verify the exact body bytes delivered by the adapter.
- The event's external ID gives retries a stable idempotency key while timestamps and signatures remain request-specific.
- A versioned signature format permits a future algorithm or canonical-input change without silently redefining `v1`.
- Constant-time comparison and strict single-value headers define a narrow verification boundary.
- Signing material remains outside persistence and observability surfaces.

### Negative

- Sender and receiver must retain the raw serialized body because parsing and re-encoding JSON can change the signed bytes.
- Clock skew can reject an otherwise authentic request, so both systems require reliable clocks and an explicit acceptance window.
- One configured secret provides no overlap for seamless rotation and cannot identify different signing keys.
- HMAC does not prevent duplicate delivery; receivers still need idempotent handling by event ID.

## Alternatives considered

### Sign the event structure before JSON encoding

Rejected because a later serializer or transport transformation could produce bytes that no longer match what was authenticated.

### Sign only the body

Rejected because binding the external event ID and request timestamp supports stable idempotency and time-window enforcement as explicit parts of the authenticated message.

### Put a digest in the payload

Rejected because it would change the event envelope, mix transport authentication with domain data, and still require a trusted secret and unambiguous byte representation.

### Use asymmetric signatures now

Rejected for this phase because key distribution, public-key identity, rotation, and algorithm agility add operational complexity that the current single-sender contract does not yet require.

## Out of scope

- signer implementation;
- delivery processor or adapter changes;
- signing header configuration or emission;
- Ironhold verification implementation and its exact temporal window;
- secret provisioning or production activation;
- secret rotation or overlap;
- multiple signing secrets or key identifiers;
- retries, backoff, or retry eligibility;
- exactly-once delivery guarantees.

## Follow-up

Implement Tidewake signing in a separate change after defining validated secret configuration. The implementation must test the vector above, exact body identity across signer and adapter, fresh timestamp and signature generation per request, constant-time verification expectations, and non-disclosure in logs, attempts, jobs, and Telemetry.

Define Ironhold's timestamp window, raw-body verification boundary, stable rejection responses, and replay behavior before enabling signed ingestion in production.

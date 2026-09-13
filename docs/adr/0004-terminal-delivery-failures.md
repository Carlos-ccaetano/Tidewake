# ADR 0004: Terminal delivery failures

- Status: accepted

## Context

[ADR 0002](0002-delivery-lifecycle.md) defines the initial delivery lifecycle, and [ADR 0003](0003-delivery-attempt-recording.md) defines append-only attempt evidence. Delivery and attempt persistence, atomic finalization, and the deterministic success path are implemented. The processor currently propagates adapter errors without recording an attempt and leaves the delivery in `processing`.

This decision defines the first failure-recording behavior before changing the processor. It preserves the existing adapter boundary and introduces no transport implementation or consumer-specific rules.

## Decision

### Valid adapter outcomes

A valid HTTP outcome is `{:ok, %{status: status, headers: headers}}`, with an integer status from 100 through 599 and headers conforming to `DeliveryAdapter` (a list of string name/value pairs). A valid failure without a response is `{:error, reason}`, where `reason` is an atom representing a transport outcome.

| Adapter outcome | Attempt result | HTTP status | Delivery final state |
| --- | --- | --- | --- |
| Any HTTP response from 200 through 299 | `succeeded` | Received status, required | `succeeded` |
| Any valid HTTP response outside 200 through 299 | `http_error` | Received status, required | `failed` |
| Transport failure without an HTTP response | `transport_error` | Absent; never synthesized | `failed` |

Every adapter call that completes with a valid outcome must produce one append-only attempt, whether it succeeds or fails externally. Claim or encoding errors before the adapter call do not represent an external attempt. This recording obligation does not imply that persistence can succeed during a database failure.

Use the existing atomic finalization boundary: lock a `processing` delivery, derive its attempt number from persisted state, insert the attempt, increment `attempt_count`, set the terminal status and `completed_at`, and commit together. Invalid attempt data or a persistence failure must not leave a partially finalized delivery. Preserve UTC timestamps, non-negative monotonic duration, uniqueness, and immutable history from the previous ADRs.

### Bounded error classification

For HTTP outcomes, `error_type` is absent; `http_status` carries the failure information. For a valid transport failure, persist exactly one of these strings:

| `error_type` | Meaning |
| --- | --- |
| `timeout` | The transport operation exceeded its time limit. |
| `dns` | Name resolution failed. |
| `tls` | TLS negotiation or certificate validation failed. |
| `connection` | A connection could not be established or failed. |
| `closed` | The connection closed before a response was available. |
| `unknown` | A valid transport failure cannot be mapped to a known category. |

Normalize known transport reason atoms through an explicit, bounded mapping. An unrecognized transport reason maps to `unknown`; do not persist its original value or dynamically create atoms. `unknown` is not a catch-all for programming errors, invalid adapter replies, or database failures.

Exception messages, URLs, headers, payloads, secrets, and arbitrary values must never become `error_type`.

### Operational outcome versus execution failure

A persisted `http_error` or `transport_error` is an operational delivery outcome, not a persistence failure. Once the attempt and the delivery's `failed` state commit together, the processor may return a successful operation result and the Oban worker may complete successfully. Job completion means processing and recording finished, not that the external endpoint accepted the webhook.

Programming errors, raised exceptions, malformed adapter responses (including invalid statuses or header shapes), and database failures must remain execution or persistence errors. Do not convert them into normal external failures, synthetic HTTP statuses, or `transport_error` with `unknown`. Do not acknowledge successful processing when finalization did not commit. A transport implementation may translate recognized transport errors into its contract, but must not broadly rescue unrelated exceptions as transport outcomes.

Retries remain disabled, with the worker retaining one attempt. `failed` remains terminal: no return to `pending`, automatic rescheduling, or retry eligibility is introduced. Job cancellation or discard does not introduce a `cancelled` delivery state. Recovery of deliveries left in `processing` requires a future decision.

### Response metadata

The ADR 0003 allowlist remains unchanged:

| Key | Limit |
| --- | --- |
| `content_type` | Optional string, at most 255 bytes. |
| `content_length` | Optional non-negative integer. |
| `request_id` | Optional string, at most 255 bytes. |

Only safe allowlisted values may enter attempt metadata. Unknown keys are not persisted; invalid or oversized values are omitted or rejected before insertion, never silently truncated. No response metadata is available for a failure without a response. Never persist raw request/response headers, authentication headers, secrets, or response bodies. An allowlisted key does not authorize storing a secret in its value.

## Consequences

- Valid success and failure outcomes receive durable, append-only evidence through the same finalization operation.
- Worker success can coexist with a failed delivery without triggering retries.
- Internal defects remain visible as execution failures rather than misleading external outcomes.
- Coarse transport categories intentionally omit raw diagnostic details.
- A failed persistence operation may leave a claimed delivery in `processing`; this decision does not provide recovery.

## Follow-up

Implement and test HTTP and transport failure recording in separate changes, including worker completion after persisted failure and propagation of invalid replies and persistence errors. The current processor and schema are unchanged by this ADR; the schema's existing length check does not yet enforce this closed `error_type` vocabulary.

Req transport, HMAC, retry policy, and recovery remain separate work. This decision does not enable real external delivery or add modules, abstractions, migrations, or consumer-specific behavior.

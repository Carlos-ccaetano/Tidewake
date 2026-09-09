# ADR 0003: Delivery attempt recording

- Status: accepted
- Date: 2026-09-09

## Context

Tidewake now persists events, endpoints, and the intention to deliver one event to one endpoint. The next part of the delivery flow will need to preserve what happened during each outbound request without storing sensitive or unbounded data. This decision defines the internal record before an `Attempt` schema, outbound HTTP client, or worker is introduced.

The delivery lifecycle defines HTTP `2xx` responses as success and leaves retry behavior for a later decision. Attempt recording must preserve that distinction while keeping transport failures separate from HTTP responses.

## Decision

An attempt is append-only evidence of one completed outbound operation for a delivery. After insertion, an attempt is not updated or deleted through the domain. A later operation may append new evidence, but it does not rewrite an earlier attempt.

Each attempt contains these minimum fields:

| Field | Requirement |
| --- | --- |
| `delivery_id` | Required reference to exactly one delivery. |
| `attempt_number` | Required positive integer, sequential within the delivery and starting at `1`. The pair `delivery_id + attempt_number` is unique. |
| `result` | Required normalized result: `succeeded`, `http_error`, or `transport_error`. |
| `http_status` | Optional integer HTTP status. It is present only when an HTTP response was received. |
| `error_type` | Optional, bounded machine-readable classification. It must not contain raw exception messages, response content, credentials, or endpoint-specific details. |
| `duration_ms` | Required non-negative integer containing elapsed duration in milliseconds. |
| `started_at` | Required UTC timestamp with microsecond precision. |
| `completed_at` | Required UTC timestamp with microsecond precision, equal to or later than `started_at`. |
| `response_metadata` | Optional object containing only the allowlisted response metadata defined below. |

The normalized results mean:

| Result | Meaning |
| --- | --- |
| `succeeded` | An HTTP response in the complete `200` through `299` range was received. `http_status` is required. |
| `http_error` | An HTTP response outside the `2xx` range was received. `http_status` is required. |
| `transport_error` | No HTTP response was received because transport or request processing failed. `http_status` must be absent. |

A transport failure is never represented by a synthetic HTTP status. The optional `error_type` may distinguish bounded categories such as timeout, DNS, TLS, connection, or another transport failure, but this classification does not decide whether the operation should be retried.

### Response metadata limits

`response_metadata` is not an arbitrary header map. The initial allowlist contains only:

| Key | Limit |
| --- | --- |
| `content_type` | Optional string of at most 255 bytes. |
| `content_length` | Optional non-negative integer. |
| `request_id` | Optional string of at most 255 bytes. |

Unknown keys are rejected rather than persisted. Values that exceed their limits are discarded or rejected before insertion; they are not truncated in a way that could conceal sensitive content.

Secrets are never persisted in an attempt. Authentication headers are never persisted, including authorization, cookies, API keys, webhook signatures, and token-bearing headers from either the request or response. The initial attempt record stores no response body. Any future response body capture requires a separate decision that defines an explicit byte limit, content filtering, redaction, access, and retention; response bodies must never be stored without a limit.

## Deferred decisions

Retry classification, retry eligibility, attempt limits, backoff, and scheduling remain for another ADR. The attempt result records what occurred and does not imply whether Tidewake should retry it.

This decision does not implement or select Req behavior, HMAC signing, an `Attempt` schema, migrations, contexts, workers, jobs, or persistence APIs. It introduces no modules, services, generic metadata abstractions, or consumer-specific rules. Those elements must be added only when their behavior is implemented and tested.

## Consequences

### Positive

- Attempt history remains stable evidence for operations and auditing.
- HTTP failures and failures without an HTTP response cannot be confused.
- Strict metadata limits reduce the risk of retaining secrets or unbounded external content.
- Retry policy can evolve independently from the facts recorded for an attempt.

### Negative

- The initial record omits response bodies that might help diagnose some failures.
- The small metadata allowlist may require a later decision when a concrete operational need appears.
- Sequential numbering will require concurrency protection when persistence is implemented.

## Follow-up

Define the attempt table and schema in separate changes that enforce these fields, uniqueness, immutability, and metadata limits. Decide retry classification before adding retry scheduling or workers.

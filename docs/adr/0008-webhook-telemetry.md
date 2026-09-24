# ADR 0008: Webhook telemetry contract

- Status: accepted
- Date: 2026-09-23

## Context

Tidewake now atomically ingests an event, its deliveries, and their initial jobs, and it can process a delivery through a persisted success, HTTP error, or transport error. The application includes `telemetry` 1.4.2 and `telemetry_metrics` 1.2.0, while `TidewakeWeb.Telemetry` currently exposes only framework, database, and VM metric definitions. The webhook path needs a stable observability contract before emission and metric definitions are added.

Telemetry events carry an atom-list name, a measurements map, and a metadata map. `Telemetry.Metrics` derives an event name and measurement from a metric name and uses selected metadata keys as tags. Each distinct tag-value combination creates a separate aggregation, so dynamic identifiers or unbounded values would make webhook metrics unsafe and expensive. Telemetry handlers also run in the process dispatching the event, which makes a small, predictable event payload important.

The domain distinguishes persisted delivery failures from processing failures. A non-2xx HTTP response or normalized transport failure is a completed processing outcome once the failed delivery and its attempt are committed. By contrast, a missing delivery, invalid transition, encoding problem, malformed adapter response, or persistence failure prevents confirmed finalization. The telemetry vocabulary must preserve that distinction.

## Decision

### Event namespace and terminal events

Webhook telemetry uses the `[:tidewake, :webhooks]` prefix and defines these terminal events:

| Event | Measurements | Metadata | Meaning |
| --- | --- | --- | --- |
| `[:tidewake, :webhooks, :event, :ingested]` | `%{count: 1, delivery_count: non_neg_integer()}` | `%{}` | Event, deliveries, and initial jobs committed successfully. |
| `[:tidewake, :webhooks, :event, :rejected]` | `%{count: 1}` | `%{reason: reason}` | Ingestion ended without committing a new event. |
| `[:tidewake, :webhooks, :delivery, :processed]` | `%{count: 1, duration_ms: non_neg_integer()}` | `%{outcome: outcome}` | Delivery and attempt finalization committed successfully. |
| `[:tidewake, :webhooks, :delivery, :error]` | `%{count: 1, duration_ms: non_neg_integer()}` | `%{reason: reason}` | Processing ended without confirmed delivery finalization. |

`count` is always the integer `1`; batching is not part of this contract. `delivery_count` is the number of deliveries committed by the successful ingestion, including `0` when no endpoint was eligible. It is a measurement, never a tag.

`duration_ms` is the non-negative elapsed time of the delivery processing operation, from entry into processing until its terminal result. It is measured with a monotonic clock and converted to integer milliseconds after subtraction. It is not a wall-clock timestamp and is not copied from client or adapter data.

No start event is defined in this first contract. Each ingestion or delivery-processing invocation emits at most one of its two terminal events, avoiding double counting and preventing a start signal from being mistaken for durable success.

### Commit and finalization boundary

`[:tidewake, :webhooks, :event, :ingested]` may be emitted only after the `Ecto.Multi` transaction used by `Webhooks.ingest_event/1` returns confirmed success. It must not be emitted from inside the transaction or after only the event insert succeeds. `delivery_count` is taken from the committed result.

`[:tidewake, :webhooks, :event, :rejected]` is emitted only after ingestion has definitively returned an error. A rolled-back transaction emits `rejected`, never `ingested`.

`[:tidewake, :webhooks, :delivery, :processed]` may be emitted only after `Webhooks.finalize_delivery/2` confirms that both the attempt and final delivery state were committed. Its `outcome` is derived from that persisted attempt. In particular, committed `http_error` and `transport_error` attempts are processed outcomes rather than `delivery:error` telemetry.

`[:tidewake, :webhooks, :delivery, :error]` is emitted when processing returns or normalizes an error without confirmed finalization. A processing invocation must not emit both `processed` and `error`. Telemetry emission is observational and occurs after the domain result is known; it does not participate in or change the transaction result.

### Metadata allowlists

The only metadata keys permitted by this contract are `:reason` and `:outcome`, and each event uses at most the key shown in the event table. No additional context is carried speculatively.

`outcome` has exactly this allowlist of string values:

- `"succeeded"`;
- `"http_error"`;
- `"transport_error"`.

The value matches the persisted attempt result. HTTP status codes, transport details, and delivery status are not additional metadata.

`reason` also uses strings and must be normalized explicitly. The ingestion rejection allowlist is:

- `"validation"` for an invalid event changeset;
- `"duplicate_external_id"` for the database-enforced idempotency conflict;
- `"persistence"` for another event, delivery, or job transaction failure;
- `"unknown"` as the bounded fallback.

The delivery processing error allowlist is:

- `"not_found"`;
- `"invalid_transition"`;
- `"encoding"`;
- `"adapter_not_configured"`;
- `"invalid_adapter_response"`;
- `"adapter_exception"`;
- `"persistence"`;
- `"unknown"` as the bounded fallback.

Implementations must map known domain errors to these values with explicit clauses. They must never use `inspect/1`, exception text, changeset errors, adapter-provided text, or arbitrary atoms or strings as `reason`. New reason or outcome values require an intentional contract change and cardinality review.

### Metric definitions

When instrumentation is implemented, `TidewakeWeb.Telemetry.metrics/0` should derive the initial metrics directly from this contract:

```elixir
counter("tidewake.webhooks.event.ingested.count")
sum("tidewake.webhooks.event.ingested.delivery_count")

counter("tidewake.webhooks.event.rejected.count", tags: [:reason])

counter("tidewake.webhooks.delivery.processed.count", tags: [:outcome])
summary("tidewake.webhooks.delivery.processed.duration_ms",
  tags: [:outcome],
  unit: :millisecond
)

counter("tidewake.webhooks.delivery.error.count", tags: [:reason])
summary("tidewake.webhooks.delivery.error.duration_ms",
  tags: [:reason],
  unit: :millisecond
)
```

The final metric-name segment selects the measurement, matching `Telemetry.Metrics` 1.2.0 conventions. Counters require the `count` measurement to be present even though a counter increments once per emitted event. The `delivery_count` sum reports the total fan-out created by accepted events. Duration summaries keep the same bounded `outcome` or `reason` dimensions as their associated counters.

This ADR does not select or configure a reporter, exporter, backend, dashboard, retention policy, buckets, percentiles, service-level objective, or alert threshold. Metric aggregation and publication remain reporter responsibilities.

### Cardinality and confidentiality boundary

Metric tags are exactly the allowlisted `reason` and `outcome` values above. Untagged metrics use no metadata dimensions. The following values are prohibited from webhook event metadata and metric tags:

- event, delivery, endpoint, attempt, or job IDs;
- `external_id`;
- event type or arbitrary status values;
- payloads or payload fragments;
- endpoint URLs;
- request or response headers;
- response bodies;
- secrets, credentials, or signatures;
- changesets or validation detail;
- exception structs, messages, stacktraces, or raw reasons.

IDs may remain available in appropriately protected operational records or logs under a separate logging decision, but they are never metric dimensions. Payloads, URLs, headers, and secrets remain prohibited even outside metric tags because Telemetry events can be consumed by multiple handlers and reporters.

## Consequences

### Positive

- Accepted and rejected ingestion can be counted without reporting success before the fan-out transaction commits.
- Persisted delivery outcomes are separated from failures that prevented finalization.
- A fixed set of tags bounds time-series cardinality and makes dashboards predictable.
- Sensitive and unbounded webhook data does not enter the Telemetry pipeline.
- The event and measurement names map directly to `Telemetry.Metrics` definitions.

### Negative

- Metrics cannot identify a specific event, endpoint, delivery, or consumer.
- The `unknown` fallback loses diagnostic detail until a deliberate reason is added.
- Summary behavior depends on the future reporter, and no telemetry is exported by this decision alone.
- Queue latency, queue depth, retries, and per-attempt diagnostics remain unmeasured.

## Alternatives considered

### Tag metrics with IDs, URLs, event types, or raw errors

Rejected because these values are sensitive, unbounded, or both. They would create high-cardinality series and couple metric storage to user-controlled data.

### Treat persisted HTTP and transport failures as `delivery:error`

Rejected because those outcomes have completed the intended local processing transaction: the attempt exists and the delivery is terminal. Recording them as `processed` with a bounded `outcome` preserves the distinction between a consumer or transport result and an internal processing failure.

### Emit success before transaction completion

Rejected because a later rollback would leave telemetry claiming work that does not exist. Success events follow confirmed persistence even if this adds a small delay before emission.

### Use logs without a telemetry contract

Rejected because free-form logs do not define stable measurements or bounded dimensions. Logs may complement these metrics later, subject to the same confidentiality constraints.

## Out of scope

- implementing `:telemetry.execute/3` calls or metric definitions;
- configuring a metrics reporter or exporter;
- queue latency, queue depth, retry, and recovery telemetry;
- tracing and correlation metadata;
- dashboards, alerts, SLOs, and retention;
- activating the Req adapter, external webhook delivery, HMAC, or retries.

## Follow-up

Instrument `Webhooks.ingest_event/1` and delivery processing in separate changes. Tests should attach handlers to the exact event names and verify one terminal event per invocation, post-commit timing, exact measurements, allowlisted metadata, zero-endpoint ingestion, duplicate rejection, persisted HTTP and transport outcomes, and processing errors. Add the metric definitions separately without selecting a reporter prematurely.

## References

- [`telemetry` 1.4.2 API](https://telemetry.hexdocs.pm/telemetry.html), for event names, measurements, metadata, handler execution, and `execute/3`.
- [`Telemetry.Metrics` 1.2.0](https://telemetry-metrics.hexdocs.pm/Telemetry.Metrics.html), for metric-name inference, counters, sums, summaries, tags, units, and reporter responsibilities.

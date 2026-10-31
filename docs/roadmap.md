# Roadmap

The roadmap is incremental. Each milestone should leave the application usable, tested, and observable without pretending later capabilities already exist.

## Milestone 0: foundation

Status: complete

- Phoenix application with LiveView and Ecto
- PostgreSQL local environment
- Oban schema and supervision
- Req dependency
- ExUnit, Telemetry, Credo, and Sobelow
- Docker Compose and continuous integration
- architecture, contribution, security, and decision documentation

No webhook delivery behavior is part of this milestone.

## Milestone 1: first vertical slice

Status: complete

Goal: prove the smallest durable workflow.

    event -> persistence -> Oban job -> recorded attempt

Implemented:

- schemas, context operations, and database persistence for events, deliveries, and attempts;
- database-enforced event idempotency, now scoped by `(project_id, external_id)`;
- `POST /api/events` for validation and atomic persistence of the event, its fan-out deliveries, and initial jobs;
- `GET /api/events/:id` for individual event retrieval;
- `GET /api/events/:id/deliveries` for the event's ordered delivery status without endpoint configuration, payloads, or attempts;
- API authentication, now using project-bound service-account Bearer credentials and explicit permissions on every route, with uniform `401 Unauthorized` and `WWW-Authenticate: Bearer`; this supersedes the initial shared static token;
- tests for event validation, persistence, duplicate ingestion, rollback boundaries, fan-out, and the implemented HTTP operations;
- atomic creation of a delivery and its Oban job through `schedule_delivery/2`;
- an Oban worker on the `default` queue with `max_attempts: 1`, delegating to the processor;
- a deterministic local adapter returning simulated HTTP 204 without external requests;
- attempt creation for successful responses, HTTP errors, and transport errors, atomically finalized with the delivery and its counter;
- safe extraction of bounded, allowlisted response metadata without response bodies or secret headers;
- the `pending → processing → succeeded/failed` transitions and terminal `pending → cancelled` transition, with atomic claim and finalization;
- delivery-time endpoint re-evaluation that cancels a pending delivery for an inactive endpoint without an adapter call or attempt;
- tests for transactional scheduling, rollback, and complete success and persisted-failure cycles through the worker;
- a Req-backed adapter with explicit timeouts, redirects and internal retries disabled;
- transactional fan-out to active endpoints in increasing ID order, creating one delivery and one initial job per destination;
- periodic recovery, every minute, of deliveries left in `processing` for at least five minutes;
- a deterministic oldest-first recovery batch limited to 100 delivery IDs, processed serially on a dedicated maintenance queue;
- row-locked revalidation and transactional replacement-job creation while returning stale work to `pending`;
- preservation of `attempt_count` and omission of an attempt when no outbound result was confirmed, with documented at-least-once resend risk;
- bounded Telemetry events for confirmed ingestion, rejection, delivery processing, cancellation, controlled processing errors, and recovery batches;
- declarative domain metrics for ingestion, rejection reasons, deliveries created, processing outcomes and duration, cancellation, controlled error reasons and duration, and recovered, skipped, and controlled-error recovery counts plus batch duration.

This milestone is complete. Its authentication and stale-delivery recovery acceptance gaps are resolved for the durable deterministic path. Safe external delivery and project ownership belong to Milestone 2; bounded automatic retries are implemented under Milestone 3, whose remaining reliability work is still open; the operational interface and metrics reporter remain in Milestone 4; and production deployment remains in Milestone 5.

## Milestone 2: endpoints and outbound delivery

Status: in progress

Completed:

- endpoint model and persistence, including schema validation and context operations.
- HTTP management API for endpoint creation, listing, retrieval, and updates, including deactivation with `active: false`.
- production-validated configuration for the webhook signing secret, with explicit local and test values;
- versioned HMAC-SHA256 headers generated from the event's public ID, attempt timestamp, exact body bytes, and configured secret;
- single-pass envelope serialization and preparation of `Tidewake-Id`, `Tidewake-Timestamp`, and `Tidewake-Signature` before the adapter is invoked, without persisting the secret, signature, or timestamp;
- application-level endpoint URL limits of 2,048 bytes;
- per-attempt URL validation, IPv4 and IPv6 resolution, IANA special-range classification, and rejection of any DNS answer set containing a disallowed address;
- IP-literal classification and connection pinning to one approved address while preserving the original hostname for Host, SNI, and TLS verification;
- redirects and Req retries disabled, with idle dynamic pools expiring after 60 seconds;
- streamed response consumption limited to 65,536 bytes, with response bodies discarded;
- bounded `destination`, `dns`, and `response_limit` persistence classifications without raw destination or transport details;
- the Req adapter enabled in production with the system resolver and public-only targets;
- deterministic development by default, with separate explicit development flags for outbound HTTP and local targets;
- a complete worker-path test using Req.Test and an independently recalculated HMAC without external network access.
- required project ownership for endpoints, events and deliveries, composite same-project database references and project-scoped event idempotency;
- project-scoped API reads/writes with default-deny route permissions and non-disclosing foreign/absent 404 responses.

Outbound adapter tests remain deterministic without external network access; HTTP boundary regressions also exercise supervised loopback listeners. Production configuration selects the guarded Req transport. Signature verification, timestamp validation, replay protection, used-signature storage, and secret rotation are responsibilities of the receiver and remain outside Tidewake.

Planned:

- add endpoint health checks and rate limiting.

## Milestone 3: retry and idempotency hardening

Status: in progress

Completed:

- classify transient and permanent HTTP and transport outcomes through explicit allowlists that fail closed;
- persist the monotonic lifetime `attempt_count` and the delivery's `retry_cycle` and `cycle_attempt_count`; record each attempt's lifetime `attempt_number`, `retry_cycle`, and `cycle_attempt_number`;
- enforce database ranges for the cycle counters and uniqueness of each attempt's delivery, cycle, and cycle ordinal;
- define a pure manual retry eligibility policy with a limit of three manual cycles after the initial cycle, each allowing six automatic attempts (theoretical maximum 24);
- limit automatic delivery to six attempts per cycle and apply exponential backoff with a 10-second base, a 300-second ceiling, and equal jitter;
- identify new jobs by `delivery_id`, `attempt_number`, `retry_cycle`, and `cycle_attempt_number`, while temporarily accepting legacy job formats;
- reject stale, duplicate, future-numbered, or early work under the delivery claim lock before sending HTTP, validating the complete cycle identity for new jobs;
- classify retry outcomes and calculate backoff from the attempt ordinal within the current cycle, while keeping lifetime attempt numbering monotonic;
- persist the failed attempt, pending delivery state, and exactly one successor job atomically;
- generate fresh signing material for each actual attempt, allowing Ironhold to acknowledge an identical freshly signed retry with its generic `202 Accepted` response;
- expose bounded Telemetry for committed retry schedules and confirmed retry exhaustion without identifiers or signing material;
- cover a later retry cycle through persisted attempts, guarded claims, worker jobs, backoff, and terminal exhaustion in an integrated pipeline test;
- add append-only `manual_retry_requests` storage for internal retry audit decisions;
- map the audit schema and enforce named database constraints for bounded identity, observations, and accepted/rejected consistency;
- enforce actor-scoped idempotency through the unique key digest, without retaining the raw key;
- derive a deterministic canonical request fingerprint for the versioned delivery retry operation;
- derive the internal `ManualRetryActor` from authenticated Scope with service-account type, opaque account subject and server-selected source;
- implement the internal transactional `request_manual_retry/3` command with delivery-then-endpoint row locks and idempotent replay resolution;
- persist accepted and rejected audit records with the observed delivery state and bounded decision reasons;
- commit the accepted audit, `failed → pending` transition, new retry cycle, and immediate cycle-aware job atomically, resetting only the cycle attempt count and preserving lifetime history;
- cover concurrent requests with PostgreSQL row locks and actor-scoped unique constraints, without relying on which task wins;
- cover audit insertion, delivery update, job insertion, legacy-job and cycle-aware conflicts, rejected-request persistence, and idempotency rollback boundaries;
- emit bounded post-transaction manual retry Telemetry with count and duration metrics, fixed outcome/reason tags, and confidentiality coverage.
- project-bound service accounts with expiring/revocable HMAC digest-only credentials and operational tasks for provisioning, rotation, revocation, account disablement and project suspension;
- authenticated admin manual retry POST and audit GET, reauthorizing replay and every page within project scope;
- project-bound v2 retry fingerprints without rewriting historical v1 digest/fingerprint bytes;
- PostgreSQL per-account retry admission (five tokens, refill one per 12 seconds), shared across credential rotation, including admitted replay/errors and excluding GET;
- bounded id-descending audit pagination and explicit historical field allowlists, with integrated HTTP concurrency, rollback, rate-limit and privacy regressions.

Planned:

- build the operational LiveView interface in Milestone 4;
- support `Retry-After` received from destinations without weakening the bounded retry policy;
- define retention and payload-size policy, with retention jobs in Milestone 5;
- complete production deployment and rollback work in Milestone 5.

The core, authenticated admin retry POST and audit GET are implemented; see the [current retry contract](api/manual-retries.md) and [authentication setup](../README.md#local-setup). Six automatic attempts apply per cycle, while lifetime history remains monotonic across at most three manual cycles. Milestone 3 remains in progress while receiver Retry-After, retention/deletion, UI and deployment work remain pending. There is no human identity or HTTP credential-management API, and this sequence has not changed Ironhold.

## Milestone 4: operational interface

- LiveView event and delivery history;
- filters for state, endpoint, and time range;
- attempt detail without secret or payload leakage;
- a reporter and operational views for the available domain metrics, plus queue, latency, and retry metrics;
- structured logs and basic administrative audit history;
- external alerts and operational notification routing.

## Milestone 5: production readiness

- threat model and security review;
- load and failure testing;
- database backup and recovery guidance;
- automatic API token and secret rotation;
- retention jobs;
- deployment and rollback documentation;
- service-level indicators and alert thresholds.

Milestone numbers group capabilities. The next operational and product work follows the risk order below, rather than milestone-number order.

Project-bound service accounts, overlapping rotatable credentials and route/object authorization are implemented. `TIDEWAKE_API_TOKEN` is removed and the old static token is rejected; production requires `TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER`. Human users, sessions, OAuth, JWT and automated credential/secret rotation remain future work. A green merge does not establish production rollout.

## Authenticated manual retry: merged implementation complete

The identity, ownership and authenticated manual-retry HTTP implementation phase is complete in main. These are merged code, regression tests and documentation, with evidence for each capability:

| Completed capability | Implementation and verification |
| --- | --- |
| Project, ServiceAccount and HMAC digest-only credentials | [Projects context](../lib/tidewake/projects.ex) and [credential regressions](../test/tidewake/projects/service_account_credentials_test.exs); no recoverable raw token is stored. |
| Operational provisioning and lifecycle | [Mix operations](../lib/mix/tasks/tidewake.provisioning.ex) and [task tests](../test/mix/tasks/provisioning_test.exs) cover project creation, provisioning, additional issuance for rotation, revocation, account disablement and project suspension. |
| Authenticated Scope and admin/producer/viewer permissions | [Scope](../lib/tidewake/projects/scope.ex), [default-deny policy](../lib/tidewake/projects/authorization.ex) and [route permission tests](../test/tidewake_web/controllers/api_authentication_test.exs). |
| Immutable Endpoint/Event/Delivery ownership through supported operations | [Ownership migration](../priv/repo/migrations/20261030074028_scope_webhook_resources_by_project.exs) and [ownership tests](../test/tidewake/webhooks/project_ownership_test.exs) verify required references, composite cross-project protection and project-local event identity. |
| Complete static-token cutover | [Router](../lib/tidewake_web/router.ex) and [API isolation regressions](../test/tidewake_web/controllers/api_isolation_regression_test.exs) verify project-bound authentication on every API route, no shared-token fallback and non-disclosing object access. |
| Project-scoped fingerprint v2 with historical v1 preservation | [Version migration](../priv/repo/migrations/20261030102400_version_manual_retry_fingerprints.exs) and [migration tests](../test/tidewake/webhooks/manual_retry_fingerprint_migration_test.exs) preserve v1 digest/fingerprint bytes; new API requests cannot reinterpret them as v2 replay. |
| Authorized retry, including replay | [Transactional command](../lib/tidewake/webhooks.ex) and [authorization tests](../test/tidewake/webhooks/manual_retry_authorization_test.exs) verify current admin/project authority before decisions and replays, atomic audit/state/job persistence and immutable history. |
| PostgreSQL admission per service account | [Limiter](../lib/tidewake/projects/manual_retry_rate_limiter.ex) and [limiter tests](../test/tidewake/projects/manual_retry_rate_limiter_test.exs) verify five tokens, one refill per complete 12 seconds, shared capacity across credentials and serialized concurrent consumption. |
| Admin retry POST and paginated audit GET | [Controller](../lib/tidewake_web/controllers/manual_retry_request_controller.ex), [HTTP tests](../test/tidewake_web/controllers/manual_retry_request_controller_test.exs) and [audit tests](../test/tidewake/webhooks/manual_retry_audit_test.exs) verify explicit field allowlists, no-store, stable historical reads and no GET admission consumption. |
| Authentication, object/function authorization, concurrency, rollback and non-disclosure regressions | [Integrated HTTP security suite](../test/tidewake_web/controllers/manual_retry_api_security_test.exs), [concurrency tests](../test/tidewake/webhooks/manual_retry_concurrency_test.exs), [rollback tests](../test/tidewake/webhooks/manual_retry_rollback_test.exs) and [real transport test](../test/tidewake_web/manual_retry_transport_test.exs). |
| Corresponding operational documentation | [Authentication and rotation](api/authentication.md), [manual retry contract](api/manual-retries.md), [architecture](architecture.md) and current implementation notes in [ADRs 0015–0020](adr/0020-project-scoped-manual-retry-api.md). |

Completion of this implementation phase does not establish production deployment, execution of production migrations/cutover, validated restores, active monitoring or customer use. Those require separate operational evidence. Human identity, administrative UI and HTTP credential management are not implemented. Ironhold was not changed by this sequence.

## Next blocks in risk order

1. **Operationally pending — rollout hardening:** establish a migration/cutover runbook, backup/restore validation, operational metrics and alerts without sensitive cardinality. Merged code and green CI do not prove this rollout work complete.
2. **Operationally pending — retention and disposal:** define and verify policy for manual_retry_requests and obsolete/orphaned rate-limit rows, preserving referential integrity and historical attribution before introducing cleanup.
3. **Operationally pending — receiver backoff:** support Retry-After received from webhook targets safely inside the cycle-aware scheduler, retaining attempt/cycle bounds and claim guards. The API's own 429 admission response is already implemented and does not supply this receiver behavior.
4. **Future product decision — human identity:** make an architectural decision for human authentication and authorization before designing access to a future administrative UI.
5. **Future product — operational UI:** proceed only after that identity boundary, with explicit confirmation for sensitive actions and durable auditability.
6. **Conditional future product — credential-management API:** evaluate HTTP management only if a real need is established; keep the existing operational Mix workflow as the baseline.

This sequence makes no date, deployment or customer-availability commitment.

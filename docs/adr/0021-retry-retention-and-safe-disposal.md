# ADR 0021: Retry retention and safe disposal

- Status: proposed — pending human review
- Date: 2026-11-09
- Issue: [#265](https://github.com/Carlos-ccaetano/Tidewake/issues/265)

## Context and evidence

Manual retry decisions are both audit evidence and the idempotency ledger. Rejected
decisions consume keys too; the three-cycle limit does not bound their volume.
ADRs [0015](0015-manual-delivery-retry.md),
[0016](0016-bounded-manual-retry-cycles.md),
[0017](0017-manual-retry-audit-persistence.md) and
[0020](0020-project-scoped-manual-retry-api.md) define no key expiry. Deleting a
decision could make the same key produce a new decision, even for another delivery.
Digests and opaque subjects remain sensitive correlation data, not anonymization.

This proposal is checked against main at `9349cfca0f82a1460458a2cc4c3c697ee31722ef`.
The following are implemented relationships, distinct from historical prospective
wording in earlier ADRs:

| Data class | Purpose, contents and retention risk | Actual relationships |
| --- | --- | --- |
| `manual_retry_requests` | Attribution, accepted/rejected decision, state snapshot, timestamps, key digest, fingerprint and version. Loss destroys evidence and replay/conflict detection; indefinite growth increases exposure and storage. | Required `delivery_id` FK, `ON DELETE RESTRICT`. No project, account, attempt or Oban FK. Unique `(actor_type, actor_subject, idempotency_key_digest)`. No `updated_at`. |
| `deliveries`, `delivery_attempts` | Current work and immutable lifetime/cycle outcome history. Removing attempts invalidates the meaning of persisted counters and audit snapshots. Response metadata may contain correlation data. | Attempts restrict deletion of their delivery. Deliveries reference same-project events/endpoints through `(event_id, project_id)` and `(endpoint_id, project_id)` restrictive FKs, plus a restrictive project FK. |
| `events`, `endpoints` | Immutable event identity/payload and destination/signing configuration. Payloads, URLs and secrets require separate minimization decisions. | Both have restrictive project FKs; referenced parents cannot be removed while deliveries exist. Events are unique on `(project_id, external_id)`; deleting one also releases that ingestion identity. |
| Projects, service accounts, credentials | Ownership, attribution and authentication. Physical deletion loses identity context; expired/revoked credentials do not imply expired audit. | Accounts restrict project deletion; credentials restrict account deletion. API actor subject is the account public UUID, a logical association rather than an audit FK. Historical subjects need not resolve to a current account. |
| `manual_retry_rate_limits` | Admission state, not a request history: tokens, refill time and timestamps. Premature removal grants a newly initialized full bucket. | `service_account_id` is both PK and FK with **ON DELETE CASCADE**, unlike the restrictive reference proposed in ADR 0020. No delivery, audit or credential FK. Valid FKs preclude ordinary orphan rows. |
| `oban_jobs` | Durable execution state, arguments and potentially error details; not authoritative domain audit. Retaining jobs increases correlation exposure; premature pruning loses work or recovery evidence. | Created by `Oban.Migration.up()`; delivery IDs are JSON arguments, not application FKs. Delivery jobs carry attempt/cycle identity, optionally recovery count; legacy argument forms are still recognized. |

Sources: [audit migration](../../priv/repo/migrations/20261025052708_create_manual_retry_requests.exs),
[fingerprint migration](../../priv/repo/migrations/20261030102400_version_manual_retry_fingerprints.exs),
[ownership migration](../../priv/repo/migrations/20261030074028_scope_webhook_resources_by_project.exs),
[identity migration](../../priv/repo/migrations/20261027071753_create_project_identity_storage.exs),
[bucket migration](../../priv/repo/migrations/20261030220749_create_manual_retry_rate_limits.exs),
[attempt migration](../../priv/repo/migrations/20260910073959_create_delivery_attempts.exs),
[cycle constraints](../../priv/repo/migrations/20261021110616_enforce_attempt_retry_cycle_integrity.exs),
[command/audit reads](../../lib/tidewake/webhooks.ex),
[Scope](../../lib/tidewake/projects/scope.ex),
[limiter](../../lib/tidewake/projects/manual_retry_rate_limiter.ex),
[worker](../../lib/tidewake/workers/deliver_webhook_worker.ex) and
[Oban configuration](../../config/config.exs). No application retention worker or
explicit terminal-job retention duration is configured there; this is not evidence
of production plugin configuration or Oban defaults.

## Proposed decision and invariants

Separate replay/audit evidence from disposable admission state. Keep the existing
contracts until this policy and a later implementation are reviewed; this ADR
authorizes no deletion and changes no HTTP behavior.

1. **Retain every audit decision for now**, accepted and rejected, including v1
   fingerprints and unresolved legacy actors. Age, terminal delivery status,
   account disablement, project suspension or credential expiry alone never make
   an audit row disposable. A failed delivery can be reopened, and actor key
   uniqueness spans deliveries. Append-only is an application contract, not a
   database delete-prevention mechanism.
2. Do not expire a key by deleting its audit row or rewriting its digest, version,
   actor or snapshot. Finite audit retention needs an explicitly approved replay
   horizon/identity-retirement contract, migration/reader compatibility and a
   decision about evidence availability after expiry. An archive alone cannot
   satisfy current online replay lookups. No tombstone service is proposed now.
3. Preserve delivery lifetime counters, attempt numbers, cycle bounds and all
   history referenced by retained decisions. Do not delete events, endpoints,
   attempts, deliveries, accounts, credentials or projects under this policy.
   Never disable constraints, cascade audit deletion, detach history or infer
   authorization from an actor subject. Protected reads continue to resolve the
   parent delivery in trusted project scope on every page, per
   [ADR 0018](0018-project-ownership.md) and
   [ADR 0019](0019-service-account-authentication.md).
4. Keep buckets for enabled accounts, including idle accounts and accounts whose
   credentials expired. Capacity is five, with one token per complete 12 seconds;
   `updated_at` is not an expiry. Deleting even an idle bucket changes refill
   phase; deleting a depleted one can bypass admission. Rotation, rollback and
   domain rejection must not refund tokens. Do not delete accounts to trigger
   the bucket cascade.
5. A future bucket cleanup may consider permanently retired, disabled accounts
   only after all admission writers/in-flight callers on every node are drained.
   The current limiter locks only the bucket, while domain Scope revalidation
   happens later. Disabling an account or locking its row does not by itself
   prevent an already authenticated caller from consuming/recreating a bucket.
   Without proven quiescence, retain it. Online cleanup would require a separately
   reviewed writer/cleanup locking protocol; no such protocol is implemented here.
6. Exclude incomplete Oban work (including scheduled, available, executing,
   retryable or suspended work) from retention. Do not treat an old timestamp as
   proof that a job is terminal. Any later terminal-job policy must inventory the
   deployed Oban version/plugins and recovery paths, including legacy arguments,
   and use supported Oban facilities separately from domain-history retention.
   Job pruning never establishes that an audit row is disposable.

## Durations and approval gates

No legal retention obligation or numeric product retention period is established.
The 12-second refill and retry cycle limits are runtime rules, not retention terms.

| Class | Proposed default | Evidence and approval required before a finite duration |
| --- | --- | --- |
| Retry audit and its replay ledger | No automatic expiry; growth is an acknowledged interim cost. | Product owns support/dispute and client retry horizons, including long offline callers. Security owns investigation needs and identity retirement; privacy/compliance reviewers determine applicable obligations, if any. Approve how old keys/conflicts and paginated evidence behave before selecting a duration. |
| Retired-account buckets | No cleanup until safe writer exclusion is proven. | Operations/security approve permanent retirement, drain procedure, bounded batch size and timeouts. Choose an operational grace period from measured in-flight request/drain bounds, not token refill alone. |
| Delivery/event/attempt/identity history and Oban | No new duration or pruning change in this ADR. | Separate lifecycle decisions must cover shared parents, replay/ingestion identity, work/recovery, support needs and deployed job behavior. |
| Backups, replicas, WAL, exports and incident holds | Logical row deletion makes no promise of physical erasure. | Operations/security must approve recovery objectives, access, copy lifetimes and any protected hold process before disposal activation. Restoration must not silently resurrect previously disposed data or release consumed keys. |

Use UTC and a fixed run cutoff with strict `< cutoff` eligibility, never moving
the cutoff during a run. Future audit expiry, if approved, must consider both
`requested_at` and `inserted_at` conservatively and recheck lifecycle/hold conditions;
old request time alone is unsafe. If approval, lifecycle evidence or hold status is
missing, skip disposal. No hold registry or automated exception system is added.

## Future execution and operational safety

Start with a read-only dry run on synthetic data, then a separately approved
implementation. A bucket-only cleanup needs no generic retention framework,
archive pipeline or new service. Operators must verify the target database,
review the plan and establish the approved quiescence boundary before any run.

Process bounded batches ordered by stable primary key, with a fixed cutoff and
row/time budget. In a short transaction, lock and revalidate candidate account
retirement, then bucket state and all eligibility conditions; delete only the
locked eligible bucket rows. Use a consistent lock order across every participant,
bounded lock/statement timeouts and `FOR UPDATE SKIP LOCKED` for competing cleaners.
Row locks coordinate nodes; a queue concurrency setting or process-local mutex
does not. This coordinates cleaners only: it does **not** replace writer exclusion
for the current initializer/refill transaction. Keep transactions out of network
I/O, and avoid table-wide locks and full-table deletion.

Re-evaluate skipped rows on later runs; a saved cursor is progress, not proof of
eligibility. On timeout, deadlock, constraint failure or changed state, roll back
the batch and report a bounded failure. A crash before commit leaves the batch
intact; committed prior batches remain disposed. Re-running must be safe for
already absent rows and must not synthesize replacement buckets. Stop scheduling
new batches to interrupt a run; preserve evidence of committed counts and policy
version. A dry-run result is not a lock or authority for a later delete.

Emit aggregate candidate/skipped/deleted counts and batch durations, with a fixed
class, outcome, reason and policy-version vocabulary. Emit deletion success only
after commit. Privileged run records may record approver, policy version, cutoff
and aggregate outcome under controlled access. Follow
[telemetry privacy](../telemetry-privacy.md): no project/account/delivery/audit/job
IDs, actor subjects, digests, fingerprints, keys, URLs, payloads, SQL parameters,
credentials or raw exceptions in metrics or ordinary logs. Review query telemetry,
Oban arguments/error instrumentation and database logging before activation.

Stopping a job or reverting code prevents future deletion; it cannot undo committed
deletion. A transaction rollback covers only its uncommitted batch. Recovery from
a verified backup requires an isolated restore, integrity/replay reconciliation and
explicit authorization before promotion, with no outbound workers enabled during
verification. Backups are not an automatic per-row undo mechanism.

## Alternatives and trade-offs

| Alternative | Assessment |
| --- | --- |
| Keep all classes forever | Simplest integrity baseline, but unbounded growth and exposure; acceptable only as the current fail-closed interim state, subject to policy review. |
| Age-based audit TTL or cascade from a terminal delivery/account | Reject: releases actor keys, loses accepted/rejected evidence and assumes terminal means permanently inactive. |
| Archive or redact audits before removal | Can reduce online exposure, but adds access/restore complexity; deleting or rewriting the online ledger breaks current replay unless a replacement contract is approved. Deferred. |
| Remove idle enabled-account buckets | Saves little per account and can reset admission/refill semantics; retain them. |
| Separate conservative bucket cleanup from later audit lifecycle work | Preferred: distinct eligibility and responsibilities, no speculative infrastructure. Requires proven quiescence for the current writers. |

## Future validation plan

Use isolated synthetic databases only; implement no cleanup tests or production
deletion in this documentation change. Extend the existing
[limiter tests](../../test/tidewake/projects/manual_retry_rate_limiter_test.exs),
[retry concurrency tests](../../test/tidewake/webhooks/manual_retry_concurrency_test.exs),
[rollback tests](../../test/tidewake/webhooks/manual_retry_rollback_test.exs) and
[audit tests](../../test/tidewake/webhooks/manual_retry_audit_test.exs) when behavior
is separately approved:

- Positive/boundary: eligible retired bucket after confirmed drain; cutoff before,
  equal to and after expiry; absent row on rerun; bounded batches and skipped-row
  revisit. Dry run writes nothing.
- Negative: enabled/merely idle accounts, missing approvals/holds, depleted buckets,
  clock regression, credential rotation/expiry and project suspension cannot grant
  disposal. No orphan repair, parent cascade or deletion of incomplete Oban work.
- Integrity: retained accepted/rejected and v1/v2 audit bytes, replay/conflict
  behavior, admin-only project isolation, pagination, lifetime counts and both
  attempt uniqueness constraints remain unchanged. Direct FK violations fail.
- Concurrency: two cleaners on distinct database connections/nodes, refill and
  initialization races, an already authenticated caller crossing disablement,
  manual retry/replay, delivery claim and stale recovery. Prove writer exclusion;
  no extra admission, lost job, key reuse or deadlock-dependent correctness.
- Failure/recovery: inject failure before commit, between batches and during lock
  acquisition; verify rollback, committed-batch accounting, interruption and safe
  rerun. Rehearse isolated backup restore without HTTP/queues, verify relationships
  and consumed-key semantics before any promotion. Assert no sensitive telemetry.

## Scope and next decision

This is a proposed policy, not an approved disposal schedule or implementation.
Human review must resolve duration owners, replay/evidence compatibility, retirement
and writer exclusion, backup/hold handling and operational limits before any cleanup
PR. No worker, migration, schema, endpoint, HTTP contract, dependency, data or
Ironhold change is authorized here. The existing roadmap already tracks retention;
no additional roadmap entry is needed.

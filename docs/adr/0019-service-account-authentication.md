# ADR 0019: Service account authentication

- Status: accepted
- Date: 2026-10-26

## Current implementation status

Project-bound service accounts, opaque HMAC-SHA-256 digest-only credentials, expiry/revocation, account disablement and project suspension are implemented in [Projects](../../lib/tidewake/projects.ex). The [router](../../lib/tidewake_web/router.ex) applies authentication and explicit permissions on every API route; this cutover supersedes ADR 0010's shared token. `TIDEWAKE_API_TOKEN` is removed; production requires the independent `TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER` of at least 32 bytes. Scope and actor attribution are derived on the server, and sensitive retry/audit transactions revalidate account/project authority.

[Operational Mix tasks](../../lib/mix/tasks/tidewake.provisioning.ex) support project creation, account provisioning, overlapping credential issuance, revocation, disablement and suspension. Tokens print once after commit and cannot be recovered. Rotation preserves account identity, immutable role, audit subject and retry budget. See [authentication operations and role matrix](../api/authentication.md) and [task regressions](../../test/mix/tasks/provisioning_test.exs). Human identity/UI, HTTP credential management, automated rotation, audit retention/deletion, receiver `Retry-After` handling and production deployment remain pending; Ironhold is unchanged. The context and decision below retain their historical wording.

## Context

The shared Bearer token from ADR 0010 authenticates possession of one secret. It cannot identify an actor, bind access to a project, distinguish administrative actions, or revoke one consumer independently. ADR 0018 defines future project ownership; the implemented manual retry core in ADRs 0015–0017 still has no authenticated operational boundary.

Service identity must remain stable when credentials rotate. Authorization also needs both a project relationship and an explicit role: a valid credential alone must not authorize endpoint management, manual retry, or protected audit reads.

## Decision

Adopt project-bound service accounts with opaque, expiring, revocable Bearer credentials and explicit default-deny permissions. `Tidewake.Projects.Scope` is constructed by trusted server code after authentication and contains only the identity and authorization needed for the request.

This decision specifies future behavior. It creates no persistence, credentials, plug, context, route, or UI and does not activate the new pipeline. Human identity, OAuth, and JWT remain outside this phase.

## Data model

### Service account

Use the existing generated integer primary-key convention and a required restrictive reference to exactly one `Project`. Preserve account identity rather than deleting or reassigning it.

| Field | Contract |
| --- | --- |
| `project_id` | Required trusted ownership; immutable through supported interfaces. |
| `public_id` | Required unique UUID, generated once and immutable; the stable audit subject. |
| `name` | Required nonblank UTF-8 display name, bounded to 255 bytes; grants no authority. |
| `role` | Required bounded string, exactly `admin`, `producer`, or `viewer`; immutable through supported interfaces. |
| `disabled_at` | Optional UTC timestamp; a non-null value prevents authentication for every associated credential. |
| timestamps | Server-generated UTC timestamps with microsecond precision. |

Changing privilege requires a new service account with the intended role, deliberate consumer migration, and disabling the old account. The context offers no delete operation. Project and account references use restrictive deletes so identity and audit attribution are retained. Role, ownership, and public identity cannot be supplied as edits to an existing account.

For API manual retry, derive actor type `service_account`, subject `ServiceAccount.public_id`, and source `api` from authenticated server context. Never use an email address, display name, token, or credential UUID as the actor subject. Rotation keeps the same account subject; replacing an account creates a new subject and does not relabel historical audit records.

### Credential

Each credential belongs to one service account through a required restrictive reference. Multiple credentials may coexist for deliberate rotation.

| Field | Contract |
| --- | --- |
| `public_id` | Required unique stable UUID used only to locate the credential. |
| digest | Required 32-byte binary HMAC-SHA-256 digest, redacted from `Inspect`. |
| `expires_at` | Required UTC expiry, later than `inserted_at` and at most 365 days after it. |
| `revoked_at` | Optional UTC timestamp; a non-null value prevents authentication. |
| timestamps | Server-generated UTC timestamps with microsecond precision. |

Database constraints and changeset validation must enforce references, uniqueness, required fields, role vocabulary, digest length, and expiry bounds. Trusted code validates names and immutable attributes. Credential identity, account association, and digest are not replaced during rotation; issuance creates a new credential row.

## Token format

The exact token format is:

```text
twk_sa.<credential-uuid>.<base64url-secret>
```

Generate the secret with `:crypto.strong_rand_bytes(32)` and encode it using Base64 URL-safe encoding without padding. Its encoded segment is 43 ASCII characters. The credential UUID uses canonical lowercase hyphenated form; the complete token is 87 ASCII bytes. Validate the exact prefix, segment count, UUID representation, alphabet, and secret length. Decode the secret to exactly 32 bytes and require its unpadded re-encoding to match, excluding alternate encodings. Do not trim, case-fold, or normalize an input into a valid token.

Compute `HMAC-SHA-256(pepper, canonical_complete_token)` over the complete canonical token bytes, including `twk_sa`, UUID, and separators. Persist only the resulting 32-byte binary digest. The raw token and secret segment have no database field. The configured pepper is a dedicated server-side secret of at least 32 bytes, generated independently of credentials, never stored alongside them. Missing or invalid pepper configuration must fail closed, with production startup rejecting it without printing its value.

The credential UUID is a lookup identifier, not proof of possession. Compare the recomputed and stored fixed-size digests in constant time; reject malformed stored digests rather than comparing invalid lengths. The token carries no trusted role or project claims.

## Credential lifecycle

- **Issue:** trusted operational code validates the account, project, and expiry, generates a fresh credential UUID and secret, persists the digest, then returns the raw token exactly once after success. Failed issuance returns no usable credential. One-time results must redact secret-bearing fields from `Inspect`; there is no recovery or subsequent read of the raw token.
- **Expire:** use server UTC time. Require `inserted_at < expires_at <= inserted_at + 365 days`, where a day is 86,400 seconds. Authentication requires `now < expires_at`; equality is expired. Expiry cannot be extended to turn the same token into an indefinitely valid credential.
- **Rotate:** issue a new independent credential for the same account. An intentional overlap permits a consumer to switch before the old credential is revoked; rotation does not change the account's project, role, or audit subject.
- **Revoke:** set `revoked_at` using trusted server time. Revocation is irreversible through supported interfaces and repeated revocation preserves the first timestamp. Retain the row rather than deleting it.
- **Disable:** setting the account's `disabled_at` invalidates authentication through all its credentials, including otherwise valid overlapping credentials. A suspended project also prevents authentication.
- **Change pepper:** existing digests cannot be recomputed without the original tokens. A pepper change requires an explicit reissuance and consumer-transition plan; do not silently try a fallback key or claim transparent rotation.

Credential issuance, rotation, revocation, and account administration are not HTTP capabilities granted by the role matrix below. Their operational implementation is separate.

## Roles and permissions

Every permission applies only inside the authenticated project and remains subject to object-level access checks from ADR 0018.

| Action | `admin` | `producer` | `viewer` |
| --- | --- | --- | --- |
| Ordinary resource reads: endpoints, events, event delivery status | Allow | Allow | Allow |
| Endpoint management: create, update, deactivate | Allow | Deny | Deny |
| Event ingestion | Allow | Allow | Deny |
| Manual retry request, including replay | Allow | Deny | Deny |
| Manual retry audit retrieval | Allow | Deny | Deny |
| Unknown or unlisted action | Deny | Deny | Deny |

An unknown role is denied, not mapped to a default role. `admin` is not a wildcard across projects or future actions. Audit retrieval is an administrative action even though it reads data. A role change cannot be simulated by rotating a credential or editing request fields. The existing internal retry command does not itself establish this authorization boundary.

## Authentication flow

1. The API plug requires exactly one `Authorization` header containing `Bearer ` followed by one canonical token. Reject missing, empty, duplicated, comma-combined, malformed, or extra-whitespace values. Do not accept credentials from a query parameter, body, cookie, or another header.
2. Validate token syntax before lookup. Locate the credential by its public UUID with Ecto query logging and query Telemetry disabled (`log: false`, `telemetry_event: nil`). Apply the same protection to associated authentication lookups so credential correlation material does not escape through query events. Never put the raw token, pepper, or digest into SQL lookup parameters.
3. Recompute and compare the digest, then require an unrevoked, unexpired credential, an enabled account with a known role, and an active project. Read persisted authentication state on every request; a previous successful request is no authorization cache.
4. Construct `Tidewake.Projects.Scope` only from those trusted records. It contains the internal project and account identifiers, the stable account UUID needed for attribution, and the role. It contains no token, secret, digest, pepper, header, display name, or loaded credential struct. Caller maps or a manually constructed struct are not proof of provenance.
5. Authorize the requested action. A purely functional denial returns `403 Forbidden` before looking up the requested resource. For an allowed action, resolve the object inside the trusted project; missing and foreign objects share the same `404 Not Found` response. Repeat authorization for retry replays and audit reads. Sensitive commands must revalidate persisted authority at their transaction boundary rather than treat a request-local Scope as permanent permission.

Missing or malformed credentials, unknown credential, digest mismatch, expiry, revocation, disabled account, suspended project, and invalid authentication state all halt with the same `401 Unauthorized`, public error envelope, and `WWW-Authenticate: Bearer` challenge. Do not expose the failed condition in the response or diagnostic metadata. Authentication precedes action authorization and resource access.

[RFC 6750](https://www.rfc-editor.org/rfc/rfc6750) supplies Bearer header and challenge semantics and the 401/403 distinction by analogy for Tidewake's own opaque tokens. Tidewake does not become an OAuth authorization server. The RFC distinguishes `invalid_request`/400, `invalid_token`/401, and `insufficient_scope`/403, and recommends omitting error details when credentials are absent. Tidewake deliberately collapses credential failures to one 401 with a bare Bearer challenge and uses roles rather than OAuth scopes; its strict parser and uniform error policy do not claim full OAuth protocol conformance.

## Migration

ADR 0010 remains the historical shared-token decision. **When the new API pipeline is activated, this ADR supersedes ADR 0010 for API authentication.** Until that activation, the existing pipeline remains the implemented behavior. This documentation change edits neither pipeline nor ADR 0010.

Activate only after credential/account storage, issuance and lifecycle operations, server Scope construction, the plug, project ownership and database integrity, role authorization, and isolation tests are implemented and reviewed. Provision deliberate project-bound identities and distribute new credentials securely before the controlled switch. The static token cannot be converted into a service account, credential, or actor subject.

At cutover, require the new boundary on every API route and remove shared-token configuration/fallbacks and implicit legacy scope as required by ADR 0018. Never accept both token types in the same pipeline after cutover, and never retry authentication with the old token after a new-credential failure. Preserve historical retry evidence and defer fingerprint-version changes to their separate compatibility decision.

Activation evidence must cover every credential failure, role/action combination, cross-project lookup, revocation, rotation overlap, suspended project, and absence of secret disclosure. A failed cutover must fail closed rather than reintroduce shared-token access to project-owned resources. No production rollout occurs in this ADR.

## Security

Raw tokens, secret segments, pepper, and complete Authorization headers must never enter database records, logs, Telemetry, errors, jobs, or `Inspect`. Keep the protected digest out of ordinary logs, responses, query events, and jobs, and redact it from structs and changesets. Validation errors must not echo submitted credentials. No debug inspection of authentication inputs or loaded credential records is permitted.

Keep actor subjects and credential/project correlation identifiers out of ordinary telemetry and error logs. Use only bounded failure/outcome classifications that do not reveal the uniform authentication failure's cause. Trusted audit records retain only the authorized identity fields from the audit contract, never credentials.

TLS is mandatory in production for credential delivery and API requests, including protection of any proxy-to-application hop carrying the header. Bearer possession is sufficient to act within the account's permissions until expiry, revocation, or disablement. [OWASP API2:2023](https://owasp.org/API-Security/editions/2023/en/0xa2-broken-authentication/) informs the authentication boundary; [OWASP API5:2023](https://owasp.org/API-Security/editions/2023/en/0xa5-broken-function-level-authorization/) and the [Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html) inform explicit permission checks and default denial. Project-scoped object checks remain necessary in addition to role checks.

## Consequences

- Stable account UUIDs make actions attributable across credential rotation without rewriting audit history.
- Revocation, bounded expiry, account disablement, and project suspension provide separate denial controls; each request needs a protected database-backed authentication lookup.
- A pepper separates credential verification from a database-only compromise, but its loss or change requires operational recovery and reissuance planning.
- Immutable roles require deliberate account replacement for privilege changes. The admin-only retry/audit boundary remains explicit.
- Uniform authentication failures reduce disclosure to clients and also limit diagnostics; secret-bearing debug output is not an acceptable workaround.

## Alternatives

| Alternative | Reason for rejection |
| --- | --- |
| Reuse the shared static token as an actor | It cannot provide individual attribution, project ownership, or independent revocation. |
| Use a token, email, or display name as audit subject | Credential rotation or mutable descriptive data would change attribution or disclose secrets/personal data. |
| Persist raw credentials or use only an unpeppered digest | Retains usable secrets or loses the chosen separation between the database and verification key. |
| Embed mutable permissions in JWTs | Adds signing and invalidation complexity beyond this opaque, database-checked identity boundary. |
| Let all authenticated callers read retry audit | Ordinary resource reading does not grant administrative audit access. |
| Accept static and service-account tokens after cutover | A legacy path would bypass attributable project/role checks. |

## Out of scope

- persistence, schemas, issuance commands, plugs, Scope, authorization modules, and their tests;
- credential-management HTTP endpoints or self-service privilege changes;
- human users, login sessions, OAuth authorization flows, JWT, or external identity providers;
- the manual retry route, audit retrieval implementation, UI, rate limiting, or retention;
- migrations, fingerprint changes, production rollout, or Ironhold changes.

## References

- [Architecture](../architecture.md)
- [ADR 0010: API token authentication](0010-api-token-authentication.md)
- [ADR 0015: Manual delivery retry policy](0015-manual-delivery-retry.md)
- [ADR 0017: Manual retry audit persistence](0017-manual-retry-audit-persistence.md)
- [ADR 0018: Project ownership](0018-project-ownership.md)
- [RFC 6750: Bearer token usage](https://www.rfc-editor.org/rfc/rfc6750)
- [OWASP API2:2023 Broken Authentication](https://owasp.org/API-Security/editions/2023/en/0xa2-broken-authentication/)
- [OWASP API5:2023 Broken Function Level Authorization](https://owasp.org/API-Security/editions/2023/en/0xa5-broken-function-level-authorization/)
- [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)

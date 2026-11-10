# ADR 0022: Human identity and administrative authorization

- Status: proposed — pending human and security review
- Date: 2026-11-10
- Issue: [#270](https://github.com/Carlos-ccaetano/Tidewake/issues/270)

## Context

Tidewake authenticates API callers as project-bound **service accounts**, not people. [ADR 0019](0019-service-account-authentication.md) and the [implemented API contract](../api/authentication.md) provide opaque credentials, immutable project ownership and role, and server-derived Scope. Admin-only [manual retry POST and audit GET](../api/manual-retries.md) already exist. The [router](../../lib/tidewake_web/router.ex) has a browser pipeline with session and CSRF plugs, but **no implemented human login, human authorization, or operational UI**. A Phoenix session alone is not proof of identity.

Exposing retry, audit or credential administration behind a copied service-account token or an unprotected LiveView would merge two principals with incompatible attribution and revocation. This ADR is a **design proposal** for the [future UI issue #271](https://github.com/Carlos-ccaetano/Tidewake/issues/271); it changes no runtime behavior.

## Decision proposed for review

Use a **managed OpenID Connect (OIDC) identity provider** with authorization-code flow, PKCE, server-side validation and a Tidewake-controlled authorization store. Avoid passwords or MFA factors managed by Tidewake. No vendor is selected yet; an identity-provider choice, operating costs, incident-response ownership and implementation approval are explicit gates.

1. **Principal separation.** A human session must never be interpreted as a service-account Bearer credential. Do not change the current `/api` pipelines or accept browser session cookies as authentication to the service-account API. Browser actions will call trusted domain commands through a distinct human authorization boundary, not proxy opaque service tokens through the client.
2. **Identity.** Use the **(issuer, subject)** pair as the durable external human identity, mapped uniquely to an immutable internal principal. Email, display name and groups claims grant no application authority; never automatically link accounts by email or reassign an old principal's identity/history. Provider migration or identity linking needs separate review. Enforce the callback/token contract below before creating a session.
3. **Projects and roles.** Model explicit, independently revocable human-to-project memberships with server-owned project IDs and a role/permission matrix. No implicit global admin, wildcard project or inheritance from service-account roles. Start with project-scoped read-only operations; audit inspection needs its own explicit administrative permission, not ordinary resource-read access. Sensitive writes need separate explicit permissions. A browser may request a project/object, but authority must come from current server-owned membership and scoped SQL lookup. Never trust browser-supplied actor, role or permission.
4. **Sessions.** Hold sensitive authentication and authorization state server-side, with opaque session identifiers in Secure, HttpOnly, appropriately scoped SameSite cookies over HTTPS. Rotate session IDs after authentication and privilege changes; bound idle and absolute lifetime and revoke on logout, local account disablement or security incident. Membership revocation must immediately remove that project's authority without depending on cookie expiry. All nodes must consult authoritative session/revocation state; recheck session and permissions on each protected request, LiveView mount/reconnect and event. A connected socket or cached assign is not continuing authorization. Lifetime and callback-compatible SameSite configuration remain to be approved, not guessed here.
5. **MFA and elevated actions.** Require provider-enforced MFA for operational administrators and reauthentication/step-up for high-impact actions based on validated `acr`/`amr` and `auth_time`, using an approved provider assurance mapping and freshness bound. Requesting `max_age` or an MFA prompt alone is not proof; reject missing or insufficient assurance. Bind step-up to the same principal/session and authorize the exact target/action again at execution. A remembered browser session does not substitute for authorization or approval of an action.
6. **Authorization timing.** Fetch current membership and project status for sensitive commands inside their transaction boundary, using database locking or another reviewed race-safe protocol. Existing service-account `Scope.revalidate/1` is **not** reusable as proof of human authentication. Avoid check-then-act authority races.
7. **Audit.** Attribute each command to an immutable internal human principal and project, action, bounded outcome and time. Human and service-account actor types must remain distinguishable, including in idempotency/replay ledgers; do not reassign historical service-account subjects. Audit access itself is protected. Preserve accepted/rejected retry evidence; define the separate evidence policy for authentication/authorization denials without fabricating retry decisions. Keep human identity mappings and audit attribution protected and consistent with ADR 0021; no expiry, anonymization or raw free-form justification is authorized here.
8. **Failure behavior.** Default-deny on missing/invalid session, stale authorization, unknown membership, unavailable identity validation or provider mismatch. Conceal foreign-object existence, return non-disclosing authorization errors and prevent unauthorized database writes, Oban jobs, audit reads or retry requests.

### OIDC callback and token contract

- Configure trusted HTTPS issuer, client ID, endpoints and exact redirect URIs server-side. Bind each login to that expected issuer/client; do not select discovery, keys or token endpoints from callback input or untrusted token headers. Validate any authorization-response issuer against the bound issuer when provided by the selected provider/profile; never accept an issuer mismatch or silently switch providers.
- Generate unpredictable, short-lived, single-use `state`, `nonce` and a PKCE verifier for each login. Bind them to the initiating browser and expected redirect; require PKCE **S256**, verify state/nonce, and atomically consume the login transaction so concurrent callbacks cannot replay it. Exchange the code server-side, bound to the same client/redirect/verifier; do not accept implicit-flow tokens or browser-supplied tokens as a shortcut.
- Validate the ID token's signature with trusted issuer keys and an algorithm allowlist; reject unsigned tokens. Require exact `iss`, an `aud` containing the configured client, and matching `azp` when present, requiring it for multiple audiences. Require and validate `exp`, `iat`, nonempty `sub` and the expected nonce; validate `nbf` when present, with bounded approved clock skew. Access tokens are not ID tokens or Tidewake permissions. Use a maintained OIDC implementation rather than custom JWT/protocol validation; select the library only in a reviewed implementation.
- Request only necessary claims/scopes. Authorization codes traverse the browser callback but are exchanged only server-side; keep PKCE verifiers, tokens and any refresh token server-side. Exclude codes, tokens and verifiers from request/proxy logs, errors and Telemetry, including callback query logging. Do not request offline access or retain refresh tokens without a separate lifecycle need. A local session has its own expiry/revocation contract; ID-token expiry does not automatically end it. An IdP-only disablement does not automatically revoke local sessions: approve offboarding/incident synchronization and its maximum delay before rollout.

### Concurrent revocation and retry compatibility

For sensitive commands, revalidate the local principal, session, membership/permission, project status and required step-up inside one transaction. Command and revocation writers must participate in the same database lock/version protocol across all nodes, with a documented common lock order before delivery then endpoint locks. If revocation commits first, the command must deny without domain audit, state change or job. If an authorized command holds the conflicting authority locks first and commits before revocation, that committed work may exist; revocation is not retroactive cancellation of durable jobs or external effects. Notifications/socket disconnects are supplementary, not the authority boundary. No database lock is held across an IdP or outbound HTTP request.

The current [Scope](../../lib/tidewake/projects/scope.ex) requires a service-account ID and the [retry/audit context](../../lib/tidewake/webhooks.ex) derives `actor_type: service_account`; neither is a human command boundary. The audit schema allowing `user` is not implemented human support. Human writes require an explicitly reviewed actor, admission and replay contract first: derive the human subject from the trusted principal, keep keys scoped by actor type/immutable subject rather than session/email, reauthorize every replay, and preserve existing v1/v2 evidence without rewriting fingerprints. Retain accepted/rejected decisions, atomic audit/transition/job insertion, lifetime numbering, six attempts per cycle and at most three manual cycles. A browser confirmation or human quota must not bypass these domain guards or refund service-account admission.

## Threat model and controls

| Threat / failure | Required control and validation |
| --- | --- |
| Forged or replayed OIDC responses | Single-use browser-bound state/nonce and PKCE S256, configured issuer/client binding, signature/audience/authorized-party verification, exact redirect allowlist, bounded clock skew |
| Session fixation or theft | Session rotation, opaque server-side state, secure cookie attributes, idle/absolute expiry, revocation and no session/token logging |
| CSRF on browser actions or LiveView events | No state-changing GET; Phoenix CSRF protection for browser mutations and CSRF/origin validation at the LiveView connection boundary, with current authorization on events; SameSite alone is insufficient |
| XSS leaking authority or sensitive content | Escaped rendering, strict CSP, redacted views, no tokens in HTML, URLs, local storage or browser-visible JS |
| Cross-project IDOR/BOLA | Server-derived membership and current project-scoped lookup on every read/write, including audit pagination |
| Privilege escalation/BFLA | Deny-by-default permission matrix for each operation; a reader cannot create retry decisions or manage credentials |
| Account/session/membership revoked during request | Shared transactional authority locks/version protocol; revocation-first denies work, command-first committed effects are not retroactively undone |
| IdP outage or malicious claim changes | Fail closed for new login/step-up; existing sessions require valid local state and approved assurance lifetime. No remote group/email authority or assumed automatic IdP logout synchronization |
| Admin retry abuse / duplicate requests | Preserve six attempts per cycle, three manual cycles, actor-scoped idempotency and audit semantics; design a **separate** human admission policy before exposing writes |
| Audit/log exfiltration | Explicit field allowlists, short safe errors and low-cardinality Telemetry; no tokens, codes, session IDs, state/nonce/verifiers, issuer/subject identifiers, email, project/audit IDs, signatures or payload in ordinary logs/metrics |
| Emergency access misuse | Break-glass process only if separately designed, tightly limited, recorded and reviewed; no undocumented bypass |

## Alternatives

| Option | Assessment |
| --- | --- |
| Reuse service-account API tokens as human login | **Rejected:** not a human identity, destroys attribution, weakens revocation and exposes credentials to browser risk |
| Build local password authentication and MFA | **Not selected:** expands password reset, factor lifecycle, account recovery, credential stuffing and breach-response obligations |
| Managed OIDC, local project memberships | **Preferred proposal:** delegates interactive login/MFA, keeps business authorization and audit under Tidewake control; requires IdP configuration, session infrastructure and operational discipline |
| Provider roles/groups directly authorizing projects | **Rejected:** external claims must not silently become Tidewake tenant permissions |
| UI without authentication in development only | **Rejected for administrative operations:** easy accidental exposure; development dashboard is not an operational authorization model |

## Proposed implementation slices (separate reviews)

1. **Decision gate:** approve provider-neutral contract and select IdP, hosting/session store, MFA assurance, exact login/redirect origins, permission owners and recovery policy. Threat-model review required before implementing a route.
2. **Human identity and session:** migrations for immutable principal and membership with restrictive FKs, OIDC callback validation, session rotation/revocation, CSRF and tests. No retry UI in this slice.
3. **Human authorization boundary:** permission matrix, project membership lookup and transaction-time revalidation; explicit API/browser separation and negative regression tests. No generic service-account impersonation.
4. **Read-only operations:** bounded status/audit views under a project membership with response field allowlists and pagination.
5. **Sensitive commands:** only after security review, add human-specific admission, replay/idempotency, step-up, justification, consistent atomic domain audit and confirmation. Integrate the [future UI #271](https://github.com/Carlos-ccaetano/Tidewake/issues/271) in independently reviewable PRs.

## Verification gates

Use synthetic identities and separate test projects; no live IdP secret or client assertion in commits, tests, CI output or screenshots. Tests must cover invalid issuer/audience/authorized-party/signature/time claims, missing or replayed state/nonce, missing or downgraded PKCE, concurrent callback/code replay, callback mismatch, CSRF, session fixation/idle and absolute expiry/revocation, LiveView reconnect/events after revocation, and both commit orders of session/membership/project revocation races on separate database connections/nodes. Include 401/403/404 boundaries, separately authorized audit reads, cross-project reads/writes, insufficient MFA/freshness, distinct human/service-account keys and unchanged accepted/rejected replay, cycle limits and audit redaction. Verify that existing service-account API clients retain their current authentication and authorization behavior.

Operational runbooks must cover IdP key rotation, unavailable IdP, lost MFA, administrator offboarding, session invalidation and incident response. No production rollout, provider integration, endpoint, credential or human login is claimed by this ADR.

## Open approvals and consequences

- Choose an OIDC provider, session store/deployment topology and owner for provider outage and credential rotation.
- Agree idle/absolute session lifetime, step-up freshness and administrative MFA assurance.
- Approve human membership provisioning, cross-project access model, separation of duties and break-glass handling.
- Approve retention of human audit subjects and personal information consistently with [ADR 0021](0021-retry-retention-and-safe-disposal.md), which itself remains proposed.
- Approve a separate human actor/admission/replay contract before exposing writes; the current service-account Scope and command cannot authenticate or attribute a human action.

**Decision requested:** approve or reject the provider-neutral architecture above: managed OIDC Authorization Code + PKCE S256, opaque server-side sessions, immutable human attribution, Tidewake-owned project permissions, MFA/step-up and transactional revocation, with service-account APIs kept separate. Acceptance of this ADR would not select a vendor, session duration/store, human role matrix or quota, authorize a route, or approve implementation. Those choices remain explicit gates above. Until the titular explicitly approves this architecture, retain `proposed` and the PR's Draft status; approval of another ADR or of operational execution is not approval of ADR 0022.

**Current status:** Proposed architecture only. Existing service-account authorization remains authoritative for current APIs. **No route, UI, human identity, session persistence or privileged action is implemented or authorized here.**

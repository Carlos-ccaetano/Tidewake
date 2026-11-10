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
2. **Identity.** Validate ID-token signature with trusted issuer keys, algorithm allowlist, issuer, audience, expiry, issued-at/nonce as appropriate, and bind authorization-code + PKCE to the initiating browser session and redirect URI. Use the **(issuer, subject)** pair as the durable human identity; email, display name and groups claims grant no application authority.
3. **Projects and roles.** Model explicit, independently revocable human-to-project memberships with server-owned project IDs and a role/permission matrix. No implicit global admin, wildcard project or inheritance from service-account roles. Start with project-scoped read-only delivery/audit inspection; sensitive actions need a separate explicit permission. Never trust a project, actor, role or permission submitted by browser input.
4. **Sessions.** Hold sensitive authentication and authorization state server-side, with opaque session identifiers in Secure, HttpOnly, appropriately scoped SameSite cookies over HTTPS. Rotate session IDs after authentication and privilege changes; bound idle and absolute lifetime and terminate on logout, account disablement, membership revocation or security incident. Configuration values remain to be approved, not guessed here.
5. **MFA and elevated actions.** Require provider-enforced MFA for operational administrators and reauthentication/step-up for high-impact actions based on validated authentication context and freshness. A remembered browser session does not substitute for authorization or approval of an action.
6. **Authorization timing.** Fetch current membership and project status for sensitive commands inside their transaction boundary, using database locking or another reviewed race-safe protocol. Existing service-account `Scope.revalidate/1` is **not** reusable as proof of human authentication. Avoid check-then-act authority races.
7. **Audit.** Attribute each command to an immutable internal human principal and project, action, bounded outcome and time. Human and service-account actor types must remain distinguishable, including in idempotency/replay ledgers; do not reassign historical service-account subjects. Audit access itself is protected. Rejected administrative decisions require a policy for evidence and privacy before implementation.
8. **Failure behavior.** Default-deny on missing/invalid session, stale authorization, unknown membership, unavailable identity validation or provider mismatch. Conceal foreign-object existence, return non-disclosing authorization errors and prevent unauthorized database writes, Oban jobs, audit reads or retry requests.

## Threat model and controls

| Threat / failure | Required control and validation |
| --- | --- |
| Forged or replayed OIDC responses | State/nonce and PKCE binding, issuer/audience/key verification, exact redirect allowlist, bounded clock skew |
| Session fixation or theft | Session rotation, opaque server-side state, secure cookie attributes, idle/absolute expiry, revocation and no session/token logging |
| CSRF on browser actions or LiveView events | Phoenix CSRF protection plus explicit CSRF controls across HTTP/LiveView lifecycle; SameSite alone is insufficient |
| XSS leaking authority or sensitive content | Escaped rendering, strict CSP, redacted views, no tokens in HTML, URLs, local storage or browser-visible JS |
| Cross-project IDOR/BOLA | Server-derived membership and current project-scoped lookup on every read/write, including audit pagination |
| Privilege escalation/BFLA | Deny-by-default permission matrix for each operation; a reader cannot create retry decisions or manage credentials |
| Account disabled during request | Transaction-time revalidation and a coherent revocation/locking policy; reject without creating work |
| IdP outage or malicious claim changes | Fail closed for new authentication; bounded sessions and locally authoritative membership, never trust remote group/email for access |
| Admin retry abuse / duplicate requests | Preserve cycle-aware six-attempt limit, idempotency keys, audit semantics and account-scoped admission where applicable; design a **separate** human admission policy before exposing writes |
| Audit/log exfiltration | Explicit field allowlists, short safe errors and low-cardinality Telemetry; no raw tokens, signatures, secret identifiers, user email or event payload in labels |
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

Use synthetic identities and separate test projects; no live IdP secret or client assertion in commits, tests, CI output or screenshots. Tests must cover invalid issuer/audience/signature, nonce/state/code replay, callback mismatch, CSRF, session fixation/expiry/revocation, membership removal races, 401/403/404 boundaries, cross-project reads and writes, MFA freshness, duplicate/terminal retry semantics, and audit redaction. Verify that existing service-account API clients retain their current authentication and authorization behavior.

Operational runbooks must cover IdP key rotation, unavailable IdP, lost MFA, administrator offboarding, session invalidation and incident response. No production rollout, provider integration, endpoint, credential or human login is claimed by this ADR.

## Open approvals and consequences

- Choose an OIDC provider, session store/deployment topology and owner for provider outage and credential rotation.
- Agree idle/absolute session lifetime, step-up freshness and administrative MFA assurance.
- Approve human membership provisioning, cross-project access model, separation of duties and break-glass handling.
- Approve retention of human audit subjects and personal information consistently with [ADR 0021](0021-retry-retention-and-safe-disposal.md), which itself remains proposed.
- Review whether reusing the service-account manual retry domain command requires a new actor-discrimination and rate-limit contract; do not assume it is already safe.

**Current status:** Proposed architecture only. Existing service-account authorization remains authoritative for current APIs. **No route, UI, human identity, session persistence or privileged action is implemented or authorized here.**

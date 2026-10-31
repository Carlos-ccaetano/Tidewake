# API authentication and operations

Every current `/api` route requires exactly one header:

```text
Authorization: Bearer <opaque-service-account-token>
```

The angle-bracket value is an intentionally invalid placeholder. A credential has the conceptual format `twk_sa.<credential-public-uuid>.<base64url-secret>`; use the exact token returned by issuance, without trimming, changing case or adding whitespace. Tokens are opaque credentials, not JWTs or client-supplied role/project claims. Send them over TLS, including any proxy-to-application hop carrying the header.

A service account belongs to exactly one project. Multiple expiring, revocable credentials may overlap for rotation; they retain the same account, role and opaque audit subject. Each request reloads persisted credential/account/project state. The server constructs Scope and derives project, role, actor and source. Body/query fields and headers cannot select another tenant or elevate permission. Resource IDs and public UUIDs alone grant no authority.

## Server secret and cutover

Production requires `TIDEWAKE_SERVICE_ACCOUNT_TOKEN_PEPPER`, injected from a secret manager, with at least 32 bytes. Generate its value independently using a cryptographically secure source; the length check does not measure entropy. There is no production fallback. Development/test defaults are explicitly non-production. The pepper is distinct from a client token and from the outbound webhook signing secret.

Only an HMAC-SHA-256 digest of the complete canonical token is stored. The database cannot recover the raw token. Changing the pepper invalidates existing credentials and requires an explicit reissuance and consumer transition; ordinary credential rotation keeps the pepper unchanged.

`TIDEWAKE_API_TOKEN` is removed and the former static token is rejected. Existing resources remain owned by the recorded `legacy` project; provision a deliberate account for that project when access to its data is intended. Creating a new project does not transfer existing data or create credentials.

## Roles

| Existing action | admin | producer | viewer |
| --- | --- | --- | --- |
| GET endpoints, individual event and event delivery status | Allow | Allow | Allow |
| POST events | Allow | Allow | Deny |
| POST/PATCH endpoints, including deactivation | Allow | Deny | Deny |
| POST manual retry, including replay | Allow | Deny | Deny |
| GET manual retry audit | Allow | Deny | Deny |
| Unknown/unlisted action | Deny | Deny | Deny |

Every allowance remains restricted to the authenticated project. Admin is not a wildcard across projects. Roles, account ownership and public identity are immutable through supported interfaces. To change privilege, provision a new account with the intended role, move the consumer deliberately and disable the old account. Credential rotation alone changes no privilege or audit attribution.

## Provisioning

Commands below use a POSIX shell and the intended `MIX_ENV`; Mix defaults to development. Set the target environment deliberately before an operational invocation. Production additionally needs its database, runtime secrets and application configuration; a successful local command proves no production rollout. Never send issuance output to shared terminal recordings, CI logs or tickets.

Inspect task options without creating records:

```sh
mix help tidewake.projects.create
mix help tidewake.service_accounts.provision
mix help tidewake.service_accounts.issue_credential
mix help tidewake.service_accounts.revoke_credential
mix help tidewake.service_accounts.disable
mix help tidewake.projects.suspend
```

For a new local project:

```sh
mix tidewake.projects.create --name Local --slug local
```

Record the printed `Project:` public UUID. The placeholders below are deliberately invalid until replaced with the printed public IDs; none is a token or secret:

```sh
PROJECT_PUBLIC_ID='<project-public-uuid-from-create>'
mix tidewake.service_accounts.provision \
  --project "$PROJECT_PUBLIC_ID" --name LocalAdmin --role admin --expires-in-days 30
```

Provisioning creates a new account and its initial credential atomically. It prints `Service account:`, `Credential:` and `Token:` only after success. Store the raw token in a secret manager immediately; it is shown once and cannot be read back. Record the public IDs for lifecycle operations. A failed operation returns no credential. Repeating provisioning is not rotation and does not reuse an existing account by name.

Tasks require each documented option exactly once and reject extra arguments. Public IDs must be canonical lowercase UUIDs, roles are exactly `admin`, `producer` or `viewer`, and `--expires-in-days` is 1–365. A project slug uses lowercase letters/digits with single separating hyphens, at most 63 bytes. Names are nonblank and at most 255 bytes. Provisioning and issuance require an enabled account/active project as applicable.

## Rotation with an overlap

1. Before the old credential expires, issue another for the same enabled account and active project:

   ```sh
   SERVICE_ACCOUNT_PUBLIC_ID='<service-account-public-uuid-from-provision>'
   mix tidewake.service_accounts.issue_credential \
     --project "$PROJECT_PUBLIC_ID" --service-account "$SERVICE_ACCOUNT_PUBLIC_ID" \
     --expires-in-days 30
   ```

2. Capture the new token securely, update the consumer's secret and verify its permitted requests using the new credential. The old unexpired/unrevoked credential remains valid during this deliberate overlap. Keep enough overlap to complete the consumer switch.
3. Revoke the old credential using its printed public ID:

   ```sh
   OLD_CREDENTIAL_PUBLIC_ID='<old-credential-public-uuid>'
   mix tidewake.service_accounts.revoke_credential \
     --project "$PROJECT_PUBLIC_ID" --credential "$OLD_CREDENTIAL_PUBLIC_ID"
   ```

Revocation is irreversible through supported interfaces and preserves the first revocation time. Expiry is enforced at server UTC time; equality with `expires_at` is already expired. Rotation neither resets the account's manual-retry bucket nor changes actor-scoped idempotency or historical audit attribution. Automated rotation is not implemented.

To retire an account or suspend a project, use their operational tasks deliberately:

```sh
mix tidewake.service_accounts.disable \
  --project "$PROJECT_PUBLIC_ID" --service-account "$SERVICE_ACCOUNT_PUBLIC_ID"
mix tidewake.projects.suspend --project "$PROJECT_PUBLIC_ID"
```

Account disablement invalidates all its credentials. Project suspension prevents authentication through all its accounts. These transitions are irreversible through the supported tasks; they preserve identity, ownership and history. Suspension does not implement cancellation of already queued delivery work.

## HTTP denial contract

| Condition | Response |
| --- | --- |
| Missing, malformed, duplicated/comma-combined, unknown, mismatched, expired or revoked credential; disabled account; suspended project | Same 401, bare `WWW-Authenticate: Bearer` challenge |
| Authenticated role lacks the route permission | 403 before object lookup |
| Otherwise valid resource ID is foreign or absent | Same resource-specific 404 without a global existence probe |

The uniform 401 body is exactly:

```json
{"error":{"code":"unauthorized","message":"Valid service account credential required"}}
```

The functional 403 body is exactly:

```json
{"error":{"code":"forbidden","message":"Permission denied"}}
```

Both denials use JSON and `Cache-Control: no-store`. Manual retry/audit apply no-store to all responses and reauthorize every invocation, including replay and every page. See [manual retries](manual-retries.md), [endpoints](endpoints.md) and [events](events.md) for each resource's contract.

There is no HTTP credential-management API, human identity/login, administrative UI or automatic secret rotation. Audit retention/deletion policy, receiver `Retry-After` support and production deployment remain pending. This authentication sequence does not modify Ironhold.

Implementation evidence: [router](../../lib/tidewake_web/router.ex), [permission policy](../../lib/tidewake/projects/authorization.ex), [provisioning](../../lib/mix/tasks/tidewake.provisioning.ex), [task regressions](../../test/mix/tasks/provisioning_test.exs) and [integrated HTTP security tests](../../test/tidewake_web/controllers/manual_retry_api_security_test.exs).

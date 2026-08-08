# Security policy

Tidewake is pre-release software. No version is currently supported for production use.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting or Security Advisory feature for this repository. Include:

- the affected commit or version;
- clear reproduction steps;
- the potential impact;
- any suggested mitigation;
- whether the report or exploit details have been shared elsewhere.

Maintainers will acknowledge a complete report as soon as practical, validate the impact, and coordinate a fix and disclosure timeline.

## Sensitive data

Never commit:

- API tokens or session tokens;
- production passwords;
- AWS credentials;
- real HMAC secrets;
- populated .env files;
- customer payloads or production logs.

The values in .env.example are placeholders or local-only defaults. Production secrets must be injected by the deployment environment.

## Scope

Until Tidewake reaches a supported release, security fixes are applied to the default branch. Historical commits and local forks are not maintained.

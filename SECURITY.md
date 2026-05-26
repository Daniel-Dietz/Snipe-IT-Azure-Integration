# Security Policy

## Supported versions

Only the latest version on `main` is supported until the project reaches a stable `1.0.0` release.

## Reporting a vulnerability

Do not create a public issue for suspected credential exposure, privilege escalation, destructive sync behavior, or data leakage.

Report security findings privately to the repository owner.

## Secret handling rules

- Do not commit Snipe-IT API tokens.
- Do not commit Azure client secrets.
- Prefer certificate-based Microsoft Graph authentication.
- Store production secrets in a protected secret store.
- Rotate secrets immediately if they are exposed in logs, console output, issue comments, commits, or CI artifacts.

## Minimum production controls

Before production use, validate that:

- the first run is executed with `-DryRun`
- the Azure app has only required read-only Graph permissions
- the Snipe-IT API token has the minimum required permissions
- destructive actions are disabled unless explicitly approved
- reports and logs are reviewed after each initial run
- the scheduled task runs under a dedicated least-privilege account
- log and report directories have restrictive ACLs

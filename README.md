# Snipe-IT Azure Integration

Production-oriented PowerShell integration to synchronize Microsoft Intune managed device inventory into existing Snipe-IT assets with safe defaults, plan/apply execution, structured logging, retry handling, and explicit update controls.

## Current safety model

The script is intentionally conservative:

- Windows-only execution is enforced because certificate-thumbprint authentication uses the Windows certificate store
- no runtime secrets are stored in the repository or in `config.json`
- runtime values are read only from process-scoped environment variables
- `Plan` mode is the default and performs no Snipe-IT writes
- writes require `Apply` mode plus `-AllowUpdate`
- create, archive, and delete lifecycle actions are not implemented and are not exposed
- only Intune managed devices are supported because Entra device objects do not reliably contain serial numbers
- unique matching uses serial number, Azure device ID, and Intune device ID
- device name is treated only as an ambiguous fallback match key
- transient API failures are retried with exponential backoff and `Retry-After` support
- sensitive values are recursively redacted from logs and reports
- log/report directories and existing files are validated before use
- config, log, and report ACLs are checked against a restrictive Windows principal allow-list
- stale sync lock files are detected and removed when the recorded process no longer exists

## Production gate

Before production use, the latest commit on `main` must have a successful CI run with all required jobs passing:

- `Validate repository hygiene`
- `Run Windows behavior tests`
- `Certification gate`

Do not deploy from a commit where any required job is failing or missing.

## Requirements

- Windows with PowerShell 7.2 or newer
- Network access to Snipe-IT and Microsoft Graph
- Snipe-IT API token with the minimum required asset update permissions
- Microsoft Entra application registration using certificate authentication
- Microsoft Graph PowerShell `Microsoft.Graph.Authentication` module

## Recommended Microsoft Graph permissions

Use the least-privilege permissions required for Intune managed device inventory:

| Use case | Application permission |
|---|---|
| Intune managed devices | `DeviceManagementManagedDevices.Read.All` |

Avoid broad write permissions such as `Directory.ReadWrite.All`, `Device.ReadWrite.All`, or `User.ReadWrite.All`. The script writes only to Snipe-IT.

## Snipe-IT field contract

Top-level Snipe-IT fields are mapped directly. Custom fields must use the Snipe-IT API field keys configured in `FieldMappings`, for example `_snipeit_azure_device_id_1`.

Before enabling `Apply`, validate in `Plan` mode that proposed custom-field changes match the field keys configured in your Snipe-IT instance. In `Apply` mode with `-AllowUpdate`, the module performs a preflight check and blocks execution when configured custom field metadata is absent from fetched Snipe-IT assets.

## First run

Create a local config from the example file:

```powershell
Copy-Item .\config.example.json C:\ProgramData\SnipeITAzureSync\config.json
notepad C:\ProgramData\SnipeITAzureSync\config.json
```

Provide runtime values as process-scoped environment variables in the launching process or scheduled task action:

```powershell
$env:SNIPEIT_API_TOKEN = '<token>'
$env:AZURE_TENANT_ID = '<tenant-id>'
$env:AZURE_CLIENT_ID = '<client-id>'
$env:AZURE_CERT_THUMBPRINT = '<certificate-thumbprint>'
```

Run a plan-only execution first:

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\ProgramData\SnipeITAzureSync\config.json -Mode Plan -LogLevel Info
```

Only enable updates after reviewing the plan report:

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\ProgramData\SnipeITAzureSync\config.json -Mode Apply -AllowUpdate -NonInteractive
```

## Security configuration

`Security.AllowedWindowsPrincipals` is an explicit extension allow-list for ACL validation. The script always allows `NT AUTHORITY\SYSTEM`, `BUILTIN\Administrators`, and the current process identity. Add only operationally required principals such as a dedicated scheduled-task service account, a deployment group, or a backup/monitoring principal.

Example:

```json
"Security": {
  "AllowedWindowsPrincipals": [
    "DOMAIN\\svc-snipeit-sync",
    "DOMAIN\\IT-Operations"
  ]
}
```

Do not add broad principals such as `Everyone`, `Authenticated Users`, `Users`, or `Domain Users`.

## Unsupported lifecycle actions

The script does **not** create, archive, or delete Snipe-IT assets. Create mode is disabled until model/status/asset-tag prerequisites are implemented and tested. Missing-asset cleanup is also intentionally unsupported.

## Logs and reports

The script writes structured JSONL logs and a JSON summary report by default:

```text
C:\ProgramData\SnipeITAzureSync\logs\snipeit-azure-sync.jsonl
C:\ProgramData\SnipeITAzureSync\reports\snipeit-azure-sync-report.json
```

Sensitive values are redacted before logging. Protect the log and report directories because they still contain operational inventory metadata such as device names and serial numbers.

`Logging.EmitInformationStream` controls whether structured log lines are also emitted to the PowerShell information stream. It should normally remain `false` for scheduled tasks and automation so JSON log lines do not pollute console output. File logging remains enabled regardless of this setting.

## Repository layout

```text
src/Sync-SnipeItAzure.ps1          Thin executable wrapper
src/SnipeItAzureSync.psm1          Consolidated production sync module
docs/runbook.md                    Operational runbook
tests/Sync-SnipeItAzure.Tests.ps1  Pester behavior tests
config.example.json                Example configuration without runtime secrets
config.schema.json                 JSON schema for configuration validation
.github/workflows/ci.yml           CI checks and certification gate
```

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | General failure |
| 2 | Configuration error |
| 3 | Authentication failure |
| 4 | API connectivity failure |
| 5 | Validation failure |
| 6 | Partial sync failure |
| 8 | Concurrent run blocked |

## Commit message

```text
Consolidate Snipe-IT Azure sync hardening
```

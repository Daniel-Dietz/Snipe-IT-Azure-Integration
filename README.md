# Snipe-IT Azure Integration

Production-oriented PowerShell integration to synchronize Microsoft Entra ID / Intune device inventory into Snipe-IT with safe defaults, dry-run support, structured logging, retry handling, and explicit destructive-action guardrails.

## Current safety model

The script is intentionally conservative:

- no secrets are stored in the repository
- dry-run is the recommended first execution mode
- deletion is disabled unless explicitly enabled
- Snipe-IT asset tags are treated as Snipe-IT-owned data by default
- ambiguous duplicate matches are blocked instead of guessed
- transient API failures are retried with exponential backoff
- sensitive values are redacted from logs

## Requirements

- PowerShell 7.2 or newer
- Network access to Snipe-IT and Microsoft Graph
- Snipe-IT API token with the minimum required asset permissions
- Microsoft Entra application registration using certificate authentication where possible

## Recommended Microsoft Graph permissions

Use the least-privilege permissions required for your selected source:

| Use case | Application permission |
|---|---|
| Entra device inventory | `Device.Read.All` |
| Intune managed devices | `DeviceManagementManagedDevices.Read.All` |
| User ownership mapping | `User.Read.All` |

Avoid broad write permissions such as `Directory.ReadWrite.All`, `Device.ReadWrite.All`, or `User.ReadWrite.All` unless the script is explicitly extended to write to Microsoft services.

## First run

Create a local config from the example file:

```powershell
Copy-Item .\config.example.json .\config.json
notepad .\config.json
```

Provide secrets via environment variables or a secure secret source:

```powershell
$env:SNIPEIT_API_TOKEN = '<token>'
$env:AZURE_TENANT_ID = '<tenant-id>'
$env:AZURE_CLIENT_ID = '<client-id>'
$env:AZURE_CERT_THUMBPRINT = '<certificate-thumbprint>'
```

Run validation and dry-run:

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath .\config.json -DryRun -LogLevel Info
```

Only enable writes after reviewing the dry-run report:

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath .\config.json -AllowCreate -AllowUpdate
```

## Destructive actions

Deletion is intentionally blocked unless both switches are present:

```powershell
-AllowDelete -IUnderstandThisCanRemoveAssets
```

Prefer archiving over deletion. Default handling for Snipe-IT assets missing from Azure is `Ignore`.

## Logs and reports

The script writes structured JSONL logs and a JSON summary report by default:

```text
logs/snipeit-azure-sync.jsonl
reports/snipeit-azure-sync-report.json
```

Sensitive values are redacted before logging.

## Repository layout

```text
src/Sync-SnipeItAzure.ps1          Main sync script
config.example.json                Example configuration without secrets
config.schema.json                 JSON schema for configuration validation
docs/runbook.md                    Operational runbook
tests/Sync-SnipeItAzure.Tests.ps1  Pester baseline tests
.github/workflows/ci.yml           CI checks
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
| 7 | Destructive action blocked |

## Commit message

```text
Implement secure Snipe-IT Azure sync baseline
```

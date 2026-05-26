# Operational Runbook

## Purpose

This runbook describes how to operate, validate, disable, and recover the Snipe-IT Azure Integration.

## Secret handling

Never store secrets in the repository or in `config.json`.

Recommended production secret sources:

1. Azure Key Vault
2. Windows Credential Manager
3. Scheduled task environment variables protected by host ACLs
4. CI/CD secret store for non-production validation

Required runtime values:

```powershell
$env:SNIPEIT_API_TOKEN = '<snipe-it-token>'
$env:AZURE_TENANT_ID = '<tenant-id>'
$env:AZURE_CLIENT_ID = '<client-id>'
$env:AZURE_CERT_THUMBPRINT = '<certificate-thumbprint>'
```

## First deployment

1. Register an Entra application.
2. Assign only the required read-only Graph application permissions.
3. Upload or bind a certificate to the app registration.
4. Create a Snipe-IT API token with the minimum required scope.
5. Copy `config.example.json` to `config.json`.
6. Configure Snipe-IT URL and field mappings.
7. Run a dry-run.
8. Review the JSONL log and JSON report.
9. Enable create/update only after validation.

## Dry-run command

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath .\config.json -DryRun -LogLevel Info
```

## Production command

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath .\config.json -AllowCreate -AllowUpdate -NonInteractive
```

## Emergency disable

Disable the scheduled task or remove the runtime secrets from the execution environment.

```powershell
Disable-ScheduledTask -TaskName 'Snipe-IT Azure Integration'
```

## Token rotation

1. Create a new Snipe-IT token.
2. Update the protected runtime secret source.
3. Run dry-run.
4. Revoke the old token.
5. Confirm the next scheduled run succeeds.

## Certificate rotation

1. Create a new certificate.
2. Upload the public certificate to the Entra app registration.
3. Install the private certificate on the sync host.
4. Update `AZURE_CERT_THUMBPRINT`.
5. Run dry-run.
6. Remove the old certificate after successful validation.

## Rollback after bad update

1. Disable the scheduled task immediately.
2. Preserve the affected log/report files.
3. Identify changed assets from the latest report and Snipe-IT audit log.
4. Revert incorrect fields manually or via a controlled restore script.
5. Correct field mappings or sync policy.
6. Run dry-run until the report is clean.
7. Re-enable the scheduled task.

## Scheduled task example

```powershell
$Action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Snipe-IT-Azure-Integration\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\Scripts\Snipe-IT-Azure-Integration\config.json -AllowCreate -AllowUpdate -NonInteractive'
$Trigger = New-ScheduledTaskTrigger -Daily -At 02:00
$Principal = New-ScheduledTaskPrincipal -UserId 'DOMAIN\svc-snipeit-sync' -LogonType Password -RunLevel LeastPrivilege
Register-ScheduledTask -TaskName 'Snipe-IT Azure Integration' -Action $Action -Trigger $Trigger -Principal $Principal
```

## Monitoring

Monitor these outputs:

- process exit code
- `reports/snipeit-azure-sync-report.json`
- warnings/errors in `logs/snipeit-azure-sync.jsonl`
- Snipe-IT audit log

## Exit codes

| Code | Meaning | Action |
|---:|---|---|
| 0 | Success | No action required |
| 1 | General failure | Review logs |
| 2 | Configuration error | Validate config and environment variables |
| 3 | Authentication failure | Check certificate, token, and permissions |
| 4 | API connectivity failure | Check network, TLS, proxy, API availability |
| 5 | Validation failure | Resolve duplicate or invalid data |
| 6 | Partial sync failure | Review failed device entries |
| 7 | Destructive action blocked | Confirm whether destructive behavior was intended |

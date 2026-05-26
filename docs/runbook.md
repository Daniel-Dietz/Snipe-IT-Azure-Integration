# Operational Runbook

## Purpose

This runbook describes how to operate, validate, disable, and recover the Snipe-IT Azure Integration.

## Supported platform

Production execution is Windows-only. The script uses Microsoft Graph certificate-thumbprint authentication against the Windows certificate store.

## Secret handling

Never store secrets in the repository or in `config.json`.

The script reads required secrets only from process-scoped environment variables. For scheduled tasks, inject the variables in the task action or a protected launcher script that sets process environment variables immediately before invoking PowerShell.

Required runtime values:

```powershell
$env:SNIPEIT_API_TOKEN = '<snipe-it-token>'
$env:AZURE_TENANT_ID = '<tenant-id>'
$env:AZURE_CLIENT_ID = '<client-id>'
$env:AZURE_CERT_THUMBPRINT = '<certificate-thumbprint>'
```

## First deployment

1. Register an Entra application.
2. Assign only `DeviceManagementManagedDevices.Read.All` as an application permission unless the script is deliberately extended.
3. Upload or bind a certificate to the app registration.
4. Install the private certificate on the sync host.
5. Create a Snipe-IT API token with the minimum required asset update scope.
6. Copy `config.example.json` to `config.json` under a protected local path such as `C:\ProgramData\SnipeITAzureSync`.
7. Configure Snipe-IT URL and field mappings.
8. Harden ACLs for config, log, and report directories.
9. Run `Plan` mode.
10. Review the JSONL log and JSON report.
11. Enable updates only after validation.

## Plan command

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\ProgramData\SnipeITAzureSync\config.json -Mode Plan -LogLevel Info
```

## Production command

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\ProgramData\SnipeITAzureSync\config.json -Mode Apply -AllowUpdate -NonInteractive
```

## Emergency disable

Disable the scheduled task or remove the runtime secrets from the execution environment.

```powershell
Disable-ScheduledTask -TaskName 'Snipe-IT Azure Integration'
```

## Token rotation

1. Create a new Snipe-IT token.
2. Update the protected runtime secret source.
3. Run `Plan` mode.
4. Revoke the old token.
5. Confirm the next scheduled run succeeds.

## Certificate rotation

1. Create a new certificate.
2. Upload the public certificate to the Entra app registration.
3. Install the private certificate on the sync host.
4. Update `AZURE_CERT_THUMBPRINT` in the process-scoped runtime source.
5. Run `Plan` mode.
6. Remove the old certificate after successful validation.

## Rollback after bad update

1. Disable the scheduled task immediately.
2. Preserve the affected log/report files.
3. Identify changed assets from the latest report and Snipe-IT audit log.
4. Revert incorrect fields manually or via a controlled restore script.
5. Correct field mappings or sync policy.
6. Run `Plan` mode until the report is clean.
7. Re-enable the scheduled task.

## Scheduled task example

```powershell
$ScriptRoot = 'C:\Scripts\Snipe-IT-Azure-Integration'
$ConfigPath = 'C:\ProgramData\SnipeITAzureSync\config.json'
$Command = @"
`$env:SNIPEIT_API_TOKEN = '<set-from-protected-source>'
`$env:AZURE_TENANT_ID = '<tenant-id>'
`$env:AZURE_CLIENT_ID = '<client-id>'
`$env:AZURE_CERT_THUMBPRINT = '<certificate-thumbprint>'
& '$ScriptRoot\src\Sync-SnipeItAzure.ps1' -ConfigPath '$ConfigPath' -Mode Apply -AllowUpdate -NonInteractive
"@
$Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
$Action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $Encoded"
$Trigger = New-ScheduledTaskTrigger -Daily -At 02:00
$Principal = New-ScheduledTaskPrincipal -UserId 'DOMAIN\svc-snipeit-sync' -LogonType Password -RunLevel LeastPrivilege
Register-ScheduledTask -TaskName 'Snipe-IT Azure Integration' -Action $Action -Trigger $Trigger -Principal $Principal
```

## Monitoring

Monitor these outputs:

- process exit code
- configured report path
- warnings/errors in the configured JSONL log path
- Snipe-IT audit log

Protect logs and reports because they contain operational inventory metadata even after secret redaction.

## Unsupported lifecycle actions

The script does not create, archive, or delete Snipe-IT assets. Do not assume missing asset cleanup is automated.

## Exit codes

| Code | Meaning | Action |
|---:|---|---|
| 0 | Success | No action required |
| 1 | General failure | Review logs |
| 2 | Configuration error | Validate config and process-scoped environment variables |
| 3 | Authentication failure | Check certificate, token, and permissions |
| 4 | API connectivity failure | Check network, TLS, proxy, API availability |
| 5 | Validation failure | Resolve duplicate or invalid data |
| 6 | Partial sync failure | Review failed device entries |
| 8 | Concurrent run blocked | Ensure no existing sync is running |

# Operational Runbook

## Purpose

This runbook describes how to operate, validate, disable, and recover the Snipe-IT Azure Integration.

## Production gate

Do not deploy a commit unless the latest CI run on that commit has both jobs passing:

- `Validate repository hygiene`
- `Run Windows behavior tests`

A missing, skipped, or failing CI job blocks production deployment.

## Supported platform

Production execution is Windows-only. The script uses Microsoft Graph certificate-thumbprint authentication against the Windows certificate store.

## Runtime value handling

Never store runtime values in the repository or in `config.json`.

The script reads required runtime values only from process-scoped environment variables. For scheduled tasks, inject them in the task action or a protected launcher script immediately before invoking PowerShell.

Required values are the environment variables named in `config.json` for Snipe-IT access and Microsoft Graph certificate authentication.

## First deployment

1. Register an Entra application.
2. Assign only `DeviceManagementManagedDevices.Read.All` as an application permission unless the script is deliberately extended.
3. Upload or bind a certificate to the app registration.
4. Install the private certificate on the sync host.
5. Create a Snipe-IT API token with the minimum required asset update scope.
6. Copy `config.example.json` to `config.json` under a protected local path such as `C:\ProgramData\SnipeITAzureSync`.
7. Configure Snipe-IT URL and field mappings.
8. Validate Snipe-IT custom-field API keys against your Snipe-IT instance.
9. Harden ACLs for config, log, and report directories and existing log/report files.
10. Run `Plan` mode.
11. Review the JSONL log and JSON report.
12. Enable updates only after validation.

## Snipe-IT custom-field validation

The configured custom-field mappings must use Snipe-IT API field keys, for example `_snipeit_azure_device_id_1`.

Before production `Apply` mode:

1. Run `Plan` mode.
2. Confirm that proposed custom-field changes target the expected Snipe-IT field keys.
3. Test one known asset in a non-production Snipe-IT system or controlled production maintenance window.
4. Confirm Snipe-IT audit history shows only the intended field changes.

## Plan command

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\ProgramData\SnipeITAzureSync\config.json -Mode Plan -LogLevel Info
```

## Production command

```powershell
pwsh .\src\Sync-SnipeItAzure.ps1 -ConfigPath C:\ProgramData\SnipeITAzureSync\config.json -Mode Apply -AllowUpdate -NonInteractive
```

## Lock handling

The script writes a per-configuration lock file to the system temp path. If a previous process crashed, stale locks are removed only when the recorded process ID no longer exists. If the sync exits with code `8`, verify whether another sync is running before deleting any lock file manually.

## Emergency disable

Disable the scheduled task or remove the runtime values from the execution environment.

```powershell
Disable-ScheduledTask -TaskName 'Snipe-IT Azure Integration'
```

## Rotation

1. Create replacement credentials or certificate material.
2. Update the protected runtime source.
3. Run `Plan` mode.
4. Revoke old material after successful validation.
5. Confirm the next scheduled run succeeds.

## Rollback after bad update

1. Disable the scheduled task immediately.
2. Preserve the affected log/report files.
3. Identify changed assets from the latest report and Snipe-IT audit log.
4. Revert incorrect fields manually or via a controlled restore script.
5. Correct field mappings or sync policy.
6. Run `Plan` mode until the report is clean.
7. Re-enable the scheduled task.

## Scheduled task guidance

Create a Windows scheduled task that launches `pwsh.exe` with `-NoProfile`, sets process-scoped runtime values inside the task action or a protected wrapper, and calls the script with `-Mode Apply -AllowUpdate -NonInteractive` only after the production gate and Plan validation pass.

Run the task with a least-privilege service account that can read the certificate private key, read the protected config, and write only to the configured log/report paths.

## Monitoring

Monitor these outputs:

- process exit code
- configured report path
- warnings/errors in the configured JSONL log path
- Snipe-IT audit log
- scheduled-task history

Protect logs and reports because they contain operational inventory metadata even after secret redaction.

## Unsupported lifecycle actions

The script does not create, archive, or delete Snipe-IT assets. Do not assume missing asset cleanup is automated.

## Exit codes

| Code | Meaning | Action |
|---:|---|---|
| 0 | Success | No action required |
| 1 | General failure | Review logs |
| 2 | Configuration error | Validate config and process-scoped environment variables |
| 3 | Authentication failure | Check certificate and permissions |
| 4 | API connectivity failure | Check network, TLS, proxy, API availability |
| 5 | Validation failure | Resolve duplicate or invalid data |
| 6 | Partial sync failure | Review failed device entries |
| 8 | Concurrent run blocked | Confirm no active sync process exists before manual lock cleanup |

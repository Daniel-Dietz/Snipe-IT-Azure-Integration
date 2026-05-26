#requires -Version 7.2
<#!
.SYNOPSIS
Compatibility wrapper for the legacy Snipe-IT to Intune sample.

.DESCRIPTION
The original sample used inline placeholders and client-secret based authentication. It has been
replaced with a safe wrapper that delegates to src/Sync-SnipeItAzure.ps1.

Secrets must be supplied through protected environment variables or another secure runtime secret
source. Do not store API tokens, client secrets, certificates, or passwords in this file.

.EXAMPLE
$env:SNIPEIT_API_TOKEN = '<set securely outside the repository>'
$env:AZURE_TENANT_ID = '<set securely outside the repository>'
$env:AZURE_CLIENT_ID = '<set securely outside the repository>'
$env:AZURE_CERT_THUMBPRINT = '<set securely outside the repository>'
.\SnipeIT-InfoImportToIntuneSample.ps1 -DryRun
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = '.\config.json',

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$AllowCreate,

    [Parameter()]
    [switch]$AllowUpdate,

    [Parameter()]
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SyncScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'src/Sync-SnipeItAzure.ps1'
if (-not (Test-Path -LiteralPath $SyncScriptPath)) {
    throw "The secure sync script was not found at '$SyncScriptPath'."
}

$ForwardedArguments = @{
    ConfigPath = $ConfigPath
}

if ($DryRun) {
    $ForwardedArguments.DryRun = $true
}

if ($AllowCreate) {
    $ForwardedArguments.AllowCreate = $true
}

if ($AllowUpdate) {
    $ForwardedArguments.AllowUpdate = $true
}

if ($NonInteractive) {
    $ForwardedArguments.NonInteractive = $true
}

Write-Output 'The legacy sample now delegates to src/Sync-SnipeItAzure.ps1 with safe defaults.'
& $SyncScriptPath @ForwardedArguments

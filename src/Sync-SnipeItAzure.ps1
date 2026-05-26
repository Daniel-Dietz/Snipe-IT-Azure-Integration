#requires -Version 7.2
<#
.SYNOPSIS
Thin executable wrapper for the Snipe-IT Azure sync module.

.DESCRIPTION
Imports SnipeItAzureSync.psm1 and exits with the module-returned process exit code.
Reusable logic lives in the module so tests can import the exact production code without modifying source text.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = '.\config.json',

    [Parameter()]
    [ValidateSet('Plan', 'Apply')]
    [string]$Mode,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$AllowCreate,

    [Parameter()]
    [switch]$AllowUpdate,

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModulePath = Join-Path $PSScriptRoot 'SnipeItAzureSync.psm1'
Import-Module -Name $ModulePath -Force -ErrorAction Stop

$InvokeParameters = @{
    ConfigPath     = $ConfigPath
    DryRun         = $DryRun
    AllowCreate    = $AllowCreate
    AllowUpdate    = $AllowUpdate
    NonInteractive = $NonInteractive
    LogLevel       = $LogLevel
}

if ($PSBoundParameters.ContainsKey('Mode')) {
    $InvokeParameters.Mode = $Mode
}

$ExitCode = Invoke-SnipeItAzureSync @InvokeParameters
exit $ExitCode

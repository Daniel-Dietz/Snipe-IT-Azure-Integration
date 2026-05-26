#requires -Version 7.2
<#
.SYNOPSIS
Certification hardening layer for SnipeItAzureSync.psm1.

.DESCRIPTION
This module dot-sources the base sync module and overrides focused safety-critical helpers.
It keeps the large sync implementation stable while providing deterministic production-gate
behavior for logging, Windows ACL policy, and Snipe-IT custom-field preflight validation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SnipeItAzureSync.psm1')

function Write-SyncLog {
    <#
    .SYNOPSIS
    Writes structured JSON logs without returning log text on the success stream.

    .DESCRIPTION
    File logging remains the durable audit path. Console emission is opt-in through
    Logging.EmitInformationStream so scheduled tasks and automation pipelines are not
    polluted by informational JSON unless explicitly requested.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][hashtable]$Data
    )

    $LevelRank = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }
    $EffectiveLogLevel = if ($Script:Options.LogLevel) { [string]$Script:Options.LogLevel } else { 'Info' }
    if ($LevelRank[$Level] -lt $LevelRank[$EffectiveLogLevel]) { return }
    if ($Level -eq 'Warning') { $Script:Summary.Warnings++ }

    $Entry = [ordered]@{
        Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        Level         = $Level
        CorrelationId = $Script:CorrelationId
        Message       = $Message
        Data          = if ($Data) { ConvertTo-RedactedValue -Value $Data } else { $null }
    }

    $Line = $Entry | ConvertTo-Json -Depth 12 -Compress

    if ($Script:Runtime -and $Script:Runtime.Config.Logging.PSObject.Properties.Name -contains 'EmitInformationStream' -and [bool]$Script:Runtime.Config.Logging.EmitInformationStream) {
        Write-Information -MessageData $Line
    }

    if ($Script:Runtime -and $Script:Runtime.Config.Logging.LogPath) {
        Add-Content -LiteralPath $Script:Runtime.Config.Logging.LogPath -Value $Line -Encoding UTF8
    }
}

function Get-ConfiguredWindowsAclPrincipals {
    <#
    .SYNOPSIS
    Builds the effective Windows ACL allow-list.

    .DESCRIPTION
    SYSTEM, local Administrators, and the current process identity are always trusted.
    Security.AllowedWindowsPrincipals may add environment-specific service, monitoring,
    backup, or deployment principals without weakening the default posture.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Config)

    $CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Principals = [System.Collections.Generic.List[string]]::new()
    foreach ($Principal in @($Script:WindowsTrustedPrincipals + $CurrentIdentity)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Principal)) { $Principals.Add([string]$Principal) }
    }

    if ($Config -and $Config.PSObject.Properties.Name -contains 'Security' -and $Config.Security -and $Config.Security.PSObject.Properties.Name -contains 'AllowedWindowsPrincipals') {
        foreach ($Principal in @($Config.Security.AllowedWindowsPrincipals)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Principal)) { $Principals.Add([string]$Principal) }
        }
    }

    return @($Principals | Select-Object -Unique)
}

function Get-AllowedWindowsAclPrincipals {
    [CmdletBinding()]
    param()
    $Config = if ($Script:Runtime) { $Script:Runtime.Config } else { $null }
    return Get-ConfiguredWindowsAclPrincipals -Config $Config
}

function Assert-SafeWindowsAcl {
    <#
    .SYNOPSIS
    Fails when protected files or directories grant access to unapproved principals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter()][AllowNull()][object]$Config
    )

    if (-not $IsWindows) { return }
    $Acl = Get-Acl -LiteralPath $Path
    if (-not $Acl.Owner) { throw "$Purpose path owner could not be determined." }
    $AllowedPrincipals = Get-ConfiguredWindowsAclPrincipals -Config $Config
    $UnsafeRules = @($Acl.Access | Where-Object { Test-UnsafeWindowsAccessRule -Rule $_ -AllowedPrincipals $AllowedPrincipals })
    if ($UnsafeRules.Count -gt 0) {
        $Names = ($UnsafeRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ', '
        throw "$Purpose path grants read/write access to unapproved principals: $Names. Allowed principals: $($AllowedPrincipals -join ', ')."
    }
}

function Read-SyncConfig {
    <#
    .SYNOPSIS
    Reads configuration and validates the config file ACL after the configured allow-list is known.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([bool]$Script:Options.NonInteractive -and $IsWindows -and -not (Test-WindowsAbsolutePath -Path $Expanded)) {
        throw 'Config path must be a fully qualified Windows path in non-interactive mode.'
    }

    $ConfigPath = Resolve-SafeFullPath -Path $Expanded
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file '$Path' was not found." }

    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    Assert-SafeWindowsAcl -Path $ConfigPath -Purpose 'Config file' -Config $Config

    if (-not $Config.SnipeIt.BaseUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { throw 'Snipe-IT BaseUrl must use HTTPS.' }
    if ($Config.Azure.Source -ne 'IntuneManagedDevices') { throw "Unsupported Azure source '$($Config.Azure.Source)'. Only IntuneManagedDevices is supported." }
    foreach ($Field in @($Config.Sync.UniqueMatchPriority)) { if ($Script:AllowedUniqueMatchFields -notcontains [string]$Field) { throw "Unsupported unique match field '$Field'." } }
    foreach ($Field in @($Config.Sync.FallbackMatchPriority)) { if ($Script:AllowedFallbackMatchFields -notcontains [string]$Field) { throw "Unsupported fallback match field '$Field'." } }
    foreach ($Field in @($Config.Sync.UpdateFields)) {
        if ($Script:AllowedDeviceFields -notcontains [string]$Field) { throw "Unsupported sync field '$Field'." }
        if (-not $Config.FieldMappings.PSObject.Properties.Name.Contains([string]$Field)) { throw "Field '$Field' is enabled but has no FieldMappings entry." }
    }
    return $Config
}

function Test-SafeOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter()][switch]$RequireFullyQualified
    )

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($RequireFullyQualified -and $IsWindows -and -not (Test-WindowsAbsolutePath -Path $Expanded)) { throw "$Purpose path must be a fully qualified Windows path in non-interactive mode." }
    $FullPath = Resolve-SafeFullPath -Path $Expanded
    $Directory = Split-Path -Parent $FullPath
    if ([string]::IsNullOrWhiteSpace($Directory)) { throw "$Purpose path must include a directory." }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $ResolvedDirectory = (Resolve-Path -LiteralPath $Directory).Path
    $RuntimeConfig = if ($Script:Runtime) { $Script:Runtime.Config } else { $null }
    Assert-SafeWindowsAcl -Path $ResolvedDirectory -Purpose "$Purpose directory" -Config $RuntimeConfig
    if ($IsWindows -and (Test-Path -LiteralPath $FullPath)) { Assert-SafeWindowsAcl -Path $FullPath -Purpose "$Purpose file" -Config $RuntimeConfig }
    if (-not $IsWindows) {
        $Item = Get-Item -LiteralPath $ResolvedDirectory
        $Mode = $Item.UnixFileMode
        if (($Mode -band [System.IO.UnixFileMode]::GroupWrite) -or ($Mode -band [System.IO.UnixFileMode]::OtherWrite)) { throw "$Purpose directory is group/world writable. Harden permissions before running." }
    }
    return $FullPath
}

function Get-ConfiguredCustomFieldMappings {
    <#
    .SYNOPSIS
    Returns configured Snipe-IT custom field mappings deterministically.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $Fields = [System.Collections.Generic.List[string]]::new()
    foreach ($Field in @($Config.Sync.UniqueMatchPriority)) { if (-not [string]::IsNullOrWhiteSpace([string]$Field)) { $Fields.Add([string]$Field) } }
    foreach ($Field in @($Config.Sync.FallbackMatchPriority)) { if (-not [string]::IsNullOrWhiteSpace([string]$Field)) { $Fields.Add([string]$Field) } }
    foreach ($Field in @($Config.Sync.UpdateFields)) { if (-not [string]::IsNullOrWhiteSpace([string]$Field)) { $Fields.Add([string]$Field) } }

    foreach ($LogicalField in @($Fields | Select-Object -Unique)) {
        if (-not $Config.FieldMappings.PSObject.Properties.Name.Contains([string]$LogicalField)) { continue }
        $Mapped = [string]$Config.FieldMappings.$LogicalField
        if ($Mapped.StartsWith('_snipeit_', [StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{ LogicalField = [string]$LogicalField; MappedName = $Mapped }
        }
    }
}

function Test-SnipeItCustomFieldPreflight {
    <#
    .SYNOPSIS
    Blocks Apply mode when configured custom fields are absent from Snipe-IT metadata.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Assets)

    $Mappings = @(Get-ConfiguredCustomFieldMappings -Config $Script:Runtime.Config)
    if ($Mappings.Count -eq 0) { return }
    if ($Assets.Count -eq 0) { throw 'Cannot validate Snipe-IT custom field mappings because no assets were returned.' }

    foreach ($Mapping in $Mappings) {
        $Found = $false
        foreach ($Asset in $Assets) {
            if (-not ($Asset.PSObject.Properties.Name -contains 'custom_fields') -or -not $Asset.custom_fields) { continue }
            if ($Asset.custom_fields.PSObject.Properties.Name -contains $Mapping.MappedName) { $Found = $true; break }
        }
        if (-not $Found) { throw "Configured Snipe-IT custom field mapping '$($Mapping.MappedName)' for '$($Mapping.LogicalField)' was not present in fetched asset metadata. Validate FieldMappings before Apply." }
    }
}

Export-ModuleMember -Function Invoke-SnipeItAzureSync

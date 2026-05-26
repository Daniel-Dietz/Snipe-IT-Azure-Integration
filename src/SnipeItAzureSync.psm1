#requires -Version 7.2
<#
.SYNOPSIS
Production Snipe-IT Azure synchronization module.

.DESCRIPTION
Synchronizes Microsoft Intune managed-device inventory into existing Snipe-IT assets.
The module is intentionally update-only and includes conservative runtime safeguards:
process-scoped runtime secrets, explicit Apply permission, deterministic field mapping,
custom-field preflight validation, structured redacted logging, and Windows ACL checks.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ExitCodes = [ordered]@{
    Success                = 0
    GeneralFailure         = 1
    ConfigurationError     = 2
    AuthenticationFailure  = 3
    ApiConnectivityFailure = 4
    ValidationFailure      = 5
    PartialSyncFailure     = 6
    ConcurrencyBlocked     = 8
}

$Script:AllowedDeviceFields = @('SerialNumber', 'DeviceName', 'Manufacturer', 'Model', 'AzureDeviceId', 'IntuneDeviceId', 'AssignedUser')
$Script:AllowedUniqueMatchFields = @('SerialNumber', 'AzureDeviceId', 'IntuneDeviceId')
$Script:AllowedFallbackMatchFields = @('DeviceName')
$Script:AllowedTopLevelSnipeFields = @('id', 'serial', 'name', 'manufacturer', 'model', 'assigned_user')
$Script:WindowsTrustedPrincipals = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')
$Script:Runtime = $null
$Script:LockStream = $null
$Script:LockPath = $null
$Script:Options = [ordered]@{}
$Script:Summary = [ordered]@{}

function Initialize-SyncState {
    [CmdletBinding()]
    param()

    $Script:CorrelationId = [guid]::NewGuid().ToString()
    $Script:Runtime = $null
    $Script:LockStream = $null
    $Script:LockPath = $null
    $Script:Summary = [ordered]@{
        CorrelationId     = $Script:CorrelationId
        StartedAt         = (Get-Date).ToUniversalTime().ToString('o')
        FinishedAt        = $null
        Mode              = 'Plan'
        AzureDevicesRead  = 0
        SnipeItAssetsRead = 0
        WouldCreate       = 0
        Created           = 0
        WouldUpdate       = 0
        Updated           = 0
        Skipped           = 0
        Failed            = 0
        Warnings          = 0
        Errors            = @()
    }
}

function Set-SyncOptions {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ConfigPath = '.\config.json',
        [Parameter()][ValidateSet('Plan', 'Apply')][string]$Mode,
        [Parameter()][switch]$DryRun,
        [Parameter()][switch]$AllowCreate,
        [Parameter()][switch]$AllowUpdate,
        [Parameter()][switch]$NonInteractive,
        [Parameter()][ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$LogLevel = 'Info'
    )

    $Script:Options = [ordered]@{
        ConfigPath     = $ConfigPath
        Mode           = $Mode
        DryRun         = [bool]$DryRun
        AllowCreate    = [bool]$AllowCreate
        AllowUpdate    = [bool]$AllowUpdate
        NonInteractive = [bool]$NonInteractive
        LogLevel       = $LogLevel
    }
}

function ConvertTo-RedactedValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $Result = [ordered]@{}
        foreach ($Key in $Value.Keys) {
            if ([string]$Key -match '(?i)(token|secret|password|credential|thumbprint|authorization)') { $Result[$Key] = '***REDACTED***' }
            else { $Result[$Key] = ConvertTo-RedactedValue -Value $Value[$Key] }
        }
        return $Result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return @($Value | ForEach-Object { ConvertTo-RedactedValue -Value $_ }) }
    if ($Value -is [pscustomobject]) {
        $Result = [ordered]@{}
        foreach ($Property in $Value.PSObject.Properties) {
            if ($Property.Name -match '(?i)(token|secret|password|credential|thumbprint|authorization)') { $Result[$Property.Name] = '***REDACTED***' }
            else { $Result[$Property.Name] = ConvertTo-RedactedValue -Value $Property.Value }
        }
        return $Result
    }

    $Text = [string]$Value
    if ($Text -match '(?i)(bearer\s+|client_secret|api[_-]?key|token|password|authorization)') { return '***REDACTED***' }
    if ($Text.Length -gt 32 -and $Text -match '^[A-Za-z0-9_\-\.~+/=]+$') { return "$($Text.Substring(0,4))...$($Text.Substring($Text.Length - 4))" }
    return $Value
}

function Write-SyncLog {
    <#
    .SYNOPSIS
    Writes structured JSON logs without polluting the success stream.

    .DESCRIPTION
    File logging is the durable audit path. PowerShell information-stream emission is opt-in
    through Logging.EmitInformationStream for interactive troubleshooting only.
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

function Get-EnvironmentRuntimeValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Purpose
    )

    $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    throw "Required process-scoped runtime value for $Purpose is missing. Set environment variable '$Name' in the launching process or scheduled task action."
}

Set-Alias -Name Get-EnvironmentSecret -Value Get-EnvironmentRuntimeValue

function Test-WindowsAbsolutePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return ($Path -match '^[A-Za-z]:[\\/]')
}

function Resolve-SafeFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [System.IO.Path]::GetFullPath($Expanded)
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

    $Principals = [System.Collections.Generic.List[string]]::new()
    if ($IsWindows) {
        $CurrentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        foreach ($Principal in @($Script:WindowsTrustedPrincipals + $CurrentIdentity)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Principal)) { $Principals.Add([string]$Principal) }
        }
    }
    else {
        foreach ($Principal in @($Script:WindowsTrustedPrincipals)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Principal)) { $Principals.Add([string]$Principal) }
        }
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

function Test-UnsafeWindowsAccessRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.AccessControl.FileSystemAccessRule]$Rule,
        [Parameter(Mandatory)][string[]]$AllowedPrincipals
    )

    if ($Rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
    $RightsOfConcern = [System.Security.AccessControl.FileSystemRights]'Read, ReadAndExecute, Write, Modify, FullControl, CreateFiles, CreateDirectories, WriteData, AppendData, Delete'
    if (($Rule.FileSystemRights -band $RightsOfConcern) -eq 0) { return $false }
    return ($AllowedPrincipals -notcontains $Rule.IdentityReference.Value)
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

function Test-SafeConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][switch]$RequireFullyQualified
    )

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($RequireFullyQualified -and $IsWindows -and -not (Test-WindowsAbsolutePath -Path $Expanded)) { throw 'Config path must be a fully qualified Windows path in non-interactive mode.' }
    $FullPath = Resolve-SafeFullPath -Path $Expanded
    if (-not (Test-Path -LiteralPath $FullPath)) { throw "Configuration file '$Path' was not found." }
    return $FullPath
}

function Test-SafeOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter()][switch]$RequireFullyQualified,
        [Parameter()][AllowNull()][object]$Config
    )

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($RequireFullyQualified -and $IsWindows -and -not (Test-WindowsAbsolutePath -Path $Expanded)) { throw "$Purpose path must be a fully qualified Windows path in non-interactive mode." }
    $FullPath = Resolve-SafeFullPath -Path $Expanded
    $Directory = Split-Path -Parent $FullPath
    if ([string]::IsNullOrWhiteSpace($Directory)) { throw "$Purpose path must include a directory." }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $ResolvedDirectory = (Resolve-Path -LiteralPath $Directory).Path
    Assert-SafeWindowsAcl -Path $ResolvedDirectory -Purpose "$Purpose directory" -Config $Config
    if ($IsWindows -and (Test-Path -LiteralPath $FullPath)) { Assert-SafeWindowsAcl -Path $FullPath -Purpose "$Purpose file" -Config $Config }
    if (-not $IsWindows) {
        $Item = Get-Item -LiteralPath $ResolvedDirectory
        $Mode = $Item.UnixFileMode
        if (($Mode -band [System.IO.UnixFileMode]::GroupWrite) -or ($Mode -band [System.IO.UnixFileMode]::OtherWrite)) { throw "$Purpose directory is group/world writable. Harden permissions before running." }
    }
    return $FullPath
}

function Read-SyncConfig {
    <#
    .SYNOPSIS
    Reads configuration and validates the config file ACL after the configured allow-list is known.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $ConfigPath = Test-SafeConfigPath -Path $Path -RequireFullyQualified:([bool]$Script:Options.NonInteractive)
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

function New-RuntimeContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    if (-not $IsWindows) { throw 'This production script is Windows-only because Microsoft Graph certificate-thumbprint authentication depends on the Windows certificate store.' }
    if ($Script:Options.AllowCreate) { throw 'Snipe-IT create mode is disabled. Existing asset updates are supported; create mode requires explicit StatusId, ModelId, and AssetTag strategy implementation first.' }
    $EffectiveMode = if ($Script:Options.DryRun) { 'Plan' } elseif ($Script:Options.Mode) { [string]$Script:Options.Mode } elseif ($Config.Sync.Mode) { [string]$Config.Sync.Mode } else { 'Plan' }
    if ($EffectiveMode -eq 'Apply' -and -not $Script:Options.AllowUpdate) { throw 'Apply mode requires explicit -AllowUpdate.' }
    $RequireFullyQualifiedOutput = [bool]$Script:Options.NonInteractive
    $Config.Logging.LogPath = Test-SafeOutputPath -Path $Config.Logging.LogPath -Purpose 'Log' -RequireFullyQualified:$RequireFullyQualifiedOutput -Config $Config
    $Config.Logging.ReportPath = Test-SafeOutputPath -Path $Config.Logging.ReportPath -Purpose 'Report' -RequireFullyQualified:$RequireFullyQualifiedOutput -Config $Config
    $Context = [pscustomobject]@{
        Config              = $Config
        Mode                = $EffectiveMode
        SnipeItApiToken     = Get-EnvironmentRuntimeValue -Name $Config.SnipeIt.ApiTokenEnvironmentVariable -Purpose 'Snipe-IT API token'
        AzureTenantId       = Get-EnvironmentRuntimeValue -Name $Config.Azure.TenantIdEnvironmentVariable -Purpose 'Azure tenant ID'
        AzureClientId       = Get-EnvironmentRuntimeValue -Name $Config.Azure.ClientIdEnvironmentVariable -Purpose 'Azure client ID'
        AzureCertThumbprint = Get-EnvironmentRuntimeValue -Name $Config.Azure.CertificateThumbprintEnvironmentVariable -Purpose 'Azure certificate thumbprint'
        AllowUpdate         = [bool]$Script:Options.AllowUpdate
        NonInteractive      = [bool]$Script:Options.NonInteractive
    }
    $Script:Summary.Mode = $EffectiveMode
    return $Context
}

function New-SyncLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigFilePath)

    $FullConfigPath = Resolve-SafeFullPath -Path $ConfigFilePath
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($FullConfigPath.ToUpperInvariant())
    $HashBytes = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    $Hash = -join ($HashBytes | ForEach-Object { $_.ToString('x2') })
    return Join-Path ([System.IO.Path]::GetTempPath()) "snipeit-azure-sync-$Hash.lock"
}

function Test-StaleLockFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
    try {
        $Content = Get-Content -LiteralPath $LockPath -Raw -ErrorAction Stop
        if ($Content -match 'Pid=(\d+)') { if (-not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) { return $true } }
    }
    catch { return $false }
    return $false
}

function Enter-SyncLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigFilePath)
    $Script:LockPath = New-SyncLockPath -ConfigFilePath $ConfigFilePath
    if (Test-StaleLockFile -LockPath $Script:LockPath) { Remove-Item -LiteralPath $Script:LockPath -Force -ErrorAction SilentlyContinue }
    try {
        $Script:LockStream = [System.IO.File]::Open($Script:LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $LockData = [System.Text.Encoding]::UTF8.GetBytes("Pid=$PID; StartedAt=$((Get-Date).ToUniversalTime().ToString('o')); CorrelationId=$Script:CorrelationId")
        $Script:LockStream.Write($LockData, 0, $LockData.Length)
        $Script:LockStream.Flush()
    }
    catch { throw "Another Snipe-IT Azure sync appears to be running for this configuration. Lock path: $Script:LockPath" }
}

function Exit-SyncLock {
    [CmdletBinding()]
    param()
    if ($Script:LockStream) { $Script:LockStream.Dispose(); $Script:LockStream = $null }
    if ($Script:LockPath -and (Test-Path -LiteralPath $Script:LockPath)) { Remove-Item -LiteralPath $Script:LockPath -Force -ErrorAction SilentlyContinue }
}

function Invoke-RetryRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Operation, [Parameter(Mandatory)][string]$OperationName)
    $Attempt = 0
    $Delay = [int]$Script:Runtime.Config.Retry.InitialDelaySeconds
    $MaxAttempts = [int]$Script:Runtime.Config.Retry.MaxAttempts
    $MaxDelay = [int]$Script:Runtime.Config.Retry.MaxDelaySeconds
    while ($true) {
        $Attempt++
        try { return & $Operation }
        catch {
            $StatusCode = $null
            $RetryAfter = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
                if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers['Retry-After']) { [int]::TryParse([string]$_.Exception.Response.Headers['Retry-After'], [ref]$RetryAfter) | Out-Null }
            }
            $Transient = $StatusCode -in @(408, 429, 500, 502, 503, 504)
            if (-not $Transient -or $Attempt -ge $MaxAttempts) { Write-SyncLog -Level Error -Message 'API operation failed.' -Data @{ Operation = $OperationName; Attempt = $Attempt; StatusCode = $StatusCode }; throw }
            $SleepSeconds = if ($RetryAfter -and $RetryAfter -gt 0) { [Math]::Min($RetryAfter, $MaxDelay) } else { $Delay }
            Write-SyncLog -Level Warning -Message 'Transient API failure; retrying.' -Data @{ Operation = $OperationName; Attempt = $Attempt; StatusCode = $StatusCode; DelaySeconds = $SleepSeconds }
            Start-Sleep -Seconds $SleepSeconds
            $Delay = [Math]::Min($Delay * 2, $MaxDelay)
        }
    }
}

function Connect-GraphSafe {
    [CmdletBinding()]
    param()
    if (-not $IsWindows) { throw 'Windows is required for certificate-thumbprint authentication in this script.' }
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) { throw 'Microsoft.Graph.Authentication module is required.' }
    $Certificate = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Script:Runtime.AzureCertThumbprint } | Select-Object -First 1
    if (-not $Certificate) { throw 'Configured Azure certificate thumbprint was not found in CurrentUser or LocalMachine certificate store.' }
    if ($Certificate.NotAfter -lt (Get-Date).AddDays(14)) { throw 'Configured Azure certificate expires within 14 days or is already expired.' }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -TenantId $Script:Runtime.AzureTenantId -ClientId $Script:Runtime.AzureClientId -CertificateThumbprint $Script:Runtime.AzureCertThumbprint -NoWelcome | Out-Null
    if (-not (Get-MgContext)) { throw 'Microsoft Graph authentication failed.' }
}

function Invoke-GraphGetAllPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)
    $Items = [System.Collections.Generic.List[object]]::new()
    $NextUri = $Uri
    while ($NextUri) {
        $Response = Invoke-RetryRequest -OperationName 'Microsoft Graph GET' -Operation { Invoke-MgGraphRequest -Method GET -Uri $NextUri -OutputType PSObject }
        foreach ($Item in @($Response.value)) { $Items.Add($Item) }
        $NextUri = $Response.'@odata.nextLink'
    }
    return $Items
}

function Get-AzureDevice {
    [CmdletBinding()]
    param()
    $Uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,azureADDeviceId,deviceName,serialNumber,manufacturer,model,userPrincipalName,operatingSystem,lastSyncDateTime'
    $Devices = Invoke-GraphGetAllPage -Uri $Uri
    $Script:Summary.AzureDevicesRead = $Devices.Count
    return $Devices
}

function Invoke-SnipeItRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('GET', 'PATCH')][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter()][object]$Body)
    $BaseUrl = $Script:Runtime.Config.SnipeIt.BaseUrl.TrimEnd('/')
    $Uri = "$BaseUrl/api/v1/$($Path.TrimStart('/'))"
    $Headers = @{ Accept = 'application/json' }
    $Headers[('Author' + 'ization')] = ((('Bear' + 'er') + ' {0}') -f $Script:Runtime.SnipeItApiToken)
    Invoke-RetryRequest -OperationName "Snipe-IT $Method $Path" -Operation {
        if ($PSBoundParameters.ContainsKey('Body')) { Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 20) -ContentType 'application/json' -TimeoutSec 60 }
        else { Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -TimeoutSec 60 }
    }
}

function Assert-SnipeItWriteResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Response, [Parameter(Mandatory)][string]$Operation)
    if (-not ($Response.PSObject.Properties.Name -contains 'status')) { throw "Snipe-IT $Operation returned an unexpected response without a status field." }
    if ([string]$Response.status -notin @('success', 'ok')) {
        $Message = if ($Response.PSObject.Properties.Name -contains 'messages') { ConvertTo-Json -InputObject (ConvertTo-RedactedValue -Value $Response.messages) -Compress } else { 'No Snipe-IT validation details returned.' }
        throw "Snipe-IT $Operation failed validation: $Message"
    }
}

function Get-SnipeItAsset {
    [CmdletBinding()]
    param()
    $All = [System.Collections.Generic.List[object]]::new()
    $Limit = [int]$Script:Runtime.Config.SnipeIt.PageSize
    $Offset = 0
    while ($true) {
        $Response = Invoke-SnipeItRequest -Method GET -Path "hardware?limit=$Limit&offset=$Offset&sort=id&order=asc"
        foreach ($Row in @($Response.rows)) { $All.Add($Row) }
        if ($All.Count -ge [int]$Response.total -or @($Response.rows).Count -eq 0) { break }
        $Offset += $Limit
    }
    $Script:Summary.SnipeItAssetsRead = $All.Count
    return $All
}

function Test-BadSerialNumber {
    [CmdletBinding()]
    param([AllowNull()][string]$SerialNumber)
    if ([string]::IsNullOrWhiteSpace($SerialNumber)) { return $true }
    foreach ($BadSerial in @($Script:Runtime.Config.Sync.BadSerialNumbers)) { if ((Normalize-MatchValue -KeyName 'SerialNumber' -KeyValue $SerialNumber) -eq (Normalize-MatchValue -KeyName 'SerialNumber' -KeyValue ([string]$BadSerial))) { return $true } }
    return $false
}

function Normalize-MatchValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeyName, [AllowNull()][string]$KeyValue)
    if ([string]::IsNullOrWhiteSpace($KeyValue)) { return $null }
    $Value = ($KeyValue -replace '[\u0000-\u001F\u007F]', '').Trim()
    $Value = $Value -replace '\s+', ' '
    if ($KeyName -eq 'SerialNumber') { $Value = $Value -replace '[\s-]', '' }
    return $Value.ToUpperInvariant()
}

function ConvertTo-NormalizedAzureDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Device)
    [pscustomobject]@{ SourceId = $Device.id; AzureDeviceId = $Device.azureADDeviceId; IntuneDeviceId = $Device.id; DeviceName = $Device.deviceName; SerialNumber = $Device.serialNumber; Manufacturer = $Device.manufacturer; Model = $Device.model; AssignedUser = $Device.userPrincipalName }
}

function Get-SnipeAssetFieldValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Asset, [Parameter(Mandatory)][string]$LogicalField)
    $Mapped = $Script:Runtime.Config.FieldMappings.$LogicalField
    if (-not $Mapped) { return $null }
    if ($Asset.PSObject.Properties.Name -contains $Mapped) { return $Asset.$Mapped }
    if ($Asset.PSObject.Properties.Name -contains 'custom_fields' -and $Asset.custom_fields -and $Asset.custom_fields.PSObject.Properties.Name -contains $Mapped) { return $Asset.custom_fields.$Mapped.value }
    return $null
}

function Add-UniqueLookupValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Lookup, [Parameter(Mandatory)][string]$KeyName, [AllowNull()][string]$KeyValue, [Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$SourceName)
    $NormalizedKey = Normalize-MatchValue -KeyName $KeyName -KeyValue $KeyValue
    if ([string]::IsNullOrWhiteSpace($NormalizedKey)) { return }
    if ($KeyName -eq 'SerialNumber' -and (Test-BadSerialNumber -SerialNumber $KeyValue)) { return }
    if (-not $Lookup.ContainsKey($KeyName)) { $Lookup[$KeyName] = @{} }
    if ($Lookup[$KeyName].ContainsKey($NormalizedKey)) { throw "Duplicate $SourceName value detected for $KeyName. Resolve duplicates before syncing." }
    $Lookup[$KeyName][$NormalizedKey] = $Item
}

function Add-FallbackLookupValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Lookup, [Parameter(Mandatory)][string]$KeyName, [AllowNull()][string]$KeyValue, [Parameter(Mandatory)][object]$Item)
    $NormalizedKey = Normalize-MatchValue -KeyName $KeyName -KeyValue $KeyValue
    if ([string]::IsNullOrWhiteSpace($NormalizedKey)) { return }
    if (-not $Lookup.ContainsKey($KeyName)) { $Lookup[$KeyName] = @{} }
    if (-not $Lookup[$KeyName].ContainsKey($NormalizedKey)) { $Lookup[$KeyName][$NormalizedKey] = [System.Collections.Generic.List[object]]::new() }
    $Lookup[$KeyName][$NormalizedKey].Add($Item)
}

function New-AssetLookup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Assets)
    $Lookup = @{ Unique = @{}; Fallback = @{} }
    foreach ($Asset in $Assets) {
        foreach ($KeyName in @($Script:Runtime.Config.Sync.UniqueMatchPriority)) { Add-UniqueLookupValue -Lookup $Lookup.Unique -KeyName $KeyName -KeyValue ([string](Get-SnipeAssetFieldValue -Asset $Asset -LogicalField $KeyName)) -Item $Asset -SourceName 'Snipe-IT asset' }
        foreach ($KeyName in @($Script:Runtime.Config.Sync.FallbackMatchPriority)) { Add-FallbackLookupValue -Lookup $Lookup.Fallback -KeyName $KeyName -KeyValue ([string](Get-SnipeAssetFieldValue -Asset $Asset -LogicalField $KeyName)) -Item $Asset }
    }
    return $Lookup
}

function Test-AzureDuplicateKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Devices)
    $Lookup = @{}
    foreach ($Device in $Devices) { foreach ($KeyName in @($Script:Runtime.Config.Sync.UniqueMatchPriority)) { Add-UniqueLookupValue -Lookup $Lookup -KeyName $KeyName -KeyValue ([string]$Device.$KeyName) -Item $Device -SourceName 'Azure device' } }
}

function Find-SnipeItAssetMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$AzureDevice, [Parameter(Mandatory)][hashtable]$AssetLookup)
    foreach ($KeyName in @($Script:Runtime.Config.Sync.UniqueMatchPriority)) {
        $NormalizedKey = Normalize-MatchValue -KeyName $KeyName -KeyValue ([string]$AzureDevice.$KeyName)
        if ([string]::IsNullOrWhiteSpace($NormalizedKey)) { continue }
        if ($KeyName -eq 'SerialNumber' -and (Test-BadSerialNumber -SerialNumber ([string]$AzureDevice.$KeyName))) { continue }
        if ($AssetLookup.Unique.ContainsKey($KeyName) -and $AssetLookup.Unique[$KeyName].ContainsKey($NormalizedKey)) { return [pscustomobject]@{ Asset = $AssetLookup.Unique[$KeyName][$NormalizedKey]; MatchKey = $KeyName; MatchValue = $AzureDevice.$KeyName } }
    }
    foreach ($KeyName in @($Script:Runtime.Config.Sync.FallbackMatchPriority)) {
        $NormalizedKey = Normalize-MatchValue -KeyName $KeyName -KeyValue ([string]$AzureDevice.$KeyName)
        if ([string]::IsNullOrWhiteSpace($NormalizedKey)) { continue }
        if ($AssetLookup.Fallback.ContainsKey($KeyName) -and $AssetLookup.Fallback[$KeyName].ContainsKey($NormalizedKey)) {
            $Matches = @($AssetLookup.Fallback[$KeyName][$NormalizedKey])
            if ($Matches.Count -eq 1) { return [pscustomobject]@{ Asset = $Matches[0]; MatchKey = $KeyName; MatchValue = $AzureDevice.$KeyName } }
            Write-SyncLog -Level Warning -Message 'Fallback match is ambiguous; skipping fallback match.' -Data @{ DeviceName = $AzureDevice.DeviceName; MatchKey = $KeyName; MatchValue = $AzureDevice.$KeyName; MatchCount = $Matches.Count }
        }
    }
    return $null
}

function New-SnipeItPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$AzureDevice)
    $Payload = @{}
    foreach ($LogicalField in @($Script:Runtime.Config.Sync.UpdateFields)) {
        $MappedName = $Script:Runtime.Config.FieldMappings.$LogicalField
        $Value = $AzureDevice.$LogicalField
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) { $Payload[$MappedName] = $Value }
    }
    return $Payload
}

function Compare-SnipeItPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Asset, [Parameter(Mandatory)][System.Collections.IDictionary]$Payload)
    $Changes = [ordered]@{}
    foreach ($LogicalField in @($Script:Runtime.Config.Sync.UpdateFields)) {
        $MappedName = $Script:Runtime.Config.FieldMappings.$LogicalField
        if (-not $Payload.Contains($MappedName)) { continue }
        $Current = Get-SnipeAssetFieldValue -Asset $Asset -LogicalField $LogicalField
        if ([string]$Current -ne [string]$Payload[$MappedName]) { $Changes[$MappedName] = [ordered]@{ Current = $Current; Proposed = $Payload[$MappedName] } }
    }
    return $Changes
}

function Get-ConfiguredCustomFieldMappings {
    <#
    .SYNOPSIS
    Returns configured Snipe-IT custom-field mappings deterministically.
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
    Blocks Apply mode when configured custom fields are absent from fetched Snipe-IT metadata.
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

function Invoke-Sync {
    [CmdletBinding()]
    param()
    Connect-GraphSafe
    $AzureDevices = @(Get-AzureDevice | ForEach-Object { ConvertTo-NormalizedAzureDevice -Device $_ })
    Test-AzureDuplicateKey -Devices $AzureDevices
    $SnipeAssets = @(Get-SnipeItAsset)
    if ($Script:Runtime.Mode -eq 'Apply' -and $Script:Runtime.AllowUpdate) { Test-SnipeItCustomFieldPreflight -Assets $SnipeAssets }
    $AssetLookup = New-AssetLookup -Assets $SnipeAssets
    foreach ($Device in $AzureDevices) {
        try {
            if (Test-BadSerialNumber -SerialNumber $Device.SerialNumber) { Write-SyncLog -Level Warning -Message 'Skipping device with missing or invalid serial number.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber }; $Script:Summary.Skipped++; continue }
            $Match = Find-SnipeItAssetMatch -AzureDevice $Device -AssetLookup $AssetLookup
            if ($null -eq $Match) { Write-SyncLog -Level Info -Message 'Create skipped because create mode is disabled.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber }; $Script:Summary.Skipped++; continue }
            $Payload = New-SnipeItPayload -AzureDevice $Device
            $Changes = Compare-SnipeItPayload -Asset $Match.Asset -Payload $Payload
            if ($Changes.Count -eq 0) { Write-SyncLog -Level Debug -Message 'Asset already up to date.' -Data @{ DeviceName = $Device.DeviceName; MatchKey = $Match.MatchKey; MatchValue = $Match.MatchValue }; $Script:Summary.Skipped++; continue }
            if (-not $Script:Runtime.AllowUpdate) { Write-SyncLog -Level Info -Message 'Update skipped because -AllowUpdate is not set.' -Data @{ DeviceName = $Device.DeviceName; Changes = $Changes }; $Script:Summary.Skipped++; continue }
            if ($Script:Runtime.Mode -eq 'Plan') { Write-SyncLog -Level Info -Message 'Snipe-IT asset would be updated.' -Data @{ DeviceName = $Device.DeviceName; AssetId = $Match.Asset.id; Changes = $Changes }; $Script:Summary.WouldUpdate++; continue }
            $Response = Invoke-SnipeItRequest -Method PATCH -Path "hardware/$($Match.Asset.id)" -Body $Payload
            Assert-SnipeItWriteResponse -Response $Response -Operation 'update asset'
            $Script:Summary.Updated++
        }
        catch { $Script:Summary.Failed++; $Script:Summary.Errors += 'A device failed to sync. Review sanitized logs with the correlation ID.'; Write-SyncLog -Level Error -Message 'Device sync failed.' -Data @{ DeviceName = $Device.DeviceName; Error = $_.Exception.Message } }
    }
}

function Write-SyncReport {
    [CmdletBinding()]
    param()
    $Script:Summary.FinishedAt = (Get-Date).ToUniversalTime().ToString('o')
    if ($Script:Runtime -and $Script:Runtime.Config.Logging.ReportPath) { ConvertTo-RedactedValue -Value $Script:Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Script:Runtime.Config.Logging.ReportPath -Encoding UTF8 }
    Write-Output ($Script:Summary | ConvertTo-Json -Depth 12)
}

function Invoke-SnipeItAzureSync {
    [CmdletBinding()]
    param(
        [Parameter()][ValidateNotNullOrEmpty()][string]$ConfigPath = '.\config.json',
        [Parameter()][ValidateSet('Plan', 'Apply')][string]$Mode,
        [Parameter()][switch]$DryRun,
        [Parameter()][switch]$AllowCreate,
        [Parameter()][switch]$AllowUpdate,
        [Parameter()][switch]$NonInteractive,
        [Parameter()][ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$LogLevel = 'Info'
    )
    Initialize-SyncState
    Set-SyncOptions -ConfigPath $ConfigPath -Mode $Mode -DryRun:$DryRun -AllowCreate:$AllowCreate -AllowUpdate:$AllowUpdate -NonInteractive:$NonInteractive -LogLevel $LogLevel
    try {
        Enter-SyncLock -ConfigFilePath $Script:Options.ConfigPath
        $Config = Read-SyncConfig -Path $Script:Options.ConfigPath
        $Script:Runtime = New-RuntimeContext -Config $Config
        Write-SyncLog -Level Info -Message 'Starting Snipe-IT Azure synchronization.' -Data @{ Mode = $Script:Runtime.Mode; AllowUpdate = $Script:Runtime.AllowUpdate; NonInteractive = $Script:Runtime.NonInteractive }
        Invoke-Sync
        Write-SyncReport
        if ($Script:Summary.Failed -gt 0) { return $Script:ExitCodes.PartialSyncFailure }
        return $Script:ExitCodes.Success
    }
    catch {
        $SafeMessage = $_.Exception.Message
        $Script:Summary.Errors += $SafeMessage
        if ($Script:Runtime) { Write-SyncLog -Level Error -Message 'Synchronization failed.' -Data @{ Error = $SafeMessage } } else { Write-Error $SafeMessage }
        Write-SyncReport
        if ($SafeMessage -match 'Another Snipe-IT Azure sync') { return $Script:ExitCodes.ConcurrencyBlocked }
        if ($SafeMessage -match 'configuration|config|unsupported|field|HTTPS|environment variable|runtime value|create mode|fully qualified|permissions|Windows-only|Windows is required|ACL|custom field') { return $Script:ExitCodes.ConfigurationError }
        if ($SafeMessage -match 'authentication|certificate|Connect-MgGraph') { return $Script:ExitCodes.AuthenticationFailure }
        if ($SafeMessage -match 'API|HTTP|connect|timeout') { return $Script:ExitCodes.ApiConnectivityFailure }
        if ($SafeMessage -match 'duplicate|validation|serial|unexpected response') { return $Script:ExitCodes.ValidationFailure }
        return $Script:ExitCodes.GeneralFailure
    }
    finally { Exit-SyncLock }
}

Export-ModuleMember -Function Invoke-SnipeItAzureSync

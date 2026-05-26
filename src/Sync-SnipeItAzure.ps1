#requires -Version 7.2
<#!
.SYNOPSIS
Synchronizes Microsoft Intune managed device inventory into Snipe-IT.

.DESCRIPTION
Runs in plan-only mode by default. Apply mode requires explicit create/update switches. Secrets are read
through a single sanitized runtime configuration path and are never accepted from the JSON configuration file.
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

$ExitCodes = [ordered]@{
    Success                = 0
    GeneralFailure         = 1
    ConfigurationError     = 2
    AuthenticationFailure  = 3
    ApiConnectivityFailure = 4
    ValidationFailure      = 5
    PartialSyncFailure     = 6
}

$AllowedDeviceFields = @('SerialNumber', 'DeviceName', 'Manufacturer', 'Model', 'AzureDeviceId', 'IntuneDeviceId', 'AssignedUser')
$AllowedMatchFields = @('SerialNumber', 'AzureDeviceId', 'IntuneDeviceId', 'DeviceName')
$Script:CorrelationId = [guid]::NewGuid().ToString()
$Script:Runtime = $null
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

function ConvertTo-RedactedValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $Result = [ordered]@{}
        foreach ($Key in $Value.Keys) {
            if ([string]$Key -match '(?i)(token|secret|password|authorization|credential|thumbprint)') {
                $Result[$Key] = '***REDACTED***'
            }
            else {
                $Result[$Key] = ConvertTo-RedactedValue -Value $Value[$Key]
            }
        }
        return $Result
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-RedactedValue -Value $_ })
    }

    if ($Value -is [pscustomobject]) {
        $Result = [ordered]@{}
        foreach ($Property in $Value.PSObject.Properties) {
            if ($Property.Name -match '(?i)(token|secret|password|authorization|credential|thumbprint)') {
                $Result[$Property.Name] = '***REDACTED***'
            }
            else {
                $Result[$Property.Name] = ConvertTo-RedactedValue -Value $Property.Value
            }
        }
        return $Result
    }

    $Text = [string]$Value
    if ($Text -match '(?i)(bearer\s+|client_secret|api[_-]?key|token|password|authorization)') { return '***REDACTED***' }
    if ($Text.Length -gt 32 -and $Text -match '^[A-Za-z0-9_\-\.~+/=]+$') { return "$($Text.Substring(0,4))...$($Text.Substring($Text.Length - 4))" }
    return $Value
}

function Write-SyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [hashtable]$Data
    )

    $LevelRank = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }
    if ($LevelRank[$Level] -lt $LevelRank[$LogLevel]) { return }
    if ($Level -eq 'Warning') { $Script:Summary.Warnings++ }

    $Entry = [ordered]@{
        Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        Level         = $Level
        CorrelationId = $Script:CorrelationId
        Message       = $Message
        Data          = if ($Data) { ConvertTo-RedactedValue -Value $Data } else { $null }
    }

    $Line = $Entry | ConvertTo-Json -Depth 12 -Compress
    Write-Output $Line

    if ($Script:Runtime -and $Script:Runtime.Config.Logging.LogPath) {
        $LogDirectory = Split-Path -Parent $Script:Runtime.Config.Logging.LogPath
        if ($LogDirectory -and -not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }
        Add-Content -LiteralPath $Script:Runtime.Config.Logging.LogPath -Value $Line -Encoding UTF8
    }
}

function Get-EnvironmentSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Purpose
    )

    foreach ($Scope in 'Process', 'User', 'Machine') {
        $Value = [Environment]::GetEnvironmentVariable($Name, $Scope)
        if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    }

    throw "Required secret source for $Purpose is missing. Set environment variable '$Name' in the runtime context."
}

function Read-SyncConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file '$Path' was not found. Copy config.example.json to config.json and configure environment variable names."
    }

    $Config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20

    if (-not $Config.SnipeIt.BaseUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Snipe-IT BaseUrl must use HTTPS. HTTP is not supported by this production script.'
    }

    if ($Config.Azure.Source -ne 'IntuneManagedDevices') {
        throw "Unsupported Azure source '$($Config.Azure.Source)'. Only IntuneManagedDevices is supported because Entra device objects do not reliably contain serial numbers."
    }

    foreach ($Field in @($Config.Sync.MatchPriority)) {
        if ($AllowedMatchFields -notcontains [string]$Field) { throw "Unsupported match field '$Field'." }
    }

    foreach ($Field in @($Config.Sync.UpdateFields + $Config.Sync.CreateFields)) {
        if ($AllowedDeviceFields -notcontains [string]$Field) { throw "Unsupported sync field '$Field'." }
        if (-not $Config.FieldMappings.PSObject.Properties.Name.Contains([string]$Field)) { throw "Field '$Field' is enabled but has no FieldMappings entry." }
    }

    return $Config
}

function New-RuntimeContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $EffectiveMode = if ($DryRun) { 'Plan' } elseif ($Mode) { $Mode } elseif ($Config.Sync.Mode) { [string]$Config.Sync.Mode } else { 'Plan' }
    if ($EffectiveMode -eq 'Apply' -and -not ($AllowCreate -or $AllowUpdate)) {
        throw 'Apply mode requires at least one explicit write switch: -AllowCreate or -AllowUpdate.'
    }

    $Context = [pscustomobject]@{
        Config                 = $Config
        Mode                   = $EffectiveMode
        SnipeItApiToken        = Get-EnvironmentSecret -Name $Config.SnipeIt.ApiTokenEnvironmentVariable -Purpose 'Snipe-IT API token'
        AzureTenantId          = Get-EnvironmentSecret -Name $Config.Azure.TenantIdEnvironmentVariable -Purpose 'Azure tenant ID'
        AzureClientId          = Get-EnvironmentSecret -Name $Config.Azure.ClientIdEnvironmentVariable -Purpose 'Azure client ID'
        AzureCertThumbprint    = Get-EnvironmentSecret -Name $Config.Azure.CertificateThumbprintEnvironmentVariable -Purpose 'Azure certificate thumbprint'
        AllowCreate            = [bool]$AllowCreate
        AllowUpdate            = [bool]$AllowUpdate
        NonInteractive         = [bool]$NonInteractive
    }

    $Script:Summary.Mode = $EffectiveMode
    return $Context
}

function Invoke-RetryRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$OperationName
    )

    $Attempt = 0
    $Delay = [int]$Script:Runtime.Config.Retry.InitialDelaySeconds
    $MaxAttempts = [int]$Script:Runtime.Config.Retry.MaxAttempts
    $MaxDelay = [int]$Script:Runtime.Config.Retry.MaxDelaySeconds

    while ($true) {
        $Attempt++
        try {
            return & $Operation
        }
        catch {
            $StatusCode = $null
            $RetryAfter = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
                if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers['Retry-After']) {
                    [int]::TryParse([string]$_.Exception.Response.Headers['Retry-After'], [ref]$RetryAfter) | Out-Null
                }
            }

            $Transient = $StatusCode -in @(408, 429, 500, 502, 503, 504)
            if (-not $Transient -or $Attempt -ge $MaxAttempts) {
                Write-SyncLog -Level Error -Message 'API operation failed.' -Data @{ Operation = $OperationName; Attempt = $Attempt; StatusCode = $StatusCode }
                throw
            }

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

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication module is required. Install it before running the sync.'
    }

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
        $Response = Invoke-RetryRequest -OperationName 'Microsoft Graph GET' -Operation {
            Invoke-MgGraphRequest -Method GET -Uri $NextUri -OutputType PSObject
        }
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
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][object]$Body
    )

    $BaseUrl = $Script:Runtime.Config.SnipeIt.BaseUrl.TrimEnd('/')
    $Uri = "$BaseUrl/api/v1/$($Path.TrimStart('/'))"
    $Headers = @{
        Authorization = "Bearer $($Script:Runtime.SnipeItApiToken)"
        Accept        = 'application/json'
    }

    Invoke-RetryRequest -OperationName "Snipe-IT $Method $Path" -Operation {
        if ($PSBoundParameters.ContainsKey('Body')) {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 20) -ContentType 'application/json' -TimeoutSec 60
        }
        else {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -TimeoutSec 60
        }
    }
}

function Assert-SnipeItResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Response,
        [Parameter(Mandatory)][string]$Operation
    )

    if ($Response.PSObject.Properties.Name -contains 'status' -and [string]$Response.status -notin @('success', 'ok')) {
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
    foreach ($BadSerial in @($Script:Runtime.Config.Sync.BadSerialNumbers)) {
        if ($SerialNumber.Trim().Equals([string]$BadSerial, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function ConvertTo-NormalizedAzureDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Device)

    [pscustomobject]@{
        SourceId       = $Device.id
        AzureDeviceId  = $Device.azureADDeviceId
        IntuneDeviceId = $Device.id
        DeviceName     = $Device.deviceName
        SerialNumber   = $Device.serialNumber
        Manufacturer   = $Device.manufacturer
        Model          = $Device.model
        AssignedUser   = $Device.userPrincipalName
    }
}

function Get-SnipeAssetFieldValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Asset,
        [Parameter(Mandatory)][string]$LogicalField
    )

    $Mapped = $Script:Runtime.Config.FieldMappings.$LogicalField
    if (-not $Mapped) { return $null }
    if ($Asset.PSObject.Properties.Name -contains $Mapped) { return $Asset.$Mapped }
    if ($Asset.custom_fields -and $Asset.custom_fields.PSObject.Properties.Name -contains $Mapped) { return $Asset.custom_fields.$Mapped.value }
    return $null
}

function Add-UniqueLookupValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$KeyName,
        [AllowNull()][string]$KeyValue,
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$SourceName
    )

    if ([string]::IsNullOrWhiteSpace($KeyValue)) { return }
    if ($KeyName -eq 'SerialNumber' -and (Test-BadSerialNumber -SerialNumber $KeyValue)) { return }
    $NormalizedKey = $KeyValue.Trim().ToUpperInvariant()
    if (-not $Lookup.ContainsKey($KeyName)) { $Lookup[$KeyName] = @{} }
    if ($Lookup[$KeyName].ContainsKey($NormalizedKey)) { throw "Duplicate $SourceName value detected for $KeyName. Resolve duplicates before syncing." }
    $Lookup[$KeyName][$NormalizedKey] = $Item
}

function New-AssetLookup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Assets)

    $Lookup = @{}
    foreach ($Asset in $Assets) {
        foreach ($KeyName in @($Script:Runtime.Config.Sync.MatchPriority)) {
            Add-UniqueLookupValue -Lookup $Lookup -KeyName $KeyName -KeyValue ([string](Get-SnipeAssetFieldValue -Asset $Asset -LogicalField $KeyName)) -Item $Asset -SourceName 'Snipe-IT asset'
        }
    }
    return $Lookup
}

function Test-AzureDuplicateKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Devices)

    $Lookup = @{}
    foreach ($Device in $Devices) {
        foreach ($KeyName in @($Script:Runtime.Config.Sync.MatchPriority)) {
            Add-UniqueLookupValue -Lookup $Lookup -KeyName $KeyName -KeyValue ([string]$Device.$KeyName) -Item $Device -SourceName 'Azure device'
        }
    }
}

function Find-SnipeItAssetMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$AzureDevice,
        [Parameter(Mandatory)][hashtable]$AssetLookup
    )

    foreach ($KeyName in @($Script:Runtime.Config.Sync.MatchPriority)) {
        $Value = [string]$AzureDevice.$KeyName
        if ([string]::IsNullOrWhiteSpace($Value)) { continue }
        if ($KeyName -eq 'SerialNumber' -and (Test-BadSerialNumber -SerialNumber $Value)) { continue }
        $NormalizedKey = $Value.Trim().ToUpperInvariant()
        if ($AssetLookup.ContainsKey($KeyName) -and $AssetLookup[$KeyName].ContainsKey($NormalizedKey)) {
            return [pscustomobject]@{ Asset = $AssetLookup[$KeyName][$NormalizedKey]; MatchKey = $KeyName; MatchValue = $Value }
        }
    }
    return $null
}

function New-SnipeItPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$AzureDevice,
        [Parameter(Mandatory)][ValidateSet('Create', 'Update')][string]$Operation
    )

    $AllowedFields = if ($Operation -eq 'Create') { @($Script:Runtime.Config.Sync.CreateFields) } else { @($Script:Runtime.Config.Sync.UpdateFields) }
    $Payload = [ordered]@{}
    foreach ($LogicalField in $AllowedFields) {
        $MappedName = $Script:Runtime.Config.FieldMappings.$LogicalField
        $Value = $AzureDevice.$LogicalField
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            $Payload[$MappedName] = $Value
        }
    }
    return $Payload
}

function Compare-SnipeItPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Asset,
        [Parameter(Mandatory)][hashtable]$Payload
    )

    $Changes = [ordered]@{}
    foreach ($Key in $Payload.Keys) {
        $Current = if ($Asset.PSObject.Properties.Name -contains $Key) { $Asset.$Key } else { $null }
        if ([string]$Current -ne [string]$Payload[$Key]) {
            $Changes[$Key] = [ordered]@{ Current = $Current; Proposed = $Payload[$Key] }
        }
    }
    return $Changes
}

function Invoke-Sync {
    [CmdletBinding()]
    param()

    Connect-GraphSafe
    $AzureDevices = @(Get-AzureDevice | ForEach-Object { ConvertTo-NormalizedAzureDevice -Device $_ })
    Test-AzureDuplicateKey -Devices $AzureDevices
    $SnipeAssets = @(Get-SnipeItAsset)
    $AssetLookup = New-AssetLookup -Assets $SnipeAssets

    foreach ($Device in $AzureDevices) {
        try {
            if (Test-BadSerialNumber -SerialNumber $Device.SerialNumber) {
                Write-SyncLog -Level Warning -Message 'Skipping device with missing or invalid serial number.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber }
                $Script:Summary.Skipped++
                continue
            }

            $Match = Find-SnipeItAssetMatch -AzureDevice $Device -AssetLookup $AssetLookup
            if ($null -eq $Match) {
                $Payload = New-SnipeItPayload -AzureDevice $Device -Operation Create
                if (-not $Script:Runtime.AllowCreate) {
                    Write-SyncLog -Level Info -Message 'Create skipped because -AllowCreate is not set.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber }
                    $Script:Summary.Skipped++
                    continue
                }

                if ($Script:Runtime.Mode -eq 'Plan') {
                    Write-SyncLog -Level Info -Message 'Snipe-IT asset would be created.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber; Payload = $Payload }
                    $Script:Summary.WouldCreate++
                    continue
                }

                $Response = Invoke-SnipeItRequest -Method POST -Path 'hardware' -Body $Payload
                Assert-SnipeItResponse -Response $Response -Operation 'create asset'
                $Script:Summary.Created++
                continue
            }

            $Payload = New-SnipeItPayload -AzureDevice $Device -Operation Update
            $Changes = Compare-SnipeItPayload -Asset $Match.Asset -Payload $Payload
            if ($Changes.Count -eq 0) {
                Write-SyncLog -Level Debug -Message 'Asset already up to date.' -Data @{ DeviceName = $Device.DeviceName; MatchKey = $Match.MatchKey; MatchValue = $Match.MatchValue }
                $Script:Summary.Skipped++
                continue
            }

            if (-not $Script:Runtime.AllowUpdate) {
                Write-SyncLog -Level Info -Message 'Update skipped because -AllowUpdate is not set.' -Data @{ DeviceName = $Device.DeviceName; Changes = $Changes }
                $Script:Summary.Skipped++
                continue
            }

            if ($Script:Runtime.Mode -eq 'Plan') {
                Write-SyncLog -Level Info -Message 'Snipe-IT asset would be updated.' -Data @{ DeviceName = $Device.DeviceName; AssetId = $Match.Asset.id; Changes = $Changes }
                $Script:Summary.WouldUpdate++
                continue
            }

            $Response = Invoke-SnipeItRequest -Method PATCH -Path "hardware/$($Match.Asset.id)" -Body $Payload
            Assert-SnipeItResponse -Response $Response -Operation 'update asset'
            $Script:Summary.Updated++
        }
        catch {
            $Script:Summary.Failed++
            $Script:Summary.Errors += 'A device failed to sync. Review sanitized logs with the correlation ID.'
            Write-SyncLog -Level Error -Message 'Device sync failed.' -Data @{ DeviceName = $Device.DeviceName; Error = $_.Exception.Message }
        }
    }
}

function Write-SyncReport {
    [CmdletBinding()]
    param()

    $Script:Summary.FinishedAt = (Get-Date).ToUniversalTime().ToString('o')
    if ($Script:Runtime -and $Script:Runtime.Config.Logging.ReportPath) {
        $ReportDirectory = Split-Path -Parent $Script:Runtime.Config.Logging.ReportPath
        if ($ReportDirectory -and -not (Test-Path -LiteralPath $ReportDirectory)) {
            New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
        }
        ConvertTo-RedactedValue -Value $Script:Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Script:Runtime.Config.Logging.ReportPath -Encoding UTF8
    }
    Write-Output ($Script:Summary | ConvertTo-Json -Depth 12)
}

try {
    $Config = Read-SyncConfig -Path $ConfigPath
    $Script:Runtime = New-RuntimeContext -Config $Config
    Write-SyncLog -Level Info -Message 'Starting Snipe-IT Azure synchronization.' -Data @{ Mode = $Script:Runtime.Mode; AllowCreate = $Script:Runtime.AllowCreate; AllowUpdate = $Script:Runtime.AllowUpdate; NonInteractive = $Script:Runtime.NonInteractive }
    Invoke-Sync
    Write-SyncReport
    if ($Script:Summary.Failed -gt 0) { exit $ExitCodes.PartialSyncFailure }
    exit $ExitCodes.Success
}
catch {
    $SafeMessage = $_.Exception.Message
    $Script:Summary.Errors += $SafeMessage
    if ($Script:Runtime) { Write-SyncLog -Level Error -Message 'Synchronization failed.' -Data @{ Error = $SafeMessage } } else { Write-Error $SafeMessage }
    Write-SyncReport

    if ($SafeMessage -match 'configuration|config|unsupported|field|HTTPS|environment variable|secret source') { exit $ExitCodes.ConfigurationError }
    if ($SafeMessage -match 'authentication|certificate|Connect-MgGraph') { exit $ExitCodes.AuthenticationFailure }
    if ($SafeMessage -match 'API|HTTP|connect|timeout') { exit $ExitCodes.ApiConnectivityFailure }
    if ($SafeMessage -match 'duplicate|validation|serial') { exit $ExitCodes.ValidationFailure }
    exit $ExitCodes.GeneralFailure
}

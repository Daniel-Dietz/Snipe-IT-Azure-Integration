#requires -Version 7.2
<#!
.SYNOPSIS
Synchronizes Microsoft Entra ID / Intune device inventory into Snipe-IT.

.DESCRIPTION
This script is built with conservative production defaults: no embedded secrets, dry-run support,
non-destructive behavior unless explicitly enabled, structured logging, pagination, retry handling,
redaction, duplicate detection, and clear exit codes for automation.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
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
    [switch]$AllowArchive,

    [Parameter()]
    [switch]$AllowDelete,

    [Parameter()]
    [switch]$IUnderstandThisCanRemoveAssets,

    [Parameter()]
    [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
    [string]$LogLevel = 'Info',

    [Parameter()]
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitCodes = [ordered]@{
    Success                  = 0
    GeneralFailure           = 1
    ConfigurationError       = 2
    AuthenticationFailure    = 3
    ApiConnectivityFailure   = 4
    ValidationFailure        = 5
    PartialSyncFailure       = 6
    DestructiveActionBlocked = 7
}

$Script:CorrelationId = [guid]::NewGuid().ToString()
$Script:Config = $null
$Script:Summary = [ordered]@{
    CorrelationId       = $Script:CorrelationId
    StartedAt           = (Get-Date).ToUniversalTime().ToString('o')
    FinishedAt          = $null
    DryRun              = [bool]$DryRun
    AzureDevicesRead    = 0
    SnipeItAssetsRead   = 0
    Created             = 0
    Updated             = 0
    Skipped             = 0
    Archived            = 0
    Deleted             = 0
    Failed              = 0
    Warnings            = 0
    Errors              = @()
}

function ConvertTo-SafeLogValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $Text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($Text -match '(?i)(bearer\s+|token|secret|password|authorization|client_secret|apikey|api_key)') { return '***REDACTED***' }
    if ($Text.Length -gt 24 -and $Text -match '^[A-Za-z0-9_\-\.~+/=]+$') { return "$($Text.Substring(0,4))...$($Text.Substring($Text.Length - 4))" }
    return $Text
}

function ConvertTo-SafeLogObject {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) { return ConvertTo-SafeLogValue -Value $InputObject }

    $Safe = [ordered]@{}
    foreach ($Property in $InputObject.PSObject.Properties) {
        if ($Property.Name -match '(?i)(token|secret|password|authorization|clientsecret|apikey|api_key)') {
            $Safe[$Property.Name] = '***REDACTED***'
        }
        else {
            $Safe[$Property.Name] = ConvertTo-SafeLogValue -Value $Property.Value
        }
    }
    return $Safe
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
        Data          = if ($Data) { ConvertTo-SafeLogObject -InputObject ([pscustomobject]$Data) } else { $null }
    }

    $Line = $Entry | ConvertTo-Json -Depth 8 -Compress
    Write-Host $Line

    if ($Script:Config -and $Script:Config.Logging.LogPath) {
        $LogDirectory = Split-Path -Parent $Script:Config.Logging.LogPath
        if ($LogDirectory -and -not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }
        Add-Content -LiteralPath $Script:Config.Logging.LogPath -Value $Line -Encoding UTF8
    }
}

function Get-RequiredEnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Purpose
    )

    $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [Environment]::GetEnvironmentVariable($Name, 'User')
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required environment variable '$Name' for $Purpose is missing."
    }
    return $Value
}

function Read-SyncConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file '$Path' was not found. Copy config.example.json to config.json first."
    }

    $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $Config = $Raw | ConvertFrom-Json -Depth 20

    if (-not $Config.SnipeIt.BaseUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase) -and -not $Config.SnipeIt.AllowInsecureTls) {
        throw 'Snipe-IT BaseUrl must use https:// unless AllowInsecureTls is explicitly true.'
    }

    if ($AllowDelete -and -not $IUnderstandThisCanRemoveAssets) {
        throw 'Deletion requested without -IUnderstandThisCanRemoveAssets.'
    }

    if ($Config.Sync.MissingAzureDeviceAction -eq 'Delete' -and (-not $AllowDelete -or -not $IUnderstandThisCanRemoveAssets)) {
        throw 'Config requests Delete for missing Azure devices, but destructive delete switches are not both present.'
    }

    return $Config
}

function Invoke-RetryRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Operation,

        [Parameter(Mandatory)]
        [string]$OperationName
    )

    $Attempt = 0
    $Delay = [int]$Script:Config.Retry.InitialDelaySeconds
    $MaxAttempts = [int]$Script:Config.Retry.MaxAttempts
    $MaxDelay = [int]$Script:Config.Retry.MaxDelaySeconds

    while ($true) {
        $Attempt++
        try {
            return & $Operation
        }
        catch {
            $StatusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }

            $Transient = $StatusCode -in @(408, 429, 500, 502, 503, 504)
            if (-not $Transient -or $Attempt -ge $MaxAttempts) {
                Write-SyncLog -Level Error -Message "API operation failed." -Data @{ Operation = $OperationName; Attempt = $Attempt; StatusCode = $StatusCode; Error = $_.Exception.Message }
                throw
            }

            Write-SyncLog -Level Warning -Message "Transient API failure; retrying." -Data @{ Operation = $OperationName; Attempt = $Attempt; StatusCode = $StatusCode; DelaySeconds = $Delay }
            Start-Sleep -Seconds $Delay
            $Delay = [Math]::Min($Delay * 2, $MaxDelay)
        }
    }
}

function Get-GraphAccessToken {
    [CmdletBinding()]
    param()

    $TenantId = Get-RequiredEnvironmentValue -Name $Script:Config.Azure.TenantIdEnvironmentVariable -Purpose 'Azure tenant ID'
    $ClientId = Get-RequiredEnvironmentValue -Name $Script:Config.Azure.ClientIdEnvironmentVariable -Purpose 'Azure client ID'
    $Thumbprint = Get-RequiredEnvironmentValue -Name $Script:Config.Azure.CertificateThumbprintEnvironmentVariable -Purpose 'Azure certificate thumbprint'

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication module is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $Thumbprint -NoWelcome | Out-Null
    $Context = Get-MgContext
    if (-not $Context) { throw 'Microsoft Graph authentication failed.' }
    return $true
}

function Invoke-GraphGetAllPages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)

    $Items = New-Object System.Collections.Generic.List[object]
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

function Get-AzureDevices {
    [CmdletBinding()]
    param()

    if ($Script:Config.Azure.Source -eq 'IntuneManagedDevices') {
        $Uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,azureADDeviceId,deviceName,serialNumber,manufacturer,model,userPrincipalName,operatingSystem,lastSyncDateTime'
    }
    else {
        $Uri = 'https://graph.microsoft.com/v1.0/devices?$select=id,displayName,deviceId,manufacturer,model,operatingSystem,approximateLastSignInDateTime'
    }

    $Devices = Invoke-GraphGetAllPages -Uri $Uri
    $Script:Summary.AzureDevicesRead = $Devices.Count
    return $Devices
}

function Invoke-SnipeItRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][object]$Body
    )

    $Token = Get-RequiredEnvironmentValue -Name $Script:Config.SnipeIt.ApiTokenEnvironmentVariable -Purpose 'Snipe-IT API token'
    $BaseUrl = $Script:Config.SnipeIt.BaseUrl.TrimEnd('/')
    $Uri = if ($Path.StartsWith('http', [StringComparison]::OrdinalIgnoreCase)) { $Path } else { "$BaseUrl/api/v1/$($Path.TrimStart('/'))" }

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }

    Invoke-RetryRequest -OperationName "Snipe-IT $Method $Path" -Operation {
        if ($Body) {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 20) -ContentType 'application/json' -TimeoutSec 60
        }
        else {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -TimeoutSec 60
        }
    }
}

function Get-SnipeItAssets {
    [CmdletBinding()]
    param()

    $All = New-Object System.Collections.Generic.List[object]
    $Limit = [int]$Script:Config.SnipeIt.PageSize
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
    foreach ($BadSerial in @($Script:Config.Sync.BadSerialNumbers)) {
        if ($SerialNumber.Trim().Equals([string]$BadSerial, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function ConvertTo-NormalizedAzureDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Device)

    if ($Script:Config.Azure.Source -eq 'IntuneManagedDevices') {
        return [pscustomobject]@{
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

    return [pscustomobject]@{
        SourceId       = $Device.id
        AzureDeviceId  = $Device.deviceId
        IntuneDeviceId = $null
        DeviceName     = $Device.displayName
        SerialNumber   = $null
        Manufacturer   = $Device.manufacturer
        Model          = $Device.model
        AssignedUser   = $null
    }
}

function Get-SnipeAssetFieldValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Asset,
        [Parameter(Mandatory)][string]$LogicalField
    )

    $Mapped = $Script:Config.FieldMappings.$LogicalField
    if (-not $Mapped) { return $null }

    if ($Asset.PSObject.Properties.Name -contains $Mapped) { return $Asset.$Mapped }
    if ($Asset.custom_fields -and $Asset.custom_fields.PSObject.Properties.Name -contains $Mapped) { return $Asset.custom_fields.$Mapped.value }
    return $null
}

function Find-SnipeItAssetMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$AzureDevice,
        [Parameter(Mandatory)][object[]]$SnipeAssets
    )

    foreach ($Key in @($Script:Config.Sync.MatchPriority)) {
        $Value = $AzureDevice.$Key
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { continue }
        if ($Key -eq 'SerialNumber' -and (Test-BadSerialNumber -SerialNumber $Value)) { continue }

        $Matches = @($SnipeAssets | Where-Object { [string](Get-SnipeAssetFieldValue -Asset $_ -LogicalField $Key) -eq [string]$Value })
        if ($Matches.Count -gt 1) {
            throw "Ambiguous Snipe-IT match for $Key '$Value': $($Matches.Count) assets matched."
        }
        if ($Matches.Count -eq 1) {
            return [pscustomobject]@{ Asset = $Matches[0]; MatchKey = $Key; MatchValue = $Value }
        }
    }

    return $null
}

function New-SnipeItPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$AzureDevice)

    $Payload = [ordered]@{}
    foreach ($LogicalField in $Script:Config.FieldMappings.PSObject.Properties.Name) {
        $MappedName = $Script:Config.FieldMappings.$LogicalField
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

    Get-GraphAccessToken | Out-Null
    $AzureDevices = @(Get-AzureDevices | ForEach-Object { ConvertTo-NormalizedAzureDevice -Device $_ })
    $SnipeAssets = @(Get-SnipeItAssets)

    foreach ($Device in $AzureDevices) {
        try {
            if (Test-BadSerialNumber -SerialNumber $Device.SerialNumber) {
                Write-SyncLog -Level Warning -Message 'Skipping device with missing or invalid serial number.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber }
                $Script:Summary.Skipped++
                continue
            }

            $Match = Find-SnipeItAssetMatch -AzureDevice $Device -SnipeAssets $SnipeAssets
            $Payload = New-SnipeItPayload -AzureDevice $Device

            if ($null -eq $Match) {
                if (-not $AllowCreate) {
                    Write-SyncLog -Level Info -Message 'Create skipped because -AllowCreate is not set.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber }
                    $Script:Summary.Skipped++
                    continue
                }

                Write-SyncLog -Level Info -Message 'Snipe-IT asset would be created.' -Data @{ DeviceName = $Device.DeviceName; SerialNumber = $Device.SerialNumber; Payload = ($Payload | ConvertTo-Json -Depth 10) }
                if (-not $DryRun -and $PSCmdlet.ShouldProcess($Device.DeviceName, 'Create Snipe-IT asset')) {
                    Invoke-SnipeItRequest -Method POST -Path 'hardware' -Body $Payload | Out-Null
                }
                $Script:Summary.Created++
                continue
            }

            $Changes = Compare-SnipeItPayload -Asset $Match.Asset -Payload $Payload
            if ($Changes.Count -eq 0) {
                Write-SyncLog -Level Debug -Message 'Asset already up to date.' -Data @{ DeviceName = $Device.DeviceName; MatchKey = $Match.MatchKey; MatchValue = $Match.MatchValue }
                $Script:Summary.Skipped++
                continue
            }

            if (-not $AllowUpdate) {
                Write-SyncLog -Level Info -Message 'Update skipped because -AllowUpdate is not set.' -Data @{ DeviceName = $Device.DeviceName; Changes = ($Changes | ConvertTo-Json -Depth 10) }
                $Script:Summary.Skipped++
                continue
            }

            Write-SyncLog -Level Info -Message 'Snipe-IT asset would be updated.' -Data @{ DeviceName = $Device.DeviceName; AssetId = $Match.Asset.id; Changes = ($Changes | ConvertTo-Json -Depth 10) }
            if (-not $DryRun -and $PSCmdlet.ShouldProcess($Device.DeviceName, 'Update Snipe-IT asset')) {
                Invoke-SnipeItRequest -Method PATCH -Path "hardware/$($Match.Asset.id)" -Body $Payload | Out-Null
            }
            $Script:Summary.Updated++
        }
        catch {
            $Script:Summary.Failed++
            $Script:Summary.Errors += $_.Exception.Message
            Write-SyncLog -Level Error -Message 'Device sync failed.' -Data @{ DeviceName = $Device.DeviceName; Error = $_.Exception.Message }
        }
    }
}

function Write-SyncReport {
    [CmdletBinding()]
    param()

    $Script:Summary.FinishedAt = (Get-Date).ToUniversalTime().ToString('o')
    if ($Script:Config -and $Script:Config.Logging.ReportPath) {
        $ReportDirectory = Split-Path -Parent $Script:Config.Logging.ReportPath
        if ($ReportDirectory -and -not (Test-Path -LiteralPath $ReportDirectory)) {
            New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
        }
        $Script:Summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Script:Config.Logging.ReportPath -Encoding UTF8
    }
    Write-Output ($Script:Summary | ConvertTo-Json -Depth 10)
}

try {
    $Script:Config = Read-SyncConfig -Path $ConfigPath
    Write-SyncLog -Level Info -Message 'Starting Snipe-IT Azure synchronization.' -Data @{ DryRun = [bool]$DryRun; AllowCreate = [bool]$AllowCreate; AllowUpdate = [bool]$AllowUpdate; AllowArchive = [bool]$AllowArchive; AllowDelete = [bool]$AllowDelete }
    Invoke-Sync
    Write-SyncReport
    if ($Script:Summary.Failed -gt 0) { exit $ExitCodes.PartialSyncFailure }
    exit $ExitCodes.Success
}
catch {
    $Message = $_.Exception.Message
    $Script:Summary.Errors += $Message
    if ($Script:Config) { Write-SyncLog -Level Error -Message 'Synchronization failed.' -Data @{ Error = $Message } }
    else { Write-Error $Message }
    Write-SyncReport

    if ($Message -match 'environment variable|Configuration|config|https|Deletion') { exit $ExitCodes.ConfigurationError }
    if ($Message -match 'authentication|certificate|Connect-MgGraph') { exit $ExitCodes.AuthenticationFailure }
    if ($Message -match 'API|HTTP|connect|timeout') { exit $ExitCodes.ApiConnectivityFailure }
    if ($Message -match 'Delete|destructive') { exit $ExitCodes.DestructiveActionBlocked }
    exit $ExitCodes.GeneralFailure
}

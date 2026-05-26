BeforeAll {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $ScriptPath = Join-Path $RepoRoot 'src/Sync-SnipeItAzure.ps1'
    $ConfigPath = Join-Path $RepoRoot 'config.example.json'
    . $ScriptPath

    function New-TestRuntimeConfig {
        $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $Config.Logging.LogPath = Join-Path $TestDrive 'logs/snipeit-azure-sync.jsonl'
        $Config.Logging.ReportPath = Join-Path $TestDrive 'reports/snipeit-azure-sync-report.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $Config.Logging.LogPath) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $Config.Logging.ReportPath) -Force | Out-Null
        return $Config
    }

    function Set-TestRuntime {
        param([object]$Config)
        $Script:Runtime = [pscustomobject]@{
            Config              = $Config
            Mode                = 'Plan'
            SnipeItApiToken     = 'unit-test-token'
            AzureTenantId       = 'unit-test-tenant'
            AzureClientId       = 'unit-test-client'
            AzureCertThumbprint = 'unit-test-thumbprint'
            AllowUpdate         = $false
            NonInteractive      = $false
        }
    }
}

Describe 'configuration safety' {
    It 'uses plan mode and update-only synchronization by default' {
        $Config = New-TestRuntimeConfig
        $Config.Sync.Mode | Should -Be 'Plan'
        $Config.Sync.PSObject.Properties.Name | Should -Contain 'UpdateFields'
        $Config.Sync.PSObject.Properties.Name | Should -Not -Contain 'CreateFields'
    }

    It 'separates unique and fallback match keys' {
        $Config = New-TestRuntimeConfig
        @($Config.Sync.UniqueMatchPriority) | Should -Contain 'SerialNumber'
        @($Config.Sync.UniqueMatchPriority) | Should -Not -Contain 'DeviceName'
        @($Config.Sync.FallbackMatchPriority) | Should -Contain 'DeviceName'
    }
}

Describe 'runtime secret handling' {
    It 'reads secrets only from process scope' {
        $Name = 'SNIPEIT_SYNC_TEST_SECRET'
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        [Environment]::SetEnvironmentVariable($Name, 'user-scope-value', 'User')
        try {
            { Get-EnvironmentSecret -Name $Name -Purpose 'unit test' } | Should -Throw '*process-scoped*'
            [Environment]::SetEnvironmentVariable($Name, 'process-scope-value', 'Process')
            Get-EnvironmentSecret -Name $Name -Purpose 'unit test' | Should -Be 'process-scope-value'
        }
        finally {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
            [Environment]::SetEnvironmentVariable($Name, $null, 'User')
        }
    }
}

Describe 'matching behavior' {
    BeforeEach {
        $Config = New-TestRuntimeConfig
        Set-TestRuntime -Config $Config
    }

    It 'normalizes serial numbers before duplicate detection' {
        $DeviceA = [pscustomobject]@{ SerialNumber = 'ABC-123'; AzureDeviceId = 'azure-1'; IntuneDeviceId = 'intune-1'; DeviceName = 'host-a' }
        $DeviceB = [pscustomobject]@{ SerialNumber = 'abc 123'; AzureDeviceId = 'azure-2'; IntuneDeviceId = 'intune-2'; DeviceName = 'host-b' }
        { Test-AzureDuplicateKey -Devices @($DeviceA, $DeviceB) } | Should -Throw '*Duplicate Azure device value detected for SerialNumber*'
    }

    It 'does not fail lookup creation on duplicate fallback device names' {
        $AssetA = [pscustomobject]@{ id = 1; serial = 'A1'; name = 'shared-name' }
        $AssetB = [pscustomobject]@{ id = 2; serial = 'B1'; name = 'shared-name' }
        { New-AssetLookup -Assets @($AssetA, $AssetB) } | Should -Not -Throw
    }

    It 'skips ambiguous fallback matches instead of guessing' {
        $AssetA = [pscustomobject]@{ id = 1; serial = 'A1'; name = 'shared-name' }
        $AssetB = [pscustomobject]@{ id = 2; serial = 'B1'; name = 'shared-name' }
        $Lookup = New-AssetLookup -Assets @($AssetA, $AssetB)
        $Device = [pscustomobject]@{ SerialNumber = $null; AzureDeviceId = $null; IntuneDeviceId = $null; DeviceName = 'shared-name' }
        Find-SnipeItAssetMatch -AzureDevice $Device -AssetLookup $Lookup | Should -BeNullOrEmpty
    }
}

Describe 'payload and response behavior' {
    BeforeEach {
        $Config = New-TestRuntimeConfig
        Set-TestRuntime -Config $Config
    }

    It 'compares custom field values through logical field mappings' {
        $Asset = [pscustomobject]@{
            id = 10
            name = 'HOST01'
            custom_fields = [pscustomobject]@{
                '_snipeit_azure_device_id_1' = [pscustomobject]@{ value = 'azure-1' }
            }
        }
        $Payload = [ordered]@{ name = 'HOST01'; _snipeit_azure_device_id_1 = 'azure-1' }
        $Changes = Compare-SnipeItPayload -Asset $Asset -Payload $Payload
        $Changes.Count | Should -Be 0
    }

    It 'rejects malformed Snipe-IT write responses without status' {
        { Assert-SnipeItWriteResponse -Response ([pscustomobject]@{ payload = 'unexpected' }) -Operation 'update asset' } | Should -Throw '*without a status field*'
    }

    It 'accepts successful Snipe-IT write responses' {
        { Assert-SnipeItWriteResponse -Response ([pscustomobject]@{ status = 'success' }) -Operation 'update asset' } | Should -Not -Throw
    }
}

Describe 'concurrency behavior' {
    It 'blocks a second lock for the same config path' {
        $ConfigFile = Join-Path $TestDrive 'config.json'
        '{}' | Set-Content -LiteralPath $ConfigFile
        Enter-SyncLock -ConfigFilePath $ConfigFile
        try {
            { Enter-SyncLock -ConfigFilePath $ConfigFile } | Should -Throw '*Another Snipe-IT Azure sync*'
        }
        finally {
            Exit-SyncLock
        }
    }
}

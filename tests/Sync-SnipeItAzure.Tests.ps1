BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ExampleConfigPath = Join-Path $RepoRoot 'config.example.json'
    $ExampleSchemaPath = Join-Path $RepoRoot 'config.schema.json'
    $ModulePath = Join-Path $RepoRoot 'src/SnipeItAzureSync.psm1'
    $ExampleConfig = Get-Content -LiteralPath $ExampleConfigPath -Raw | ConvertFrom-Json
    $ExampleConfig.Logging.LogPath = Join-Path $TestDrive 'logs/out.jsonl'
    $ExampleConfig.Logging.ReportPath = Join-Path $TestDrive 'reports/out.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $ExampleConfig.Logging.LogPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $ExampleConfig.Logging.ReportPath) -Force | Out-Null
    Import-Module -Name $ModulePath -Force

    function New-TestAsset {
        param(
            [int]$Id,
            [string]$Serial,
            [string]$Name,
            [string]$AzureId = '',
            [string]$IntuneId = ''
        )

        [pscustomobject]@{
            id = $Id
            serial = $Serial
            name = $Name
            custom_fields = [pscustomobject]@{
                '_snipeit_azure_device_id_1' = [pscustomobject]@{ value = $AzureId }
                '_snipeit_intune_device_id_2' = [pscustomobject]@{ value = $IntuneId }
            }
        }
    }
}

Describe 'configuration and schema safety' {
    It 'keeps JSON files parseable' {
        { Get-Content -LiteralPath $ExampleConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        { Get-Content -LiteralPath $ExampleSchemaPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'uses update-only plan mode by default' {
        $ExampleConfig.Sync.Mode | Should -Be 'Plan'
        $ExampleConfig.Sync.PSObject.Properties.Name | Should -Contain 'UpdateFields'
        $ExampleConfig.Sync.PSObject.Properties.Name | Should -Not -Contain 'CreateFields'
    }

    It 'separates reliable and fallback matching' {
        @($ExampleConfig.Sync.UniqueMatchPriority) | Should -Contain 'SerialNumber'
        @($ExampleConfig.Sync.UniqueMatchPriority) | Should -Not -Contain 'DeviceName'
        @($ExampleConfig.Sync.FallbackMatchPriority) | Should -Contain 'DeviceName'
    }
}

Describe 'module behavior' {
    BeforeEach {
        InModuleScope SnipeItAzureSync {
            param($RuntimeConfig)
            Initialize-SyncState
            Set-SyncOptions -ConfigPath 'C:/ProgramData/SnipeITAzureSync/config.json' -Mode Plan -LogLevel Info
            $Script:Runtime = [pscustomobject]@{
                Config         = $RuntimeConfig
                Mode           = 'Plan'
                AllowUpdate    = $false
                NonInteractive = $false
            }
        } -ArgumentList $ExampleConfig
    }

    It 'uses only process scope for runtime values' {
        InModuleScope SnipeItAzureSync {
            $Name = 'SYNC_TEST_VALUE'
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
            try {
                { Get-EnvironmentRuntimeValue -Name $Name -Purpose 'unit test' } | Should -Throw '*process-scoped*'
                [Environment]::SetEnvironmentVariable($Name, 'process-value', 'Process')
                Get-EnvironmentRuntimeValue -Name $Name -Purpose 'unit test' | Should -Be 'process-value'
            }
            finally {
                [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
            }
        }
    }

    It 'keeps log text off the success stream' {
        InModuleScope SnipeItAzureSync {
            $Result = Write-SyncLog -Level Warning -Message 'unit warning' -Data @{ Name = 'value' }
            $Result | Should -BeNullOrEmpty
        }
    }

    It 'normalizes serial values before duplicate detection' {
        InModuleScope SnipeItAzureSync {
            $DeviceA = [pscustomobject]@{ SerialNumber = 'ABC-123'; AzureDeviceId = 'az-1'; IntuneDeviceId = 'in-1'; DeviceName = 'host-a' }
            $DeviceB = [pscustomobject]@{ SerialNumber = 'abc 123'; AzureDeviceId = 'az-2'; IntuneDeviceId = 'in-2'; DeviceName = 'host-b' }
            { Test-AzureDuplicateKey -Devices @($DeviceA, $DeviceB) } | Should -Throw '*Duplicate Azure device value detected for SerialNumber*'
        }
    }

    It 'skips ambiguous fallback matches instead of guessing' {
        InModuleScope SnipeItAzureSync {
            param($AssetA, $AssetB)
            $Lookup = New-AssetLookup -Assets @($AssetA, $AssetB)
            $Device = [pscustomobject]@{ SerialNumber = $null; AzureDeviceId = $null; IntuneDeviceId = $null; DeviceName = 'shared-name' }
            Find-SnipeItAssetMatch -AzureDevice $Device -AssetLookup $Lookup | Should -BeNullOrEmpty
        } -ArgumentList (New-TestAsset -Id 1 -Serial 'A1' -Name 'shared-name'), (New-TestAsset -Id 2 -Serial 'B1' -Name 'shared-name')
    }

    It 'reads custom mapped field values safely' {
        InModuleScope SnipeItAzureSync {
            param($Asset)
            Get-SnipeAssetFieldValue -Asset $Asset -LogicalField 'AzureDeviceId' | Should -Be 'az-1'
            $AssetWithoutCustom = [pscustomobject]@{ id = 11; serial = 'S2'; name = 'HOST02' }
            { Get-SnipeAssetFieldValue -Asset $AssetWithoutCustom -LogicalField 'AzureDeviceId' } | Should -Not -Throw
        } -ArgumentList (New-TestAsset -Id 10 -Serial 'S1' -Name 'HOST01' -AzureId 'az-1')
    }

    It 'compares custom field values through logical mappings' {
        InModuleScope SnipeItAzureSync {
            param($Asset)
            $Payload = @{ name = 'HOST03'; _snipeit_azure_device_id_1 = 'az-3' }
            $Changes = Compare-SnipeItPayload -Asset $Asset -Payload $Payload
            $Changes.Count | Should -Be 0
        } -ArgumentList (New-TestAsset -Id 12 -Serial 'S3' -Name 'HOST03' -AzureId 'az-3')
    }

    It 'rejects malformed write responses without status' {
        InModuleScope SnipeItAzureSync {
            { Assert-SnipeItWriteResponse -Response ([pscustomobject]@{ payload = 'unexpected' }) -Operation 'update asset' } | Should -Throw '*without a status field*'
        }
    }

    It 'recognizes Windows absolute paths independently of runner OS' {
        InModuleScope SnipeItAzureSync {
            Test-WindowsAbsolutePath -Path 'C:/ProgramData/SnipeITAzureSync/logs/file.jsonl' | Should -BeTrue
            Test-WindowsAbsolutePath -Path './relative/file.jsonl' | Should -BeFalse
        }
    }

    It 'removes stale locks when recorded process no longer exists' {
        InModuleScope SnipeItAzureSync {
            param($LockPath)
            'Pid=99999999; StartedAt=2000-01-01T00:00:00Z' | Set-Content -LiteralPath $LockPath
            Test-StaleLockFile -LockPath $LockPath | Should -BeTrue
        } -ArgumentList (Join-Path $TestDrive 'sync.lock')
    }

    It 'validates configured custom fields before Apply updates' {
        InModuleScope SnipeItAzureSync {
            param($Asset)
            { Test-SnipeItCustomFieldPreflight -Assets @($Asset) } | Should -Not -Throw
            $BadAsset = [pscustomobject]@{ id = 99; serial = 'S9'; name = 'HOST99'; custom_fields = [pscustomobject]@{} }
            { Test-SnipeItCustomFieldPreflight -Assets @($BadAsset) } | Should -Throw '*custom field mapping*'
        } -ArgumentList (New-TestAsset -Id 10 -Serial 'S1' -Name 'HOST01' -AzureId 'az-1' -IntuneId 'in-1')
    }
}

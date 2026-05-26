BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ExampleConfigPath = Join-Path $RepoRoot 'config.example.json'
    $ExampleSchemaPath = Join-Path $RepoRoot 'config.schema.json'
    $ScriptPath = Join-Path $RepoRoot 'src/Sync-SnipeItAzure.ps1'
    $ExampleConfig = Get-Content -LiteralPath $ExampleConfigPath -Raw | ConvertFrom-Json
    $RuntimeScriptPath = Join-Path $TestDrive 'Sync-SnipeItAzure.Runtime.ps1'
    $RuntimeScript = Get-Content -LiteralPath $ScriptPath -Raw
    $RuntimeScript = $RuntimeScript -replace "(?s)if \(\$MyInvocation\.InvocationName -ne '\.'\) \{ Invoke-Main \}\s*$", ''
    Set-Content -LiteralPath $RuntimeScriptPath -Value $RuntimeScript -Encoding UTF8
    . $RuntimeScriptPath

    function Set-TestRuntime {
        param([object]$RuntimeConfig)
        $Script:Runtime = [pscustomobject]@{
            Config         = $RuntimeConfig
            Mode           = 'Plan'
            AllowUpdate    = $false
            NonInteractive = $false
        }
    }

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

Describe 'runtime value sourcing' {
    It 'uses only process scope for runtime values' {
        $Name = 'SYNC_TEST_VALUE'
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        try {
            { Get-EnvironmentSecret -Name $Name -Purpose 'unit test' } | Should -Throw '*process-scoped*'
            [Environment]::SetEnvironmentVariable($Name, 'process-value', 'Process')
            Get-EnvironmentSecret -Name $Name -Purpose 'unit test' | Should -Be 'process-value'
        }
        finally {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        }
    }
}

Describe 'matching behavior' {
    BeforeEach {
        Set-TestRuntime -RuntimeConfig $ExampleConfig
    }

    It 'normalizes serial values before duplicate detection' {
        $DeviceA = [pscustomobject]@{ SerialNumber = 'ABC-123'; AzureDeviceId = 'az-1'; IntuneDeviceId = 'in-1'; DeviceName = 'host-a' }
        $DeviceB = [pscustomobject]@{ SerialNumber = 'abc 123'; AzureDeviceId = 'az-2'; IntuneDeviceId = 'in-2'; DeviceName = 'host-b' }
        { Test-AzureDuplicateKey -Devices @($DeviceA, $DeviceB) } | Should -Throw '*Duplicate Azure device value detected for SerialNumber*'
    }

    It 'does not fail on duplicate fallback names during lookup creation' {
        $AssetA = New-TestAsset -Id 1 -Serial 'A1' -Name 'shared-name'
        $AssetB = New-TestAsset -Id 2 -Serial 'B1' -Name 'shared-name'
        { New-AssetLookup -Assets @($AssetA, $AssetB) } | Should -Not -Throw
    }

    It 'skips ambiguous fallback matches instead of guessing' {
        $AssetA = New-TestAsset -Id 1 -Serial 'A1' -Name 'shared-name'
        $AssetB = New-TestAsset -Id 2 -Serial 'B1' -Name 'shared-name'
        $Lookup = New-AssetLookup -Assets @($AssetA, $AssetB)
        $Device = [pscustomobject]@{ SerialNumber = $null; AzureDeviceId = $null; IntuneDeviceId = $null; DeviceName = 'shared-name' }
        Find-SnipeItAssetMatch -AzureDevice $Device -AssetLookup $Lookup | Should -BeNullOrEmpty
    }
}

Describe 'payload behavior' {
    BeforeEach {
        Set-TestRuntime -RuntimeConfig $ExampleConfig
    }

    It 'reads custom mapped field values without failing when custom fields are present' {
        $Asset = New-TestAsset -Id 10 -Serial 'S1' -Name 'HOST01' -AzureId 'az-1'
        Get-SnipeAssetFieldValue -Asset $Asset -LogicalField 'AzureDeviceId' | Should -Be 'az-1'
    }

    It 'does not fail when optional custom fields are missing' {
        $Asset = [pscustomobject]@{ id = 11; serial = 'S2'; name = 'HOST02' }
        { Get-SnipeAssetFieldValue -Asset $Asset -LogicalField 'AzureDeviceId' } | Should -Not -Throw
        Get-SnipeAssetFieldValue -Asset $Asset -LogicalField 'AzureDeviceId' | Should -BeNullOrEmpty
    }

    It 'compares custom field values through logical mappings' {
        $Asset = New-TestAsset -Id 12 -Serial 'S3' -Name 'HOST03' -AzureId 'az-3'
        $Payload = @{ name = 'HOST03'; _snipeit_azure_device_id_1 = 'az-3' }
        $Changes = Compare-SnipeItPayload -Asset $Asset -Payload $Payload
        $Changes.Count | Should -Be 0
    }

    It 'rejects malformed write responses without status' {
        { Assert-SnipeItWriteResponse -Response ([pscustomobject]@{ payload = 'unexpected' }) -Operation 'update asset' } | Should -Throw '*without a status field*'
    }
}

Describe 'path and lock behavior' {
    It 'recognizes Windows absolute paths independently of runner OS' {
        Test-WindowsAbsolutePath -Path 'C:/ProgramData/SnipeITAzureSync/logs/file.jsonl' | Should -BeTrue
        Test-WindowsAbsolutePath -Path './relative/file.jsonl' | Should -BeFalse
    }

    It 'removes stale locks when recorded process no longer exists' {
        $LockPath = Join-Path $TestDrive 'sync.lock'
        'Pid=99999999; StartedAt=2000-01-01T00:00:00Z' | Set-Content -LiteralPath $LockPath
        Test-StaleLockFile -LockPath $LockPath | Should -BeTrue
    }
}

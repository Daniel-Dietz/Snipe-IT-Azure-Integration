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
            [string]$IntuneId = '',
            [string]$AssignedUser = ''
        )

        [pscustomobject]@{
            id = $Id
            serial = $Serial
            name = $Name
            assigned_user = $AssignedUser
            custom_fields = [pscustomobject]@{
                '_snipeit_azure_device_id_1' = [pscustomobject]@{ value = $AzureId }
                '_snipeit_intune_device_id_2' = [pscustomobject]@{ value = $IntuneId }
            }
        }
    }

    function Copy-TestConfig {
        param([object]$Config = $ExampleConfig)
        return ($Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
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
            Set-SyncOptions -ConfigPath 'C:/ProgramData/SnipeITAzureSync/config.json' -Mode Plan -LogLevel Error
            $Script:Runtime = [pscustomobject]@{
                Config         = $RuntimeConfig
                Mode           = 'Plan'
                AllowUpdate    = $false
                NonInteractive = $false
            }
        } -ArgumentList (Copy-TestConfig)
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
            Set-SyncOptions -ConfigPath 'C:/ProgramData/SnipeITAzureSync/config.json' -Mode Plan -LogLevel Warning
            $Result = Write-SyncLog -Level Warning -Message 'unit warning' -Data @{ Name = 'value' }
            $Result | Should -BeNullOrEmpty
        }
    }

    It 'rejects runtime configuration values outside the production schema contract' {
        InModuleScope SnipeItAzureSync {
            param($RuntimeConfig)
            $RuntimeConfig.SnipeIt.PageSize = 9999
            { Assert-SyncConfigShape -Config $RuntimeConfig } | Should -Throw '*SnipeIt.PageSize*between 1 and 500*'
        } -ArgumentList (Copy-TestConfig)
    }

    It 'rejects unsupported runtime configuration properties' {
        InModuleScope SnipeItAzureSync {
            param($RuntimeConfig)
            $RuntimeConfig.SnipeIt | Add-Member -NotePropertyName ApiToken -NotePropertyValue 'must-not-exist'
            { Assert-SyncConfigShape -Config $RuntimeConfig } | Should -Throw '*unsupported property*ApiToken*'
        } -ArgumentList (Copy-TestConfig)
    }

    It 'validates output parents before creating missing leaf directories without depending on runner ACLs' {
        Mock -ModuleName SnipeItAzureSync -CommandName Assert-SafeExistingPathSegment -MockWith { }
        InModuleScope SnipeItAzureSync {
            param($Root)
            $Target = Join-Path $Root 'missing/out.jsonl'
            $Resolved = Test-SafeOutputPath -Path $Target -Purpose 'Log'
            $Resolved | Should -Be ([System.IO.Path]::GetFullPath($Target))
            Test-Path -LiteralPath (Split-Path -Parent $Target) | Should -BeTrue
        } -ArgumentList $TestDrive
        Should -Invoke -CommandName Assert-SafeExistingPathSegment -ModuleName SnipeItAzureSync -Times 1
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

    It 'matches by Azure device ID even when the serial number is missing or invalid' {
        InModuleScope SnipeItAzureSync {
            param($Asset)
            $Lookup = New-AssetLookup -Assets @($Asset)
            $Device = [pscustomobject]@{ SerialNumber = 'To Be Filled By O.E.M.'; AzureDeviceId = 'az-serialless'; IntuneDeviceId = $null; DeviceName = 'serialless-host' }
            $Match = Find-SnipeItAssetMatch -AzureDevice $Device -AssetLookup $Lookup
            $Match | Should -Not -BeNullOrEmpty
            $Match.MatchKey | Should -Be 'AzureDeviceId'
        } -ArgumentList (New-TestAsset -Id 42 -Serial '' -Name 'serialless-host' -AzureId 'az-serialless')
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

    It 'accepts configured custom field metadata before Apply updates' {
        InModuleScope SnipeItAzureSync {
            param($Asset)
            { Test-SnipeItCustomFieldPreflight -Assets @($Asset) } | Should -Not -Throw
        } -ArgumentList (New-TestAsset -Id 10 -Serial 'S1' -Name 'HOST01' -AzureId 'az-1' -IntuneId 'in-1')
    }
}

Describe 'sync execution gates' {
    BeforeEach {
        InModuleScope SnipeItAzureSync {
            param($RuntimeConfig)
            Initialize-SyncState
            Set-SyncOptions -ConfigPath 'C:/ProgramData/SnipeITAzureSync/config.json' -Mode Plan -LogLevel Error
            $Script:Runtime = [pscustomobject]@{
                Config         = $RuntimeConfig
                Mode           = 'Plan'
                AllowUpdate    = $false
                NonInteractive = $false
            }
        } -ArgumentList (Copy-TestConfig)
    }

    It 'does not patch Snipe-IT in Plan mode' {
        Mock -ModuleName SnipeItAzureSync -CommandName Connect-GraphSafe -MockWith { }
        Mock -ModuleName SnipeItAzureSync -CommandName Get-AzureDevice -MockWith {
            @([pscustomobject]@{ id = 'intune-2'; azureADDeviceId = 'azure-2'; deviceName = 'HOST02'; serialNumber = 'SERIAL02'; manufacturer = 'Vendor'; model = 'Model'; userPrincipalName = 'user@example.com' })
        }
        Mock -ModuleName SnipeItAzureSync -CommandName Get-SnipeItAsset -MockWith {
            @([pscustomobject]@{
                id = 100
                serial = 'SERIAL02'
                name = 'OLDNAME'
                custom_fields = [pscustomobject]@{
                    '_snipeit_azure_device_id_1' = [pscustomobject]@{ value = 'azure-2' }
                    '_snipeit_intune_device_id_2' = [pscustomobject]@{ value = 'intune-2' }
                }
            })
        }
        Mock -ModuleName SnipeItAzureSync -CommandName Invoke-SnipeItRequest -MockWith { throw 'PATCH must not be called in Plan mode.' }

        InModuleScope SnipeItAzureSync {
            Invoke-Sync
            $Script:Summary.Skipped | Should -Be 1
            $Script:Summary.Updated | Should -Be 0
        }

        Should -Invoke -CommandName Invoke-SnipeItRequest -ModuleName SnipeItAzureSync -Times 0 -Exactly
    }

    It 'patches exactly the matched asset in Apply mode with AllowUpdate' {
        Mock -ModuleName SnipeItAzureSync -CommandName Connect-GraphSafe -MockWith { }
        Mock -ModuleName SnipeItAzureSync -CommandName Get-AzureDevice -MockWith {
            @([pscustomobject]@{ id = 'intune-200'; azureADDeviceId = 'azure-200'; deviceName = 'HOST200'; serialNumber = 'SERIAL200'; manufacturer = 'Vendor'; model = 'Model'; userPrincipalName = 'user@example.com' })
        }
        Mock -ModuleName SnipeItAzureSync -CommandName Get-SnipeItAsset -MockWith {
            @([pscustomobject]@{
                id = 200
                serial = 'SERIAL200'
                name = 'OLD200'
                custom_fields = [pscustomobject]@{
                    '_snipeit_azure_device_id_1' = [pscustomobject]@{ value = 'azure-200' }
                    '_snipeit_intune_device_id_2' = [pscustomobject]@{ value = 'intune-200' }
                }
            })
        }
        Mock -ModuleName SnipeItAzureSync -CommandName Invoke-SnipeItRequest -MockWith { [pscustomobject]@{ status = 'success' } }

        InModuleScope SnipeItAzureSync {
            param($RuntimeConfig)
            $Script:Runtime = [pscustomobject]@{
                Config         = $RuntimeConfig
                Mode           = 'Apply'
                AllowUpdate    = $true
                NonInteractive = $false
            }
            $Script:Summary.Mode = 'Apply'
            Invoke-Sync
            $Script:Summary.Updated | Should -Be 1
        } -ArgumentList (Copy-TestConfig)

        Should -Invoke -CommandName Invoke-SnipeItRequest -ModuleName SnipeItAzureSync -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Path -eq 'hardware/200' -and $Body.name -eq 'HOST200' }
    }

    It 'updates serialless matched assets by Azure device ID during full sync' {
        Mock -ModuleName SnipeItAzureSync -CommandName Connect-GraphSafe -MockWith { }
        Mock -ModuleName SnipeItAzureSync -CommandName Get-AzureDevice -MockWith {
            @([pscustomobject]@{ id = 'intune-300'; azureADDeviceId = 'azure-300'; deviceName = 'SERIALLESS300'; serialNumber = 'To Be Filled By O.E.M.'; manufacturer = 'Vendor'; model = 'Model'; userPrincipalName = 'user@example.com' })
        }
        Mock -ModuleName SnipeItAzureSync -CommandName Get-SnipeItAsset -MockWith {
            @([pscustomobject]@{
                id = 300
                serial = ''
                name = 'OLD300'
                custom_fields = [pscustomobject]@{
                    '_snipeit_azure_device_id_1' = [pscustomobject]@{ value = 'azure-300' }
                    '_snipeit_intune_device_id_2' = [pscustomobject]@{ value = 'intune-300' }
                }
            })
        }
        Mock -ModuleName SnipeItAzureSync -CommandName Invoke-SnipeItRequest -MockWith { [pscustomobject]@{ status = 'success' } }

        InModuleScope SnipeItAzureSync {
            param($RuntimeConfig)
            $Script:Runtime = [pscustomobject]@{
                Config         = $RuntimeConfig
                Mode           = 'Apply'
                AllowUpdate    = $true
                NonInteractive = $false
            }
            $Script:Summary.Mode = 'Apply'
            Invoke-Sync
            $Script:Summary.Updated | Should -Be 1
        } -ArgumentList (Copy-TestConfig)

        Should -Invoke -CommandName Invoke-SnipeItRequest -ModuleName SnipeItAzureSync -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Path -eq 'hardware/300' }
    }
}

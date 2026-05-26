BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ExampleConfigPath = Join-Path $RepoRoot 'config.example.json'
    $ExampleSchemaPath = Join-Path $RepoRoot 'config.schema.json'
    $ModulePath = Join-Path $RepoRoot 'src/SnipeItAzureSync.psm1'
    $ModuleSource = Get-Content -LiteralPath $ModulePath -Raw
    $ExampleConfig = Get-Content -LiteralPath $ExampleConfigPath -Raw | ConvertFrom-Json
    Import-Module -Name $ModulePath -Force
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
        @($ExampleConfig.Sync.UniqueMatchPriority) | Should -Contain 'AzureDeviceId'
        @($ExampleConfig.Sync.UniqueMatchPriority) | Should -Contain 'IntuneDeviceId'
        @($ExampleConfig.Sync.UniqueMatchPriority) | Should -Not -Contain 'DeviceName'
        @($ExampleConfig.Sync.FallbackMatchPriority) | Should -Contain 'DeviceName'
    }

    It 'maps every enabled sync field explicitly' {
        $EnabledFields = @($ExampleConfig.Sync.UniqueMatchPriority) + @($ExampleConfig.Sync.FallbackMatchPriority) + @($ExampleConfig.Sync.UpdateFields)
        foreach ($Field in @($EnabledFields | Select-Object -Unique)) {
            $ExampleConfig.FieldMappings.PSObject.Properties.Name | Should -Contain $Field
            [string]$ExampleConfig.FieldMappings.$Field | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'production module contract' {
    It 'imports and exposes only the production entry point' {
        $Command = Get-Command -Name Invoke-SnipeItAzureSync -Module SnipeItAzureSync -ErrorAction Stop
        $Command.CommandType | Should -Be 'Function'
        @(Get-Command -Module SnipeItAzureSync).Name | Should -Be @('Invoke-SnipeItAzureSync')
    }

    It 'does not implement create archive or delete API operations' {
        $ModuleSource | Should -Match "ValidateSet\('GET', 'PATCH'\)"
        $ModuleSource | Should -Not -Match "ValidateSet\('GET', 'POST'"
        $ModuleSource | Should -Not -Match "ValidateSet\('GET', 'PUT'"
        $ModuleSource | Should -Not -Match "ValidateSet\('GET', 'DELETE'"
    }

    It 'keeps writes gated behind apply mode and explicit update permission' {
        $ModuleSource | Should -Match 'Apply mode requires explicit -AllowUpdate'
        $ModuleSource | Should -Match 'if \(-not \$Script:Runtime.AllowUpdate\)'
        $ModuleSource | Should -Match 'Invoke-SnipeItRequest -Method PATCH -Path "hardware/\$\(\$Match.Asset.id\)"'
    }

    It 'keeps serialless matching support for Azure and Intune IDs' {
        $ModuleSource | Should -Match 'function Find-SnipeItAssetMatch'
        $ModuleSource | Should -Match "if \(\$KeyName -eq 'SerialNumber' -and \(Test-BadSerialNumber"
        $ModuleSource | Should -Match 'continue'
        $ModuleSource | Should -Match 'AzureDeviceId'
        $ModuleSource | Should -Match 'IntuneDeviceId'
    }

    It 'contains runtime configuration shape validation' {
        $ModuleSource | Should -Match 'function Assert-SyncConfigShape'
        $ModuleSource | Should -Match 'Unsupported Azure source'
        $ModuleSource | Should -Match 'Snipe-IT BaseUrl must use HTTPS'
        $ModuleSource | Should -Match 'FieldMappings entry'
        $ModuleSource | Should -Match 'PageSize.*between 1 and 500'
    }

    It 'validates output parent paths before creating leaf directories' {
        $ModuleSource | Should -Match 'function Assert-SafeOutputParentPath'
        $ModuleSource | Should -Match 'Assert-SafeOutputParentPath -Directory \$Directory'
        $ModuleSource | Should -Match 'New-Item -ItemType Directory -Path \$Directory'
        $ModuleSource.IndexOf('Assert-SafeOutputParentPath -Directory $Directory') | Should -BeLessThan $ModuleSource.IndexOf('New-Item -ItemType Directory -Path $Directory')
    }
}

BeforeAll {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $ConfigPath = Join-Path $RepoRoot 'config.example.json'
    $SchemaPath = Join-Path $RepoRoot 'config.schema.json'
    $ScriptPath = Join-Path $RepoRoot 'src/Sync-SnipeItAzure.ps1'
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $ScriptText = Get-Content -LiteralPath $ScriptPath -Raw
}

Describe 'repository safety contract' {
    It 'uses plan mode by default' {
        $Config.Sync.Mode | Should -Be 'Plan'
    }

    It 'uses update-only config fields' {
        $Config.Sync.PSObject.Properties.Name | Should -Contain 'UpdateFields'
        $Config.Sync.PSObject.Properties.Name | Should -Not -Contain 'CreateFields'
    }

    It 'separates reliable and fallback matching' {
        @($Config.Sync.UniqueMatchPriority) | Should -Contain 'SerialNumber'
        @($Config.Sync.UniqueMatchPriority) | Should -Not -Contain 'DeviceName'
        @($Config.Sync.FallbackMatchPriority) | Should -Contain 'DeviceName'
    }

    It 'keeps Windows service output paths configured' {
        $Config.Logging.LogPath | Should -Match '^[A-Za-z]:/'
        $Config.Logging.ReportPath | Should -Match '^[A-Za-z]:/'
    }

    It 'keeps unsupported destructive operations out of the active script' {
        $ScriptText | Should -Not -Match 'AllowDelete'
        $ScriptText | Should -Not -Match 'AllowArchive'
        $ScriptText | Should -Not -Match 'MissingAzureDeviceAction'
    }

    It 'keeps create operations disabled in the active request wrapper' {
        $ScriptText | Should -Match 'create mode is disabled'
        $ScriptText | Should -Match "ValidateSet\('GET', 'PATCH'\)"
    }

    It 'keeps concurrency protection in the active script' {
        $ScriptText | Should -Match 'function Enter-SyncLock'
        $ScriptText | Should -Match 'function Exit-SyncLock'
    }

    It 'keeps JSON files parseable' {
        { Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        { Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}

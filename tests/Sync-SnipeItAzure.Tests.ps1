BeforeAll {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $ScriptPath = Join-Path $RepoRoot 'src/Sync-SnipeItAzure.ps1'
    $ConfigPath = Join-Path $RepoRoot 'config.example.json'
    $ScriptContent = Get-Content -LiteralPath $ScriptPath -Raw
    $ConfigContent = Get-Content -LiteralPath $ConfigPath -Raw
}

Describe 'Snipe-IT Azure sync safety contract' {
    It 'uses plan mode as the safe default in example configuration' {
        $Config = $ConfigContent | ConvertFrom-Json
        $Config.Sync.Mode | Should -Be 'Plan'
    }

    It 'does not expose archive or delete switches in the active sync script' {
        $ScriptContent | Should -Not -Match 'AllowArchive'
        $ScriptContent | Should -Not -Match 'AllowDelete'
        $ScriptContent | Should -Not -Match 'IUnderstandThisCanRemoveAssets'
        $ScriptContent | Should -Not -Match 'MissingAzureDeviceAction'
    }

    It 'does not support the unsafe EntraDevices source in active configuration' {
        $Config = $ConfigContent | ConvertFrom-Json
        $Config.Azure.Source | Should -Be 'IntuneManagedDevices'
        $ConfigContent | Should -Not -Match 'EntraDevices'
    }

    It 'removes AssetTag from default match priority because Azure does not supply it' {
        $Config = $ConfigContent | ConvertFrom-Json
        @($Config.Sync.MatchPriority) | Should -Not -Contain 'AssetTag'
    }

    It 'separates plan counters from applied write counters' {
        $ScriptContent | Should -Match 'WouldCreate'
        $ScriptContent | Should -Match 'WouldUpdate'
        $ScriptContent | Should -Match 'Created'
        $ScriptContent | Should -Match 'Updated'
    }

    It 'centralizes runtime secret loading through a single function' {
        $ScriptContent | Should -Match 'function Get-EnvironmentSecret'
        $ScriptContent | Should -Match 'function New-RuntimeContext'
        ($ScriptContent | Select-String -Pattern '\[Environment\]::GetEnvironmentVariable' -AllMatches).Matches.Count | Should -Be 1
    }

    It 'validates duplicate Azure and Snipe-IT match keys before updates' {
        $ScriptContent | Should -Match 'function Test-AzureDuplicateKey'
        $ScriptContent | Should -Match 'function New-AssetLookup'
        $ScriptContent | Should -Match 'Duplicate \$SourceName value detected'
    }

    It 'validates Snipe-IT semantic responses for write operations' {
        $ScriptContent | Should -Match 'function Assert-SnipeItResponse'
        $ScriptContent | Should -Match 'Assert-SnipeItResponse -Response \$Response -Operation ''create asset'''
        $ScriptContent | Should -Match 'Assert-SnipeItResponse -Response \$Response -Operation ''update asset'''
    }

    It 'does not contain obvious hard-coded bearer tokens or client secrets' {
        $ScriptContent | Should -Not -Match 'Bearer\s+[A-Za-z0-9_\-\.]{20,}'
        $ScriptContent | Should -Not -Match 'client_secret\s*[=:]\s*[''\"][^''\"]+'
        $ScriptContent | Should -Not -Match 'SNIPEIT_API_TOKEN\s*=\s*[''\"][^''\"]+'
    }
}

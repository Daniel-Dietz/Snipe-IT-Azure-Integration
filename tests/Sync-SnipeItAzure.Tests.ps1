BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot '..\src\Sync-SnipeItAzure.ps1'
}

Describe 'Sync-SnipeItAzure repository baseline' {
    It 'contains the main script' {
        Test-Path -LiteralPath $ScriptPath | Should -BeTrue
    }

    It 'does not contain obvious hard-coded bearer tokens or client secrets' {
        $Content = Get-Content -LiteralPath $ScriptPath -Raw
        $Content | Should -Not -Match 'Bearer\s+[A-Za-z0-9_\-\.]{20,}'
        $Content | Should -Not -Match 'client_secret\s*[=:]\s*[''\"][^''\"]+'
        $Content | Should -Not -Match 'SNIPEIT_API_TOKEN\s*=\s*[''\"][^''\"]+'
    }

    It 'defines destructive delete guardrails' {
        $Content = Get-Content -LiteralPath $ScriptPath -Raw
        $Content | Should -Match 'IUnderstandThisCanRemoveAssets'
        $Content | Should -Match 'AllowDelete'
        $Content | Should -Match 'DestructiveActionBlocked'
    }

    It 'defines dry-run support' {
        $Content = Get-Content -LiteralPath $ScriptPath -Raw
        $Content | Should -Match 'DryRun'
        $Content | Should -Match 'ShouldProcess'
    }
}

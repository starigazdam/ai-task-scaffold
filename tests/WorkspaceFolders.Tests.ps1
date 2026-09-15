Describe 'Update-WorkspaceFolders' {
    BeforeEach {
        $script:workspacePath = Join-Path $TestDrive 'team.code-workspace'
        @'
{
  // Human notes must survive.
  "folders": [
    { "path": ".", "name": "🌳 root" }, // keep this too
  ],
  "settings": {
    "service.url": "https://example.invalid/api"
  }
}
'@ | Set-Content -LiteralPath $script:workspacePath -NoNewline
        $script:scriptPath = Join-Path $PSScriptRoot '../scripts/Update-WorkspaceFolders.ps1'
        $script:foldersJson = '[{"path":"tasks/FEATURE-123/worktrees/api","name":"🔧 worktree: FEATURE-123 api"}]'
    }

    It 'proposes an add-only change without rewriting JSONC' {
        $before = Get-Content -LiteralPath $workspacePath -Raw
        $plan = & $scriptPath -WorkspaceFile $workspacePath -FoldersJson $foldersJson | ConvertFrom-Json

        $plan.Action | Should -Be 'add'
        $plan.RequiresConfirmation | Should -BeTrue
        $plan.OriginalSha256 | Should -Not -BeNullOrEmpty
        $plan.ProposedContent | Should -Match '// Human notes must survive.'
        $plan.ProposedContent | Should -Match 'https://example.invalid/api'
        $plan.ProposedContent | Should -Match 'tasks/FEATURE-123/worktrees/api'
        (Get-Content -LiteralPath $workspacePath -Raw) | Should -Be $before
    }

    It 'applies only the reviewed add-only content after hash confirmation' {
        $plan = & $scriptPath -WorkspaceFile $workspacePath -FoldersJson $foldersJson | ConvertFrom-Json
        & $scriptPath -WorkspaceFile $workspacePath -FoldersJson $foldersJson -Apply -ExpectedSha256 $plan.OriginalSha256 | Out-Null

        (Get-Content -LiteralPath $workspacePath -Raw) | Should -Be $plan.ProposedContent
        Test-Path -LiteralPath "$workspacePath.bak" | Should -BeTrue
        (Get-Content -LiteralPath $workspacePath -Raw) | Should -Match '// Human notes must survive.'
    }

    It 'refuses a stale reviewed hash without changing the workspace' {
        $before = Get-Content -LiteralPath $workspacePath -Raw
        { & $scriptPath -WorkspaceFile $workspacePath -FoldersJson $foldersJson -Apply -ExpectedSha256 ('0' * 64) } | Should -Throw '*changed since planning*'
        (Get-Content -LiteralPath $workspacePath -Raw) | Should -Be $before
    }

    It 'adds a separating comma to a strict JSON folders array' {
        @'
{
  "folders": [
    { "path": ".", "name": "root" }
  ]
}
'@ | Set-Content -LiteralPath $workspacePath -NoNewline

        $plan = & $scriptPath -WorkspaceFile $workspacePath -FoldersJson $foldersJson | ConvertFrom-Json

        $plan.ProposedContent | Should -Match '"name": "root" },\s*\{'
        $plan.ProposedContent | ConvertFrom-Json | Out-Null
    }
}

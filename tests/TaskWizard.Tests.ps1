Describe 'Start-TaskScaffold' {
    It 'creates a starter PRD when none is supplied and applies only after confirmation' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $canonsPath = Join-Path $workspaceRoot 'canons'
        $repositoryPath = Join-Path $canonsPath 'api'
        New-Item -ItemType Directory -Path $repositoryPath -Force | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null
        @'
{
  "schemaVersion": 1,
  "repositories": { "api": { "baseBranch": "main" } }
}
'@ | Set-Content -LiteralPath (Join-Path $workspaceRoot 'task-scaffold.settings.json') -NoNewline
        $global:taskWizardAnswers = @('FEATURE-123', 'Add endpoint', '', 'y', 'y')
        $global:taskWizardMessages = @()
        Import-Module (Join-Path $PSScriptRoot '../scripts/Private/TerminalSelector.psm1') -Force
        Mock Select-TaskRepositories { @('api') }
        Mock Write-Host { $global:taskWizardMessages += [string]$Object }
        Mock Read-Host {
            $answer = $global:taskWizardAnswers[0]
            $global:taskWizardAnswers = @($global:taskWizardAnswers | Select-Object -Skip 1)
            $answer
        }

        $script = Join-Path $PSScriptRoot '../scripts/Start-TaskScaffold.ps1'
        & $script -WorkspaceRoot $workspaceRoot | Out-Null

        $taskPath = Join-Path $workspaceRoot 'tasks/FEATURE-123'
        $prd = Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw
        $prd | Should -Match '^# Add endpoint'
        $prd | Should -Match '## Acceptance Criteria'
        ($global:taskWizardMessages -join "`n") | Should -Match 'No PRD source supplied; a starter PRD.md will be created\.'
        (& git -C (Join-Path $taskPath 'worktrees/api') branch --show-current) | Should -Be 'feature/FEATURE-123'
    }
}

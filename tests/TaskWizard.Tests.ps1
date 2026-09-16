Describe 'Start-TaskScaffold' {
    It 'checks selected canons, reviews a plan, and applies only after PRD-copy confirmation' {
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
        $prdPath = Join-Path $TestDrive 'prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Add endpoint'
        @'
{
  "schemaVersion": 1,
  "repositories": { "api": { "baseBranch": "main" } }
}
'@ | Set-Content -LiteralPath (Join-Path $workspaceRoot 'task-scaffold.settings.json') -NoNewline
        $global:taskWizardAnswers = @('y', 'FEATURE-123', 'Add endpoint', $prdPath, 'y', 'y')
        Import-Module (Join-Path $PSScriptRoot '../scripts/Private/TerminalSelector.psm1') -Force
        Mock Select-TaskRepositories { @('api') }
        Mock Read-Host {
            $answer = $global:taskWizardAnswers[0]
            $global:taskWizardAnswers = @($global:taskWizardAnswers | Select-Object -Skip 1)
            $answer
        }

        $script = Join-Path $PSScriptRoot '../scripts/Start-TaskScaffold.ps1'
        & $script -WorkspaceRoot $workspaceRoot | Out-Null

        $taskPath = Join-Path $workspaceRoot 'tasks/FEATURE-123'
        Test-Path -LiteralPath (Join-Path $taskPath 'PRD.md') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be "# Add endpoint`n"
        (& git -C (Join-Path $taskPath 'worktrees/api') branch --show-current) | Should -Be 'feature/FEATURE-123'
    }
}

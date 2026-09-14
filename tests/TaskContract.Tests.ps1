BeforeAll {
    $module = Join-Path $PSScriptRoot '../scripts/Private/TaskContract.psm1'
    Import-Module $module -Force
}

Describe 'ConvertTo-TaskRequest' {
    It 'preserves an explicit branch for each repository' {
        $requestPath = Join-Path $TestDrive 'task-request.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" },
    { "name": "web", "path": "C:/work/canons/web", "baseBranch": "origin/develop", "branch": "bump-version-1.2" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        $request = ConvertTo-TaskRequest -Path $requestPath

        $request.Task.Key | Should -Be 'FEATURE-123'
        $request.Repositories.Name | Should -Be @('api', 'web')
        $request.Repositories[0].Branch | Should -Be 'feature/FEATURE-123'
        $request.Repositories[1].Branch | Should -Be 'bump-version-1.2'
    }

    It 'rejects duplicate repository names' {
        $requestPath = Join-Path $TestDrive 'duplicate-repository.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" },
    { "name": "api", "path": "C:/work/canons/web", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*duplicate repository name*'
    }

    It 'rejects a task key that escapes its task directory' {
        $requestPath = Join-Path $TestDrive 'unsafe-key.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "../escape", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*invalid task key*'
    }
    It 'rejects repository names that escape the worktrees directory' {
        $requestPath = Join-Path $TestDrive 'unsafe-repository.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "../../outside", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*invalid repository name*'
    }

    It 'rejects invalid Git branch names' {
        $requestPath = Join-Path $TestDrive 'unsafe-branch.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/a..b" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*invalid Git branch*'
    }
}

Describe 'Invoke-TaskRequestBuilder' {
    It 'suggests configured canons and writes a reviewed request without applying task state' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $canonsPath = Join-Path $workspaceRoot 'canons'
        New-Item -ItemType Directory -Path (Join-Path $canonsPath 'api') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $canonsPath 'web') -Force | Out-Null
        $prdPath = Join-Path $TestDrive 'prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Add endpoint'
        @'
{
  "schemaVersion": 1,
  "repositories": {
    "api": { "baseBranch": "develop" },
    "web": { "baseBranch": "main" }
  },
  "workspace": { "file": "team.code-workspace" }
}
'@ | Set-Content -LiteralPath (Join-Path $workspaceRoot 'task-scaffold.settings.json') -NoNewline
        $outputPath = Join-Path $workspaceRoot 'task-request.json'
        $global:taskRequestBuilderAnswers = @('FEATURE-123', 'Add endpoint', $prdPath, 'y')
        Mock Read-Host {
            $answer = $global:taskRequestBuilderAnswers[0]
            $global:taskRequestBuilderAnswers = @($global:taskRequestBuilderAnswers | Select-Object -Skip 1)
            $answer
        }

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskRequestBuilder.ps1'
        & $script -WorkspaceRoot $workspaceRoot -OutputPath $outputPath -RepositoryNames api, web | Out-Null
        $request = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

        $request.task.key | Should -Be 'FEATURE-123'
        $request.repositories.Name | Should -Be @('api', 'web')
        $request.repositories[0].path | Should -Be (Join-Path $canonsPath 'api')
        $request.repositories[0].baseBranch | Should -Be 'develop'
        $request.repositories[0].branch | Should -Be 'feature/FEATURE-123'
        $request.workspace.file | Should -Be (Join-Path $workspaceRoot 'team.code-workspace')
        Test-Path -LiteralPath (Join-Path $workspaceRoot 'tasks/FEATURE-123') | Should -BeFalse
    }
}

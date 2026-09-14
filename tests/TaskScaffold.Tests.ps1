Describe 'Invoke-TaskScaffold' {
    It 'emits a worktree plan without creating task state' {
        $repositoryPath = Join-Path $TestDrive 'api'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $requestPath = Join-Path $TestDrive 'task-request.json'
        @"
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "$(Join-Path $TestDrive 'prd.md')" },
  "repositories": [
    { "name": "api", "path": "$repositoryPath", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
"@ | Set-Content -LiteralPath $requestPath -NoNewline

        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $tasksRoot = Join-Path $TestDrive 'tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -WorkspaceRoot $workspaceRoot -TasksRoot $tasksRoot | ConvertFrom-Json

        $plan.TaskKey | Should -Be 'FEATURE-123'
        $plan.WorktreeOperations.Count | Should -Be 1
        $plan.WorktreeOperations[0].Action | Should -Be 'create-local'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $workspaceRoot 'worktrees/FEATURE-123/api') | Should -BeFalse
    }

    It 'applies the task skeleton and planned worktree after explicit confirmation' {
        $repositoryPath = Join-Path $TestDrive 'api-apply'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $prdPath = Join-Path $TestDrive 'prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Add endpoint'
        $requestPath = Join-Path $TestDrive 'apply-request.json'
        @"
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "$prdPath" },
  "repositories": [
    { "name": "api", "path": "$repositoryPath", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
"@ | Set-Content -LiteralPath $requestPath -NoNewline

        $workspaceRoot = Join-Path $TestDrive 'workspace-apply'
        $tasksRoot = Join-Path $TestDrive 'tasks-apply'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        & $script -RequestPath $requestPath -WorkspaceRoot $workspaceRoot -TasksRoot $tasksRoot -Apply | Out-Null

        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be "# Add endpoint`n"
        Test-Path -LiteralPath (Join-Path $taskPath 'PLAN.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'STATUS.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'task.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'artifacts') | Should -BeTrue
        (& git -C (Join-Path $workspaceRoot 'worktrees/FEATURE-123/api') branch --show-current) | Should -Be 'feature/FEATURE-123'
    }

    It 'only proposes workspace folders until the dedicated workspace script applies them' {
        $repositoryPath = Join-Path $TestDrive 'api-workspace'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $prdPath = Join-Path $TestDrive 'workspace-prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Workspace endpoint'
        $workspaceFile = Join-Path $TestDrive 'team.code-workspace'
        '{ "folders": [], "settings": { "keep": true } }' | Set-Content -LiteralPath $workspaceFile -NoNewline
        $requestPath = Join-Path $TestDrive 'workspace-request.json'
        @"
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "$prdPath" },
  "repositories": [
    { "name": "api", "path": "$repositoryPath", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ],
  "workspace": { "file": "$workspaceFile" }
}
"@ | Set-Content -LiteralPath $requestPath -NoNewline

        $workspaceRoot = Join-Path $TestDrive 'workspace-root'
        $tasksRoot = Join-Path $TestDrive 'workspace-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $before = Get-Content -LiteralPath $workspaceFile -Raw
        $plan = & $script -RequestPath $requestPath -WorkspaceRoot $workspaceRoot -TasksRoot $tasksRoot | ConvertFrom-Json
        & $script -RequestPath $requestPath -WorkspaceRoot $workspaceRoot -TasksRoot $tasksRoot -Apply | Out-Null

        $plan.WorkspaceFolderPlan.Action | Should -Be 'add'
        $plan.WorkspaceFolderPlan.RequiresConfirmation | Should -BeTrue
        (Get-Content -LiteralPath $workspaceFile -Raw) | Should -Be $before

        $foldersJson = @([ordered]@{ path = (Join-Path $workspaceRoot 'worktrees/FEATURE-123/api'); name = '🔧 worktree: FEATURE-123 api' }) | ConvertTo-Json -Compress
        $workspaceScript = Join-Path $PSScriptRoot '../scripts/Update-WorkspaceFolders.ps1'
        & $workspaceScript -WorkspaceFile $workspaceFile -FoldersJson $foldersJson -Apply -ExpectedSha256 $plan.WorkspaceFolderPlan.OriginalSha256 | Out-Null
        (Get-Content -LiteralPath $workspaceFile -Raw) | Should -Be $plan.WorkspaceFolderPlan.ProposedContent
    }

    It 'refuses to overwrite a task with a different PRD' {
        $repositoryPath = Join-Path $TestDrive 'api-collision'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $prdPath = Join-Path $TestDrive 'new-prd.md'
        Set-Content -LiteralPath $prdPath -Value '# New PRD'
        $tasksRoot = Join-Path $TestDrive 'tasks-collision'
        $existingTask = Join-Path $tasksRoot 'FEATURE-123'
        New-Item -ItemType Directory -Path $existingTask -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $existingTask 'PRD.md') -Value '# Different PRD'
        $requestPath = Join-Path $TestDrive 'collision-request.json'
        @"
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "$prdPath" },
  "repositories": [
    { "name": "api", "path": "$repositoryPath", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
"@ | Set-Content -LiteralPath $requestPath -NoNewline

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        { & $script -RequestPath $requestPath -WorkspaceRoot (Join-Path $TestDrive 'workspace-collision') -TasksRoot $tasksRoot -Apply } | Should -Throw '*different PRD.md*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'workspace-collision/worktrees/FEATURE-123/api') | Should -BeFalse
    }
}

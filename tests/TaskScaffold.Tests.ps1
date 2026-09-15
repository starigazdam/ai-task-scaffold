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
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $plan.TaskKey | Should -Be 'FEATURE-123'
        $plan.WorktreeOperations.Count | Should -Be 1
        $plan.WorktreeOperations[0].Action | Should -Be 'create-local'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse
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
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply | Out-Null

        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be "# Add endpoint`n"
        Test-Path -LiteralPath (Join-Path $taskPath 'PLAN.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'STATUS.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'task.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'artifacts') | Should -BeTrue
        (& git -C (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') branch --show-current) | Should -Be 'feature/FEATURE-123'
    }

    It 'refuses a task directory swapped to a symlink after creation on Linux' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-task-symlink-race'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $prdPath = Join-Path $TestDrive 'task-symlink-race-prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Add endpoint'
        $tasksRoot = Join-Path $TestDrive 'tasks-task-symlink-race'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        $externalTaskPath = Join-Path $TestDrive 'external-task-symlink-race'
        $requestPath = Join-Path $TestDrive 'task-symlink-race-request.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = $prdPath }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        function New-Item {
            param([string]$Path, [string]$ItemType, [switch]$Force)
            $result = Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Path $Path -Force:$Force
            if ($Path -ceq $taskPath) {
                Move-Item -LiteralPath $taskPath -Destination $externalTaskPath
                Microsoft.PowerShell.Management\New-Item -ItemType SymbolicLink -Path $taskPath -Target $externalTaskPath | Out-Null
            }
            return $result
        }
        try {
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply } | Should -Throw '*unsafe-task-path*'
        }
        finally {
            Remove-Item -Path function:New-Item -Force -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath (Join-Path $externalTaskPath 'PRD.md') | Should -BeFalse
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
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply | Out-Null

        $plan.WorkspaceFolderPlan.Action | Should -Be 'add'
        $plan.WorkspaceFolderPlan.RequiresConfirmation | Should -BeTrue
        (Get-Content -LiteralPath $workspaceFile -Raw) | Should -Be $before

        $foldersJson = @([ordered]@{ path = (Join-Path $tasksRoot 'FEATURE-123/worktrees/api'); name = '🔧 worktree: FEATURE-123 api' }) | ConvertTo-Json -Compress
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
        @"
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "PRD.md" },
  "repositories": [
    { "name": "api", "path": "$repositoryPath", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ],
  "phases": []
}
"@ | Set-Content -LiteralPath (Join-Path $existingTask 'task.json') -NoNewline
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
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply } | Should -Throw '*different PRD.md*'
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse
    }

    It 'refuses a case-distinct existing manifest title' {
        $repositoryPath = Join-Path $TestDrive 'api-manifest-case'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $prdPath = Join-Path $TestDrive 'manifest-case-prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Same PRD'
        $tasksRoot = Join-Path $TestDrive 'tasks-manifest-case'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Copy-Item -LiteralPath $prdPath -Destination (Join-Path $taskPath 'PRD.md')
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'add endpoint'; prdPath = 'PRD.md' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            phases = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskPath 'task.json') -NoNewline
        $requestPath = Join-Path $TestDrive 'manifest-case-request.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = $prdPath }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply } | Should -Throw '*manifest differs*'
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'refuses an existing task whose manifest differs from the request' {
        $repositoryPath = Join-Path $TestDrive 'api-manifest-collision'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $prdPath = Join-Path $TestDrive 'manifest-prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Same PRD'
        $tasksRoot = Join-Path $TestDrive 'tasks-manifest-collision'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Copy-Item -LiteralPath $prdPath -Destination (Join-Path $taskPath 'PRD.md')
        '{"schemaVersion":1,"task":{"key":"FEATURE-123","title":"Old title","prdPath":"PRD.md"},"repositories":[],"phases":[]}' | Set-Content -LiteralPath (Join-Path $taskPath 'task.json') -NoNewline
        $requestPath = Join-Path $TestDrive 'manifest-collision-request.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = $prdPath }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply } | Should -Throw '*manifest differs*'
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }
}

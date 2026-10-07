Describe 'Invoke-TaskScaffold' {
    BeforeAll {
        function Invoke-TaskScaffoldWithCurrentPlan {
            param([string]$ScriptPath, [string]$RequestPath, [string]$TasksRoot)

            $plan = & $ScriptPath -RequestPath $RequestPath -TasksRoot $TasksRoot | ConvertFrom-Json
            & $ScriptPath -RequestPath $RequestPath -TasksRoot $TasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null
            return $plan
        }

        function New-TaskScaffoldIdentityRepository {
            param([string]$RepositoryPath)

            New-Item -ItemType Directory -Path $RepositoryPath -Force | Out-Null
            & git -C $RepositoryPath init -b main | Out-Null
            & git -C $RepositoryPath config user.name Test
            & git -C $RepositoryPath config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $RepositoryPath 'README.md') -Value 'fixture'
            & git -C $RepositoryPath add README.md
            & git -C $RepositoryPath commit -m fixture | Out-Null
        }
    }

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
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = (Join-Path $TestDrive 'prd.md') }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $tasksRoot = Join-Path $TestDrive 'tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $plan.TaskKey | Should -Be 'FEATURE-123'
        $plan.RequestedProfiles | Should -BeNullOrEmpty
        $plan.InjectedProfiles.Name | Should -Be 'task-scaffold'
        $plan.EffectiveProfiles.Name | Should -Be 'task-scaffold'
        $plan.WorktreeOperations.Count | Should -Be 1
        $plan.WorktreeOperations[0].Action | Should -Be 'create-local'
        $plan.PlanIdentity | Should -Match '^[a-f0-9]{64}$'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse
    }

    It 'rejects apply without a reviewed plan identity before creating task state' {
        $repositoryPath = Join-Path $TestDrive 'api-missing-plan-identity'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'missing-plan-identity.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'missing-plan-identity-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply } | Should -Throw '*Apply requires ExpectedPlanIdentity*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
    }

    It 'rejects a changed request before creating task state' {
        $repositoryPath = Join-Path $TestDrive 'api-request-identity'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'request-identity.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'request-identity-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $changedRequest = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
        $changedRequest.task.title = 'Change after review'
        $changedRequest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse
    }

    It 'rejects changed task scaffold state before creating a worktree' {
        $repositoryPath = Join-Path $TestDrive 'api-task-state-identity'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-state-identity.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'task-state-identity-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $taskPath 'PLAN.md') -Value 'State changed after review'

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $taskPath 'task.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $taskPath 'PLAN.md') -Raw).Trim() | Should -Be 'State changed after review'
    }

    It 'rejects changed repository refs before creating task state' {
        $repositoryPath = Join-Path $TestDrive 'api-repository-identity'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'repository-identity.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'repository-identity-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'base branch changed after review'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m 'advance base after review' | Out-Null

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse
    }

    It 'rechecks covered inputs under the mutation lock before mutating state' {
        $repositoryPath = Join-Path $TestDrive 'api-under-lock'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'under-lock-request.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'under-lock-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        function Enter-TaskMutationLock {
            param([string]$TasksRoot)
            $lock = & (Get-Module GitWorktree) { param($root) Enter-TaskMutationLock -TasksRoot $root } $TasksRoot
            Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'base branch advanced under the mutation lock'
            & git -C $repositoryPath add README.md
            & git -C $repositoryPath commit -m 'advance base under lock' | Out-Null
            return $lock
        }
        try {
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed before apply*'
        }
        finally {
            Remove-Item -Path function:Enter-TaskMutationLock -Force -ErrorAction SilentlyContinue
        }

        (& git -C $repositoryPath log -1 --format=%s) | Should -Be 'advance base under lock'
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse
    }

    It 'rejects changed profile instructions before creating task state' {
        $repositoryPath = Join-Path $TestDrive 'api-profile-identity'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $profilePath = Join-Path $TestDrive 'team-profile-identity'
        New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profilePath 'AGENTS.md') -Value '# Team profile'
        $requestPath = Join-Path $TestDrive 'profile-identity.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            profiles = @([ordered]@{ name = 'team'; path = $profilePath })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'profile-identity-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        Set-Content -LiteralPath (Join-Path $profilePath 'AGENTS.md') -Value '# Team profile changed after review'

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse
    }

    It 'rejects invalid profile roots before creating task state' {
        $profileWithoutAgents = Join-Path $TestDrive 'profile-without-agents'
        New-Item -ItemType Directory -Path $profileWithoutAgents -Force | Out-Null
        $requestPath = Join-Path $TestDrive 'invalid-profile-request.json'
        $tasksRoot = Join-Path $TestDrive 'invalid-profile-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $baseRequest = [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = 'C:/does/not/matter'; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        }
        $invalidProfiles = @(
            [pscustomobject]@{ Descriptor = [ordered]@{ name = 'team'; path = (Join-Path $TestDrive 'missing-profile') }; Error = '*directory does not exist*' },
            [pscustomobject]@{ Descriptor = [ordered]@{ name = 'team'; path = $profileWithoutAgents }; Error = '*AGENTS.md is required*' }
        )

        foreach ($invalidProfile in $invalidProfiles) {
            $request = [ordered]@{
                schemaVersion = $baseRequest.schemaVersion
                task = $baseRequest.task
                repositories = $baseRequest.repositories
                profiles = @($invalidProfile.Descriptor)
            }
            $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw $invalidProfile.Error
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        }
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
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = $prdPath }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $workspaceRoot = Join-Path $TestDrive 'workspace-apply'
        $tasksRoot = Join-Path $TestDrive 'tasks-apply'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot | Out-Null

        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw).Replace("`r`n", "`n") | Should -Be (Get-Content -LiteralPath $prdPath -Raw).Replace("`r`n", "`n")
        Test-Path -LiteralPath (Join-Path $taskPath 'PLAN.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'STATUS.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'task.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'artifacts') | Should -BeTrue
        (& git -C (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') branch --show-current) | Should -Be 'feature/FEATURE-123'
    }

        It 'creates a starter PRD when the source path is omitted or missing' {
        $repositoryPath = Join-Path $TestDrive 'api-starter-prd'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $tasksRoot = Join-Path $TestDrive 'tasks-starter-prd'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $cases = @(
            [pscustomobject]@{ Key = 'FEATURE-123'; PrdPath = $null },
            [pscustomobject]@{ Key = 'FEATURE-124'; PrdPath = (Join-Path $TestDrive 'missing-prd.md') }
        )

        foreach ($case in $cases) {
            $task = [ordered]@{ key = $case.Key; title = 'Add endpoint' }
            if ($null -ne $case.PrdPath) {
                $task.prdPath = $case.PrdPath
            }
            $requestPath = Join-Path $TestDrive "$($case.Key)-starter-request.json"
            [ordered]@{
                schemaVersion = 1
                task = $task
                repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = "feature/$($case.Key)" })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

            $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
            $plan.PrdOperation.Action | Should -Be 'create-starter'
            & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

            $prd = Get-Content -LiteralPath (Join-Path $tasksRoot "$($case.Key)/PRD.md") -Raw
            $prd | Should -Match "^# Add endpoint"
            $prd | Should -Match '## Context'
            $prd | Should -Match '## Objective'
            $prd | Should -Match '## Scope'
            $prd | Should -Match '## Requirements'
            $prd | Should -Match '## Acceptance Criteria'
            $prd | Should -Match '## Out of Scope'
            $prd | Should -Match '## Open Questions'
        }
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
            { Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*unsafe-task-path*'
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
        $profilePaths = @('team', 'dotnet') | ForEach-Object {
            $profilePath = Join-Path $TestDrive "workspace-profile-$_"
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $profilePath 'AGENTS.md') -Value "# $_"
            $profilePath
        }
        $requestPath = Join-Path $TestDrive 'workspace-request.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = $prdPath }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            profiles = @(
                [ordered]@{ name = 'team'; path = $profilePaths[0] },
                [ordered]@{ name = 'dotnet'; path = $profilePaths[1] }
            )
            workspace = [ordered]@{ file = $workspaceFile }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $workspaceRoot = Join-Path $TestDrive 'workspace-root'
        $tasksRoot = Join-Path $TestDrive 'workspace-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $before = Get-Content -LiteralPath $workspaceFile -Raw
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $ctxPath = Join-Path (Join-Path $tasksRoot 'FEATURE-123') '.ctx'
        $expectedCtx = (@($plan.EffectiveProfiles | ForEach-Object { "$($_.Name):$($_.Path)" }) -join "`n") + "`n"
        $plan.CtxFilePlan.Action | Should -Be 'create'
        $plan.CtxFilePlan.Path | Should -Be $ctxPath
        $plan.CtxFilePlan.Content | Should -Be $expectedCtx
        Test-Path -LiteralPath $ctxPath | Should -BeFalse
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

        [IO.File]::ReadAllText($ctxPath) | Should -Be $expectedCtx
        $plan.WorkspaceFolderPlan.Action | Should -Be 'add'
        $plan.WorkspaceFolderPlan.RequiresConfirmation | Should -BeTrue
        $plan.EffectiveProfiles.Name | Should -Be @('team', 'dotnet', 'task-scaffold')
        $proposedFolders = ($plan.WorkspaceFolderPlan.ProposedContent | ConvertFrom-Json).folders
        $aiFolders = @($proposedFolders | Where-Object { $_.name.StartsWith('[AI] ') })
        $aiFolders.name | Should -Be @('[AI] team', '[AI] dotnet', '[AI] task-scaffold')
        $aiFolders.path | Should -Be @($plan.EffectiveProfiles.Path)
        $manifest = Get-Content -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/task.json') -Raw | ConvertFrom-Json
        $manifest.profiles.name | Should -Be @('team', 'dotnet', 'task-scaffold')
        (Get-Content -LiteralPath $workspaceFile -Raw) | Should -Be $before

        $foldersJson = @(
            [ordered]@{ path = $profilePaths[0]; name = '[AI] team' },
            [ordered]@{ path = $profilePaths[1]; name = '[AI] dotnet' },
            [ordered]@{ path = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../agent-profile')).Path; name = '[AI] task-scaffold' },
            [ordered]@{ path = (Join-Path $tasksRoot 'FEATURE-123/worktrees/api'); name = '🔧 worktree: FEATURE-123 api' }
        ) | ConvertTo-Json -Compress
        $workspaceScript = Join-Path $PSScriptRoot '../scripts/Update-WorkspaceFolders.ps1'
        & $workspaceScript -WorkspaceFile $workspaceFile -FoldersJson $foldersJson -Apply -ExpectedSha256 $plan.WorkspaceFolderPlan.OriginalSha256 | Out-Null
        (Get-Content -LiteralPath $workspaceFile -Raw) | Should -Be $plan.WorkspaceFolderPlan.ProposedContent

        Set-Content -LiteralPath $ctxPath -Value 'stale:path' -NoNewline
        Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot | Out-Null
        [IO.File]::ReadAllText($ctxPath) | Should -Be $expectedCtx
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
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = 'PRD.md' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            phases = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $existingTask 'task.json') -NoNewline
        $requestPath = Join-Path $TestDrive 'collision-request.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = $prdPath }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        { Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*different PRD.md*'
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
        { Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*manifest differs*'
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
        { Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*manifest differs*'
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'reports profile path drift separately and blocks apply before mutation' {
        $repositoryPath = Join-Path $TestDrive 'api-profile-drift'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $oldProfilePath = Join-Path $TestDrive 'old-team-profile'
        $newProfilePath = Join-Path $TestDrive 'new-team-profile'
        New-Item -ItemType Directory -Path $oldProfilePath, $newProfilePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $oldProfilePath 'AGENTS.md') -Value '# Team'
        Set-Content -LiteralPath (Join-Path $newProfilePath 'AGENTS.md') -Value '# Team'
        $taskPath = Join-Path (Join-Path $TestDrive 'profile-drift-tasks') 'FEATURE-123'
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Value '# Add endpoint'
        $taskScaffoldPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../agent-profile')).Path
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint'; prdPath = 'PRD.md' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; branch = 'feature/FEATURE-123'; baseBranch = 'main' })
            profiles = @(
                [ordered]@{ name = 'team'; path = $oldProfilePath },
                [ordered]@{ name = 'task-scaffold'; path = $taskScaffoldPath }
            )
            phases = @()
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskPath 'task.json') -NoNewline

        $requestPath = Join-Path $TestDrive 'profile-drift-request.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            profiles = @([ordered]@{ name = 'team'; path = $newProfilePath })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline

        $tasksRoot = Split-Path -Parent $taskPath
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $plan.ProfileIdentityMatches | Should -BeTrue
        $plan.ProfilePathDrift.Count | Should -Be 1
        $plan.ProfilePathDrift[0].Name | Should -Be 'team'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*reconciliation is required*'
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse

        $manifestPath = Join-Path $taskPath 'task.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.profiles | Where-Object { $_.name -eq 'team' } | ForEach-Object { $_.path = $newProfilePath }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -NoNewline

        $reconciledPlan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $reconciledPlan.ProfileIdentityMatches | Should -BeTrue
        $reconciledPlan.ProfilePathDrift.Count | Should -Be 0
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $reconciledPlan.PlanIdentity | Out-Null

        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeTrue
        $reconciledManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $reconciledManifest.profiles.name | Should -Be @('team', 'task-scaffold')
        ([IO.Path]::GetFullPath([string]$reconciledManifest.profiles[0].path)) | Should -Be ([IO.Path]::GetFullPath($newProfilePath))
    }

    It 'adds the injected profile when applying a legacy profileless task manifest' {
        $repositoryPath = Join-Path $TestDrive 'api-legacy-profiles'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $tasksRoot = Join-Path $TestDrive 'legacy-profile-tasks'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Value '# Legacy task'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Legacy task'; prdPath = 'PRD.md' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; branch = 'feature/FEATURE-123'; baseBranch = 'main' })
            phases = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskPath 'task.json') -NoNewline
        $requestPath = Join-Path $TestDrive 'legacy-profile-request.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Legacy task' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        Invoke-TaskScaffoldWithCurrentPlan -ScriptPath $script -RequestPath $requestPath -TasksRoot $tasksRoot | Out-Null

        $manifest = Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw | ConvertFrom-Json
        $manifest.profiles.Name | Should -Be 'task-scaffold'
        $manifest.repositories.Name | Should -Be 'api'
    }

    Context 'ctx root directives' {
        BeforeAll {
            function New-CtxRootFixture {
                param([Parameter(Mandatory)][string]$Name)

                $base = Join-Path $TestDrive $Name
                $configRoot = Join-Path $base 'ai-config'
                $teamProfile = Join-Path $configRoot 'profiles/team'
                New-Item -ItemType Directory -Path $teamProfile -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $teamProfile 'AGENTS.md') -Value '# team' -NoNewline
                $externalRoot = Join-Path $base 'external'
                New-Item -ItemType Directory -Path $externalRoot -Force | Out-Null

                [pscustomobject]@{
                    ConfigRoot   = $configRoot
                    TeamProfile  = $teamProfile
                    ExternalRoot = $externalRoot
                }
            }

            function New-CtxRootRequest {
                param(
                    [Parameter(Mandatory)][string]$RepositoryPath,
                    [Parameter(Mandatory)][string]$TeamProfilePath,
                    [string]$Key = 'FEATURE-123'
                )

                [ordered]@{
                    schemaVersion = 2
                    task          = [ordered]@{ key = $Key; title = 'Add endpoint' }
                    repositories  = @([ordered]@{ name = 'api'; path = $RepositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
                    profiles      = @([ordered]@{ name = 'team'; path = $TeamProfilePath })
                }
            }
        }

        It 'plans root-mode .ctx with relative directives and touches neither the tasks root nor the environment' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-plan'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-plan-fixture'
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-plan-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $requestPath = Join-Path $TestDrive 'ctx-roots-plan.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
            $agentProfilePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../agent-profile')).Path

            $configEnvBefore = $env:AI_CTX_PROFILES_CONFIG_ROOT
            $externalEnvBefore = $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT

            $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot | ConvertFrom-Json

            $expected = @(
                "config-root:$([IO.Path]::GetRelativePath($taskPath, $fixture.ConfigRoot))"
                "external-profiles-root:$([IO.Path]::GetRelativePath($taskPath, $fixture.ExternalRoot))"
                "team:$([IO.Path]::GetRelativePath($taskPath, $fixture.TeamProfile))"
                "task-scaffold:$([IO.Path]::GetRelativePath($taskPath, $agentProfilePath))"
            ) -join "`n"
            $expected += "`n"

            $plan.CtxFilePlan.Action | Should -Be 'create'
            ($plan.CtxFilePlan.Content -ceq $expected) | Should -BeTrue -Because 'root-mode content must match exactly'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
            $env:AI_CTX_PROFILES_CONFIG_ROOT | Should -Be $configEnvBefore
            $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT | Should -Be $externalEnvBefore
        }

        It 'keeps legacy absolute .ctx content byte-identical when no roots are supplied' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-legacy'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-legacy-fixture'
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-legacy-tasks'
            $requestPath = Join-Path $TestDrive 'ctx-roots-legacy.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
            $agentProfilePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../agent-profile')).Path

            $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

            $expected = "team:$($fixture.TeamProfile)`ntask-scaffold:$agentProfilePath`n"
            ($plan.CtxFilePlan.Content -ceq $expected) | Should -BeTrue -Because 'legacy content must be unchanged'
        }

        It 'emits only the supplied directive and binds roots into the plan identity' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-identity'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixtureA = New-CtxRootFixture -Name 'ctx-roots-identity-a'
            $fixtureB = New-CtxRootFixture -Name 'ctx-roots-identity-b'
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-identity-tasks'
            $requestPath = Join-Path $TestDrive 'ctx-roots-identity.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixtureA.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $withoutRoots = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
            $externalOnly = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxExternalProfilesRoot $fixtureA.ExternalRoot | ConvertFrom-Json
            $withA = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixtureA.ConfigRoot | ConvertFrom-Json
            $withB = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixtureB.ConfigRoot | ConvertFrom-Json

            $externalOnly.CtxFilePlan.Content | Should -Match '^external-profiles-root:'
            $externalOnly.CtxFilePlan.Content | Should -Not -Match '(?m)^config-root:'

            $withA.PlanIdentity | Should -Not -Be $withoutRoots.PlanIdentity
            $withB.PlanIdentity | Should -Not -Be $withA.PlanIdentity
        }

        It 'rejects invalid ctx roots before any task state is created' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-invalid'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-invalid-fixture'
            $requestPath = Join-Path $TestDrive 'ctx-roots-invalid.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $fileRoot = Join-Path $TestDrive 'ctx-roots-invalid-file'
            Set-Content -LiteralPath $fileRoot -Value 'not a directory' -NoNewline
            $missingRoot = Join-Path $TestDrive 'ctx-roots-invalid-missing'
            $noProfilesRoot = Join-Path $TestDrive 'ctx-roots-invalid-no-profiles'
            New-Item -ItemType Directory -Path $noProfilesRoot -Force | Out-Null

            $tasksRoot = Join-Path $TestDrive 'ctx-roots-invalid-tasks'
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $missingRoot } | Should -Throw '*must be an absolute existing directory*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot 'relative/path' } | Should -Throw '*must be an absolute existing directory*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fileRoot } | Should -Throw '*must be an absolute existing directory*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $noProfilesRoot } | Should -Throw "*must contain a 'profiles' directory*"
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxExternalProfilesRoot $missingRoot } | Should -Throw '*must be an absolute existing directory*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        }

        It 'rejects a raw line break in the supplied root even when nothing is cancelled' {
            if (-not $IsLinux) { Set-ItResult -Skipped -Because 'embedding a raw newline in a directory name is Linux-only'; return }

            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-linebreak'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-linebreak-fixture'
            $requestPath = Join-Path $TestDrive 'ctx-roots-linebreak.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $lineBreakRoot = Join-Path $TestDrive "ctx-roots-invalid-linebreak`nmore"
            New-Item -ItemType Directory -Path (Join-Path $lineBreakRoot 'profiles') -Force | Out-Null
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-linebreak-tasks'

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $lineBreakRoot } | Should -Throw '*must not contain line breaks*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        }

        It 'rejects a line break even when a trailing .. would otherwise cancel it out during normalization' {
            if (-not $IsLinux) { Set-ItResult -Skipped -Because 'embedding a raw newline in a directory name is Linux-only'; return }

            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-linebreak-bypass'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-linebreak-bypass-fixture'
            $requestPath = Join-Path $TestDrive 'ctx-roots-linebreak-bypass.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $bypassBase = Join-Path $TestDrive 'ctx-roots-linebreak-bypass-base'
            $noisyDir = Join-Path $bypassBase "noisy`nsegment"
            $realConfigRoot = Join-Path $bypassBase 'real-config'
            New-Item -ItemType Directory -Path (Join-Path $realConfigRoot 'profiles') -Force | Out-Null
            New-Item -ItemType Directory -Path $noisyDir -Force | Out-Null
            $bypassValue = Join-Path $noisyDir '../real-config'
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-linebreak-bypass-tasks'

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $bypassValue } | Should -Throw '*must not contain line breaks*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        }

        It 'applies root-mode .ctx and re-applies as a no-op without touching the environment' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-apply'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-apply-fixture'
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-apply-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $requestPath = Join-Path $TestDrive 'ctx-roots-apply.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $configEnvBefore = $env:AI_CTX_PROFILES_CONFIG_ROOT
            $externalEnvBefore = $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT

            $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot | ConvertFrom-Json
            & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot | Out-Null

            $ctxPath = Join-Path $taskPath '.ctx'
            $bytes = [IO.File]::ReadAllBytes($ctxPath)
            @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should -Not -Be '239,187,191' -Because '.ctx must be written without a BOM'
            ([IO.File]::ReadAllText($ctxPath) -ceq $plan.CtxFilePlan.Content) | Should -BeTrue -Because 'the applied .ctx must equal the planned content'

            $replan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot | ConvertFrom-Json
            $replan.CtxFilePlan.Action | Should -Be 'noop'
            & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $replan.PlanIdentity -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot | Out-Null
            [IO.File]::ReadAllText($ctxPath) | Should -Be $plan.CtxFilePlan.Content

            $env:AI_CTX_PROFILES_CONFIG_ROOT | Should -Be $configEnvBefore
            $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT | Should -Be $externalEnvBefore
        }

        It 'rejects a reviewed identity when ctx roots change, are added, or are removed before apply' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-stale'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixtureA = New-CtxRootFixture -Name 'ctx-roots-stale-a'
            $fixtureB = New-CtxRootFixture -Name 'ctx-roots-stale-b'
            $requestPath = Join-Path $TestDrive 'ctx-roots-stale.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixtureA.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $tasksRootA = Join-Path $TestDrive 'ctx-roots-stale-changed-tasks'
            $planA = & $script -RequestPath $requestPath -TasksRoot $tasksRootA -CtxConfigRoot $fixtureA.ConfigRoot | ConvertFrom-Json
            { & $script -RequestPath $requestPath -TasksRoot $tasksRootA -Apply -ExpectedPlanIdentity $planA.PlanIdentity -CtxConfigRoot $fixtureB.ConfigRoot } | Should -Throw '*plan identity changed*'
            Test-Path -LiteralPath (Join-Path $tasksRootA 'FEATURE-123') | Should -BeFalse

            $tasksRootB = Join-Path $TestDrive 'ctx-roots-stale-removed-tasks'
            $planB = & $script -RequestPath $requestPath -TasksRoot $tasksRootB -CtxConfigRoot $fixtureA.ConfigRoot -CtxExternalProfilesRoot $fixtureA.ExternalRoot | ConvertFrom-Json
            { & $script -RequestPath $requestPath -TasksRoot $tasksRootB -Apply -ExpectedPlanIdentity $planB.PlanIdentity } | Should -Throw '*plan identity changed*'
            Test-Path -LiteralPath (Join-Path $tasksRootB 'FEATURE-123') | Should -BeFalse

            $tasksRootC = Join-Path $TestDrive 'ctx-roots-stale-added-tasks'
            $planC = & $script -RequestPath $requestPath -TasksRoot $tasksRootC | ConvertFrom-Json
            { & $script -RequestPath $requestPath -TasksRoot $tasksRootC -Apply -ExpectedPlanIdentity $planC.PlanIdentity -CtxConfigRoot $fixtureA.ConfigRoot } | Should -Throw '*plan identity changed*'
            Test-Path -LiteralPath (Join-Path $tasksRootC 'FEATURE-123') | Should -BeFalse
        }

        It 'rejects apply when a supplied config root disappears after review' {
            $repositoryPath = Join-Path $TestDrive 'api-ctx-roots-removed'
            New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
            $fixture = New-CtxRootFixture -Name 'ctx-roots-removed-fixture'
            $tasksRoot = Join-Path $TestDrive 'ctx-roots-removed-tasks'
            $requestPath = Join-Path $TestDrive 'ctx-roots-removed.json'
            (New-CtxRootRequest -RepositoryPath $repositoryPath -TeamProfilePath $fixture.TeamProfile) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
            $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

            $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot | ConvertFrom-Json
            Remove-Item -LiteralPath $fixture.ConfigRoot -Recurse -Force

            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity -CtxConfigRoot $fixture.ConfigRoot } | Should -Throw '*must be an absolute existing directory*'
            Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse
        }
    }
}

Describe 'Invoke-TaskScaffold task files' {
    BeforeAll {
        function New-TaskScaffoldIdentityRepository {
            param([string]$RepositoryPath)

            New-Item -ItemType Directory -Path $RepositoryPath -Force | Out-Null
            & git -C $RepositoryPath init -b main | Out-Null
            & git -C $RepositoryPath config user.name Test
            & git -C $RepositoryPath config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $RepositoryPath 'README.md') -Value 'fixture'
            & git -C $RepositoryPath add README.md
            & git -C $RepositoryPath commit -m fixture | Out-Null
        }

        function New-ExistingTaskFixture {
            param([string]$RepositoryPath, [string]$TasksRoot, [string]$TaskKey)

            $taskPath = Join-Path $TasksRoot $TaskKey
            New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Value '# Add endpoint' -NoNewline
            [ordered]@{
                schemaVersion = 1
                task = [ordered]@{ key = $TaskKey; title = 'Add endpoint'; prdPath = 'PRD.md' }
                repositories = @([ordered]@{ name = 'api'; path = $RepositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
                phases = @()
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskPath 'task.json') -NoNewline
            return $taskPath
        }
    }

    It 'creates no custom files when taskFiles is omitted' {
        $repositoryPath = Join-Path $TestDrive 'api-no-task-files'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'no-task-files.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'no-task-files-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        @($plan.CustomFileOperations).Count | Should -Be 0
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

        $manifest = Get-Content -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/task.json') -Raw | ConvertFrom-Json
        $manifest.PSObject.Properties['taskFiles'] | Should -BeNullOrEmpty
    }

    It 'creates caller task files with exact UTF-8 bytes and records their paths' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-create'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $rootContent = "# Guidance`nno trailing newline — ünïcode ✓"
        $nestedContent = 'nested-content'
        $requestPath = Join-Path $TestDrive 'task-files-create.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @(
                [ordered]@{ path = 'AGENTS.md'; content = $rootContent },
                [ordered]@{ path = 'guidance/sub/note.md'; content = $nestedContent }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'task-files-create-tasks'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        @($plan.CustomFileOperations).Count | Should -Be 2
        $plan.CustomFileOperations[0].Path | Should -Be 'AGENTS.md'
        $plan.CustomFileOperations[0].Action | Should -Be 'create'
        $plan.CustomFileOperations[1].Path | Should -Be 'guidance/sub/note.md'
        $plan.CustomFileOperations[1].Action | Should -Be 'create'
        Test-Path -LiteralPath (Join-Path $taskPath 'AGENTS.md') | Should -BeFalse

        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

        $expectedBytes = ([Text.UTF8Encoding]::new($false)).GetBytes($rootContent)
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $taskPath 'AGENTS.md'))) | Should -Be ([Convert]::ToHexString($expectedBytes))
        [IO.File]::ReadAllText((Join-Path $taskPath 'guidance/sub/note.md')) | Should -Be $nestedContent
        $manifest = Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw | ConvertFrom-Json
        @($manifest.taskFiles) | Should -Be @('AGENTS.md', 'guidance/sub/note.md')
    }

    It 'preserves recorded caller paths when a later request omits taskFiles' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-reuse'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-reuse-tasks'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        $withFilesPath = Join-Path $TestDrive 'task-files-reuse-with-files.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'guidance' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $withFilesPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $withFilesPath -TasksRoot $tasksRoot | ConvertFrom-Json
        & $script -RequestPath $withFilesPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

        $withoutFilesPath = Join-Path $TestDrive 'task-files-reuse-without-files.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $withoutFilesPath -NoNewline
        $reusePlan = & $script -RequestPath $withoutFilesPath -TasksRoot $tasksRoot | ConvertFrom-Json
        @($reusePlan.CustomFileOperations).Count | Should -Be 0
        & $script -RequestPath $withoutFilesPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $reusePlan.PlanIdentity | Out-Null

        $manifest = Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw | ConvertFrom-Json
        @($manifest.taskFiles) | Should -Be @('AGENTS.md')
    }

    It 'treats a byte-identical existing caller file as a no-op' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-noop'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $content = 'identical — content'
        $tasksRoot = Join-Path $TestDrive 'task-files-noop-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        [IO.File]::WriteAllText((Join-Path $taskPath 'AGENTS.md'), $content, [Text.UTF8Encoding]::new($false))
        $requestPath = Join-Path $TestDrive 'task-files-noop.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = $content })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'noop'
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

        [IO.File]::ReadAllText((Join-Path $taskPath 'AGENTS.md')) | Should -Be $content
        $manifest = Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw | ConvertFrom-Json
        @($manifest.taskFiles) | Should -Be @('AGENTS.md')
    }

    It 'blocks a differing existing caller file before any worktree mutation' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-conflict'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-conflict-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        Set-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Value 'existing different' -NoNewline
        $requestPath = Join-Path $TestDrive 'task-files-conflict.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'requested different' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*destination-differs*'
        (Get-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Raw) | Should -Be 'existing different'
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'blocks a caller destination that is an existing directory' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-dir'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-dir-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        New-Item -ItemType Directory -Path (Join-Path $taskPath 'notes') -Force | Out-Null
        $requestPath = Join-Path $TestDrive 'task-files-dir.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'notes'; content = 'x' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*destination-is-directory*'
        Test-Path -LiteralPath (Join-Path $taskPath 'notes') -PathType Container | Should -BeTrue
    }

    It 'invalidates the reviewed identity when caller file content changes' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-content-drift'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-files-content-drift.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'version one' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'task-files-content-drift-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $changed = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
        $changed.taskFiles[0].content = 'version two'
        $changed | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
    }

    It 'invalidates the reviewed identity when a caller destination changes bytes' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-byte-drift'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-byte-drift-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        [IO.File]::WriteAllText((Join-Path $taskPath 'AGENTS.md'), 'original', [Text.UTF8Encoding]::new($false))
        $requestPath = Join-Path $TestDrive 'task-files-byte-drift.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'original' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'noop'

        [IO.File]::WriteAllText((Join-Path $taskPath 'AGENTS.md'), 'changed externally', [Text.UTF8Encoding]::new($false))

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'invalidates the reviewed identity when a caller destination path changes' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-path-drift'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-files-path-drift.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'guidance/AGENTS.md'; content = 'x' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'task-files-path-drift-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $changed = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
        $changed.taskFiles[0].path = 'guidance/team/AGENTS.md'
        $changed | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
    }

    It 'invalidates the reviewed identity when a caller destination appears' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-state-drift'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-files-state-drift.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'x' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'task-files-state-drift-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Value 'x' -NoNewline

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed since review*'
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
    }

    It 'refuses a symlinked caller path without writing outside the task root' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-symlink'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-symlink-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        $externalPath = Join-Path $TestDrive 'external-task-files'
        New-Item -ItemType Directory -Path $externalPath -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $taskPath 'link') -Target $externalPath | Out-Null
        $requestPath = Join-Path $TestDrive 'task-files-symlink.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'link/AGENTS.md'; content = 'escape' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*unsafe-task-file-path*'
        Test-Path -LiteralPath (Join-Path $externalPath 'AGENTS.md') | Should -BeFalse
    }

    It 'rechecks caller files under the mutation lock before mutating state' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-under-lock'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-files-under-lock.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'reviewed' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $tasksRoot = Join-Path $TestDrive 'task-files-under-lock-tasks'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json

        function Enter-TaskMutationLock {
            param([string]$TasksRoot)
            $lock = & (Get-Module GitWorktree) { param($root) Enter-TaskMutationLock -TasksRoot $root } $TasksRoot
            New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Value 'changed under lock' -NoNewline
            return $lock
        }
        try {
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*plan identity changed before apply*'
        }
        finally {
            Remove-Item -Path function:Enter-TaskMutationLock -Force -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'reports a symlinked existing destination as a reparse-point conflict' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-reparse-dest'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-reparse-dest-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        $externalPath = Join-Path $TestDrive 'external-reparse-dest'
        New-Item -ItemType Directory -Path $externalPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $externalPath 'secret.txt') -Value 'outside' -NoNewline
        New-Item -ItemType SymbolicLink -Path (Join-Path $taskPath 'AGENTS.md') -Target (Join-Path $externalPath 'secret.txt') | Out-Null
        $requestPath = Join-Path $TestDrive 'task-files-reparse-dest.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'x' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        $plan.CustomFileOperations[0].Reason | Should -Be 'reparse-point'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*reparse-point*'
        (Get-Content -LiteralPath (Join-Path $externalPath 'secret.txt') -Raw) | Should -Be 'outside'
    }

    It 'refuses a deeper nested caller link without following it' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-deep-link'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-deep-link-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        New-Item -ItemType Directory -Path (Join-Path $taskPath 'a') -Force | Out-Null
        $externalPath = Join-Path $TestDrive 'external-deep-link'
        New-Item -ItemType Directory -Path $externalPath -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $taskPath 'a/link') -Target $externalPath | Out-Null
        $requestPath = Join-Path $TestDrive 'task-files-deep-link.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'a/link/AGENTS.md'; content = 'escape' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        $plan.CustomFileOperations[0].Reason | Should -Be 'unsafe-task-file-path'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*unsafe-task-file-path*'
        Test-Path -LiteralPath (Join-Path $externalPath 'AGENTS.md') | Should -BeFalse
    }

    It 'blocks a caller file whose ancestor is an existing regular file' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-ancestor-file'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-ancestor-file-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        Set-Content -LiteralPath (Join-Path $taskPath 'notes') -Value 'not a directory' -NoNewline
        $requestPath = Join-Path $TestDrive 'task-files-ancestor-file.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'notes/AGENTS.md'; content = 'x' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        $plan.CustomFileOperations[0].Reason | Should -Be 'ancestor-is-file'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*ancestor-is-file*'
        (Get-Content -LiteralPath (Join-Path $taskPath 'notes') -Raw) | Should -Be 'not a directory'
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'leaves workspace and task state untouched when a caller file conflicts' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-workspace'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-workspace-tasks'
        $taskPath = New-ExistingTaskFixture -RepositoryPath $repositoryPath -TasksRoot $tasksRoot -TaskKey 'FEATURE-123'
        Set-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Value 'existing' -NoNewline
        $workspaceFile = Join-Path $TestDrive 'team.code-workspace'
        '{ "folders": [] }' | Set-Content -LiteralPath $workspaceFile -NoNewline
        $manifestBefore = Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw
        $requestPath = Join-Path $TestDrive 'task-files-workspace.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            workspace = [ordered]@{ file = $workspaceFile }
            taskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 'requested' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        $plan.CustomFileOperations[0].Action | Should -Be 'conflict'
        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity } | Should -Throw '*destination-differs*'

        (Get-Content -LiteralPath $workspaceFile -Raw) | Should -Be '{ "folders": [] }'
        (Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw) | Should -Be $manifestBefore
        (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be '# Add endpoint'
        Test-Path -LiteralPath (Join-Path $taskPath 'PLAN.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $taskPath 'STATUS.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $taskPath 'worktrees/api') | Should -BeFalse
    }

    It 'rejects a rooted or traversing caller path before creating any task state' {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-e2e'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $externalPath = Join-Path $TestDrive 'e2e-external'
        New-Item -ItemType Directory -Path $externalPath -Force | Out-Null
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $cases = @(
            [pscustomobject]@{ Path = (Join-Path $externalPath 'escape.md') },
            [pscustomobject]@{ Path = 'escape/../escape.md' }
        )

        foreach ($case in $cases) {
            $requestPath = Join-Path $TestDrive ('e2e-request-' + [guid]::NewGuid().ToString() + '.json')
            [ordered]@{
                schemaVersion = 2
                task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
                repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
                taskFiles = @([ordered]@{ path = $case.Path; content = 'x' })
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
            $tasksRoot = Join-Path $TestDrive ('e2e-tasks-' + [guid]::NewGuid().ToString())
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*task file path*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        }
        @(Get-ChildItem -LiteralPath $externalPath -Force).Count | Should -Be 0
    }

    It 'rejects Windows path aliases of managed outputs' -Skip:(-not $IsWindows) {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-win-alias'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $tasksRoot = Join-Path $TestDrive 'task-files-win-alias-tasks'
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        foreach ($alias in @('worktrees./api/AGENTS.md', 'PRD.md.', 'task.json ')) {
            $requestPath = Join-Path $TestDrive ('win-alias-' + [guid]::NewGuid().ToString() + '.json')
            [ordered]@{
                schemaVersion = 2
                task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
                repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
                taskFiles = @([ordered]@{ path = $alias; content = 'x' })
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
            { & $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*collides with a scaffold-managed path*'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        }
    }

    It 'rejects Windows normalization-equivalent duplicate destinations' -Skip:(-not $IsWindows) {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-win-dup'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-files-win-dup.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @(
                [ordered]@{ path = 'a.md'; content = 'one' },
                [ordered]@{ path = 'a.md.'; content = 'two' }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        { & $script -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'task-files-win-dup-tasks') } | Should -Throw '*duplicate task file path*'
    }

    It 'rejects a Windows 8.3 short-name task file path before any mutation' -Skip:(-not $IsWindows) {
        $repositoryPath = Join-Path $TestDrive 'api-task-files-short-name'
        New-TaskScaffoldIdentityRepository -RepositoryPath $repositoryPath
        $requestPath = Join-Path $TestDrive 'task-files-short-name.json'
        [ordered]@{
            schemaVersion = 2
            task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
            repositories = @([ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'task/FEATURE-123' })
            taskFiles = @([ordered]@{ path = 'WORKTR~1/x.md'; content = 'y' })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $tasksRoot = Join-Path $TestDrive 'task-files-short-name-tasks'

        { & $script -RequestPath $requestPath -TasksRoot $tasksRoot } | Should -Throw '*task file path*'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
    }
}

Describe 'ConvertTo-TaskRequest task files' {
    BeforeAll {
        $module = Join-Path $PSScriptRoot '../scripts/Private/TaskContract.psm1'
        $requestPath = Join-Path $TestDrive 'task-files-contract.json'

        function New-TaskFilesContractRequest {
            param([object]$TaskFiles)

            [ordered]@{
                schemaVersion = 2
                task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
                repositories = @([ordered]@{ name = 'api'; path = 'C:/work/canons/api'; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
                taskFiles = $TaskFiles
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestPath -NoNewline
            return $requestPath
        }
    }

    BeforeEach {
        Import-Module $module -Force
    }

    It 'normalizes a valid caller path and preserves empty taskFiles as no custom files' {
        $path = New-TaskFilesContractRequest -TaskFiles @([ordered]@{ path = 'guidance\AGENTS.md'; content = 'x' })
        $request = ConvertTo-TaskRequest -Path $path
        $request.TaskFiles.Count | Should -Be 1
        $request.TaskFiles[0].Path | Should -Be 'guidance/AGENTS.md'
        $request.TaskFiles[0].Content | Should -Be 'x'

        $emptyPath = New-TaskFilesContractRequest -TaskFiles @()
        $emptyRequest = ConvertTo-TaskRequest -Path $emptyPath
        @($emptyRequest.TaskFiles).Count | Should -Be 0
    }

    It 'rejects malformed task file descriptors' {
        $cases = @(
            [pscustomobject]@{ TaskFiles = @([ordered]@{ path = 'AGENTS.md' }); Error = '*expected path and content*' },
            [pscustomobject]@{ TaskFiles = @([ordered]@{ content = 'x' }); Error = '*expected path and content*' },
            [pscustomobject]@{ TaskFiles = @([ordered]@{ path = 'AGENTS.md'; content = 12 }); Error = '*content must be a string*' },
            [pscustomobject]@{ TaskFiles = 'AGENTS.md'; Error = '*taskFiles must be an array*' }
        )
        foreach ($case in $cases) {
            $path = New-TaskFilesContractRequest -TaskFiles $case.TaskFiles
            { ConvertTo-TaskRequest -Path $path } | Should -Throw $case.Error
        }
    }

    It 'rejects rooted, traversing, and empty-segment task file paths' {
        $invalidPaths = @('/absolute/AGENTS.md', 'C:\absolute\AGENTS.md', '../escape.md', 'a/../b.md', 'a//b.md', './AGENTS.md', '')
        foreach ($invalidPath in $invalidPaths) {
            $path = New-TaskFilesContractRequest -TaskFiles @([ordered]@{ path = $invalidPath; content = 'x' })
            { ConvertTo-TaskRequest -Path $path } | Should -Throw '*task file path*'
        }
    }

    It 'rejects a colon inside any task file path segment' {
        $path = New-TaskFilesContractRequest -TaskFiles @([ordered]@{ path = 'task.json:x'; content = 'x' })
        { ConvertTo-TaskRequest -Path $path } | Should -Throw '*task file path*'
    }

    It 'rejects duplicate and ancestor-conflicting task file destinations' {
        $duplicatePath = New-TaskFilesContractRequest -TaskFiles @(
            [ordered]@{ path = 'guidance/AGENTS.md'; content = 'a' },
            [ordered]@{ path = 'guidance/AGENTS.md'; content = 'b' }
        )
        { ConvertTo-TaskRequest -Path $duplicatePath } | Should -Throw '*duplicate task file path*'

        $ancestorPath = New-TaskFilesContractRequest -TaskFiles @(
            [ordered]@{ path = 'dir'; content = 'a' },
            [ordered]@{ path = 'dir/file.md'; content = 'b' }
        )
        { ConvertTo-TaskRequest -Path $ancestorPath } | Should -Throw '*conflicts with*'
    }

    It 'rejects collisions with scaffold-managed outputs and trees' {
        $managedPaths = @('task.json', 'PRD.md', 'PRD.MD', 'PLAN.md', 'STATUS.md', '.ctx', 'artifacts', 'artifacts/x.md', 'worktrees', 'worktrees/api/file')
        foreach ($managedPath in $managedPaths) {
            $path = New-TaskFilesContractRequest -TaskFiles @([ordered]@{ path = $managedPath; content = 'x' })
            { ConvertTo-TaskRequest -Path $path } | Should -Throw '*collides with a scaffold-managed path*'
        }
    }

    It 'rejects platform-equivalent duplicate destinations' -Skip:(-not $IsWindows) {
        $path = New-TaskFilesContractRequest -TaskFiles @(
            [ordered]@{ path = 'guidance/AGENTS.md'; content = 'a' },
            [ordered]@{ path = 'GUIDANCE/agents.md'; content = 'b' }
        )
        { ConvertTo-TaskRequest -Path $path } | Should -Throw '*duplicate task file path*'
    }
}

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
}

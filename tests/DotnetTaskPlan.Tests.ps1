BeforeAll {
    $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ProjectPath = Join-Path $script:RepositoryRoot 'src/TaskScaffold/TaskScaffold.csproj'
    $script:AgentProfilePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot 'agent-profile')))

    function Invoke-TaskPlanRaw {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments,
            [string]$WorkingDirectory,
            [string]$CliHome
        )

        if (-not $WorkingDirectory) { $WorkingDirectory = $TestDrive }
        if (-not $CliHome) { $CliHome = Join-Path $TestDrive 'dotnet-cli-home' }
        if (-not (Test-Path -LiteralPath $CliHome)) {
            New-Item -ItemType Directory -Path $CliHome -Force | Out-Null
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'dotnet'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.Environment['DOTNET_CLI_HOME'] = $CliHome
        $startInfo.Environment['DOTNET_NOLOGO'] = '1'
        $startInfo.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
        $startInfo.Environment['DOTNET_SKIP_FIRST_TIME_EXPERIENCE'] = '1'

        foreach ($argument in (@('run', '--project', $script:ProjectPath, '--') + $Arguments)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }

    function Invoke-TaskPlanCli {
        param(
            [Parameter(Mandatory)][string]$RequestPath,
            [Parameter(Mandatory)][string]$TasksRoot,
            [string]$WorkingDirectory,
            [string]$CliHome,
            [string]$CtxConfigRoot,
            [string]$CtxExternalProfilesRoot
        )

        $arguments = @('task', 'plan', '--request', $RequestPath, '--tasks-root', $TasksRoot)
        if ($PSBoundParameters.ContainsKey('CtxConfigRoot')) {
            $arguments += @('--ctx-config-root', $CtxConfigRoot)
        }
        if ($PSBoundParameters.ContainsKey('CtxExternalProfilesRoot')) {
            $arguments += @('--ctx-external-profiles-root', $CtxExternalProfilesRoot)
        }

        return Invoke-TaskPlanRaw -Arguments $arguments -WorkingDirectory $WorkingDirectory -CliHome $CliHome
    }

    function New-CtxRootFixture {
        param(
            [Parameter(Mandatory)][string]$Name
        )

        $base = Join-Path $TestDrive $Name
        $configRoot = Join-Path $base 'ai-config'
        $teamProfile = Join-Path $configRoot 'profiles/team'
        New-Item -ItemType Directory -Path $teamProfile -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $teamProfile 'AGENTS.md') -Value '# team' -NoNewline

        return [pscustomobject]@{
            ConfigRoot   = $configRoot
            TeamProfile  = $teamProfile
            ExternalRoot = $script:RepositoryRoot
        }
    }

    function New-TestRepository {
        param(
            [Parameter(Mandatory)][string]$Name,
            [string]$Root
        )

        if (-not $Root) { $Root = $TestDrive }
        $path = Join-Path $Root $Name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        & git -C $path init -b main | Out-Null
        & git -C $path config user.name Test
        & git -C $path config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $path 'README.md') -Value 'fixture'
        & git -C $path add README.md
        & git -C $path commit -m fixture | Out-Null
        return $path
    }

    function New-TaskPlanRequest {
        param(
            [Parameter(Mandatory)][object[]]$Repositories,
            [string]$Key = 'FEATURE-123',
            [string]$Title = 'Add endpoint',
            [string]$BaseBranch = 'main',
            [string]$Branch = 'feature/FEATURE-123'
        )

        $requestRepositories = @($Repositories | ForEach-Object {
            [ordered]@{ name = $_.Name; path = $_.Path; baseBranch = $BaseBranch; branch = $Branch }
        })

        return [ordered]@{
            schemaVersion = 3
            task = [ordered]@{ key = $Key; title = $Title }
            repositories = $requestRepositories
        }
    }

    function Write-TaskPlanRequest {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object]$Request
        )

        $Request | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -NoNewline
        return $Path
    }

    function Assert-TaskPlanSuccess {
        param(
            [Parameter(Mandatory)]$Run,
            [Parameter(Mandatory)][string]$Case
        )

        $Run.ExitCode | Should -Be 0 -Because "$Case should plan (stderr: $($Run.StdErr.Trim()))"
        $text = $Run.StdOut.Trim()
        $text | Should -Match '(?s)^\{.*\}$' -Because "$Case should emit exactly one JSON object"
        return ($text | ConvertFrom-Json)
    }

    function Assert-PropertySet {
        param(
            [Parameter(Mandatory)]$Object,
            [Parameter(Mandatory)][string[]]$Expected,
            [string]$Case = 'the object'
        )

        @($Object.PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected | Sort-Object) -Because "$Case should expose exactly the contract properties"
    }

    function Assert-TaskPlanFailure {
        param(
            [Parameter(Mandatory)]$Run,
            [Parameter(Mandatory)][string]$Case,
            [string]$MessagePattern
        )

        $Run.ExitCode | Should -Be 2 -Because "$Case should be rejected (stderr: $($Run.StdErr.Trim()))"
        $Run.StdOut.Trim() | Should -Be '' -Because "$Case should not write stdout"
        $Run.StdErr | Should -Not -Match '(?m)^\s+at\s' -Because "$Case should not emit a stack trace"
        $Run.StdErr | Should -Not -Match 'Unhandled exception' -Because "$Case should not emit an unhandled exception"
        if ($MessagePattern) {
            $Run.StdErr | Should -Match $MessagePattern -Because "$Case should explain the failure"
        }
    }
}

Describe 'dotnet task plan' {
    Context 'planning a new task from a local base branch' {
        It 'emits the exact JSON shape with one create-local operation' {
            $repositoryPath = New-TestRepository -Name 'api'
            $tasksRoot = Join-Path $TestDrive 'tasks'
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request.json') -Request $request

            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'task plan'

            Assert-PropertySet -Object $result -Expected @('planIdentity', 'plan') -Case 'the plan payload'
            $result.planIdentity | Should -Match '^[0-9a-f]{64}$'
            Assert-PropertySet -Object $result.plan -Expected @('taskKey', 'taskOperation', 'worktreeOperations', 'requiresConfirmation', 'ctxFile') -Case 'the plan'
            $result.plan.taskKey | Should -Be 'FEATURE-123'
            $result.plan.taskOperation | Should -Be 'create'
            $result.plan.requiresConfirmation | Should -BeTrue

            @($result.plan.worktreeOperations).Count | Should -Be 1
            $operation = $result.plan.worktreeOperations[0]
            Assert-PropertySet -Object $operation -Expected @('repository', 'action', 'source', 'branchMode', 'destination', 'reason') -Case 'the worktree operation'
            $operation.repository | Should -Be 'api'
            $operation.action | Should -Be 'create-local'
            $operation.source | Should -Be 'main'
            $operation.branchMode | Should -Be 'new'
            $operation.destination | Should -Be ([IO.Path]::GetFullPath((Join-Path $tasksRoot 'FEATURE-123/worktrees/api')))
            $operation.reason | Should -BeNullOrEmpty
        }

        It 'orders worktree operations by repository name' {
            $webPath = New-TestRepository -Name 'web'
            $apiPath = New-TestRepository -Name 'api'
            $tasksRoot = Join-Path $TestDrive 'tasks-order'
            $request = New-TaskPlanRequest -Repositories @(
                [pscustomobject]@{ Name = 'web'; Path = $webPath },
                [pscustomobject]@{ Name = 'api'; Path = $apiPath }
            )
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-order.json') -Request $request

            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'task plan ordering'

            @($result.plan.worktreeOperations).Count | Should -Be 2
            $result.plan.worktreeOperations.repository | Should -Be @('api', 'web')
            $result.plan.worktreeOperations[0].destination | Should -Be ([IO.Path]::GetFullPath((Join-Path $tasksRoot 'FEATURE-123/worktrees/api')))
            $result.plan.worktreeOperations[1].destination | Should -Be ([IO.Path]::GetFullPath((Join-Path $tasksRoot 'FEATURE-123/worktrees/web')))
        }

        It 'produces a stable identity and changes it when the request changes' {
            $repositoryPath = New-TestRepository -Name 'api'
            $tasksRoot = Join-Path $TestDrive 'tasks-identity'
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-identity.json') -Request $request

            $first = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'first plan'
            $repeat = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'repeated plan'
            $repeat.planIdentity | Should -Be $first.planIdentity

            $changedRequest = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath }) -Title 'Add a different endpoint'
            $changedPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-changed.json') -Request $changedRequest
            $changed = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $changedPath -TasksRoot $tasksRoot) -Case 'changed plan'
            $changed.planIdentity | Should -Not -Be $first.planIdentity
        }

        It 'does not create tasksRoot or mutate the repository' {
            $repositoryPath = New-TestRepository -Name 'api'
            $tasksRoot = Join-Path $TestDrive 'tasks-readonly'
            $destination = Join-Path $tasksRoot 'FEATURE-123/worktrees/api'
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-readonly.json') -Request $request

            $headBefore = (& git -C $repositoryPath rev-parse HEAD).Trim()
            $branchBefore = (& git -C $repositoryPath branch --show-current).Trim()
            $branchesBefore = @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object)
            $worktreesBefore = @(& git -C $repositoryPath worktree list --porcelain)
            $statusBefore = @(& git -C $repositoryPath status --porcelain)

            [void](Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'read-only plan')

            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
            Test-Path -LiteralPath $destination | Should -BeFalse
            (& git -C $repositoryPath rev-parse HEAD).Trim() | Should -Be $headBefore
            (& git -C $repositoryPath branch --show-current).Trim() | Should -Be $branchBefore
            @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object) | Should -Be $branchesBefore
            @(& git -C $repositoryPath worktree list --porcelain) | Should -Be $worktreesBefore
            @(& git -C $repositoryPath status --porcelain) | Should -Be $statusBefore
        }
    }

    Context 'path-conflict safety' {
        It 'blocks a regular-file destination collision without overwriting it' {
            $repositoryPath = New-TestRepository -Name 'api'
            $tasksRoot = Join-Path $TestDrive 'tasks-file-collision'
            $destination = Join-Path $tasksRoot 'FEATURE-123/worktrees/api'
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Set-Content -LiteralPath $destination -Value 'sentinel-collision' -NoNewline
            $sentinelHex = [Convert]::ToHexString([IO.File]::ReadAllBytes($destination))
            $branchesBefore = @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object)
            $worktreesBefore = @(& git -C $repositoryPath worktree list --porcelain)
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-file-collision.json') -Request $request

            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'regular-file destination collision'

            @($result.plan.worktreeOperations).Count | Should -Be 1
            $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
            $result.plan.worktreeOperations[0].reason | Should -Be 'destination-exists'
            [Convert]::ToHexString([IO.File]::ReadAllBytes($destination)) | Should -Be $sentinelHex
            @(& git -C $repositoryPath branch --format '%(refname:short)') | Should -Not -Contain 'feature/FEATURE-123'
            @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object) | Should -Be $branchesBefore
            @(& git -C $repositoryPath worktree list --porcelain) | Should -Be $worktreesBefore
        }

        It 'blocks a symlinked tasksRoot without following it on Linux' -Skip:(-not $IsLinux) {
            $repositoryPath = New-TestRepository -Name 'api'
            $target = Join-Path $TestDrive 'unsafe-target'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $tasksRoot = Join-Path $TestDrive 'tasks-symlink-root'
            New-Item -ItemType SymbolicLink -Path $tasksRoot -Target $target | Out-Null
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-symlink-root.json') -Request $request

            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'symlinked tasksRoot'

            @($result.plan.worktreeOperations).Count | Should -Be 1
            $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
            $result.plan.worktreeOperations[0].reason | Should -Be 'unsafe-worktree-path'
            @(Get-ChildItem -LiteralPath $target -Force) | Should -BeNullOrEmpty
            @(& git -C $repositoryPath branch --format '%(refname:short)') | Should -Not -Contain 'feature/FEATURE-123'
        }

        It 'fails closed when a regular file occupies a worktree destination ancestor' {
            $scenarios = @(
                [pscustomobject]@{ Label = 'tasksRoot'; Relative = $null },
                [pscustomobject]@{ Label = 'taskKey'; Relative = 'FEATURE-123' },
                [pscustomobject]@{ Label = 'worktrees'; Relative = 'FEATURE-123/worktrees' }
            )

            $observedActions = @()
            $observedReasons = @()
            foreach ($scenario in $scenarios) {
                $repositoryPath = New-TestRepository -Name "parent-$($scenario.Label)"
                $tasksRoot = Join-Path $TestDrive "tasks-parent-$($scenario.Label)"
                $blockingPath = if ($scenario.Relative) { Join-Path $tasksRoot $scenario.Relative } else { $tasksRoot }
                New-Item -ItemType Directory -Path (Split-Path -Parent $blockingPath) -Force | Out-Null
                Set-Content -LiteralPath $blockingPath -Value 'sentinel-ancestor' -NoNewline
                $sentinelHex = [Convert]::ToHexString([IO.File]::ReadAllBytes($blockingPath))
                $branchesBefore = @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object)
                $worktreesBefore = @(& git -C $repositoryPath worktree list --porcelain)
                $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
                $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive "task-request-parent-$($scenario.Label).json") -Request $request

                $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case "ancestor collision: $($scenario.Label)"
                $operation = $result.plan.worktreeOperations[0]
                $observedActions += $operation.action
                $observedReasons += $operation.reason

                [Convert]::ToHexString([IO.File]::ReadAllBytes($blockingPath)) | Should -Be $sentinelHex -Because "the $($scenario.Label) sentinel must be unchanged"
                Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse -Because "no worktree must be created for $($scenario.Label)"
                @(& git -C $repositoryPath branch --format '%(refname:short)') | Should -Not -Contain 'feature/FEATURE-123' -Because "no feature branch must appear for $($scenario.Label)"
                @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object) | Should -Be $branchesBefore
                @(& git -C $repositoryPath worktree list --porcelain) | Should -Be $worktreesBefore
            }

            $observedActions | Should -Be @('blocked', 'blocked', 'blocked')
            $observedReasons | Should -Be @('unsafe-worktree-path', 'unsafe-worktree-path', 'unsafe-worktree-path')
        }
    }
    Context 'planning from an explicit start commit' {
        It 'plans create-local from the start commit and changes the identity' {
            $repositoryPath = New-TestRepository -Name 'api-start-commit'
            $older = (& git -C $repositoryPath rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'newer'
            & git -C $repositoryPath commit -am 'advance main' | Out-Null
            $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
            $tasksRoot = Join-Path $TestDrive 'tasks-start-commit'

            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $request.repositories[0]['startCommit'] = $older
            $olderPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-start-commit-older.json') -Request $request
            $olderPlan = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $olderPath -TasksRoot $tasksRoot) -Case 'start commit plan'

            $operation = $olderPlan.plan.worktreeOperations[0]
            $operation.action | Should -Be 'create-local'
            $operation.source | Should -Be $older
            $operation.branchMode | Should -Be 'new'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse

            $headRequest = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $headRequest.repositories[0]['startCommit'] = $head
            $headPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-start-commit-head.json') -Request $headRequest
            $headPlan = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $headPath -TasksRoot $tasksRoot) -Case 'newer start commit plan'
            $headPlan.planIdentity | Should -Not -Be $olderPlan.planIdentity

            $noCommitRequest = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $noCommitPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-start-commit-none.json') -Request $noCommitRequest
            $noCommitPlan = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $noCommitPath -TasksRoot $tasksRoot) -Case 'plan without start commit'
            $noCommitPlan.planIdentity | Should -Not -Be $olderPlan.planIdentity
        }

        It 'blocks a start commit that is missing locally' {
            $repositoryPath = New-TestRepository -Name 'api-start-commit-missing'
            $tasksRoot = Join-Path $TestDrive 'tasks-start-commit-missing'
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $request.repositories[0]['startCommit'] = ('a' * 40)
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-start-commit-missing.json') -Request $request

            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'missing start commit plan'

            $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
            $result.plan.worktreeOperations[0].reason | Should -Be 'start-commit-missing'
        }

        It 'blocks a missing start commit before reusing an existing worktree and reuses a valid one' {
            $repositoryPath = New-TestRepository -Name 'api-start-commit-reuse'
            $older = (& git -C $repositoryPath rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'newer'
            & git -C $repositoryPath commit -am 'advance main' | Out-Null
            $tasksRoot = Join-Path $TestDrive 'tasks-start-commit-reuse'
            & git -C $repositoryPath worktree add -b feature/FEATURE-123 (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') main | Out-Null

            $missing = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $missing.repositories[0]['startCommit'] = ('a' * 40)
            $missingPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-reuse-missing.json') -Request $missing
            $missingResult = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $missingPath -TasksRoot $tasksRoot) -Case 'missing start commit with an existing worktree'
            $missingResult.plan.worktreeOperations[0].action | Should -Be 'blocked'
            $missingResult.plan.worktreeOperations[0].reason | Should -Be 'start-commit-missing'

            $valid = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $valid.repositories[0]['startCommit'] = $older
            $validPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-reuse-valid.json') -Request $valid
            $validResult = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $validPath -TasksRoot $tasksRoot) -Case 'valid start commit with an existing worktree'
            $validResult.plan.worktreeOperations[0].action | Should -Be 'reuse'
            $validResult.plan.worktreeOperations[0].source | Should -Be 'feature/FEATURE-123'
        }

        It 'blocks reuse when the per-repository incomplete-creation marker exists' {
            $repositoryPath = New-TestRepository -Name 'api-incomplete-marker'
            $tasksRoot = Join-Path $TestDrive 'tasks-incomplete-marker'
            & git -C $repositoryPath worktree add -b feature/FEATURE-123 (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') main | Out-Null
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-incomplete-marker.json') -Request $request

            $healthy = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'healthy reuse plan'
            $healthy.plan.worktreeOperations[0].action | Should -Be 'reuse'

            $markerPath = Join-Path $tasksRoot 'FEATURE-123/worktrees/.ai-task-scaffold-incomplete.api'
            '{"markerVersion":1}' | Set-Content -LiteralPath $markerPath -NoNewline
            $blocked = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'incomplete marker plan'
            $blocked.plan.worktreeOperations[0].action | Should -Be 'blocked'
            $blocked.plan.worktreeOperations[0].reason | Should -Be 'incomplete-worktree-creation'
            Test-Path -LiteralPath $markerPath | Should -BeTrue
        }

        It 'plans a tracking branch from the full remote ref when the start commit matches' {
            $repositoryPath = New-TestRepository -Name 'api-start-commit-remote'
            $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
            $remotePath = Join-Path $TestDrive 'api-start-commit-remote.git'
            & git init --bare $remotePath | Out-Null
            & git -C $repositoryPath remote add origin $remotePath
            & git -C $repositoryPath push origin 'main:refs/heads/feature/FEATURE-123' | Out-Null
            & git -C $repositoryPath fetch origin | Out-Null
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $request.repositories[0]['startCommit'] = $head
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'task-request-start-commit-remote.json') -Request $request

            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'tasks-start-commit-remote')) -Case 'remote start commit plan'

            $result.plan.worktreeOperations[0].action | Should -Be 'create-remote'
            $result.plan.worktreeOperations[0].source | Should -Be 'refs/remotes/origin/feature/FEATURE-123'
            $result.plan.worktreeOperations[0].branchMode | Should -Be 'track'
        }

        It 'keeps a reuse plan at one start commit distinct from the same plan at another' {
            $repositoryPath = New-TestRepository -Name 'api-start-commit-identity'
            $older = (& git -C $repositoryPath rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'newer'
            & git -C $repositoryPath commit -am 'advance main' | Out-Null
            $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
            $tasksRoot = Join-Path $TestDrive 'tasks-start-commit-identity'
            & git -C $repositoryPath worktree add -b feature/FEATURE-123 (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') main | Out-Null

            $plans = @()
            foreach ($commit in @($older, $head)) {
                $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
                $request.repositories[0]['startCommit'] = $commit
                $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive "task-request-identity-$commit.json") -Request $request
                $plans += (Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case "reuse plan at $commit")
            }

            $plans[0].plan.worktreeOperations[0].action | Should -Be 'reuse'
            $plans[1].plan.worktreeOperations[0].action | Should -Be 'reuse'
            $plans[1].planIdentity | Should -Not -Be $plans[0].planIdentity
        }
    }
}

Describe 'dotnet task plan ref resolution and Git capability' {
    BeforeAll {
        function New-OldGitShimDirectory {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            $shimPath = Join-Path $Path 'git'
            $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
            @(
                '#!/bin/sh'
                "REAL_GIT='$realGit'"
                'if [ "$1" = "--no-lazy-fetch" ]; then'
                '  echo "error: unknown option: --no-lazy-fetch" >&2'
                '  exit 129'
                'fi'
                'exec "$REAL_GIT" "$@"'
            ) | Set-Content -LiteralPath $shimPath
            & chmod +x $shimPath
            return $Path
        }

        function New-PartialCloneRepository {
            param([string]$SourcePath, [string]$ClonePath)

            New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
            & git -C $SourcePath init -b main | Out-Null
            & git -C $SourcePath config user.name Test
            & git -C $SourcePath config user.email test@example.invalid
            & git -C $SourcePath config uploadpack.allowFilter true
            Set-Content -LiteralPath (Join-Path $SourcePath 'README.md') -Value 'first'
            & git -C $SourcePath add README.md
            & git -C $SourcePath commit -m first | Out-Null
            Set-Content -LiteralPath (Join-Path $SourcePath 'README.md') -Value 'second'
            & git -C $SourcePath commit -am second | Out-Null
            & git clone --filter=blob:none --no-local "file://$SourcePath" $ClonePath 2>&1 | Out-Null
            return $ClonePath
        }

        function Set-UnreadableLooseRef {
            param([string]$RepositoryPath, [string]$Reference)

            $refPath = Join-Path $RepositoryPath ".git/$Reference"
            New-Item -ItemType Directory -Path (Split-Path -Parent $refPath) -Force | Out-Null
            Set-Content -LiteralPath $refPath -Value ('1' * 40) -NoNewline
        }
    }

    It 'fails closed on a partial clone when Git ignores --no-lazy-fetch' -Skip:(-not $IsLinux) {
        $repositoryPath = New-PartialCloneRepository -SourcePath (Join-Path $TestDrive 'cli-partial-source-old') -ClonePath (Join-Path $TestDrive 'cli-partial-old')
        (& git -C $repositoryPath config --get remote.origin.promisor) | Should -Be 'true'
        $shimDir = New-OldGitShimDirectory -Path (Join-Path $TestDrive 'cli-shim-old')
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-partial-old.json') -Request $request

        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            $run = Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-partial-old')
        }
        finally { $env:PATH = $savedPath }

        $run.ExitCode | Should -Be 1
        $run.StdErr | Should -Match 'partial clone'
        $run.StdErr | Should -Match '--no-lazy-fetch'
    }

    It 'still plans a full clone when Git ignores --no-lazy-fetch' -Skip:(-not $IsLinux) {
        $repositoryPath = New-TestRepository -Name 'cli-full-old'
        $shimDir = New-OldGitShimDirectory -Path (Join-Path $TestDrive 'cli-shim-full')
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-full-old.json') -Request $request

        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-full-old')) -Case 'full clone with old git'
        }
        finally { $env:PATH = $savedPath }

        $result.plan.worktreeOperations[0].action | Should -Be 'create-local'
        $result.plan.worktreeOperations[0].branchMode | Should -Be 'new'
    }

    It 'plans a real partial clone with a Git that supports --no-lazy-fetch' {
        # Capability of the local Git, not the OS.
        & git --no-lazy-fetch --version *> $null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'this Git does not support --no-lazy-fetch'; return }

        $repositoryPath = New-PartialCloneRepository -SourcePath (Join-Path $TestDrive 'cli-partial-source-modern') -ClonePath (Join-Path $TestDrive 'cli-partial-modern')
        $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-partial-modern.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-partial-modern')) -Case 'partial clone with modern git'

        $result.plan.worktreeOperations[0].action | Should -Be 'create-local'
        $result.plan.worktreeOperations[0].source | Should -Be 'main'
    }

    It 'does not let a lookalike tag stand in for the remote task ref' {
        $repositoryPath = New-TestRepository -Name 'cli-ref-tag-lookalike'
        $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
        & git -C $repositoryPath tag 'refs/remotes/origin/feature/FEATURE-123' $head
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-tag.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-ref-tag')) -Case 'lookalike tag without pin'
        $result.plan.worktreeOperations[0].action | Should -Be 'create-local'
        $result.plan.worktreeOperations[0].source | Should -Be 'main'
        $result.plan.worktreeOperations[0].branchMode | Should -Be 'new'

        $pinned = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $pinned.repositories[0]['startCommit'] = $head
        $pinnedPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-tag-pinned.json') -Request $pinned
        $pinnedResult = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $pinnedPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-ref-tag-pinned')) -Case 'lookalike tag with pin'
        $pinnedResult.plan.worktreeOperations[0].action | Should -Be 'create-local'
        $pinnedResult.plan.worktreeOperations[0].branchMode | Should -Be 'new'
        $pinnedResult.plan.worktreeOperations[0].source | Should -Be $head
    }

    It 'blocks a present local task ref whose tip cannot be verified against the pin' {
        $repositoryPath = New-TestRepository -Name 'cli-ref-unverified'
        $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
        Set-UnreadableLooseRef -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request.repositories[0]['startCommit'] = $head
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-unverified.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-ref-unverified')) -Case 'unverified ref with pin'

        $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
        $result.plan.worktreeOperations[0].reason | Should -Be 'start-commit-mismatch'
    }

    It 'blocks a no-pin local task ref whose tip is missing locally' {
        $repositoryPath = New-TestRepository -Name 'cli-ref-unverified-no-pin'
        Set-UnreadableLooseRef -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-unverified-no-pin.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-ref-unverified-no-pin')) -Case 'unverified ref without pin'

        $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
        $result.plan.worktreeOperations[0].reason | Should -Be 'start-commit-missing'
    }

    It 'blocks a dangling symbolic branch ref instead of creating one' {
        $repositoryPath = New-TestRepository -Name 'cli-ref-dangling'
        # Present but unreadable: for-each-ref omits a symbolic ref whose target
        # is missing, so absence must not be inferred from that listing.
        & git -C $repositoryPath symbolic-ref refs/heads/feature/FEATURE-123 refs/heads/missing
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-dangling.json') -Request $request
        $tasksRoot = Join-Path $TestDrive 'cli-tasks-ref-dangling'

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'dangling symbolic task ref'

        $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
        $result.plan.worktreeOperations[0].reason | Should -Be 'start-commit-missing'
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') | Should -BeFalse
    }

    It 'blocks a start commit that only a replacement ref can resolve' {
        $repositoryPath = New-TestRepository -Name 'cli-ref-replacement'
        & git -C $repositoryPath replace -l *> $null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'git replace is unavailable'; return }

        $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
        $missing = '36478499d1d27f636b8ea3604772d3aa7cd5e8d3'
        & git -C $repositoryPath update-ref "refs/replace/$missing" $head
        (& git -C $repositoryPath rev-parse --verify --quiet "$missing^{commit}") | Should -Be $missing

        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request.repositories[0]['startCommit'] = $missing
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-replacement.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-ref-replacement')) -Case 'replacement-only start commit'

        $result.plan.worktreeOperations[0].action | Should -Be 'blocked'
        $result.plan.worktreeOperations[0].reason | Should -Be 'start-commit-missing'
    }

    It 'rechecks a new promisor remote between the initial and locked plan' -Skip:(-not $IsLinux) {
        # The shim behaves like Git without --no-lazy-fetch and turns the full
        # clone into a partial one once apply holds the mutation lock, so only a
        # config re-read can refuse the locked re-plan.
        $repositoryPath = New-TestRepository -Name 'cli-promisor-later'
        $tasksRoot = Join-Path $TestDrive 'cli-tasks-promisor-later'
        $shimDir = Join-Path $TestDrive 'cli-shim-promisor-later'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shimPath = Join-Path $shimDir 'git'
        @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            "LOCK='$(Join-Path $tasksRoot '.ai-task-scaffold.lock')'"
            "FLAG='$(Join-Path $TestDrive 'cli-promisor-later.flag')'"
            "REPO='$repositoryPath'"
            'if [ "$1" = "--no-lazy-fetch" ]; then'
            '  echo "error: unknown option: --no-lazy-fetch" >&2'
            '  exit 129'
            'fi'
            'case " $* " in'
            '  *" config "*extensions.partialClone*)'
            '    if [ -e "$LOCK" ] && [ ! -e "$FLAG" ]; then'
            '      "$REAL_GIT" -C "$REPO" config remote.origin.promisor true'
            '      : > "$FLAG"'
            '    fi ;;'
            'esac'
            'exec "$REAL_GIT" "$@"'
        ) | Set-Content -LiteralPath $shimPath
        & chmod +x $shimPath

        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-promisor-later.json') -Request $request

        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            $plan = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'full clone before the promisor remote appears'
            $run = Invoke-TaskPlanRaw -Arguments @('task', 'apply', '--request', $requestPath, '--tasks-root', $tasksRoot, '--expected-plan-identity', $plan.planIdentity)
        }
        finally { $env:PATH = $savedPath }

        $run.ExitCode | Should -Be 1
        $run.StdErr | Should -Match 'partial clone'
        (& git -C $repositoryPath config --get remote.origin.promisor) | Should -Be 'true'
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123/task.json') | Should -BeFalse
    }

    It 'binds the validated pin without re-reading the mutable task ref' -Skip:(-not $IsLinux) {
        $repositoryPath = New-TestRepository -Name 'cli-ref-single-read'
        $head = (& git -C $repositoryPath rev-parse HEAD).Trim()
        & git -C $repositoryPath branch feature/FEATURE-123 $head
        $logPath = Join-Path $TestDrive 'cli-ref-single-read.log'
        $shimDir = Join-Path $TestDrive 'cli-shim-single-read'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $shimPath = Join-Path $shimDir 'git'
        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            "LOG='$logPath'"
            'printf ''%s\n'' "$*" >> "$LOG"'
            'exec "$REAL_GIT" "$@"'
        ) | Set-Content -LiteralPath $shimPath
        & chmod +x $shimPath

        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request.repositories[0]['startCommit'] = $head
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'cli-ref-single-read.json') -Request $request

        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot (Join-Path $TestDrive 'cli-tasks-ref-single-read')) -Case 'single read pin plan'
        }
        finally { $env:PATH = $savedPath }

        $result.plan.worktreeOperations[0].action | Should -Be 'create-local'
        $result.plan.worktreeOperations[0].branchMode | Should -Be 'existing'
        $log = @(Get-Content -LiteralPath $logPath)
        @($log | Where-Object { $_ -match 'rev-parse.*refs/heads/feature/FEATURE-123' }) |
            Should -BeNullOrEmpty -Because 'the pin path must not resolve the mutable ref a second time'
        @($log | Where-Object { $_ -match 'for-each-ref.*refs/heads/feature/FEATURE-123' }) |
            Should -Not -BeNullOrEmpty -Because 'the exact ref snapshot is the one verified read'
    }
}

Describe 'dotnet task plan ctx roots' {
    It 'plans root-mode .ctx with relative directives and does not touch the tasks root or environment' {
        $repositoryPath = New-TestRepository -Name 'api-ctx-roots-plan'
        $tasksRoot = Join-Path $TestDrive 'ctx-roots-plan-tasks'
        $taskPath = Join-Path $tasksRoot 'FEATURE-123'
        $fixture = New-CtxRootFixture -Name 'ctx-roots-plan-fixture'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'ctx-roots-plan.json') -Request $request

        $configEnvBefore = $env:AI_CTX_PROFILES_CONFIG_ROOT
        $externalEnvBefore = $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot) -Case 'root-mode plan'

        $expected = @(
            "config-root:$([IO.Path]::GetRelativePath($taskPath, $fixture.ConfigRoot))"
            "external-profiles-root:$([IO.Path]::GetRelativePath($taskPath, $fixture.ExternalRoot))"
            "team:$([IO.Path]::GetRelativePath($taskPath, $fixture.TeamProfile))"
            "task-scaffold:$([IO.Path]::GetRelativePath($taskPath, $script:AgentProfilePath))"
        ) -join "`n"
        $expected += "`n"

        $result.plan.ctxFile.action | Should -Be 'create'
        ($result.plan.ctxFile.content -ceq $expected) | Should -BeTrue -Because 'root-mode content must match exactly'
        $result.plan.ctxFile.path | Should -Be (Join-Path $tasksRoot 'FEATURE-123' '.ctx')
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
        $env:AI_CTX_PROFILES_CONFIG_ROOT | Should -Be $configEnvBefore
        $env:AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT | Should -Be $externalEnvBefore
    }

    It 'produces a deterministic identity and content for identical root-mode plans' {
        $repositoryPath = New-TestRepository -Name 'api-ctx-roots-deterministic'
        $tasksRoot = Join-Path $TestDrive 'ctx-roots-deterministic-tasks'
        $fixture = New-CtxRootFixture -Name 'ctx-roots-deterministic-fixture'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'ctx-roots-deterministic.json') -Request $request

        $first = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot) -Case 'first root-mode plan'
        $second = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot) -Case 'second root-mode plan'

        $second.planIdentity | Should -Be $first.planIdentity
        ($second.plan.ctxFile.content -ceq $first.plan.ctxFile.content) | Should -BeTrue
    }

    It 'emits only an external-profiles-root directive when only the external root is supplied' {
        $repositoryPath = New-TestRepository -Name 'api-ctx-roots-external'
        $tasksRoot = Join-Path $TestDrive 'ctx-roots-external-tasks'
        $fixture = New-CtxRootFixture -Name 'ctx-roots-external-fixture'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'ctx-roots-external.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxExternalProfilesRoot $fixture.ExternalRoot) -Case 'external-only plan'

        $result.plan.ctxFile.content | Should -Match '^external-profiles-root:'
        $result.plan.ctxFile.content | Should -Not -Match '(?m)^config-root:'
        @($result.plan.ctxFile.content.TrimEnd("`n") -split "`n").Count | Should -Be 3
    }

    It 'keeps the legacy absolute .ctx content when no roots are supplied' {
        $repositoryPath = New-TestRepository -Name 'api-ctx-roots-legacy'
        $tasksRoot = Join-Path $TestDrive 'ctx-roots-legacy-tasks'
        $fixture = New-CtxRootFixture -Name 'ctx-roots-legacy-fixture'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'ctx-roots-legacy.json') -Request $request

        $result = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'legacy plan'

        $expected = "team:$($fixture.TeamProfile)`ntask-scaffold:$($script:AgentProfilePath)`n"
        ($result.plan.ctxFile.content -ceq $expected) | Should -BeTrue -Because 'legacy content must be unchanged'
    }

    It 'binds the supplied roots into the plan identity' {
        $repositoryPath = New-TestRepository -Name 'api-ctx-roots-identity'
        $tasksRoot = Join-Path $TestDrive 'ctx-roots-identity-tasks'
        $fixtureA = New-CtxRootFixture -Name 'ctx-roots-identity-a'
        $fixtureB = New-CtxRootFixture -Name 'ctx-roots-identity-b'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixtureA.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'ctx-roots-identity.json') -Request $request

        $withoutRoots = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot) -Case 'no-root plan'
        $withA = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixtureA.ConfigRoot) -Case 'roots-A plan'
        $withB = Assert-TaskPlanSuccess -Run (Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixtureB.ConfigRoot) -Case 'roots-B plan'

        $withA.planIdentity | Should -Not -Be $withoutRoots.planIdentity
        $withB.planIdentity | Should -Not -Be $withA.planIdentity
    }

    It 'rejects invalid ctx roots before any planning' {
        $fixture = New-CtxRootFixture -Name 'ctx-roots-invalid-fixture'
        $fileRoot = Join-Path $TestDrive 'ctx-roots-invalid-file'
        Set-Content -LiteralPath $fileRoot -Value 'not a directory' -NoNewline
        $missingRoot = Join-Path $TestDrive 'ctx-roots-invalid-missing'
        $noProfilesRoot = Join-Path $TestDrive 'ctx-roots-invalid-no-profiles'
        New-Item -ItemType Directory -Path $noProfilesRoot -Force | Out-Null

        $cases = @(
            [pscustomobject]@{ Label = 'nonexistent'; Value = $missingRoot; Pattern = 'ctx config root must be an absolute existing directory' },
            [pscustomobject]@{ Label = 'relative'; Value = 'ai-config'; Pattern = 'ctx config root must be an absolute existing directory' },
            [pscustomobject]@{ Label = 'file'; Value = $fileRoot; Pattern = 'ctx config root must be an absolute existing directory' },
            [pscustomobject]@{ Label = 'no-profiles'; Value = $noProfilesRoot; Pattern = "ctx config root must contain a 'profiles' directory" },
            [pscustomobject]@{ Label = 'empty'; Value = ''; Pattern = 'ctx config root must be an absolute existing directory' }
        )

        if ($IsLinux) {
            $lineBreakRoot = Join-Path $TestDrive "ctx-roots-invalid-linebreak`nmore"
            New-Item -ItemType Directory -Path (Join-Path $lineBreakRoot 'profiles') -Force | Out-Null
            $cases += [pscustomobject]@{ Label = 'line-break'; Value = $lineBreakRoot; Pattern = 'must not contain line breaks' }
        }

        foreach ($case in $cases) {
            $repositoryPath = New-TestRepository -Name "api-ctx-invalid-$($case.Label)"
            $tasksRoot = Join-Path $TestDrive "ctx-roots-invalid-$($case.Label)-tasks"
            $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
            $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
            $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive "ctx-roots-invalid-$($case.Label).json") -Request $request

            $run = Invoke-TaskPlanCli -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $case.Value
            Assert-TaskPlanFailure -Run $run -Case "ctx config root $($case.Label)" -MessagePattern $case.Pattern
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse -Because "no task state may be created for the $($case.Label) root"
        }
    }

    It 'rejects unknown and duplicated options' {
        $repositoryPath = New-TestRepository -Name 'api-ctx-options'
        $tasksRoot = Join-Path $TestDrive 'ctx-roots-options-tasks'
        $fixture = New-CtxRootFixture -Name 'ctx-roots-options-fixture'
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive 'ctx-roots-options.json') -Request $request

        $unknown = Invoke-TaskPlanRaw -Arguments @('task', 'plan', '--request', $requestPath, '--tasks-root', $tasksRoot, '--ctx-root', 'x')
        Assert-TaskPlanFailure -Run $unknown -Case 'unknown option' -MessagePattern 'usage:'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse

        $duplicate = Invoke-TaskPlanRaw -Arguments @('task', 'plan', '--request', $requestPath, '--tasks-root', $tasksRoot, '--ctx-config-root', $fixture.ConfigRoot, '--ctx-config-root', $fixture.ConfigRoot)
        Assert-TaskPlanFailure -Run $duplicate -Case 'duplicated option' -MessagePattern 'usage:'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse
    }

    $rawRootCases = foreach ($command in @('plan', 'apply')) {
        foreach ($option in @('--ctx-config-root', '--ctx-external-profiles-root')) {
            foreach ($breakCase in @([pscustomobject]@{ Name = 'CR'; Value = "`r" }, [pscustomobject]@{ Name = 'LF'; Value = "`n" })) {
                @{
                    Label   = "$command $option $($breakCase.Name)"
                    Token   = "$command-$(($option -replace '^--', ''))-$($breakCase.Name.ToLowerInvariant())"
                    Command = $command
                    Option  = $option
                    Break   = $breakCase.Value
                }
            }
        }
    }

    It 'rejects raw line breaks before dot-segment normalization for <Label>' -ForEach $rawRootCases -Skip:(-not $IsLinux) {
        $repositoryPath = New-TestRepository -Name "api-raw-$($_.Token)"
        $tasksRoot = Join-Path $TestDrive "raw-$($_.Token)-tasks"
        $fixture = New-CtxRootFixture -Name "raw-$($_.Token)-fixture"
        $request = New-TaskPlanRequest -Repositories @([pscustomobject]@{ Name = 'api'; Path = $repositoryPath })
        $request['profiles'] = @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
        $requestPath = Write-TaskPlanRequest -Path (Join-Path $TestDrive "raw-$($_.Token).json") -Request $request

        $noisyDirectory = Join-Path (Split-Path -Parent $fixture.ConfigRoot) "noisy$($_.Break)segment"
        New-Item -ItemType Directory -Path $noisyDirectory -Force | Out-Null
        $rawRoot = "$noisyDirectory/../ai-config"

        $normalized = [IO.Path]::GetFullPath($rawRoot)
        $normalized | Should -Be $fixture.ConfigRoot -Because 'the raw spelling must lexically cancel the newline component'
        $normalized.IndexOfAny([char[]]@("`n", "`r")) | Should -Be -1 -Because 'the normalized root must not retain a line break'

        $headBefore = (& git -C $repositoryPath rev-parse HEAD).Trim()
        $branchBefore = (& git -C $repositoryPath branch --show-current).Trim()
        $branchesBefore = @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object)
        $worktreesBefore = @(& git -C $repositoryPath worktree list --porcelain)
        $statusBefore = @(& git -C $repositoryPath status --porcelain)

        if ($_.Command -eq 'apply') {
            $clean = Invoke-TaskPlanRaw -Arguments @('task', 'plan', '--request', $requestPath, '--tasks-root', $tasksRoot, $_.Option, $fixture.ConfigRoot)
            $clean.ExitCode | Should -Be 0 -Because "the clean-root plan must succeed (stderr: $($clean.StdErr.Trim()))"
            $identity = ($clean.StdOut.Trim() | ConvertFrom-Json).planIdentity
            $run = Invoke-TaskPlanRaw -Arguments @('task', 'apply', '--request', $requestPath, '--tasks-root', $tasksRoot, '--expected-plan-identity', $identity, $_.Option, $rawRoot)
        }
        else {
            $run = Invoke-TaskPlanRaw -Arguments @('task', 'plan', '--request', $requestPath, '--tasks-root', $tasksRoot, $_.Option, $rawRoot)
        }

        Assert-TaskPlanFailure -Run $run -Case "raw line break root for $($_.Label)" -MessagePattern 'must not contain line breaks'
        Test-Path -LiteralPath $tasksRoot | Should -BeFalse -Because 'no task state may be created for a rejected raw root'
        Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse -Because 'no task directory may be created for a rejected raw root'
        Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse -Because 'no mutation lock may be created for a rejected raw root'
        (& git -C $repositoryPath rev-parse HEAD).Trim() | Should -Be $headBefore
        (& git -C $repositoryPath branch --show-current).Trim() | Should -Be $branchBefore
        @(& git -C $repositoryPath branch --format '%(refname:short)' | Sort-Object) | Should -Be $branchesBefore
        @(& git -C $repositoryPath worktree list --porcelain) | Should -Be $worktreesBefore
        @(& git -C $repositoryPath status --porcelain) | Should -Be $statusBefore
    }
}

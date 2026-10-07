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
}

BeforeAll {
    $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ProjectPath = Join-Path $script:RepositoryRoot 'src/TaskScaffold/TaskScaffold.csproj'
    $script:AgentProfilePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot 'agent-profile')))

    function Invoke-Cli {
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

    function Get-Plan {
        param(
            [Parameter(Mandatory)][string]$RequestPath,
            [Parameter(Mandatory)][string]$TasksRoot,
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

        $run = Invoke-Cli -Arguments $arguments
        $run.ExitCode | Should -Be 0 -Because "task plan should succeed (stderr: $($run.StdErr.Trim()))"
        return ($run.StdOut.Trim() | ConvertFrom-Json)
    }

    function Invoke-Apply {
        param(
            [Parameter(Mandatory)][string]$RequestPath,
            [Parameter(Mandatory)][string]$TasksRoot,
            [string]$ExpectedPlanIdentity,
            [string]$CtxConfigRoot,
            [string]$CtxExternalProfilesRoot
        )

        $arguments = @('task', 'apply', '--request', $RequestPath, '--tasks-root', $TasksRoot)
        if ($PSBoundParameters.ContainsKey('ExpectedPlanIdentity') -and $null -ne $ExpectedPlanIdentity) {
            $arguments += @('--expected-plan-identity', $ExpectedPlanIdentity)
        }
        if ($PSBoundParameters.ContainsKey('CtxConfigRoot')) {
            $arguments += @('--ctx-config-root', $CtxConfigRoot)
        }
        if ($PSBoundParameters.ContainsKey('CtxExternalProfilesRoot')) {
            $arguments += @('--ctx-external-profiles-root', $CtxExternalProfilesRoot)
        }

        return Invoke-Cli -Arguments $arguments
    }

    function Invoke-CurrentPlanApply {
        param(
            [Parameter(Mandatory)][string]$RequestPath,
            [Parameter(Mandatory)][string]$TasksRoot,
            [string]$CtxConfigRoot,
            [string]$CtxExternalProfilesRoot
        )

        $rootArguments = @{}
        if ($PSBoundParameters.ContainsKey('CtxConfigRoot')) { $rootArguments['CtxConfigRoot'] = $CtxConfigRoot }
        if ($PSBoundParameters.ContainsKey('CtxExternalProfilesRoot')) { $rootArguments['CtxExternalProfilesRoot'] = $CtxExternalProfilesRoot }

        $plan = Get-Plan -RequestPath $RequestPath -TasksRoot $TasksRoot @rootArguments
        $run = Invoke-Apply -RequestPath $RequestPath -TasksRoot $TasksRoot -ExpectedPlanIdentity $plan.planIdentity @rootArguments
        return [pscustomobject]@{ Plan = $plan; Run = $run }
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

    function New-ApplyRequest {
        param(
            [Parameter(Mandatory)][string]$RepositoryPath,
            [object[]]$Profiles,
            [object[]]$TaskFiles,
            [string]$PrdPath,
            [string]$Key = 'FEATURE-123',
            [string]$Title = 'Add endpoint',
            [string]$RepositoryName = 'api',
            [string]$BaseBranch = 'main',
            [string]$Branch = 'feature/FEATURE-123'
        )

        $request = [ordered]@{
            schemaVersion = 3
            task = [ordered]@{ key = $Key; title = $Title }
            repositories = @([ordered]@{ name = $RepositoryName; path = $RepositoryPath; baseBranch = $BaseBranch; branch = $Branch })
        }
        if ($PSBoundParameters.ContainsKey('PrdPath') -and -not [string]::IsNullOrWhiteSpace($PrdPath)) {
            $request.task['prdPath'] = $PrdPath
        }
        if ($null -ne $Profiles) { $request['profiles'] = @($Profiles) }
        if ($null -ne $TaskFiles) { $request['taskFiles'] = @($TaskFiles) }
        return $request
    }

    function Write-JsonRequest {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object]$Request
        )

        $Request | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -NoNewline
        return $Path
    }

    function Set-ManifestContent {
        param(
            [Parameter(Mandatory)][string]$ManifestPath,
            [Parameter(Mandatory)][scriptblock]$Mutate
        )

        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        & $Mutate $manifest
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ManifestPath -NoNewline
    }

    function Assert-ApplySuccess {
        param(
            [Parameter(Mandatory)]$Run,
            [Parameter(Mandatory)][string]$Case
        )

        $Run.ExitCode | Should -Be 0 -Because "$Case should apply (stderr: $($Run.StdErr.Trim()))"
        $Run.StdErr.Trim() | Should -Be '' -Because "$Case should not write stderr"
    }

    function Assert-ApplyFailure {
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

    function Get-TreeSnapshot {
        param([Parameter(Mandatory)][string]$Root)

        $entries = foreach ($item in (Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)) {
            $relative = [IO.Path]::GetRelativePath($Root, $item.FullName)
            if ($item.PSIsContainer) {
                "D:$relative"
            }
            else {
                "F:${relative}:$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
            }
        }
        return @($entries)
    }
}

Describe 'dotnet task apply' {
    Context 'plan identity gating' {
        It 'rejects a missing, malformed, or mismatched reviewed plan identity' {
            $repositoryPath = New-TestRepository -Name 'api-identity'
            $tasksRoot = Join-Path $TestDrive 'identity-tasks'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'identity.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            $plan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot

            $missing = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $missing -Case 'apply without an identity' -MessagePattern 'Apply requires ExpectedPlanIdentity from the reviewed plan'

            $malformed = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity 'NOT-A-SHA256'
            Assert-ApplyFailure -Run $malformed -Case 'apply with a malformed identity' -MessagePattern 'ExpectedPlanIdentity must be a SHA-256 plan identity from the reviewed plan'

            $mismatched = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity ('0' * 64)
            Assert-ApplyFailure -Run $mismatched -Case 'apply with a stale identity' -MessagePattern 'plan identity changed since review; replan and approve again'

            $plan.planIdentity | Should -Match '^[a-f0-9]{64}$'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse -Because 'no rejected apply may create the tasks root'
        }
    }

    Context 'TOCTOU recheck between review and apply' {
        It 'aborts with no state when the base branch advances after review' {
            $repositoryPath = New-TestRepository -Name 'api-toctou-branch'
            $tasksRoot = Join-Path $TestDrive 'toctou-branch-tasks'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'toctou-branch.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            $plan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot

            Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'base branch advanced after review'
            & git -C $repositoryPath add README.md
            & git -C $repositoryPath commit -m 'advance base after review' | Out-Null

            $run = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $plan.planIdentity
            Assert-ApplyFailure -Run $run -Case 'base branch advanced after review' -MessagePattern 'plan identity changed since review; replan and approve again'
            Test-Path -LiteralPath $tasksRoot | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse
        }

        It 'aborts with no state when a task-file destination changes after review' {
            $repositoryPath = New-TestRepository -Name 'api-toctou-file'
            $tasksRoot = Join-Path $TestDrive 'toctou-file-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'toctou-file.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'AGENTS.md'; content = 'reviewed' }))
            $plan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot

            New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Value 'changed after review' -NoNewline

            $run = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $plan.planIdentity
            Assert-ApplyFailure -Run $run -Case 'task file changed after review' -MessagePattern 'plan identity changed since review; replan and approve again'
            Test-Path -LiteralPath (Join-Path $taskPath 'task.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $taskPath 'PRD.md') | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Raw) | Should -Be 'changed after review'
        }
    }

    Context 'fresh task creation' {
        It 'creates the directory, PRD, PLAN, STATUS, manifest, .ctx, and artifacts' {
            $repositoryPath = New-TestRepository -Name 'api-fresh'
            $tasksRoot = Join-Path $TestDrive 'fresh-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'fresh.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)

            $outcome = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplySuccess -Run $outcome.Run -Case 'fresh task apply'

            $outcome.Run.StdOut.Trim() | Should -Match '(?s)^\{.*\}$'
            $payload = $outcome.Run.StdOut.Trim() | ConvertFrom-Json
            $payload.planIdentity | Should -Match '^[a-f0-9]{64}$'
            $payload.plan.taskOperation | Should -Be 'create'

            Test-Path -LiteralPath $taskPath -PathType Container | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $taskPath 'artifacts') -PathType Container | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $tasksRoot '.ai-task-scaffold.lock') -PathType Leaf | Should -BeTrue

            $template = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'templates/PRD.md') -Raw
            (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be $template.Replace('{{TASK_TITLE}}', 'Add endpoint')
            (Get-Content -LiteralPath (Join-Path $taskPath 'PLAN.md') -Raw) | Should -Be "# FEATURE-123 — Add endpoint`n`nSource PRD: PRD.md`n`n## Phases"
            (Get-Content -LiteralPath (Join-Path $taskPath 'STATUS.md') -Raw) | Should -Be "# FEATURE-123 — Add endpoint`nstate: not-started`nplan: PLAN.md`nrepos:`n  - api: feature/FEATURE-123`nphases:"
            (Get-Content -LiteralPath (Join-Path $taskPath '.ctx') -Raw) | Should -Be "task-scaffold:$script:AgentProfilePath`n"

            $manifest = Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw | ConvertFrom-Json
            $manifest.schemaVersion | Should -Be 3
            $manifest.task.key | Should -Be 'FEATURE-123'
            $manifest.task.title | Should -Be 'Add endpoint'
            $manifest.task.prdPath | Should -Be 'PRD.md'
            $manifest.repositories[0].name | Should -Be 'api'
            $manifest.repositories[0].path | Should -Be $repositoryPath
            $manifest.repositories[0].branch | Should -Be 'feature/FEATURE-123'
            $manifest.repositories[0].baseBranch | Should -Be 'main'
            @($manifest.profiles).Count | Should -Be 1
            $manifest.profiles[0].name | Should -Be 'task-scaffold'
            $manifest.profiles[0].path | Should -Be $script:AgentProfilePath
            @($manifest.phases).Count | Should -Be 0
        }
    }

    Context 'idempotent re-apply' {
        It 're-applies a task with custom files as a clean no-op' {
            $repositoryPath = New-TestRepository -Name 'api-idempotent'
            $tasksRoot = Join-Path $TestDrive 'idempotent-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'idempotent.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @(
                [ordered]@{ path = 'docs/notes.md'; content = "hello`n" },
                [ordered]@{ path = 'AGENTS.md'; content = 'agent notes' }
            ))

            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'first apply'
            (Get-Content -LiteralPath (Join-Path $taskPath 'docs/notes.md') -Raw) | Should -Be "hello`n"
            (Get-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Raw) | Should -Be 'agent notes'
            (Get-Content -LiteralPath (Join-Path $taskPath 'task.json') -Raw | ConvertFrom-Json).taskFiles | Should -Be @('docs/notes.md', 'AGENTS.md')

            $before = Get-TreeSnapshot -Root $taskPath
            $second = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplySuccess -Run $second.Run -Case 'second apply'
            $after = Get-TreeSnapshot -Root $taskPath
            $after | Should -Be $before -Because 'a repeated apply with identical inputs must not change content'
        }
    }

    Context 'PRD operations' {
        It 'copies a supplied PRD source when creating a task' {
            $repositoryPath = New-TestRepository -Name 'api-prd-copy'
            $tasksRoot = Join-Path $TestDrive 'prd-copy-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $source = Join-Path $TestDrive 'source-prd.md'
            Set-Content -LiteralPath $source -Value "# Source PRD`nbody`n" -NoNewline
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'prd-copy.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -PrdPath $source)

            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'copy-source apply'
            (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be "# Source PRD`nbody`n"
        }

        It 'accepts a matching PRD source on an existing task' {
            $repositoryPath = New-TestRepository -Name 'api-prd-match'
            $tasksRoot = Join-Path $TestDrive 'prd-match-tasks'
            $source = Join-Path $TestDrive 'matching-prd.md'
            Set-Content -LiteralPath $source -Value '# Matching PRD' -NoNewline
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'prd-match.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -PrdPath $source)

            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'initial copy-source apply'
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'matching compare-existing apply'
        }

        It 'rejects a differing PRD source on an existing task' {
            $repositoryPath = New-TestRepository -Name 'api-prd-differs'
            $tasksRoot = Join-Path $TestDrive 'prd-differs-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $source = Join-Path $TestDrive 'drifting-prd.md'
            Set-Content -LiteralPath $source -Value '# Original' -NoNewline
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'prd-differs.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -PrdPath $source)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'initial copy-source apply'

            Set-Content -LiteralPath $source -Value '# Changed' -NoNewline
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'differing PRD source' -MessagePattern "existing task 'FEATURE-123' has a different PRD.md"
            (Get-Content -LiteralPath (Join-Path $taskPath 'PRD.md') -Raw) | Should -Be '# Original'
        }

        It 'rejects an existing task whose PRD source disappeared' {
            $repositoryPath = New-TestRepository -Name 'api-prd-blocked'
            $tasksRoot = Join-Path $TestDrive 'prd-blocked-tasks'
            $source = Join-Path $TestDrive 'vanishing-prd.md'
            Set-Content -LiteralPath $source -Value '# Vanishing' -NoNewline
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'prd-blocked.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -PrdPath $source)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'initial copy-source apply'

            Remove-Item -LiteralPath $source -Force
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'missing PRD source' -MessagePattern 'cannot apply task'
        }
    }

    Context 'custom task files' {
        It 'rejects a destination that differs in content without overwriting it' {
            $repositoryPath = New-TestRepository -Name 'api-file-differs'
            $tasksRoot = Join-Path $TestDrive 'file-differs-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $initialRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'file-differs-initial.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'AGENTS.md'; content = 'original' }))
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $initialRequest -TasksRoot $tasksRoot).Run -Case 'initial custom file apply'

            $changedRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'file-differs-changed.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'AGENTS.md'; content = 'different' }))
            $run = Invoke-CurrentPlanApply -RequestPath $changedRequest -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'destination differs' -MessagePattern "cannot apply task file 'AGENTS.md': destination-differs"
            (Get-Content -LiteralPath (Join-Path $taskPath 'AGENTS.md') -Raw) | Should -Be 'original'
        }

        It 'rejects a destination that is a directory' {
            $repositoryPath = New-TestRepository -Name 'api-file-dir'
            $tasksRoot = Join-Path $TestDrive 'file-dir-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $emptyRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'file-dir-empty.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $emptyRequest -TasksRoot $tasksRoot).Run -Case 'initial task apply'
            New-Item -ItemType Directory -Path (Join-Path $taskPath 'AGENTS.md') -Force | Out-Null

            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'file-dir.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'AGENTS.md'; content = 'x' }))
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'destination is a directory' -MessagePattern "cannot apply task file 'AGENTS.md': destination-is-directory"
            Test-Path -LiteralPath (Join-Path $taskPath 'AGENTS.md') -PathType Container | Should -BeTrue
        }

        It 'rejects an ancestor that is a regular file' {
            $repositoryPath = New-TestRepository -Name 'api-file-ancestor'
            $tasksRoot = Join-Path $TestDrive 'file-ancestor-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $emptyRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'file-ancestor-empty.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $emptyRequest -TasksRoot $tasksRoot).Run -Case 'initial task apply'
            Set-Content -LiteralPath (Join-Path $taskPath 'a') -Value 'blocking file' -NoNewline

            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'file-ancestor.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'a/b.txt'; content = 'y' }))
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'ancestor is a file' -MessagePattern "cannot apply task file 'a/b.txt': ancestor-is-file"
            (Get-Content -LiteralPath (Join-Path $taskPath 'a') -Raw) | Should -Be 'blocking file'
            Test-Path -LiteralPath (Join-Path $taskPath 'a/b.txt') | Should -BeFalse
        }

        It 'rejects a symlinked destination as a reparse-point conflict' -Skip:(-not $IsLinux) {
            $repositoryPath = New-TestRepository -Name 'api-file-reparse'
            $tasksRoot = Join-Path $TestDrive 'file-reparse-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $emptyRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'file-reparse-empty.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $emptyRequest -TasksRoot $tasksRoot).Run -Case 'initial task apply'

            $external = Join-Path $TestDrive 'file-reparse-external'
            New-Item -ItemType Directory -Path $external -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $external 'secret.txt') -Value 'outside' -NoNewline
            New-Item -ItemType SymbolicLink -Path (Join-Path $taskPath 'AGENTS.md') -Target (Join-Path $external 'secret.txt') | Out-Null

            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'file-reparse.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'AGENTS.md'; content = 'x' }))
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'symlinked destination' -MessagePattern "cannot apply task file 'AGENTS.md': reparse-point"
            (Get-Content -LiteralPath (Join-Path $external 'secret.txt') -Raw) | Should -Be 'outside'
        }

        It 'rejects a symlinked ancestor as unsafe without following it' -Skip:(-not $IsLinux) {
            $repositoryPath = New-TestRepository -Name 'api-file-link'
            $tasksRoot = Join-Path $TestDrive 'file-link-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $emptyRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'file-link-empty.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $emptyRequest -TasksRoot $tasksRoot).Run -Case 'initial task apply'

            $external = Join-Path $TestDrive 'file-link-external'
            New-Item -ItemType Directory -Path $external -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $taskPath 'link') -Target $external | Out-Null

            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'file-link.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'link/AGENTS.md'; content = 'escape' }))
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'symlinked ancestor' -MessagePattern "cannot apply task file 'link/AGENTS.md': unsafe-task-file-path"
            Test-Path -LiteralPath (Join-Path $external 'AGENTS.md') | Should -BeFalse
        }
    }

    Context 'existing task consistency' {
        It 'rejects a manifest that differs from the request' {
            $repositoryPath = New-TestRepository -Name 'api-manifest-differs'
            $tasksRoot = Join-Path $TestDrive 'manifest-differs-tasks'
            $manifestPath = Join-Path $tasksRoot 'FEATURE-123/task.json'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'manifest-differs.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'initial task apply'

            Set-ManifestContent -ManifestPath $manifestPath -Mutate { param($manifest) $manifest['task']['title'] = 'Old title' }
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'manifest differs' -MessagePattern "existing task 'FEATURE-123' manifest differs from the request"
        }

        It 'rejects a manifest whose profile identity does not match the request' {
            $repositoryPath = New-TestRepository -Name 'api-profile-identity'
            $tasksRoot = Join-Path $TestDrive 'profile-identity-tasks'
            $manifestPath = Join-Path $tasksRoot 'FEATURE-123/task.json'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'profile-identity.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'initial task apply'

            Set-ManifestContent -ManifestPath $manifestPath -Mutate {
                param($manifest)
                $manifest['profiles'] = @([ordered]@{ name = 'other'; path = $script:AgentProfilePath })
            }
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'profile identity mismatch' -MessagePattern "existing task 'FEATURE-123' manifest profiles differ from the request"
        }

        It 'rejects a manifest whose profile path drifted' {
            $repositoryPath = New-TestRepository -Name 'api-profile-drift'
            $tasksRoot = Join-Path $TestDrive 'profile-drift-tasks'
            $manifestPath = Join-Path $tasksRoot 'FEATURE-123/task.json'
            $otherProfile = Join-Path $TestDrive 'drift-profile'
            New-Item -ItemType Directory -Path $otherProfile -Force | Out-Null
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'profile-drift.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'initial task apply'

            Set-ManifestContent -ManifestPath $manifestPath -Mutate {
                param($manifest)
                $manifest['profiles'] = @([ordered]@{ name = 'task-scaffold'; path = $otherProfile })
            }
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'profile path drift' -MessagePattern "existing task 'FEATURE-123' profile paths changed; reconciliation is required before apply"
        }

        It 'rejects an existing task directory without a task.json' {
            $repositoryPath = New-TestRepository -Name 'api-no-manifest'
            $tasksRoot = Join-Path $TestDrive 'no-manifest-tasks'
            New-Item -ItemType Directory -Path (Join-Path $tasksRoot 'FEATURE-123') -Force | Out-Null
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'no-manifest.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'missing manifest' -MessagePattern "existing task 'FEATURE-123' has no task.json"
        }
    }

    Context 'path safety' {
        It 'blocks a symlinked tasks root without writing task state outside it' -Skip:(-not $IsLinux) {
            $repositoryPath = New-TestRepository -Name 'api-symlink-root'
            $target = Join-Path $TestDrive 'symlink-root-target'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $tasksRoot = Join-Path $TestDrive 'symlink-root-tasks'
            New-Item -ItemType SymbolicLink -Path $tasksRoot -Target $target | Out-Null
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'symlink-root.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)

            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'symlinked tasks root' -MessagePattern "cannot scaffold task 'FEATURE-123': unsafe-task-path"
            Test-Path -LiteralPath (Join-Path $target 'FEATURE-123') | Should -BeFalse
        }

        It 'blocks a symlinked task directory' -Skip:(-not $IsLinux) {
            $repositoryPath = New-TestRepository -Name 'api-symlink-task'
            $tasksRoot = Join-Path $TestDrive 'symlink-task-tasks'
            New-Item -ItemType Directory -Path $tasksRoot -Force | Out-Null
            $target = Join-Path $TestDrive 'symlink-task-target'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $tasksRoot 'FEATURE-123') -Target $target | Out-Null
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'symlink-task.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)

            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'symlinked task directory' -MessagePattern "cannot scaffold task 'FEATURE-123': unsafe-task-path"
            Test-Path -LiteralPath (Join-Path $target 'task.json') | Should -BeFalse
        }

        It 'blocks a symlinked custom-file parent without following it' -Skip:(-not $IsLinux) {
            $repositoryPath = New-TestRepository -Name 'api-symlink-parent'
            $tasksRoot = Join-Path $TestDrive 'symlink-parent-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $emptyRequest = Write-JsonRequest -Path (Join-Path $TestDrive 'symlink-parent-empty.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)
            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $emptyRequest -TasksRoot $tasksRoot).Run -Case 'initial task apply'

            $external = Join-Path $TestDrive 'symlink-parent-external'
            New-Item -ItemType Directory -Path $external -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $taskPath 'nested') -Target $external | Out-Null

            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'symlink-parent.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath -TaskFiles @([ordered]@{ path = 'nested/AGENTS.md'; content = 'escape' }))
            $run = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot
            Assert-ApplyFailure -Run $run.Run -Case 'symlinked custom-file parent' -MessagePattern "cannot apply task file 'nested/AGENTS.md': unsafe-task-file-path"
            Test-Path -LiteralPath (Join-Path $external 'AGENTS.md') | Should -BeFalse
        }
    }

    Context 'ctx root directives' {
        It 'applies root-mode .ctx as UTF-8 without BOM and re-applies as a no-op' {
            $repositoryPath = New-TestRepository -Name 'api-ctx-fresh'
            $tasksRoot = Join-Path $TestDrive 'ctx-fresh-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $fixture = New-CtxRootFixture -Name 'ctx-fresh-fixture'
            $request = New-ApplyRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'ctx-fresh.json') -Request $request

            $outcome = Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot
            Assert-ApplySuccess -Run $outcome.Run -Case 'root-mode fresh apply'

            $ctxPath = Join-Path $taskPath '.ctx'
            $bytes = [IO.File]::ReadAllBytes($ctxPath)
            @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should -Not -Be '239,187,191' -Because '.ctx must be written without a BOM'
            ([IO.File]::ReadAllText($ctxPath) -ceq $outcome.Plan.plan.ctxFile.content) | Should -BeTrue -Because 'the applied .ctx must equal the planned content'

            $replan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot
            $replan.plan.ctxFile.action | Should -Be 'noop'

            $before = Get-TreeSnapshot -Root $taskPath
            $reapply = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $replan.planIdentity -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot
            Assert-ApplySuccess -Run $reapply -Case 'root-mode re-apply'
            (Get-TreeSnapshot -Root $taskPath) | Should -Be $before -Because 'a repeated root-mode apply must not change content'
        }

        It 'adds and removes ctx root directives through the reviewed flow' {
            $repositoryPath = New-TestRepository -Name 'api-ctx-update'
            $tasksRoot = Join-Path $TestDrive 'ctx-update-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $fixture = New-CtxRootFixture -Name 'ctx-update-fixture'
            $request = New-ApplyRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'ctx-update.json') -Request $request

            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'legacy initial apply'
            $legacyBytes = [IO.File]::ReadAllBytes((Join-Path $taskPath '.ctx'))

            $rootPlan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot
            $rootPlan.plan.ctxFile.action | Should -Be 'update'
            $rootApply = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $rootPlan.planIdentity -CtxConfigRoot $fixture.ConfigRoot -CtxExternalProfilesRoot $fixture.ExternalRoot
            Assert-ApplySuccess -Run $rootApply -Case 'add directives apply'
            ([IO.File]::ReadAllText((Join-Path $taskPath '.ctx')) -ceq $rootPlan.plan.ctxFile.content) | Should -BeTrue -Because 'the applied .ctx must equal the planned content'
            (Get-Content -LiteralPath (Join-Path $taskPath '.ctx') -Raw) | Should -Match '(?m)^config-root:'

            $legacyPlan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot
            $legacyPlan.plan.ctxFile.action | Should -Be 'update'
            $legacyApply = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $legacyPlan.planIdentity
            Assert-ApplySuccess -Run $legacyApply -Case 'remove directives apply'
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $taskPath '.ctx'))) | Should -Be ([Convert]::ToHexString($legacyBytes))
        }

        It 'rejects a reviewed identity when the ctx roots change before apply' {
            $repositoryPath = New-TestRepository -Name 'api-ctx-stale'
            $fixtureA = New-CtxRootFixture -Name 'ctx-stale-a'
            $fixtureB = New-CtxRootFixture -Name 'ctx-stale-b'
            $request = New-ApplyRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $fixtureA.TeamProfile })
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'ctx-stale.json') -Request $request

            $tasksRootA = Join-Path $TestDrive 'ctx-stale-different-roots-tasks'
            $planA = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRootA -CtxConfigRoot $fixtureA.ConfigRoot
            $changedRoot = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRootA -ExpectedPlanIdentity $planA.planIdentity -CtxConfigRoot $fixtureB.ConfigRoot
            Assert-ApplyFailure -Run $changedRoot -Case 'different valid config root' -MessagePattern 'plan identity changed'
            Test-Path -LiteralPath (Join-Path $tasksRootA 'FEATURE-123') | Should -BeFalse

            $tasksRootB = Join-Path $TestDrive 'ctx-stale-removed-roots-tasks'
            $planB = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRootB -CtxConfigRoot $fixtureA.ConfigRoot -CtxExternalProfilesRoot $fixtureA.ExternalRoot
            $removedRoots = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRootB -ExpectedPlanIdentity $planB.planIdentity
            Assert-ApplyFailure -Run $removedRoots -Case 'apply without roots' -MessagePattern 'plan identity changed'
            Test-Path -LiteralPath (Join-Path $tasksRootB 'FEATURE-123') | Should -BeFalse

            $tasksRootC = Join-Path $TestDrive 'ctx-stale-added-roots-tasks'
            $planC = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRootC
            $addedRoots = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRootC -ExpectedPlanIdentity $planC.planIdentity -CtxConfigRoot $fixtureA.ConfigRoot
            Assert-ApplyFailure -Run $addedRoots -Case 'apply with roots' -MessagePattern 'plan identity changed'
            Test-Path -LiteralPath (Join-Path $tasksRootC 'FEATURE-123') | Should -BeFalse
        }

        It 'rejects apply when a supplied config root disappears after review' {
            $repositoryPath = New-TestRepository -Name 'api-ctx-removed'
            $tasksRoot = Join-Path $TestDrive 'ctx-removed-tasks'
            $fixture = New-CtxRootFixture -Name 'ctx-removed-fixture'
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'ctx-removed.json') -Request (New-ApplyRequest -RepositoryPath $repositoryPath)

            $plan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot
            Remove-Item -LiteralPath $fixture.ConfigRoot -Recurse -Force

            $run = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $plan.planIdentity -CtxConfigRoot $fixture.ConfigRoot
            Assert-ApplyFailure -Run $run -Case 'config root removed after review' -MessagePattern 'ctx config root must be an absolute existing directory'
            Test-Path -LiteralPath (Join-Path $tasksRoot 'FEATURE-123') | Should -BeFalse
        }

        It 'keeps task.json byte-identical when adding root directives to an existing task' {
            $repositoryPath = New-TestRepository -Name 'api-ctx-manifest'
            $tasksRoot = Join-Path $TestDrive 'ctx-manifest-tasks'
            $taskPath = Join-Path $tasksRoot 'FEATURE-123'
            $fixture = New-CtxRootFixture -Name 'ctx-manifest-fixture'
            $request = New-ApplyRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $fixture.TeamProfile })
            $requestPath = Write-JsonRequest -Path (Join-Path $TestDrive 'ctx-manifest.json') -Request $request

            Assert-ApplySuccess -Run (Invoke-CurrentPlanApply -RequestPath $requestPath -TasksRoot $tasksRoot).Run -Case 'legacy initial apply'
            $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $taskPath 'task.json'))

            $rootPlan = Get-Plan -RequestPath $requestPath -TasksRoot $tasksRoot -CtxConfigRoot $fixture.ConfigRoot
            $rootApply = Invoke-Apply -RequestPath $requestPath -TasksRoot $tasksRoot -ExpectedPlanIdentity $rootPlan.planIdentity -CtxConfigRoot $fixture.ConfigRoot
            Assert-ApplySuccess -Run $rootApply -Case 'root-mode update apply'

            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $taskPath 'task.json'))) | Should -Be ([Convert]::ToHexString($manifestBytes)) -Because 'only .ctx may change when adding root directives'
        }
    }
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../scripts/Private/GitWorktree.psm1'
    Import-Module $modulePath -Force

    function New-ConcurrencyFixtureRepository {
        param([string]$RepositoryPath)

        New-Item -ItemType Directory -Path $RepositoryPath -Force | Out-Null
        & git -C $RepositoryPath init -b main | Out-Null
        & git -C $RepositoryPath config user.name Test
        & git -C $RepositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $RepositoryPath 'README.md') -Value 'fixture'
        & git -C $RepositoryPath add README.md
        & git -C $RepositoryPath commit -m fixture | Out-Null
    }

    function New-ConcurrencyCaseRoot {
        # Pester 6 shares TestDrive between tests, so every case needs its own root.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function New-WorkItem {
        param([string]$CaseRoot, [string]$Name, [int]$Index, [string]$Branch = "feature/CONCURRENCY-$Index")

        $repository = [pscustomobject]@{
            Name = $Name
            Path = (Join-Path $CaseRoot "repos/$Name")
            BaseBranch = 'main'
            Branch = $Branch
        }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'CONCURRENCY-1' -TasksRoot (Join-Path $CaseRoot 'tasks')
        return [pscustomobject]@{ Index = $Index; Plan = $plan; Repository = $repository }
    }

    function New-TimingGitShim {
        param([string]$ShimRoot, [string]$LogPath)

        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shimDir = Join-Path $ShimRoot 'shim'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $shimPath = Join-Path $shimDir 'git'
        $lines = @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            "LOG='$LogPath'"
            'case " $* " in'
            '  *" worktree add "*)'
            '    START=$(date +%s%N)'
            '    case " $* " in'
            '      *"${SHIM_FAIL_MATCH:-@@none@@}"*)'
            '        sleep "$SHIM_FAIL_SLEEP"'
            '        END=$(date +%s%N)'
            '        printf "%s %s\n" "$START" "$END" >> "$LOG"'
            '        echo "shim: forced stdout"'
            '        echo "shim: forced failure" >&2'
            '        exit 1'
            '        ;;'
            '    esac'
            '    case " $* " in *"$SHIM_SLEEP_MATCH"*) sleep "$SHIM_SLEEP" ;; esac'
            '    "$REAL_GIT" "$@"; CODE=$?'
            '    END=$(date +%s%N)'
            '    printf "%s %s\n" "$START" "$END" >> "$LOG"'
            '    exit $CODE'
            '    ;;'
            'esac'
            'exec "$REAL_GIT" "$@"'
        )
        Set-Content -LiteralPath $shimPath -Value $lines
        & chmod +x $shimPath
        return [pscustomobject]@{ Directory = $shimDir; LogPath = $LogPath }
    }

    function Get-ShimIntervals {
        param([string]$LogPath)

        if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
        return @(Get-Content -LiteralPath $LogPath | ForEach-Object {
            $parts = $_ -split ' '
            [pscustomobject]@{ Start = [long]$parts[0]; End = [long]$parts[1] }
        })
    }
}

Describe 'Get-TaskWorktreeConcurrencyLimit' {
    AfterEach {
        Remove-Item Env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY -ErrorAction SilentlyContinue
    }

    It 'defaults to three when the variable is unset or empty' {
        Remove-Item Env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY -ErrorAction SilentlyContinue
        Get-TaskWorktreeConcurrencyLimit | Should -Be 3
        $env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY = '  '
        Get-TaskWorktreeConcurrencyLimit | Should -Be 3
    }

    It 'accepts every value from one to eight' {
        foreach ($value in 1..8) {
            $env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY = "$value"
            Get-TaskWorktreeConcurrencyLimit | Should -Be $value
        }
    }

    It 'refuses a value outside one to eight or a non-integer' {
        foreach ($value in '0', '9', '-1', '1.5', 'three') {
            $env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY = $value
            { Get-TaskWorktreeConcurrencyLimit } | Should -Throw '*expected an integer from 1 to 8*'
        }
    }

    It 'keeps the reviewed plan identity independent of the limit' {
        $case = New-ConcurrencyCaseRoot
        New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case 'repos/identity')
        $requestPath = Join-Path $case 'identity.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'CONCURRENCY-1'; title = 'identity'; prdPath = (Join-Path $case 'prd.md') }
            repositories = @([ordered]@{ name = 'identity'; path = (Join-Path $case 'repos/identity'); baseBranch = 'main'; branch = 'feature/CONCURRENCY-1' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'

        $env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY = '1'
        $serialPlan = & $script -RequestPath $requestPath -TasksRoot (Join-Path $case 'tasks') | ConvertFrom-Json
        $env:AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY = '8'
        $parallelPlan = & $script -RequestPath $requestPath -TasksRoot (Join-Path $case 'tasks') | ConvertFrom-Json

        $parallelPlan.PlanIdentity | Should -Be $serialPlan.PlanIdentity
    }
}

Describe 'Invoke-TaskWorktreePlanBatch' {
    It 'creates every planned worktree and returns results in plan order' {
        $case = New-ConcurrencyCaseRoot
        $names = @('alpha', 'bravo', 'charlie')
        foreach ($name in $names) { New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case "repos/$name") }
        $items = @(for ($index = 0; $index -lt $names.Count; $index++) { New-WorkItem -CaseRoot $case -Name $names[$index] -Index $index })

        $results = Invoke-TaskWorktreePlanBatch -WorkItems $items -Limit 3 -ModulePath $modulePath

        $results.Index | Should -Be @(0, 1, 2)
        $results.Status | Should -Be @('created', 'created', 'created')
        foreach ($name in $names) {
            Test-Path -LiteralPath (Join-Path $case "tasks/CONCURRENCY-1/worktrees/$name") | Should -BeTrue
        }
    }

    It 'runs independent repositories in parallel' -Skip:(-not $IsLinux) {
        $case = New-ConcurrencyCaseRoot
        $shim = New-TimingGitShim -ShimRoot $case -LogPath (Join-Path $case 'parallel.log')
        $names = @('alpha', 'bravo', 'charlie')
        foreach ($name in $names) { New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case "repos/$name") }
        $items = @(for ($index = 0; $index -lt $names.Count; $index++) { New-WorkItem -CaseRoot $case -Name $names[$index] -Index $index })

        $savedPath = $env:PATH
        $env:PATH = "$($shim.Directory):$savedPath"
        $env:SHIM_SLEEP = '0.4'
        $env:SHIM_SLEEP_MATCH = '/worktrees/'
        try {
            $results = Invoke-TaskWorktreePlanBatch -WorkItems $items -Limit 3 -ModulePath $modulePath
        }
        finally {
            $env:PATH = $savedPath
            Remove-Item Env:SHIM_SLEEP, Env:SHIM_SLEEP_MATCH -ErrorAction SilentlyContinue
        }

        $results.Status | Should -Be @('created', 'created', 'created')
        $intervals = Get-ShimIntervals -LogPath $shim.LogPath
        $intervals.Count | Should -Be 3
        $overlap = $false
        for ($i = 0; $i -lt $intervals.Count; $i++) {
            for ($j = $i + 1; $j -lt $intervals.Count; $j++) {
                if ($intervals[$i].Start -lt $intervals[$j].End -and $intervals[$j].Start -lt $intervals[$i].End) { $overlap = $true }
            }
        }
        $overlap | Should -BeTrue
    }

    It 'keeps repositories that share one Git common directory serial' -Skip:(-not $IsLinux) {
        $case = New-ConcurrencyCaseRoot
        $canonPath = Join-Path $case 'repos/canon'
        New-ConcurrencyFixtureRepository -RepositoryPath $canonPath
        $linkedPath = Join-Path $case 'repos/linked'
        & git -C $canonPath worktree add -b feature/LINKED $linkedPath main | Out-Null
        (Get-GitCommonDir -RepositoryPath $linkedPath) | Should -Be (Get-GitCommonDir -RepositoryPath $canonPath)

        $shim = New-TimingGitShim -ShimRoot $case -LogPath (Join-Path $case 'shared.log')
        $items = @(
            (New-WorkItem -CaseRoot $case -Name 'canon' -Index 0 -Branch 'feature/CANON'),
            (New-WorkItem -CaseRoot $case -Name 'linked' -Index 1 -Branch 'feature/OTHER')
        )

        $savedPath = $env:PATH
        $env:PATH = "$($shim.Directory):$savedPath"
        $env:SHIM_SLEEP = '0.3'
        $env:SHIM_SLEEP_MATCH = '/worktrees/'
        try {
            $results = Invoke-TaskWorktreePlanBatch -WorkItems $items -Limit 3 -ModulePath $modulePath
        }
        finally {
            $env:PATH = $savedPath
            Remove-Item Env:SHIM_SLEEP, Env:SHIM_SLEEP_MATCH -ErrorAction SilentlyContinue
        }

        $results.Status | Should -Be @('created', 'created')
        $intervals = Get-ShimIntervals -LogPath $shim.LogPath
        $intervals.Count | Should -Be 2
        $overlap = $intervals[0].Start -lt $intervals[1].End -and $intervals[1].Start -lt $intervals[0].End
        $overlap | Should -BeFalse
    }

    It 'starts no new worktree after a failure and reports the first failure by plan order' -Skip:(-not $IsLinux) {
        $case = New-ConcurrencyCaseRoot
        $names = @('alpha', 'bravo', 'charlie', 'delta', 'echo')
        foreach ($name in $names) { New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case "repos/$name") }
        $items = @(for ($index = 0; $index -lt $names.Count; $index++) { New-WorkItem -CaseRoot $case -Name $names[$index] -Index $index })

        # alpha fails 0.1 s into its git start; bravo succeeds 0.8 s into its own start.
        # Both starts are admitted first, so bravo is running when alpha publishes. The
        # remaining three reach the gate after the publication and stay skipped.
        $shim = New-TimingGitShim -ShimRoot $case -LogPath (Join-Path $case 'failure.log')
        $savedPath = $env:PATH
        $env:PATH = "$($shim.Directory):$savedPath"
        $env:SHIM_SLEEP_MATCH = '/worktrees/bravo'
        $env:SHIM_FAIL_MATCH = '/worktrees/alpha'
        $env:SHIM_SLEEP = '0.8'
        $env:SHIM_FAIL_SLEEP = '0.1'
        try {
            $results = Invoke-TaskWorktreePlanBatch -WorkItems $items -Limit 2 -ModulePath $modulePath
        }
        finally {
            $env:PATH = $savedPath
            Remove-Item Env:SHIM_SLEEP, Env:SHIM_SLEEP_MATCH, Env:SHIM_FAIL_MATCH, Env:SHIM_FAIL_SLEEP -ErrorAction SilentlyContinue
        }

        $results.Status[0] | Should -Be 'failed'
        $results.Status[1] | Should -Be 'created'
        $results.Status[2..4] | Should -Be @('skipped', 'skipped', 'skipped')
        $firstFailure = $results | Where-Object Status -eq 'failed' | Select-Object -First 1
        $firstFailure.Message | Should -Match "git worktree add failed for 'alpha'"
        $firstFailure.Message | Should -Match 'shim: forced failure'
        $firstFailure.Message | Should -Match 'shim: forced stdout'
        Test-Path -LiteralPath (Join-Path $case 'tasks/CONCURRENCY-1/worktrees/charlie') | Should -BeFalse
    }

    It 'reports the failure with the lowest plan index, not the first to finish' -Skip:(-not $IsLinux) {
        $case = New-ConcurrencyCaseRoot
        $names = @('alpha', 'bravo', 'charlie')
        foreach ($name in $names) { New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case "repos/$name") }
        $items = @(for ($index = 0; $index -lt $names.Count; $index++) { New-WorkItem -CaseRoot $case -Name $names[$index] -Index $index })

        # charlie (index 2) fails at once because its base branch is gone; alpha
        # (index 0) fails after 0.6 s through the shim; bravo succeeds at 0.2 s.
        & git -C (Join-Path $case 'repos/charlie') branch -m main main-renamed
        $shim = New-TimingGitShim -ShimRoot $case -LogPath (Join-Path $case 'order.log')
        $savedPath = $env:PATH
        $env:PATH = "$($shim.Directory):$savedPath"
        $env:SHIM_SLEEP_MATCH = '/worktrees/bravo'
        $env:SHIM_SLEEP = '0.2'
        $env:SHIM_FAIL_MATCH = '/worktrees/alpha'
        $env:SHIM_FAIL_SLEEP = '0.6'
        try {
            $results = Invoke-TaskWorktreePlanBatch -WorkItems $items -Limit 3 -ModulePath $modulePath
        }
        finally {
            $env:PATH = $savedPath
            Remove-Item Env:SHIM_SLEEP, Env:SHIM_SLEEP_MATCH, Env:SHIM_FAIL_MATCH, Env:SHIM_FAIL_SLEEP -ErrorAction SilentlyContinue
        }

        @($results | Where-Object Status -eq 'failed').Count | Should -Be 2
        $results.Index | Should -Be @(0, 1, 2)
        $intervals = Get-ShimIntervals -LogPath $shim.LogPath
        $intervals.Count | Should -Be 3
        # charlie's start ended before alpha's, so completion order is not plan order.
        $intervals[0].End | Should -BeLessThan $intervals[2].End
        $firstFailure = $results | Where-Object Status -eq 'failed' | Select-Object -First 1
        $firstFailure.Index | Should -Be 0
        $firstFailure.Repository | Should -Be 'alpha'
        $firstFailure.Message | Should -Match 'shim: forced failure'
        ($results | Where-Object Status -eq 'failed' | Select-Object -Last 1).Repository | Should -Be 'charlie'
    }

    It 'keeps the serial behavior and message when the limit is one' {
        $case = New-ConcurrencyCaseRoot
        $names = @('alpha', 'bravo')
        foreach ($name in $names) { New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case "repos/$name") }
        $items = @(for ($index = 0; $index -lt $names.Count; $index++) { New-WorkItem -CaseRoot $case -Name $names[$index] -Index $index })
        New-Item -ItemType Directory -Path (Join-Path $case 'tasks/CONCURRENCY-1/worktrees/alpha') -Force | Out-Null

        $results = Invoke-TaskWorktreePlanBatch -WorkItems $items -Limit 1 -ModulePath $modulePath

        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'failed'
        $results[0].Repository | Should -Be 'alpha'
        $results[0].Message | Should -Match 'refusing to overwrite existing destination'
        Test-Path -LiteralPath (Join-Path $case 'tasks/CONCURRENCY-1/worktrees/bravo') | Should -BeFalse
    }
}

Describe 'Worktree start gate' {
    It 'starts no git process once a failure is published' {
        $case = New-ConcurrencyCaseRoot
        New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case 'repos/alpha')
        $item = New-WorkItem -CaseRoot $case -Name 'alpha' -Index 0
        $state = [hashtable]::Synchronized(@{ Failed = $false; FirstFailedIndex = -1 })
        $gate = [System.Threading.SemaphoreSlim]::new(1, 1)
        Set-TaskWorktreeFailure -State $state -Gate $gate -Index 3

        $started = Invoke-TaskWorktreePlan -Repository $item.Repository -Plan $item.Plan -State $state -Gate $gate

        $started | Should -BeFalse
        Test-Path -LiteralPath $item.Plan.Destination | Should -BeFalse
    }

    It 'holds the gate across the git start, so a paused start is refused after publication' {
        # The barrier: the main thread owns the gate, a caller blocks on it just
        # before starting git, the failure is published first, then the gate is
        # released. A start that is not gated would create the worktree.
        $case = New-ConcurrencyCaseRoot
        New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case 'repos/alpha')
        $item = New-WorkItem -CaseRoot $case -Name 'alpha' -Index 0
        $state = [hashtable]::Synchronized(@{ Failed = $false; FirstFailedIndex = -1; Reached = $false })
        $gate = [System.Threading.SemaphoreSlim]::new(1, 1)
        $gate.Wait()
        $job = Start-ThreadJob -ArgumentList $modulePath, $item, $state, $gate -ScriptBlock {
            param($modulePath, $item, $state, $gate)
            Import-Module $modulePath -Force
            $state.Reached = $true
            return (Invoke-TaskWorktreePlan -Repository $item.Repository -Plan $item.Plan -State $state -Gate $gate)
        }
        try {
            for ($wait = 0; $wait -lt 250 -and -not $state.Reached; $wait++) { Start-Sleep -Milliseconds 20 }
            $state.Reached | Should -BeTrue
            Start-Sleep -Milliseconds 200
            # This thread owns the gate, so this write is the exclusive publication
            # step that Set-TaskWorktreeFailure performs in production.
            $state.Failed = $true
        }
        finally {
            $gate.Release()
        }
        $started = Receive-Job -Job $job -Wait
        Remove-Job -Job $job

        $started | Should -BeFalse
        Test-Path -LiteralPath $item.Plan.Destination | Should -BeFalse
    }

    It 'makes failure publication wait for the gate as well' {
        $state = [hashtable]::Synchronized(@{ Failed = $false; FirstFailedIndex = -1; Done = $false })
        $gate = [System.Threading.SemaphoreSlim]::new(1, 1)
        $gate.Wait()
        $job = Start-ThreadJob -ArgumentList $modulePath, $state, $gate -ScriptBlock {
            param($modulePath, $state, $gate)
            Import-Module $modulePath -Force
            Set-TaskWorktreeFailure -State $state -Gate $gate -Index 7
            $state.Done = $true
        }
        try {
            Start-Sleep -Milliseconds 300
            $state.Done | Should -BeFalse
            $state.Failed | Should -BeFalse
        }
        finally {
            $gate.Release()
        }
        Receive-Job -Job $job -Wait | Out-Null
        Remove-Job -Job $job

        $state.Done | Should -BeTrue
        $state.Failed | Should -BeTrue
        $state.FirstFailedIndex | Should -Be 7
    }
}

Describe 'Invoke-TaskScaffold parallel worktree apply' {
    It 'applies several independent repositories in one reviewed plan' {
        $case = New-ConcurrencyCaseRoot
        $names = @('alpha', 'bravo', 'charlie')
        foreach ($name in $names) { New-ConcurrencyFixtureRepository -RepositoryPath (Join-Path $case "repos/$name") }
        $requestPath = Join-Path $case 'multi.json'
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = 'CONCURRENCY-2'; title = 'multi'; prdPath = (Join-Path $case 'prd.md') }
            repositories = @($names | ForEach-Object { [ordered]@{ name = $_; path = (Join-Path $case "repos/$_"); baseBranch = 'main'; branch = 'feature/CONCURRENCY-2' } })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskScaffold.ps1'
        $tasksRoot = Join-Path $case 'tasks'

        $plan = & $script -RequestPath $requestPath -TasksRoot $tasksRoot | ConvertFrom-Json
        & $script -RequestPath $requestPath -TasksRoot $tasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity | Out-Null

        foreach ($name in $names) {
            Test-Path -LiteralPath (Join-Path $tasksRoot "CONCURRENCY-2/worktrees/$name/.git") | Should -BeTrue
            (& git -C (Join-Path $tasksRoot "CONCURRENCY-2/worktrees/$name") branch --show-current) | Should -Be 'feature/CONCURRENCY-2'
        }
    }
}

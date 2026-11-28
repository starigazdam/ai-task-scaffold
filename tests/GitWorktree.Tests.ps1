BeforeAll {
    $module = Join-Path $PSScriptRoot '../scripts/Private/GitWorktree.psm1'
    Import-Module $module -Force
}

Describe 'New-TaskWorktreePlan' {
    It 'plans a new local branch without creating a worktree' {
        $repositoryPath = Join-Path $TestDrive 'api'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $repository = [pscustomobject]@{
            Name = 'api'
            Path = $repositoryPath
            BaseBranch = 'main'
            Branch = 'feature/FEATURE-123'
        }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $workspaceRoot

        $plan.Action | Should -Be 'create-local'
        $plan.Destination | Should -Be (Join-Path $workspaceRoot 'FEATURE-123/worktrees/api')
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        (& git -C $repositoryPath branch --format '%(refname:short)') | Should -Not -Contain 'feature/FEATURE-123'
    }

    It 'plans an existing local feature branch without recreating it' {
        $repositoryPath = Join-Path $TestDrive 'api-existing-branch'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null
        & git -C $repositoryPath branch feature/FEATURE-123

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'feature/FEATURE-123'
        $plan.BranchMode | Should -Be 'existing'
    }

    It 'blocks a destination collision without changing the repository' {
        $repositoryPath = Join-Path $TestDrive 'api-collision'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $destination = Join-Path $workspaceRoot 'FEATURE-123/worktrees/api'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $workspaceRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'destination-exists'
        (& git -C $repositoryPath branch --format '%(refname:short)') | Should -Not -Contain 'feature/FEATURE-123'
    }

    if ($IsLinux) {
    It 'blocks a case-distinct repository at an existing destination' {
        $upperRepositoryPath = Join-Path $TestDrive 'CaseRepo'
        $lowerRepositoryPath = Join-Path $TestDrive 'caserepo'
        foreach ($repositoryPath in @($upperRepositoryPath, $lowerRepositoryPath)) {
            New-Item -ItemType Directory -Path $repositoryPath | Out-Null
            & git -C $repositoryPath init -b main | Out-Null
            & git -C $repositoryPath config user.name Test
            & git -C $repositoryPath config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
            & git -C $repositoryPath add README.md
            & git -C $repositoryPath commit -m fixture | Out-Null
        }

        $workspaceRoot = Join-Path $TestDrive 'workspace-case-distinct'
        $destination = Join-Path $workspaceRoot 'FEATURE-123/worktrees/api'
        & git -C $lowerRepositoryPath worktree add -b feature/FEATURE-123 $destination main | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $upperRepositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $workspaceRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'destination-exists'
    }
    }

    It 'blocks a case-distinct branch at an existing destination' {
        $repositoryPath = Join-Path $TestDrive 'api-branch-case'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $workspaceRoot = Join-Path $TestDrive 'workspace-branch-case'
        $destination = Join-Path $workspaceRoot 'FEATURE-123/worktrees/api'
        & git -C $repositoryPath worktree add -b feature/FEATURE-123 $destination main | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/feature-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $workspaceRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'destination-exists'
    }

    It 'blocks a symlinked matching destination on Linux' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-symlink-reuse'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $externalPath = Join-Path $TestDrive 'external-worktree'
        & git -C $repositoryPath worktree add -b feature/FEATURE-123 $externalPath main | Out-Null
        $workspaceRoot = Join-Path $TestDrive 'workspace-symlink-reuse'
        $destination = Join-Path $workspaceRoot 'FEATURE-123/worktrees/api'
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $destination -Target $externalPath | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $workspaceRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'unsafe-worktree-path'
    }

    It 'blocks a symlinked worktrees ancestor on Linux' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-symlink-ancestor'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $workspaceRoot = Join-Path $TestDrive 'workspace-symlink-ancestor'
        $worktreesPath = Join-Path $workspaceRoot 'FEATURE-123/worktrees'
        $externalPath = Join-Path $TestDrive 'external-worktrees'
        New-Item -ItemType Directory -Path $externalPath | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $worktreesPath) -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $worktreesPath -Target $externalPath | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $workspaceRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'unsafe-worktree-path'
    }

    It 'plans from an explicit origin base branch' {
        $originPath = Join-Path $TestDrive 'origin.git'
        $seedPath = Join-Path $TestDrive 'seed'
        $repositoryPath = Join-Path $TestDrive 'api-origin'
        & git init --bare $originPath | Out-Null
        New-Item -ItemType Directory -Path $seedPath | Out-Null
        & git -C $seedPath init -b main | Out-Null
        & git -C $seedPath config user.name Test
        & git -C $seedPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $seedPath 'README.md') -Value 'fixture'
        & git -C $seedPath add README.md
        & git -C $seedPath commit -m fixture | Out-Null
        & git -C $seedPath remote add origin $originPath
        & git -C $seedPath push -u origin main | Out-Null
        & git -C $originPath symbolic-ref HEAD refs/heads/main
        & git clone $originPath $repositoryPath | Out-Null
        & git -C $repositoryPath checkout main | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'origin/main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-origin')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'origin/main'
        $plan.BranchMode | Should -Be 'new'
    }
}

Describe 'Invoke-TaskWorktreePlan' {
    It 'creates exactly the planned local worktree' {
        $repositoryPath = Join-Path $TestDrive 'api-apply'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace')

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        Test-Path -LiteralPath $plan.Destination | Should -BeTrue
        (& git -C $plan.Destination branch --show-current) | Should -Be 'feature/FEATURE-123'
        (& git -C $repositoryPath branch --format '%(refname:short)') | Should -Contain 'feature/FEATURE-123'
    }

    It 'rechecks the worktree path before applying on Linux' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-apply-recheck'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $tasksRoot = Join-Path $TestDrive 'tasks-apply-recheck'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $worktreesPath = Join-Path $tasksRoot 'FEATURE-123/worktrees'
        $externalPath = Join-Path $TestDrive 'external-apply-recheck'
        New-Item -ItemType Directory -Path $externalPath | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $worktreesPath) -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $worktreesPath -Target $externalPath | Out-Null

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*unsafe worktree destination*'
        Test-Path -LiteralPath (Join-Path $externalPath 'api') | Should -BeFalse
    }

    It 'rejects a symlinked worktree swapped after planning on Linux' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'api-operation-symlink'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $tasksRoot = Join-Path $TestDrive 'tasks-operation-symlink'
        $destination = Join-Path $tasksRoot 'FEATURE-123/worktrees/api'
        $externalPath = Join-Path $TestDrive 'external-operation-symlink'
        & git -C $repositoryPath worktree add -b feature/FEATURE-123 $externalPath main | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $destination -Target $externalPath | Out-Null

        Test-TaskWorktreeOperationSafety -TasksRoot $tasksRoot -TaskKey 'FEATURE-123' -RepositoryName 'api' -RepositoryPath $repositoryPath -WorktreePath $destination -Branch 'feature/FEATURE-123' -ExpectedCommonDir (Get-GitCommonDir -RepositoryPath $repositoryPath) | Should -BeFalse
        Test-Path -LiteralPath $externalPath | Should -BeTrue
    }

    It 'refuses a reused worktree replaced after planning' {
        $repositoryPath = Join-Path $TestDrive 'api-reuse-replaced'
        $replacementRepositoryPath = Join-Path $TestDrive 'api-reuse-replacement'
        foreach ($path in @($repositoryPath, $replacementRepositoryPath)) {
            New-Item -ItemType Directory -Path $path | Out-Null
            & git -C $path init -b main | Out-Null
            & git -C $path config user.name Test
            & git -C $path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $path 'README.md') -Value 'fixture'
            & git -C $path add README.md
            & git -C $path commit -m fixture | Out-Null
        }

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'workspace-reuse-replaced'
        $initialPlan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        Invoke-TaskWorktreePlan -Repository $repository -Plan $initialPlan
        $reusePlan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        & git -C $repositoryPath worktree remove -- $reusePlan.Destination
        & git -C $replacementRepositoryPath worktree add -b feature/FEATURE-123 $reusePlan.Destination main | Out-Null

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reusePlan } | Should -Throw '*reused worktree changed since planning*'
        $expectedDestination = ([IO.Path]::GetFullPath($reusePlan.Destination)).Replace('\', '/')
        (@(& git -C $replacementRepositoryPath worktree list --porcelain) -join "`n") | Should -Match ([regex]::Escape($expectedDestination))
    }

    It 'rejects a same-branch worktree with a different Git directory' {
        $repositoryPath = Join-Path $TestDrive 'api-git-dir-identity'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null
        & git -C $repositoryPath branch feature/FEATURE-123

        $firstWorktree = Join-Path $TestDrive 'first-worktree'
        $secondWorktree = Join-Path $TestDrive 'second-worktree'
        & git -C $repositoryPath worktree add $firstWorktree feature/FEATURE-123 | Out-Null
        & git -C $repositoryPath worktree add --force $secondWorktree feature/FEATURE-123 | Out-Null
        $expectedGitDir = (& git -C $firstWorktree rev-parse --path-format=absolute --git-dir).Trim()

        Test-TaskWorktreeIdentity -RepositoryPath $repositoryPath -WorktreePath $secondWorktree -Branch 'feature/FEATURE-123' -ExpectedCommonDir (Get-GitCommonDir -RepositoryPath $repositoryPath) -ExpectedGitDir $expectedGitDir | Should -BeFalse
    }

    It 'reuses an existing matching worktree' {
        $repositoryPath = Join-Path $TestDrive 'api-reuse'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $initialPlan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-reuse')
        Invoke-TaskWorktreePlan -Repository $repository -Plan $initialPlan

        $repeatPlan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-reuse')
        Invoke-TaskWorktreePlan -Repository $repository -Plan $repeatPlan

        $repeatPlan.Action | Should -Be 'reuse'
        $repeatPlan.Destination | Should -Be $initialPlan.Destination
        (& git -C $repeatPlan.Destination branch --show-current) | Should -Be 'feature/FEATURE-123'
    }
}

Describe 'New-TaskWorktreePlan start commit' {
    BeforeAll {
        function New-StartCommitRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'first'
            & git -C $Path add README.md
            & git -C $Path commit -m first | Out-Null
            $older = (& git -C $Path rev-parse HEAD).Trim()
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'second'
            & git -C $Path commit -am second | Out-Null
            $head = (& git -C $Path rev-parse HEAD).Trim()

            [pscustomobject]@{ Path = $Path; Older = $older; Head = $head }
        }
    }

    It 'plans and applies a new branch from an explicit start commit' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Older }
        $tasksRoot = Join-Path $TestDrive 'workspace-start-commit'
        $noLazyFetchBefore = [Environment]::GetEnvironmentVariable('GIT_NO_LAZY_FETCH')

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be $fixture.Older
        $plan.BranchMode | Should -Be 'new'
        [Environment]::GetEnvironmentVariable('GIT_NO_LAZY_FETCH') | Should -Be $noLazyFetchBefore -Because 'the fetch guard must not leak into worktree add'

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        Test-Path -LiteralPath $plan.Destination | Should -BeTrue
        (& git -C $fixture.Path rev-parse 'feature/FEATURE-123').Trim() | Should -Be $fixture.Older
        (& git -C $fixture.Path rev-parse 'main').Trim() | Should -Be $fixture.Head
    }

    It 'scopes the no-lazy-fetch guard to read-only git calls' -Skip:(-not $IsLinux) {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-no-lazy-fetch')
        $logPath = Join-Path $TestDrive 'no-lazy-fetch.log'
        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shimDir = Join-Path $TestDrive 'no-lazy-fetch-shim'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $shimPath = Join-Path $shimDir 'git'
        @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            "LOG='$logPath'"
            'case " $* " in'
            '  *" rev-parse --verify "*) echo "verify ${GIT_NO_LAZY_FETCH:-unset}" >> "$LOG" ;;'
            '  *" worktree add "*) echo "add ${GIT_NO_LAZY_FETCH:-unset}" >> "$LOG" ;;'
            'esac'
            'exec "$REAL_GIT" "$@"'
        ) | Set-Content -LiteralPath $shimPath
        & chmod +x $shimPath

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Older }
        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-no-lazy-fetch')
            Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        }
        finally { $env:PATH = $savedPath }

        $log = @(Get-Content -LiteralPath $logPath)
        $log | Should -Contain 'verify 1'
        $log | Should -Contain 'add unset'
        @($log | Where-Object { $_ -cne 'verify 1' -and $_ -cne 'add unset' }) | Should -BeNullOrEmpty -Because 'only the read-only resolution is guarded, never the checkout'
    }

    It 'blocks a start commit that is missing locally' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit-missing')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = ('a' * 40) }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-start-commit-missing')

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing'
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
    }

    It 'blocks an existing branch that points at another commit' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit-mismatch')
        & git -C $fixture.Path branch feature/FEATURE-123 | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Older }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-start-commit-mismatch')

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-mismatch'
    }

    It 'reuses an existing branch that points at the start commit' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit-existing')
        & git -C $fixture.Path branch feature/FEATURE-123 $fixture.Older | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Older }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-start-commit-existing')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'feature/FEATURE-123'
        $plan.BranchMode | Should -Be 'existing'
    }

    It 'blocks a missing start commit before reusing a matching worktree' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit-reuse-missing')
        $tasksRoot = Join-Path $TestDrive 'workspace-start-commit-reuse-missing'
        & git -C $fixture.Path worktree add -b feature/FEATURE-123 (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') main | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = ('a' * 40) }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing'
    }

    It 'reuses a matching worktree when a valid start commit is supplied' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit-reuse-valid')
        $tasksRoot = Join-Path $TestDrive 'workspace-start-commit-reuse-valid'
        & git -C $fixture.Path worktree add -b feature/FEATURE-123 (Join-Path $tasksRoot 'FEATURE-123/worktrees/api') main | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Older }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $plan.Action | Should -Be 'reuse'
        $plan.Source | Should -Be 'feature/FEATURE-123'
    }

    It 'plans and applies a tracking branch from the full remote ref' {
        $fixture = New-StartCommitRepository -Path (Join-Path $TestDrive 'api-start-commit-remote')
        $remotePath = Join-Path $TestDrive 'api-start-commit-remote.git'
        & git init --bare $remotePath | Out-Null
        & git -C $fixture.Path remote add origin $remotePath
        & git -C $fixture.Path push origin 'main:refs/heads/feature/FEATURE-123' | Out-Null
        & git -C $fixture.Path fetch origin | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Head }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-start-commit-remote')

        $plan.Action | Should -Be 'create-remote'
        $plan.Source | Should -Be 'refs/remotes/origin/feature/FEATURE-123'

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination branch --show-current) | Should -Be 'feature/FEATURE-123'
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
    }
}

Describe 'Invoke-TaskWorktreePlan tracking start' {
    BeforeAll {
        function New-TrackingFixture {
            param([string]$Path, [string]$RemotePath, [string]$Branch = 'feature/FEATURE-123')

            New-Item -ItemType Directory -Path $Path | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'first'
            & git -C $Path add README.md
            & git -C $Path commit -m first | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'second'
            & git -C $Path commit -am second | Out-Null
            $reviewed = (& git -C $Path rev-parse HEAD).Trim()

            & git init --bare $RemotePath | Out-Null
            & git -C $Path remote add origin $RemotePath
            & git -C $Path push origin "main:refs/heads/$Branch" | Out-Null
            & git -C $Path fetch origin | Out-Null

            [pscustomobject]@{ Path = $Path; Remote = $RemotePath; Branch = $Branch; Reviewed = $reviewed }
        }

        function Move-TrackingBranch {
            param([pscustomobject]$Fixture)

            # Move only the selected remote-tracking ref. commit-tree creates a
            # new commit without moving any local branch, so main cannot advance
            # and mask a plan that bound the wrong ref.
            $old = (& git -C $Fixture.Path rev-parse "refs/remotes/origin/$($Fixture.Branch)").Trim()
            $tree = (& git -C $Fixture.Path rev-parse 'HEAD^{tree}').Trim()
            $commit = (& git -C $Fixture.Path commit-tree $tree -p $old -m 'move the remote task ref').Trim()
            & git -C $Fixture.Path push origin "${commit}:refs/heads/$($Fixture.Branch)" | Out-Null
            & git -C $Fixture.Path fetch origin | Out-Null
            $new = (& git -C $Fixture.Path rev-parse "refs/remotes/origin/$($Fixture.Branch)").Trim()
            [pscustomobject]@{
                Old = $old
                New = $new
                Main = (& git -C $Fixture.Path rev-parse 'refs/heads/main').Trim()
            }
        }
    }

    It 'creates a tracking branch at the reviewed commit when the remote ref moves after planning' {
        $fixture = New-TrackingFixture -Path (Join-Path $TestDrive 'api-track-moved') -RemotePath (Join-Path $TestDrive 'api-track-moved.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch; StartCommit = $fixture.Reviewed }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-track-moved')

        $plan.Action | Should -Be 'create-remote'
        $plan.SourceCommit | Should -Be $fixture.Reviewed

        $move = Move-TrackingBranch -Fixture $fixture
        $move.Old | Should -Be $fixture.Reviewed -Because 'only the selected remote-tracking ref may move'
        $move.New | Should -Not -Be $move.Old
        $move.Main | Should -Be $fixture.Reviewed -Because 'a main advance must not be able to mask which ref moved'
        (& git -C $fixture.Path rev-parse "refs/remotes/origin/$($fixture.Branch)").Trim() | Should -Be $move.New -Because 'the race fixture must really move the selected remote ref'
        (& git -C $fixture.Remote rev-parse "refs/heads/$($fixture.Branch)").Trim() | Should -Be $move.New

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be "refs/remotes/origin/$($fixture.Branch)"
        (& git -C $plan.Destination rev-parse "$($fixture.Branch)@{upstream}").Trim() | Should -Be $move.New -Because 'the upstream stays on origin even though the branch starts at the reviewed commit'
    }

    It 'binds the remote commit without startCommit and still starts at it after the ref moves' {
        $fixture = New-TrackingFixture -Path (Join-Path $TestDrive 'api-track-moved-none') -RemotePath (Join-Path $TestDrive 'api-track-moved-none.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-track-moved-none')

        $plan.Action | Should -Be 'create-remote'
        $plan.Source | Should -Be "origin/$($fixture.Branch)"
        $plan.SourceCommit | Should -Be $fixture.Reviewed

        $move = Move-TrackingBranch -Fixture $fixture
        $move.Old | Should -Be $fixture.Reviewed
        $move.New | Should -Not -Be $move.Old
        $move.Main | Should -Be $fixture.Reviewed -Because 'only the selected remote-tracking ref moved'
        (& git -C $fixture.Path rev-parse "refs/remotes/origin/$($fixture.Branch)").Trim() | Should -Be $move.New -Because 'the race fixture must really move the selected remote ref'

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be "refs/remotes/origin/$($fixture.Branch)"
    }

    It 'ignores a local branch named like the origin shorthand' {
        $fixture = New-TrackingFixture -Path (Join-Path $TestDrive 'api-track-decoy') -RemotePath (Join-Path $TestDrive 'api-track-decoy.git')
        Set-Content -LiteralPath (Join-Path $fixture.Path 'README.md') -Value 'decoy'
        & git -C $fixture.Path commit -am decoy | Out-Null
        $decoy = (& git -C $fixture.Path rev-parse HEAD).Trim()
        & git -C $fixture.Path branch "origin/$($fixture.Branch)" $decoy | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-track-decoy')
        $plan.Action | Should -Be 'create-remote'
        $plan.SourceCommit | Should -Be $fixture.Reviewed -Because 'a local origin/<branch> branch must not redirect the start'

        $startCommitRepository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch; StartCommit = $fixture.Reviewed }
        $startCommitPlan = New-TaskWorktreePlan -Repository $startCommitRepository -TaskKey 'FEATURE-124' -TasksRoot (Join-Path $TestDrive 'workspace-track-decoy-start-commit')
        $startCommitPlan.Action | Should -Be 'create-remote'
        $startCommitPlan.SourceCommit | Should -Be $fixture.Reviewed

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Not -Be $decoy
    }

    It 'creates a local branch at the reviewed base commit when the base branch moves after planning' {
        $repositoryPath = Join-Path $TestDrive 'api-base-moved'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'first'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m first | Out-Null
        $reviewed = (& git -C $repositoryPath rev-parse HEAD).Trim()
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-base-moved')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'main'
        $plan.SourceCommit | Should -Be $reviewed

        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'moved'
        & git -C $repositoryPath commit -am moved | Out-Null
        $moved = (& git -C $repositoryPath rev-parse HEAD).Trim()

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $reviewed
        (& git -C $repositoryPath rev-parse main).Trim() | Should -Be $moved
    }

    It 'refuses an existing branch that moved after planning' {
        $repositoryPath = Join-Path $TestDrive 'api-existing-moved'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'first'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m first | Out-Null
        $reviewed = (& git -C $repositoryPath rev-parse HEAD).Trim()
        & git -C $repositoryPath branch feature/FEATURE-123 $reviewed | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-existing-moved')

        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'
        $plan.SourceCommit | Should -Be $reviewed

        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'moved'
        & git -C $repositoryPath commit -am moved | Out-Null
        $moved = (& git -C $repositoryPath rev-parse HEAD).Trim()
        & git -C $repositoryPath branch -f feature/FEATURE-123 $moved | Out-Null

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*is not the planned commit*'
    }

    It 'accepts a checked-out task branch that is itself a symbolic alias' {
        $repositoryPath = Join-Path $TestDrive 'api-alias'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null
        & git -C $repositoryPath branch feature/REAL | Out-Null
        & git -C $repositoryPath symbolic-ref refs/heads/feature/ALIAS refs/heads/feature/REAL
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/ALIAS' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-alias')

        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (Get-Content -LiteralPath (Join-Path $repositoryPath '.git/worktrees/api/HEAD') -Raw).Trim() |
            Should -Be 'ref: refs/heads/feature/ALIAS'
        (& git -C $plan.Destination symbolic-ref -q --no-recurse HEAD) | Should -Be 'refs/heads/feature/ALIAS'
    }

    It 'accepts a checked-out task branch that is an indirect symbolic alias' {
        $repositoryPath = Join-Path $TestDrive 'api-alias-indirect'
        New-Item -ItemType Directory -Path $repositoryPath | Out-Null
        & git -C $repositoryPath init -b main | Out-Null
        & git -C $repositoryPath config user.name Test
        & git -C $repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $repositoryPath 'README.md') -Value 'fixture'
        & git -C $repositoryPath add README.md
        & git -C $repositoryPath commit -m fixture | Out-Null
        & git -C $repositoryPath branch feature/REAL | Out-Null
        & git -C $repositoryPath symbolic-ref refs/heads/feature/ALIAS refs/heads/feature/REAL
        & git -C $repositoryPath symbolic-ref refs/heads/feature/ALIAS2 refs/heads/feature/ALIAS
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/ALIAS2' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-alias-indirect')

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (Get-Content -LiteralPath (Join-Path $repositoryPath '.git/worktrees/api/HEAD') -Raw).Trim() |
            Should -Be 'ref: refs/heads/feature/ALIAS2'
        (& git -C $plan.Destination symbolic-ref -q --no-recurse HEAD) | Should -Be 'refs/heads/feature/ALIAS2'
    }
}

Describe 'Worktree reuse verification and repair' {
    BeforeAll {
        function New-ReuseRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'first'
            & git -C $Path add README.md
            & git -C $Path commit -m first | Out-Null
            return [pscustomobject]@{ Path = $Path; Head = (& git -C $Path rev-parse HEAD).Trim() }
        }

        function New-TrackingRepository {
            param([string]$Path, [string]$RemotePath, [string]$Branch = 'feature/FEATURE-123')

            $fixture = New-ReuseRepository -Path $Path
            & git init --bare $RemotePath | Out-Null
            & git -C $Path remote add origin $RemotePath
            & git -C $Path push origin 'main:refs/heads/main' "main:refs/heads/$Branch" | Out-Null
            & git -C $Path fetch origin | Out-Null
            return [pscustomobject]@{ Path = $Path; Remote = $RemotePath; Branch = $Branch; Head = $fixture.Head }
        }

        function New-FailureShim {
            param([string]$Directory, [string]$Body)

            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
            $shimPath = Join-Path $Directory 'git'
            $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
            @(
                '#!/bin/sh'
                "REAL_GIT='$realGit'"
                'case " $* " in'
                ('  *" worktree add "*) ' + $Body + '; exit 1 ;;')
                'esac'
                'exec "$REAL_GIT" "$@"'
            ) | Set-Content -LiteralPath $shimPath
            & chmod +x $shimPath
            return $shimPath
        }

        function New-UpstreamRaceShim {
            param([string]$Directory, [string]$RepositoryPath, [string]$Branch, [string]$Mode, [string]$OtherCommit = '', [string]$CountPath = '')

            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
            $shimPath = Join-Path $Directory 'git'
            $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
            @(
                '#!/bin/sh'
                "REAL_GIT='$realGit'"
                "REPO='$RepositoryPath'"
                "BRANCH='$Branch'"
                "MODE='$Mode'"
                "OTHER='$OtherCommit'"
                "COUNT_FILE='$CountPath'"
                'case " $* " in'
                '  *" for-each-ref "*)'
                '    case " $* " in'
                '      *"%(upstream)"*)'
                '        if [ "$MODE" = "upstream" ]; then'
                '          N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$COUNT_FILE"'
                '          if [ "$N" -eq 2 ]; then'
                '            "$REAL_GIT" -C "$REPO" branch --set-upstream-to=refs/remotes/origin/main "$BRANCH" >/dev/null 2>&1'
                '          fi'
                '        fi'
                '        ;;'
                '    esac'
                '    ;;'
                '  *" config --replace-all branch."*)'
                '    "$REAL_GIT" "$@"; CODE=$?'
                '    if [ "$MODE" = "tip" ]; then'
                '      "$REAL_GIT" -C "$REPO" update-ref "refs/heads/$BRANCH" "$OTHER"'
                '    fi'
                '    exit $CODE'
                '    ;;'
                'esac'
                'exec "$REAL_GIT" "$@"'
            ) | Set-Content -LiteralPath $shimPath
            & chmod +x $shimPath
            return $shimPath
        }
    }

    It 'attaches the branch left by a failed tracking add without inventing an upstream' -Skip:(-not $IsLinux) {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'retry-branch-only') -RemotePath (Join-Path $TestDrive 'retry-branch-only.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $tasksRoot = Join-Path $TestDrive 'retry-branch-only-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'
        $plan.SourceCommit | Should -Be $fixture.Head

        # The add fails after creating only the branch at the pinned commit: no
        # destination, no worktree registration, nothing recorded by the scaffold.
        $shimDir = Join-Path $TestDrive 'retry-branch-only-shim'
        $body = '"$REAL_GIT" -C ''{0}'' branch ''{1}'' ''{2}'' >/dev/null 2>&1; echo ''shim: branch-only failure'' >&2' -f $fixture.Path, $fixture.Branch, $fixture.Head
        New-FailureShim -Directory $shimDir -Body $body | Out-Null

        $savedPath = $env:PATH
        $env:PATH = "${shimDir}:${savedPath}"
        try {
            { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*git worktree add failed*'
        }
        finally { $env:PATH = $savedPath }

        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        (& git -C $fixture.Path rev-parse "refs/heads/$($fixture.Branch)").Trim() | Should -Be $fixture.Head -Because 'a failed attempt must preserve the branch, never delete it'

        # The branch exists but tracks nothing. A readable origin/<branch> is not
        # evidence that the tracking create was interrupted, so the retry binds
        # no upstream and attaches without writing one. Recovering a lost
        # upstream would need recorded request intent, which the request does not
        # carry; set the upstream by hand, or leave the branch untracked. A
        # recreated worktree would not restore tracking either.
        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Action | Should -Be 'create-local'
        $retry.BranchMode | Should -Be 'existing'
        $retry.UpstreamRef | Should -BeNullOrEmpty -Because 'attach binds the branch actual upstream, including none'
        Invoke-TaskWorktreePlan -Repository $repository -Plan $retry

        (& git -C $retry.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
        (& git -C $retry.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty -Because 'attach never invents tracking'
    }

    It 'binds the upstream an attached worktree inherits from a worktree-local source config' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-worktree-config') -RemotePath (Join-Path $TestDrive 'attach-worktree-config.git')
        $tasksRoot = Join-Path $TestDrive 'attach-worktree-config-tasks'
        # The local task branch exists and the shared config tracks nothing.
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path config extensions.worktreeConfig true
        # Only the source worktree tracks a branch, through worktree-local
        # config. Git copies that config to a new worktree on add, so the plan
        # must bind the inherited upstream or apply would fail on an unchanged
        # branch.
        & git -C $fixture.Path config --worktree "branch.$($fixture.Branch).remote" origin
        & git -C $fixture.Path config --worktree "branch.$($fixture.Branch).merge" refs/heads/main
        (& git -C $fixture.Path for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main' -Because 'the fixture must really set a source worktree-local upstream'
        (& git -C $fixture.Path config --local --get "branch.$($fixture.Branch).remote" 2>$null) | Out-Null
        $LASTEXITCODE | Should -Be 1 -Because 'the shared config must have no upstream for the branch'
        $sourceWorktreeConfig = [IO.File]::ReadAllText((& git -C $fixture.Path rev-parse --path-format=absolute --git-path config.worktree).Trim())

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'
        $plan.UpstreamRef | Should -Be 'refs/remotes/origin/main' -Because 'the destination inherits the copied source worktree config'

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main' -Because 'the unchanged branch keeps exactly the upstream it inherited'
        # Attach never writes tracking: the shared config stays empty, and the
        # destination's worktree config is the copy Git made, not a repair.
        (& git -C $plan.Destination config --local --get "branch.$($fixture.Branch).remote" 2>$null) | Out-Null
        $LASTEXITCODE | Should -Be 1 -Because 'attach must not write an upstream into the shared config'
        [IO.File]::ReadAllText((& git -C $plan.Destination rev-parse --path-format=absolute --git-path config.worktree).Trim()) | Should -Be $sourceWorktreeConfig -Because 'a repair would have rewritten the destination worktree config'
    }

    It 'binds and verifies a shared-config upstream when attaching an existing branch' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-shared-upstream') -RemotePath (Join-Path $TestDrive 'attach-shared-upstream.git')
        $tasksRoot = Join-Path $TestDrive 'attach-shared-upstream-tasks'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path config "branch.$($fixture.Branch).remote" origin
        & git -C $fixture.Path config "branch.$($fixture.Branch).merge" refs/heads/main
        (& git -C $fixture.Path for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'
        $plan.UpstreamRef | Should -Be 'refs/remotes/origin/main' -Because 'attach binds the upstream the new worktree inherits'

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'
    }

    It 'creates the task branch at the reviewed commit when a branch is named after it' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'sha-named-branch') -RemotePath (Join-Path $TestDrive 'sha-named-branch.git')
        $tasksRoot = Join-Path $TestDrive 'sha-named-branch-tasks'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/LOCAL-1' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.SourceCommit | Should -Be $fixture.Head
        # worktree add resolves a branch literally named after a bare object ID
        # before the object itself.
        $other = (& git -C $fixture.Path commit-tree "$($fixture.Head)^{tree}" -p $fixture.Head -m other).Trim()
        & git -C $fixture.Path branch $fixture.Head $other 2>$null | Out-Null
        (& git -C $fixture.Path rev-parse --verify --quiet "refs/heads/$($fixture.Head)").Trim() | Should -Be $other -Because 'the fixture must really hold the lookalike branch'

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
    }

    It 'sets the planned upstream when a tag is spelled like the remote ref' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'tag-lookalike-upstream') -RemotePath (Join-Path $TestDrive 'tag-lookalike-upstream.git')
        $tasksRoot = Join-Path $TestDrive 'tag-lookalike-upstream-tasks'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'
        # `git branch --set-upstream-to` reads this full name as ambiguous.
        & git -C $fixture.Path tag "refs/remotes/origin/$($fixture.Branch)" $fixture.Head | Out-Null
        & git -C $fixture.Path show-ref --verify --quiet "refs/tags/refs/remotes/origin/$($fixture.Branch)"
        $LASTEXITCODE | Should -Be 0 -Because 'the fixture must really hold the lookalike tag'

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be "refs/remotes/origin/$($fixture.Branch)"
    }

    It 'sets the planned upstream over several stale remote values' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'multi-remote-upstream') -RemotePath (Join-Path $TestDrive 'multi-remote-upstream.git')
        $tasksRoot = Join-Path $TestDrive 'multi-remote-upstream-tasks'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'
        # Two remote values and no merge value: no upstream, but plain
        # `git config` refuses to overwrite the key.
        & git -C $fixture.Path config --add "branch.$($fixture.Branch).remote" origin
        & git -C $fixture.Path config --add "branch.$($fixture.Branch).remote" origin

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be "refs/remotes/origin/$($fixture.Branch)"
    }

    It 'plans an attach from a valid UTF-8 path that contains U+FFFD' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive "fffd-$([char]0xFFFD)-path") -RemotePath (Join-Path $TestDrive 'fffd.git')
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'fffd-tasks')
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'
    }

    It 'blocks an attach plan whose worktree config has an empty includeIf condition' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-empty-includeif') -RemotePath (Join-Path $TestDrive 'attach-empty-includeif.git')
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        $worktreeConfig = (& git -C $fixture.Path rev-parse --path-format=absolute --git-path config.worktree).Trim()
        Set-Content -LiteralPath $worktreeConfig -Value "[includeIf `"`"]`n`tpath = ./extra.cfg"

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'attach-empty-includeif-tasks')
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'worktree-config-include'
    }

    It 'refuses to plan an attach when the worktree config path is not UTF-8' -Skip:(-not $IsLinux) {
        $raw = Join-Path $TestDrive 'raw-parent'
        New-Item -ItemType Directory -Path $raw -Force | Out-Null
        & bash -c 'cd "$1" && mkdir "$(printf "x\377y")" && ln -s "$(printf "x\377y")" valid-link' _ $raw
        $fixture = New-TrackingRepository -Path (Join-Path $raw 'valid-link/api') -RemotePath (Join-Path $TestDrive 'raw-api.git')
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null

        try {
            $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
            { New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'raw-tasks') } | Should -Throw '*not valid UTF-8*'
        }
        finally {
            # Pester cannot delete a TestDrive entry whose name is not UTF-8.
            & bash -c 'rm -rf "$1"' _ $raw
        }
    }

    It 'blocks pinned and no-pin attach plans when the Git directory path has a backslash' -Skip:(-not $IsLinux) {
        $raw = Join-Path $TestDrive 'backslash-parent'
        New-Item -ItemType Directory -Path $raw -Force | Out-Null
        # PowerShell on Linux reads a backslash as a separator, so create the
        # directory natively and reach it through a plain symlink.
        & bash -c 'cd "$1" && mkdir "x\\y" && ln -s "x\\y" plain-link' _ $raw
        try {
            $fixture = New-TrackingRepository -Path (Join-Path $raw 'plain-link/api') -RemotePath (Join-Path $TestDrive 'backslash-api.git')
            & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
            & git -C $fixture.Path config extensions.worktreeConfig true
            & git -C $fixture.Path config --worktree include.path ./extra.cfg
            (& git -C $fixture.Path rev-parse --path-format=absolute --git-path config.worktree) | Should -BeLike '*x\y*' -Because 'Git must report the real path with the backslash'

            foreach ($pin in @($null, $fixture.Head)) {
                $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch; StartCommit = $pin }
                $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'backslash-tasks')
                $plan.Action | Should -Be 'blocked' -Because "pin '$pin'"
                $plan.Reason | Should -Be 'worktree-config-include'
            }
        }
        finally {
            & bash -c 'rm -rf "$1"' _ $raw
        }
    }

    It 'blocks an attach plan when the source path contains a newline' -Skip:(-not $IsLinux) {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive "attach-newline`npath") -RemotePath (Join-Path $TestDrive 'attach-newline.git')
        $tasksRoot = Join-Path $TestDrive 'attach-newline-tasks'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path config extensions.worktreeConfig true
        & git -C $fixture.Path config --worktree include.path ./extra.cfg

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'worktree-config-include'
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
    }

    It 'blocks an attach plan whose source worktree config includes a relative file' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-relative-include') -RemotePath (Join-Path $TestDrive 'attach-relative-include.git')
        $tasksRoot = Join-Path $TestDrive 'attach-relative-include-tasks'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path config extensions.worktreeConfig true
        # The only source of the upstream is a file reached through a relative
        # include.path. `git worktree add` copies the include line but not the
        # file, so the destination would resolve no upstream and apply would
        # fail on an unchanged branch.
        $worktreeConfig = (& git -C $fixture.Path rev-parse --path-format=absolute --git-path config.worktree).Trim()
        Set-Content -LiteralPath (Join-Path (Split-Path -Parent $worktreeConfig) 'attach-extra.cfg') -Value "[branch `"$($fixture.Branch)`"]`n`tremote = origin`n`tmerge = refs/heads/main"
        & git -C $fixture.Path config --worktree include.path ./attach-extra.cfg
        (& git -C $fixture.Path for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main' -Because 'the fixture must really take its upstream from the included file'

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'worktree-config-include'
        $plan.Destination | Should -Be (Join-Path $tasksRoot (Join-Path 'FEATURE-123/worktrees' 'api'))
        $plan.Message | Should -Match ([regex]::Escape($worktreeConfig)) -Because 'the diagnostic must name the worktree config file'
        $plan.Message | Should -Match 'shared repository config' -Because 'the diagnostic must name the fix'
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw "*$($plan.Reason)*"
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse -Because 'a blocked plan must create no worktree'
    }

    It 'blocks an attach plan whose source worktree config conditionally includes a relative file' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-relative-includeif') -RemotePath (Join-Path $TestDrive 'attach-relative-includeif.git')
        $tasksRoot = Join-Path $TestDrive 'attach-relative-includeif-tasks'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path config extensions.worktreeConfig true
        # includeIf.<condition>.path also resolves against the including file.
        & git -C $fixture.Path config --worktree 'includeIf.onbranch:no such/x.path' ./attach-extra.cfg

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'worktree-config-include'
        $plan.Message | Should -Match ([regex]::Escape('includeif.onbranch:no such/x.path'))
    }

    It 'blocks an attach plan whose source worktree config includes an absolute file' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-absolute-include') -RemotePath (Join-Path $TestDrive 'attach-absolute-include.git')
        $tasksRoot = Join-Path $TestDrive 'attach-absolute-include-tasks'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        # The planner does not classify include paths. Any include in the
        # copied file blocks, even with the extension off (a stale file).
        & git -C $fixture.Path config --file (& git -C $fixture.Path rev-parse --path-format=absolute --git-path config.worktree).Trim() include.path (Join-Path $TestDrive 'attach-absolute-extra.cfg')

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'worktree-config-include'
    }

    It 'plans and attaches when the upstream comes from an include in the shared config' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'attach-shared-include') -RemotePath (Join-Path $TestDrive 'attach-shared-include.git')
        $tasksRoot = Join-Path $TestDrive 'attach-shared-include-tasks'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path config extensions.worktreeConfig true
        # A shared-config include resolves against the common config file, so
        # every worktree reads the same file.
        $commonDir = (& git -C $fixture.Path rev-parse --path-format=absolute --git-common-dir).Trim()
        Set-Content -LiteralPath (Join-Path $commonDir 'shared-extra.cfg') -Value "[branch `"$($fixture.Branch)`"]`n`tremote = origin`n`tmerge = refs/heads/main"
        & git -C $fixture.Path config include.path ./shared-extra.cfg
        (& git -C $fixture.Path for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'
        $plan.UpstreamRef | Should -Be 'refs/remotes/origin/main'

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'
    }

    It 'refuses an upstream that a concurrent writer set before the write' -Skip:(-not $IsLinux) {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'upstream-writer-race') -RemotePath (Join-Path $TestDrive 'upstream-writer-race.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'upstream-writer-race-tasks')
        $plan.Action | Should -Be 'create-remote'
        $plan.UpstreamRef | Should -Be "refs/remotes/origin/$($fixture.Branch)"

        # On the guard re-read (the second upstream read), an external writer has
        # already set origin/main. Apply must refuse instead of overwriting it.
        # The window is best effort: the guard read and the write are separate
        # Git commands, so a writer that lands after the guard can still be
        # overwritten. Post-write verification detects a mismatch that stays
        # visible after the write; it cannot detect an overwrite that another
        # writer replaced with exactly the planned value.
        $countPath = Join-Path $TestDrive 'upstream-writer-race-count'
        $shimDir = Join-Path $TestDrive 'upstream-writer-race-shim'
        New-UpstreamRaceShim -Directory $shimDir -RepositoryPath $fixture.Path -Branch $fixture.Branch -Mode 'upstream' -CountPath $countPath | Out-Null

        $savedPath = $env:PATH
        $env:PATH = "${shimDir}:${savedPath}"
        try {
            { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*acquired upstream*replan and approve again*'
        }
        finally { $env:PATH = $savedPath }

        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'
    }

    It 're-verifies the tip after the upstream write' -Skip:(-not $IsLinux) {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'upstream-tip-race') -RemotePath (Join-Path $TestDrive 'upstream-tip-race.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'upstream-tip-race-tasks')
        $plan.Action | Should -Be 'create-remote'

        # A writer moves the branch tip while the upstream write is executing.
        Set-Content -LiteralPath (Join-Path $fixture.Path 'README.md') -Value 'moved'
        & git -C $fixture.Path commit -am moved | Out-Null
        $other = (& git -C $fixture.Path rev-parse HEAD).Trim()
        $shimDir = Join-Path $TestDrive 'upstream-tip-race-shim'
        New-UpstreamRaceShim -Directory $shimDir -RepositoryPath $fixture.Path -Branch $fixture.Branch -Mode 'tip' -OtherCommit $other | Out-Null

        $savedPath = $env:PATH
        $env:PATH = "${shimDir}:${savedPath}"
        try {
            { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*is not the planned commit*replan and approve again*'
        }
        finally { $env:PATH = $savedPath }

        (& git -C $fixture.Path rev-parse "refs/heads/$($fixture.Branch)").Trim() | Should -Be $other -Because 'the failed write must not reset the branch'
    }

    It 'reuses a pinned worktree after its branch advances and keeps the historical pin' {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-pinned-advanced')
        & git -C $fixture.Path branch feature/FEATURE-123 $fixture.Head | Out-Null
        $tasksRoot = Join-Path $TestDrive 'reuse-pinned-advanced-tasks'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Head }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        Set-Content -LiteralPath (Join-Path $plan.Destination 'README.md') -Value 'advanced'
        & git -C $plan.Destination commit -am advanced | Out-Null
        $advanced = (& git -C $plan.Destination rev-parse HEAD).Trim()
        $advanced | Should -Not -Be $fixture.Head

        # The reviewed StartCommit stays the historical pin. Reuse does not
        # re-pin to the advanced tip and still verifies it through apply: the
        # historical pin and the live branch tip legitimately differ.
        $replanned = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $fixture.Head }
        $reuse = New-TaskWorktreePlan -Repository $replanned -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        $reuse.SourceCommit | Should -Be $advanced
        $reuse.UpstreamRef | Should -BeNullOrEmpty
        { Invoke-TaskWorktreePlan -Repository $replanned -Plan $reuse } | Should -Not -Throw
        (& git -C $reuse.Destination rev-parse HEAD).Trim() | Should -Be $advanced
    }

    It 'reuses an untouched worktree whose branch has no upstream and writes nothing' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-upstream-missing') -RemotePath (Join-Path $TestDrive 'reuse-upstream-missing.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $tasksRoot = Join-Path $TestDrive 'reuse-upstream-missing-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        & git -C $plan.Destination branch --unset-upstream
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty

        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        $reuse.UpstreamRef | Should -BeNullOrEmpty -Because 'reuse binds the branch actual upstream, including its absence'

        # Both sides are none, so the untouched worktree is reusable. Reuse only
        # verifies: it never writes the remote task ref back as an upstream.
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Not -Throw
        (& git -C $reuse.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty
    }

    It 'reuses a local task branch with no upstream and never invents one from origin' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-no-upstream') -RemotePath (Join-Path $TestDrive 'reuse-no-upstream.git')
        # The remote task ref exists, but the local branch was never published
        # with -u and tracks nothing.
        & git -C $fixture.Path branch $fixture.Branch $fixture.Head | Out-Null
        $tasksRoot = Join-Path $TestDrive 'reuse-no-upstream-tasks'
        $destination = Join-Path $tasksRoot "FEATURE-123/worktrees/api"
        & git -C $fixture.Path worktree add $destination $fixture.Branch | Out-Null
        (& git -C $destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty
        (& git -C $fixture.Path rev-parse "refs/remotes/origin/$($fixture.Branch)").Trim() | Should -Be $fixture.Head

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $reuse.Action | Should -Be 'reuse'
        $reuse.UpstreamRef | Should -BeNullOrEmpty -Because 'a readable origin/<task> ref is not evidence the branch tracks it'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Not -Throw
        (& git -C $reuse.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty
    }

    It 'reads a worktree-local upstream under extensions.worktreeConfig from the destination' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-worktree-config') -RemotePath (Join-Path $TestDrive 'reuse-worktree-config.git')
        $tasksRoot = Join-Path $TestDrive 'reuse-worktree-config-tasks'
        $destination = Join-Path $tasksRoot 'FEATURE-123/worktrees/api'
        & git -C $fixture.Path branch --no-track $fixture.Branch $fixture.Head | Out-Null
        & git -C $fixture.Path worktree add $destination $fixture.Branch | Out-Null
        & git -C $fixture.Path config extensions.worktreeConfig true

        # The upstream exists only in the destination worktree config. The shared
        # repository view has none, so reading the wrong place binds no upstream
        # and then fails to match what apply reads from the destination.
        & git -C $destination config --worktree "branch.$($fixture.Branch).remote" origin
        & git -C $destination config --worktree "branch.$($fixture.Branch).merge" refs/heads/main
        (& git -C $fixture.Path for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty -Because 'the worktree config is not the shared repository config'
        (& git -C $destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'reuse'
        $plan.UpstreamRef | Should -Be 'refs/remotes/origin/main' -Because 'the plan reads the upstream from the destination, not the repository'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw

        # A fresh plan still finds the same destination-local upstream, and reuse
        # verifies it without writing anything.
        $fresh = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $fresh.Action | Should -Be 'reuse'
        $fresh.UpstreamRef | Should -Be 'refs/remotes/origin/main'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $fresh } | Should -Not -Throw
        (& git -C $destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'
        (& git -C $fixture.Path for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -BeNullOrEmpty -Because 'reuse never writes the shared upstream'
    }

    It 'refuses a reuse when the planned upstream ref became symbolic after planning' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-post-plan-symref') -RemotePath (Join-Path $TestDrive 'reuse-post-plan-symref.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $tasksRoot = Join-Path $TestDrive 'reuse-post-plan-symref-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        $reuse.UpstreamRef | Should -Be "refs/remotes/origin/$($fixture.Branch)"

        # The configured upstream ref becomes symbolic to another ref at the same
        # commit. Re-resolving the planned side would make both sides agree; the
        # stored planned name must stay authoritative.
        & git -C $fixture.Path update-ref -d "refs/remotes/origin/$($fixture.Branch)"
        & git -C $fixture.Path symbolic-ref "refs/remotes/origin/$($fixture.Branch)" refs/remotes/origin/main
        (& git -C $fixture.Path rev-parse refs/remotes/origin/main).Trim() | Should -Be $fixture.Head

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } |
            Should -Throw "*instead of the planned 'refs/remotes/origin/$($fixture.Branch)'*"
    }

    It 'leaves a nonempty upstream alone on reuse and refuses a plan-time change' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-upstream-wrong') -RemotePath (Join-Path $TestDrive 'reuse-upstream-wrong.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $tasksRoot = Join-Path $TestDrive 'reuse-upstream-wrong-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        & git -C $fixture.Path push origin 'main:refs/heads/other-branch' | Out-Null
        & git -C $fixture.Path fetch origin | Out-Null
        & git -C $plan.Destination branch --set-upstream-to=refs/remotes/origin/other-branch $fixture.Branch | Out-Null
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/other-branch'

        # A nonempty upstream is the branch's decision: the plan binds it and
        # apply leaves it alone instead of retargeting it to the task remote ref.
        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        $reuse.UpstreamRef | Should -Be 'refs/remotes/origin/other-branch'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Not -Throw
        (& git -C $reuse.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/other-branch'

        # When the live upstream changes after review, the plan-bound value wins
        # and apply refuses rather than retargeting the nonempty upstream.
        $reviewed = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        & git -C $reviewed.Destination branch --set-upstream-to=refs/remotes/origin/main $fixture.Branch | Out-Null
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reviewed } |
            Should -Throw "*instead of the planned 'refs/remotes/origin/other-branch'*"
        (& git -C $reviewed.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'
    }

    It 'blocks reuse when the branch tip cannot be read locally' {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-unreadable')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'reuse-unreadable-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        $refPath = Join-Path $fixture.Path ".git/refs/heads/$($repository.Branch)"
        Set-Content -LiteralPath $refPath -Value ('1' * 40) -NoNewline

        $blocked = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $blocked.Action | Should -Be 'blocked'
        $blocked.Reason | Should -Be 'reuse-unreadable'
        $blocked.SourceCommit | Should -BeNullOrEmpty -Because 'an unreadable tip must never be returned as a verified reuse commit'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $blocked } | Should -Throw '*cannot apply blocked plan*'
    }

    It 'rejects a new worktree whose HEAD was detached at the reviewed commit' -Skip:(-not $IsLinux) {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-detached')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'reuse-detached-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.SourceCommit | Should -Be $fixture.Head

        $hookPath = Join-Path $fixture.Path '.git/hooks/post-checkout'
        @(
            '#!/bin/sh'
            'if [ "$3" = "1" ]; then git -c core.hooksPath=/dev/null checkout -q --detach; fi'
        ) | Set-Content -LiteralPath $hookPath
        & chmod +x $hookPath

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*detached HEAD*'

        Test-Path -LiteralPath $plan.Destination -PathType Container | Should -BeTrue
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
        (& git -C $fixture.Path rev-parse "refs/heads/$($repository.Branch)").Trim() | Should -Be $fixture.Head

        # A detached destination is not a reuse candidate: the requested branch
        # is not checked out.
        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Action | Should -Be 'blocked'
        $retry.Reason | Should -Be 'destination-exists'
    }

    It 'rejects an indirect alias that only resolves to the requested branch' -Skip:(-not $IsLinux) {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-indirect-alias')
        & git -C $fixture.Path branch feature/REAL | Out-Null
        & git -C $fixture.Path symbolic-ref refs/heads/feature/ALIAS refs/heads/feature/REAL
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/REAL' }
        $tasksRoot = Join-Path $TestDrive 'reuse-indirect-alias-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'

        # The checkout ends on an alias whose target is the requested branch. A
        # recursive read would accept it; the immediate HEAD target must not.
        $hookPath = Join-Path $fixture.Path '.git/hooks/post-checkout'
        @(
            '#!/bin/sh'
            'if [ "$3" = "1" ]; then git symbolic-ref HEAD refs/heads/feature/ALIAS; fi'
        ) | Set-Content -LiteralPath $hookPath
        & chmod +x $hookPath

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } |
            Should -Throw "*/feature/ALIAS' instead of the planned*/feature/REAL*"
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
    }

    It 'accepts a reuse whose requested branch is itself a symbolic alias' {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-alias-accept')
        & git -C $fixture.Path branch feature/REAL | Out-Null
        & git -C $fixture.Path symbolic-ref refs/heads/feature/ALIAS refs/heads/feature/REAL
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/ALIAS' }
        $tasksRoot = Join-Path $TestDrive 'reuse-alias-accept-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Not -Throw
        (& git -C $reuse.Destination symbolic-ref -q --no-recurse HEAD) | Should -Be 'refs/heads/feature/ALIAS'
    }

    It 'refuses reuse when HEAD only indirectly resolves to the requested branch' {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-indirect-alias-stale')
        & git -C $fixture.Path branch feature/REAL | Out-Null
        & git -C $fixture.Path symbolic-ref refs/heads/feature/ALIAS refs/heads/feature/REAL
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/REAL' }
        $tasksRoot = Join-Path $TestDrive 'reuse-indirect-alias-stale-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'

        & git -C $reuse.Destination symbolic-ref HEAD refs/heads/feature/ALIAS
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Throw '*reused worktree changed since planning*'

        $replanned = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $replanned.Action | Should -Be 'blocked'
        $replanned.Reason | Should -Be 'destination-exists'
    }

    It 'accepts a symbolic remote task ref as the upstream target' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-symbolic-upstream') -RemotePath (Join-Path $TestDrive 'reuse-symbolic-upstream.git')
        & git -C $fixture.Path symbolic-ref "refs/remotes/origin/$($fixture.Branch)" refs/remotes/origin/main
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $tasksRoot = Join-Path $TestDrive 'reuse-symbolic-upstream-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $plan.Action | Should -Be 'create-remote'
        $plan.SourceCommit | Should -Be $fixture.Head

        # Git stores and reads the symbolic ref back as its target, so the
        # literal spelling never matches; the resolved target does.
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be 'refs/remotes/origin/main'

        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        $reuse.UpstreamRef | Should -Be 'refs/remotes/origin/main' -Because 'the plan binds the canonical target, not the alias spelling'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Not -Throw
    }

    It 'leaves no state when git fails before creating a worktree' -Skip:(-not $IsLinux) {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-git-failure')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'reuse-git-failure-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'new'

        $shimDir = Join-Path $TestDrive 'reuse-git-failure-shim'
        New-FailureShim -Directory $shimDir -Body "echo 'shim: forced failure' >&2" | Out-Null
        $savedPath = $env:PATH
        $env:PATH = "${shimDir}:${savedPath}"
        try {
            { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*git worktree add failed*'
        }
        finally { $env:PATH = $savedPath }

        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        & git -C $fixture.Path show-ref --verify --quiet "refs/heads/$($repository.Branch)"
        $LASTEXITCODE | Should -Be 1

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        Test-Path -LiteralPath $plan.Destination -PathType Container | Should -BeTrue
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
    }

    It 'refuses a reviewed plan whose task branch moved and binds a fresh plan to the new tip' {
        $fixture = New-ReuseRepository -Path (Join-Path $TestDrive 'reuse-existing-moved')
        & git -C $fixture.Path branch feature/FEATURE-123 | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'reuse-existing-moved-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.BranchMode | Should -Be 'existing'
        $plan.SourceCommit | Should -Be $fixture.Head

        Set-Content -LiteralPath (Join-Path $fixture.Path 'README.md') -Value 'moved'
        & git -C $fixture.Path commit -am moved | Out-Null
        $moved = (& git -C $fixture.Path rev-parse HEAD).Trim()
        & git -C $fixture.Path branch -f feature/FEATURE-123 $moved | Out-Null

        # The attach moved the destination to B and failed verification. The
        # reviewed plan bound A, so it keeps refusing B instead of accepting the
        # failed attach as proof of success.
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*is not the planned commit*replan and approve again*'
        (& git -C $fixture.Path rev-parse 'refs/heads/feature/FEATURE-123').Trim() | Should -Be $moved -Because 'the user branch must not be reset or deleted'
        Test-Path -LiteralPath $plan.Destination | Should -BeTrue

        # A fresh plan is a new decision: it binds the new tip explicitly.
        $replanned = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $replanned.Action | Should -Be 'reuse'
        $replanned.SourceCommit | Should -Be $moved
        $replanned.HeadRef | Should -Be 'refs/heads/feature/FEATURE-123'
    }

    It 'keeps the worktree when the tracking upstream disappears and retries as reuse' {
        $fixture = New-TrackingRepository -Path (Join-Path $TestDrive 'reuse-upstream-pruned') -RemotePath (Join-Path $TestDrive 'reuse-upstream-pruned.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $tasksRoot = Join-Path $TestDrive 'reuse-upstream-pruned-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'

        # The remote ref is pruned between planning and the upstream step.
        & git -C $fixture.Path update-ref -d "refs/remotes/origin/$($fixture.Branch)"

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*does not exist*'
        Test-Path -LiteralPath $plan.Destination -PathType Container | Should -BeTrue
        (& git -C $plan.Destination symbolic-ref -q --no-recurse HEAD) | Should -Be "refs/heads/$($fixture.Branch)"
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head

        # No upstream is expected any more, so the complete worktree is reusable.
        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        { Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse } | Should -Not -Throw
        Test-Path -LiteralPath $reuse.Destination -PathType Container | Should -BeTrue
    }
}

Describe 'branch.autoSetupMerge upstream preservation' {
    BeforeAll {
        function New-AutoSetupFixture {
            param([string]$Root, [string]$RemoteName = 'origin')

            $repositoryPath = Join-Path $Root 'repo'
            $remotePath = Join-Path $Root 'remote.git'
            $seedPath = Join-Path $Root 'seed'
            & git init --bare $remotePath | Out-Null
            New-Item -ItemType Directory -Path $seedPath | Out-Null
            & git -C $seedPath init -b main | Out-Null
            & git -C $seedPath config user.name Test
            & git -C $seedPath config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $seedPath 'README.md') -Value 'first'
            & git -C $seedPath add README.md
            & git -C $seedPath commit -m first | Out-Null
            & git -C $seedPath remote add $RemoteName $remotePath
            & git -C $seedPath push $RemoteName 'main:refs/heads/main' | Out-Null
            & git -C $remotePath symbolic-ref HEAD refs/heads/main
            & git clone -q -o $RemoteName $remotePath $repositoryPath | Out-Null
            & git -C $repositoryPath config user.name Test
            & git -C $repositoryPath config user.email test@example.invalid
            $reviewed = (& git -C $seedPath rev-parse HEAD).Trim()
            & git -C $repositoryPath checkout --detach | Out-Null
            & git -C $repositoryPath branch -D main | Out-Null
            & git -C $repositoryPath fetch $RemoteName | Out-Null

            [pscustomobject]@{
                Path = $repositoryPath
                Seed = $seedPath
                Remote = $remotePath
                RemoteName = $RemoteName
                Reviewed = $reviewed
            }
        }

        function Move-AutoSetupRemoteBase {
            param([pscustomobject]$Fixture)

            Set-Content -LiteralPath (Join-Path $Fixture.Seed 'README.md') -Value 'moved'
            & git -C $Fixture.Seed commit -am moved | Out-Null
            & git -C $Fixture.Seed push $Fixture.RemoteName 'main:refs/heads/main' | Out-Null
            & git -C $Fixture.Path fetch $Fixture.RemoteName | Out-Null
            return (& git -C $Fixture.Path rev-parse "refs/remotes/$($Fixture.RemoteName)/main").Trim()
        }

        function New-AutoSetupCaseRoot {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            return $root
        }

        function Set-BareAutoSetupMerge {
            param([string]$RepositoryPath)

            # A bare key has no '=' line; git config --type=bool reads it as true.
            Add-Content -LiteralPath (Join-Path $RepositoryPath '.git/config') -Value "[branch]`n`tautoSetupMerge"
        }
    }

    It 'matches native git upstream selection for <Mode>' -ForEach @(
        @{ Mode = 'default'; Value = $null; Branch = 'feature/FEATURE-123' }
        @{ Mode = 'true'; Value = 'true'; Branch = 'feature/FEATURE-123' }
        @{ Mode = 'false'; Value = 'false'; Branch = 'feature/FEATURE-123' }
        @{ Mode = 'always'; Value = 'always'; Branch = 'feature/FEATURE-123' }
        @{ Mode = 'inherit'; Value = 'inherit'; Branch = 'feature/FEATURE-123' }
        @{ Mode = 'simple'; Value = 'simple'; Branch = 'feature/FEATURE-123' }
    ) {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        if ($null -ne $Value) { & git -C $fixture.Path config branch.autoSetupMerge $Value }

        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b $Branch $nativeDestination refs/remotes/origin/main | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' "refs/heads/$Branch") | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D $Branch | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $plannedUpstream = if ($plan.PSObject.Properties['UpstreamRef'] -and $plan.UpstreamRef) { [string]$plan.UpstreamRef } else { '' }
        $plannedUpstream | Should -Be $nativeUpstream -Because 'the planned upstream must match native branch.autoSetupMerge'
    }

    It 'matches native simple tracking when the branch name matches the remote branch' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot -RemoteName 'upstream'
        & git -C $fixture.Path config branch.autoSetupMerge simple

        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b main $nativeDestination refs/remotes/upstream/main | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' 'refs/heads/main') | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D main | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'upstream/main'; Branch = 'main' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $nativeUpstream | Should -Be 'refs/remotes/upstream/main'
        $plan.UpstreamRef | Should -Be $nativeUpstream
    }

    It 'starts at the reviewed commit and tracks the moved remote base by default' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.SourceCommit | Should -Be $fixture.Reviewed
        $plan.UpstreamRef | Should -Be 'refs/remotes/origin/main'

        $moved = Move-AutoSetupRemoteBase -Fixture $fixture
        $moved | Should -Not -Be $fixture.Reviewed
        (& git -C $fixture.Path rev-parse 'refs/remotes/origin/main').Trim() | Should -Be $moved -Because 'the race fixture must really move the remote base'

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -Be 'refs/remotes/origin/main'
        (& git -C $plan.Destination rev-parse 'feature/FEATURE-123@{upstream}').Trim() | Should -Be $moved
    }

    It 'creates no upstream when branch.autoSetupMerge is false and still pins the start' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        & git -C $fixture.Path config branch.autoSetupMerge false
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.PSObject.Properties.Name | Should -Contain 'UpstreamRef'
        $plan.UpstreamRef | Should -BeNullOrEmpty

        $moved = Move-AutoSetupRemoteBase -Fixture $fixture
        $moved | Should -Not -Be $fixture.Reviewed

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -BeNullOrEmpty
    }

    It 'creates no upstream when branch.autoSetupMerge is an empty value' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        # Git treats an explicitly empty value as boolean false, not as unset.
        & git -C $fixture.Path config branch.autoSetupMerge ''
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.UpstreamRef | Should -BeNullOrEmpty

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -BeNullOrEmpty
    }

    It 'matches native git for a <Spelling> branch.autoSetupMerge spelling' -ForEach @(
        @{ Spelling = 'bare'; NativeTracks = $true }
        @{ Spelling = 'empty'; NativeTracks = $false }
    ) {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        if ($Spelling -ceq 'bare') {
            Set-BareAutoSetupMerge -RepositoryPath $fixture.Path
            (& git -C $fixture.Path config --type=bool --get branch.autoSetupMerge).Trim() | Should -Be 'true'
        }
        else {
            & git -C $fixture.Path config branch.autoSetupMerge ''
            (& git -C $fixture.Path config --type=bool --get branch.autoSetupMerge).Trim() | Should -Be 'false'
        }

        # Native Git is the oracle for the same remote-base request.
        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b feature/FEATURE-123 $nativeDestination refs/remotes/origin/main | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123') | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D feature/FEATURE-123 | Out-Null
        if ($NativeTracks) { $nativeUpstream | Should -Be 'refs/remotes/origin/main' } else { $nativeUpstream | Should -BeNullOrEmpty }

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')
        $plannedUpstream = if ($plan.PSObject.Properties['UpstreamRef'] -and $plan.UpstreamRef) { [string]$plan.UpstreamRef } else { '' }
        $plannedUpstream | Should -Be $nativeUpstream

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -Be $nativeUpstream
    }

    It 'tracks a remote task ref despite branch.autoSetupMerge being <Mode>' -ForEach @(
        @{ Mode = 'false'; Value = 'false' }
        @{ Mode = 'empty'; Value = '' }
    ) {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        & git -C $fixture.Path config branch.autoSetupMerge $Value
        & git -C $fixture.Path push origin 'refs/remotes/origin/main:refs/heads/feature/FEATURE-123' | Out-Null
        & git -C $fixture.Path fetch origin | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        # Explicit tracking is unconditional: an existing remote task ref is
        # tracked even when implicit base tracking is off.
        $plan.Action | Should -Be 'create-remote'
        $plan.UpstreamRef | Should -Be 'refs/remotes/origin/feature/FEATURE-123'

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() |
            Should -Be 'refs/remotes/origin/feature/FEATURE-123'
    }

    It 'tracks a local base when branch.autoSetupMerge is always' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        & git -C $fixture.Path branch main $fixture.Reviewed
        & git -C $fixture.Path config branch.autoSetupMerge always

        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b feature/FEATURE-123 $nativeDestination refs/heads/main | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123') | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D feature/FEATURE-123 | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'main'
        $nativeUpstream | Should -Be 'refs/heads/main'
        $plan.UpstreamRef | Should -Be $nativeUpstream

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -Be $nativeUpstream
    }

    It 'inherits a local base upstream that is already gone, as native Git does' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        & git -C $fixture.Path branch base $fixture.Reviewed
        & git -C $fixture.Path update-ref refs/remotes/origin/pruned $fixture.Reviewed
        & git -C $fixture.Path branch --set-upstream-to=origin/pruned base | Out-Null
        & git -C $fixture.Path update-ref -d refs/remotes/origin/pruned
        & git -C $fixture.Path config branch.autoSetupMerge inherit

        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b feature/FEATURE-123 $nativeDestination refs/heads/base | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123') | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D feature/FEATURE-123 | Out-Null
        $nativeUpstream | Should -Be 'refs/remotes/origin/pruned'

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'base'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')
        $plan.Action | Should -Be 'create-local'
        $plan.UpstreamRef | Should -Be $nativeUpstream

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Not -Throw
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -Be $nativeUpstream
    }

    It 'copies a local base upstream when branch.autoSetupMerge is inherit' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        & git -C $fixture.Path branch base $fixture.Reviewed
        & git -C $fixture.Path branch --set-upstream-to=origin/main base | Out-Null
        & git -C $fixture.Path config branch.autoSetupMerge inherit

        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b feature/FEATURE-123 $nativeDestination refs/heads/base | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123') | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D feature/FEATURE-123 | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'base'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $nativeUpstream | Should -Be 'refs/remotes/origin/main'
        $plan.UpstreamRef | Should -Be $nativeUpstream

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -Be $nativeUpstream
    }

    It 'tracks the target of a symbolic remote base like native git' {
        $caseRoot = New-AutoSetupCaseRoot
        $fixture = New-AutoSetupFixture -Root $caseRoot
        (& git -C $fixture.Path symbolic-ref refs/remotes/origin/HEAD).Trim() | Should -Be 'refs/remotes/origin/main'

        $nativeDestination = Join-Path $caseRoot 'native'
        & git -C $fixture.Path worktree add -q -b feature/FEATURE-123 $nativeDestination refs/remotes/origin/HEAD | Out-Null
        $nativeUpstream = ([string](@(& git -C $nativeDestination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123') | Select-Object -First 1)).Trim()
        & git -C $fixture.Path worktree remove $nativeDestination | Out-Null
        & git -C $fixture.Path branch -D feature/FEATURE-123 | Out-Null

        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'origin/HEAD'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $caseRoot 'tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'origin/HEAD'
        $plan.SourceCommit | Should -Be $fixture.Reviewed
        $nativeUpstream | Should -Be 'refs/remotes/origin/main'
        $plan.UpstreamRef | Should -Be $nativeUpstream

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' 'refs/heads/feature/FEATURE-123').Trim() | Should -Be $nativeUpstream
    }
}

Describe 'Exact task ref resolution' {
    BeforeAll {
        function New-ExactRefRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'first'
            & git -C $Path add README.md
            & git -C $Path commit -m first | Out-Null
            return (& git -C $Path rev-parse HEAD).Trim()
        }

        function Set-UnreadableLooseRef {
            param([string]$RepositoryPath, [string]$Reference)

            $refPath = Join-Path $RepositoryPath ".git/$Reference"
            New-Item -ItemType Directory -Path (Split-Path -Parent $refPath) -Force | Out-Null
            Set-Content -LiteralPath $refPath -Value ('1' * 40) -NoNewline
        }
    }

    It 'blocks a present local task ref whose tip cannot be verified against the pin' {
        $repositoryPath = Join-Path $TestDrive 'exact-ref-unverified'
        $head = New-ExactRefRepository -Path $repositoryPath
        Set-UnreadableLooseRef -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $head }
        $tasksRoot = Join-Path $TestDrive 'exact-ref-unverified-tasks'

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-mismatch' -Because 'a present ref with an unreadable tip must not fall through to create-local/new'
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
    }

    It 'blocks a no-pin local task ref whose tip is missing locally' {
        $repositoryPath = Join-Path $TestDrive 'exact-ref-no-pin-unverified'
        [void](New-ExactRefRepository -Path $repositoryPath)
        Set-UnreadableLooseRef -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'exact-ref-no-pin-tasks')

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing'
    }

    It 'blocks a dangling symbolic task ref instead of creating a branch' {
        $repositoryPath = Join-Path $TestDrive 'exact-ref-dangling'
        $head = New-ExactRefRepository -Path $repositoryPath
        # A symbolic ref whose target does not exist is present but unreadable:
        # for-each-ref omits it, so absence must not be inferred from the listing.
        & git -C $repositoryPath symbolic-ref refs/heads/feature/FEATURE-123 refs/heads/missing
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'exact-ref-dangling-tasks')

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing' -Because 'a present symbolic ref with a missing target must never fall through to main'
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse

        $pinned = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $head }
        $pinnedPlan = New-TaskWorktreePlan -Repository $pinned -TaskKey 'FEATURE-124' -TasksRoot (Join-Path $TestDrive 'exact-ref-dangling-pinned-tasks')

        $pinnedPlan.Action | Should -Be 'blocked'
        $pinnedPlan.Reason | Should -Be 'start-commit-mismatch'
        Test-Path -LiteralPath $pinnedPlan.Destination | Should -BeFalse
    }

    It 'blocks a start commit that only a replacement ref can resolve' {
        $repositoryPath = Join-Path $TestDrive 'exact-ref-replacement'
        $head = New-ExactRefRepository -Path $repositoryPath
        & git -C $repositoryPath replace -l *> $null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'git replace is unavailable'; return }

        # The original object is absent; a replace ref maps it to a real commit,
        # so a plain rev-parse would validate a commit that is not here.
        $missing = '36478499d1d27f636b8ea3604772d3aa7cd5e8d3'
        & git -C $repositoryPath update-ref "refs/replace/$missing" $head
        (& git -C $repositoryPath rev-parse --verify --quiet "$missing^{commit}") | Should -Be $missing

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $missing }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'exact-ref-replacement-tasks')

        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing'
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
    }

    It 'does not let a lookalike tag stand in for the remote task ref' {
        $repositoryPath = Join-Path $TestDrive 'exact-ref-tag-lookalike'
        $head = New-ExactRefRepository -Path $repositoryPath
        & git -C $repositoryPath tag 'refs/remotes/origin/feature/FEATURE-123' $head
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'exact-ref-tag-tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'main'
        $plan.BranchMode | Should -Be 'new'

        $pinned = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123'; StartCommit = $head }
        $pinnedPlan = New-TaskWorktreePlan -Repository $pinned -TaskKey 'FEATURE-124' -TasksRoot (Join-Path $TestDrive 'exact-ref-tag-pinned-tasks')

        $pinnedPlan.Action | Should -Be 'create-local'
        $pinnedPlan.BranchMode | Should -Be 'new'
        $pinnedPlan.Source | Should -Be $head
        $pinnedPlan.SourceCommit | Should -Be $head
    }
}

Describe 'Native repository path resolution' {
    It 'resolves link/../repo with native chdir semantics on Linux' -Skip:(-not $IsLinux) {
        # link -> other/dir, so native `git -C link/../repo` enters other/repo.
        # A lexical GetFullPath would collapse the dot segment first and select
        # the decoy repository at link/../repo's lexical position.
        $base = Join-Path $TestDrive 'native-path'
        foreach ($name in @('other/dir', 'other/repo', 'repo')) {
            New-Item -ItemType Directory -Path (Join-Path $base $name) -Force | Out-Null
        }
        foreach ($name in @('other/repo', 'repo')) {
            $path = Join-Path $base $name
            & git -C $path init -b main | Out-Null
            & git -C $path config user.name Test
            & git -C $path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $path 'README.md') -Value 'first'
            & git -C $path add README.md
            & git -C $path commit -m first | Out-Null
        }
        $nativeHead = (& git -C (Join-Path $base 'other/repo') rev-parse HEAD).Trim()
        Set-Content -LiteralPath (Join-Path $base 'repo/README.md') -Value 'second'
        & git -C (Join-Path $base 'repo') commit -am second | Out-Null
        $decoyHead = (& git -C (Join-Path $base 'repo') rev-parse HEAD).Trim()
        New-Item -ItemType SymbolicLink -Path (Join-Path $base 'link') -Target (Join-Path $base 'other/dir') | Out-Null

        Push-Location $base
        try {
            $nativeTop = (& git -C 'link/../repo' rev-parse --show-toplevel).Trim()
            $repository = [pscustomobject]@{ Name = 'api'; Path = 'link/../repo'; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
            $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'native-path-tasks')
        }
        finally { Pop-Location }

        $nativeTop | Should -Be ([IO.Path]::TrimEndingDirectorySeparator((Join-Path $base 'other/repo')))
        $plan.Action | Should -Be 'create-local'
        $plan.SourceCommit | Should -Be $nativeHead
        $plan.SourceCommit | Should -Not -Be $decoyHead -Because 'a lexically normalized path would select the decoy repository'
    }
}

Describe 'No-lazy-fetch capability' {
    BeforeAll {
        function New-CapabilitySourceRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            & git -C $Path config uploadpack.allowFilter true
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'first'
            & git -C $Path add README.md
            & git -C $Path commit -m first | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'second'
            & git -C $Path commit -am second | Out-Null
        }

        function New-PartialCloneFixture {
            param([string]$SourcePath, [string]$ClonePath)

            New-CapabilitySourceRepository -Path $SourcePath
            & git clone --filter=blob:none --no-local "file://$SourcePath" $ClonePath 2>&1 | Out-Null
            return [pscustomobject]@{
                Path = $ClonePath
                Head = (& git -C $ClonePath rev-parse HEAD).Trim()
            }
        }

        function New-OldGitShim {
            param([string]$Directory)

            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
            $shimPath = Join-Path $Directory 'git'
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
            return $shimPath
        }
    }

    It 'fails closed on a partial clone when Git ignores --no-lazy-fetch' -Skip:(-not $IsLinux) {
        $fixture = New-PartialCloneFixture -SourcePath (Join-Path $TestDrive 'capability-source-old') -ClonePath (Join-Path $TestDrive 'capability-partial-old')
        (& git -C $fixture.Path config --get remote.origin.promisor) | Should -Be 'true'
        $shimDir = Join-Path $TestDrive 'capability-shim-old'
        New-OldGitShim -Directory $shimDir | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            { New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'capability-old-tasks') } |
                Should -Throw '*partial clone*--no-lazy-fetch*'
        }
        finally { $env:PATH = $savedPath }
    }

    It 'still plans a full clone when Git ignores --no-lazy-fetch' -Skip:(-not $IsLinux) {
        $repositoryPath = Join-Path $TestDrive 'capability-full-old'
        New-CapabilitySourceRepository -Path $repositoryPath
        $shimDir = Join-Path $TestDrive 'capability-shim-full'
        New-OldGitShim -Directory $shimDir | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $savedPath = $env:PATH
        $env:PATH = "$($shimDir):$savedPath"
        try {
            $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'capability-full-tasks')
        }
        finally { $env:PATH = $savedPath }

        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'new'
    }

    It 'plans a real partial clone with a Git that supports --no-lazy-fetch' {
        # Capability of the local Git, not the OS: a supported Git can plan a
        # partial clone on any platform that can create one.
        & git --no-lazy-fetch --version *> $null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'this Git does not support --no-lazy-fetch'; return }

        $fixture = New-PartialCloneFixture -SourcePath (Join-Path $TestDrive 'capability-source-modern') -ClonePath (Join-Path $TestDrive 'capability-partial-modern')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'capability-modern-tasks')

        $plan.Action | Should -Be 'create-local'
        $plan.Source | Should -Be 'main'
        $plan.SourceCommit | Should -Be $fixture.Head
    }
}

Describe 'Ref presence failure modes' {
    BeforeAll {
        function New-RefPresenceRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'fixture'
            & git -C $Path add README.md
            & git -C $Path commit -m fixture | Out-Null
            return $Path
        }
    }

    It 'reports a malformed loose ref as present but unreadable' {
        $repositoryPath = New-RefPresenceRepository -Path (Join-Path $TestDrive 'ref-malformed')
        $refPath = Join-Path $repositoryPath '.git/refs/heads/feature/FEATURE-123'
        New-Item -ItemType Directory -Path (Split-Path -Parent $refPath) -Force | Out-Null
        Set-Content -LiteralPath $refPath -Value 'this-is-not-an-object-id' -NoNewline

        $snapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $snapshot.Exists | Should -BeTrue
        $snapshot.Commit | Should -BeNullOrEmpty

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'ref-malformed-tasks')
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing'
    }

    It 'reports a cyclic symref as present but unreadable' {
        $repositoryPath = New-RefPresenceRepository -Path (Join-Path $TestDrive 'ref-cyclic')
        $refPath = Join-Path $repositoryPath '.git/refs/heads/feature/FEATURE-123'
        New-Item -ItemType Directory -Path (Split-Path -Parent $refPath) -Force | Out-Null
        try { New-Item -ItemType SymbolicLink -Path $refPath -Target 'FEATURE-123' | Out-Null }
        catch { Set-ItResult -Skipped -Because 'this platform cannot create a cyclic symbolic ref'; return }

        $snapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $snapshot.Exists | Should -BeTrue
        $snapshot.Commit | Should -BeNullOrEmpty

        $repository = [pscustomobject]@{ Name = 'api'; Path = $repositoryPath; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'ref-cyclic-tasks')
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'start-commit-missing'
    }

    It 'treats a truly absent ref as absent' {
        $repositoryPath = New-RefPresenceRepository -Path (Join-Path $TestDrive 'ref-absent')

        $snapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference 'refs/heads/feature/FEATURE-123'
        $snapshot.Exists | Should -BeFalse
        $snapshot.Commit | Should -BeNullOrEmpty
    }
}

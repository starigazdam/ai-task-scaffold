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

            Set-Content -LiteralPath (Join-Path $Fixture.Path 'README.md') -Value 'third'
            & git -C $Fixture.Path commit -am third | Out-Null
            & git -C $Fixture.Path push origin "main:refs/heads/$($Fixture.Branch)" | Out-Null
            & git -C $Fixture.Path fetch origin | Out-Null
            return (& git -C $Fixture.Path rev-parse HEAD).Trim()
        }
    }

    It 'creates a tracking branch at the reviewed commit when the remote ref moves after planning' {
        $fixture = New-TrackingFixture -Path (Join-Path $TestDrive 'api-track-moved') -RemotePath (Join-Path $TestDrive 'api-track-moved.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch; StartCommit = $fixture.Reviewed }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-track-moved')

        $plan.Action | Should -Be 'create-remote'
        $plan.SourceCommit | Should -Be $fixture.Reviewed

        $moved = Move-TrackingBranch -Fixture $fixture
        $moved | Should -Not -Be $fixture.Reviewed

        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan

        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Reviewed
        (& git -C $plan.Destination for-each-ref --format='%(upstream)' "refs/heads/$($fixture.Branch)").Trim() | Should -Be "refs/remotes/origin/$($fixture.Branch)"
        (& git -C $plan.Destination rev-parse "$($fixture.Branch)@{upstream}").Trim() | Should -Be $moved -Because 'the upstream stays on origin even though the branch starts at the reviewed commit'
    }

    It 'binds the remote commit without startCommit and still starts at it after the ref moves' {
        $fixture = New-TrackingFixture -Path (Join-Path $TestDrive 'api-track-moved-none') -RemotePath (Join-Path $TestDrive 'api-track-moved-none.git')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = $fixture.Branch }
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot (Join-Path $TestDrive 'workspace-track-moved-none')

        $plan.Action | Should -Be 'create-remote'
        $plan.Source | Should -Be "origin/$($fixture.Branch)"
        $plan.SourceCommit | Should -Be $fixture.Reviewed

        $moved = Move-TrackingBranch -Fixture $fixture
        $moved | Should -Not -Be $fixture.Reviewed

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

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*is not the reviewed commit*'
    }
}

Describe 'Worktree creation markers' {
    BeforeAll {
        function New-MarkerRepository {
            param([string]$Path)

            New-Item -ItemType Directory -Path $Path | Out-Null
            & git -C $Path init -b main | Out-Null
            & git -C $Path config user.name Test
            & git -C $Path config user.email test@example.invalid
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'first'
            & git -C $Path add README.md
            & git -C $Path commit -m first | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'second'
            & git -C $Path commit -am second | Out-Null
            return [pscustomobject]@{
                Path = $Path
                Head = (& git -C $Path rev-parse HEAD).Trim()
                Previous = (& git -C $Path rev-parse HEAD~1).Trim()
            }
        }

        function Get-MarkerPath {
            param([string]$TasksRoot, [string]$RepositoryName = 'api')

            return Join-Path $TasksRoot "FEATURE-123/worktrees/.ai-task-scaffold-incomplete.$RepositoryName"
        }
    }

    It 'blocks a retry when the upstream is lost after the worktree was created' {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-pruned')
        $remotePath = Join-Path $TestDrive 'marker-pruned.git'
        & git init --bare $remotePath | Out-Null
        & git -C $fixture.Path remote add origin $remotePath
        & git -C $fixture.Path push origin 'main:refs/heads/feature/FEATURE-123' | Out-Null
        & git -C $fixture.Path fetch origin | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-pruned-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-remote'

        # The remote ref is pruned between planning and the upstream step.
        & git -C $fixture.Path update-ref -d refs/remotes/origin/feature/FEATURE-123

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*set-upstream-to failed*'
        Test-Path -LiteralPath $plan.Destination -PathType Container | Should -BeTrue
        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $markerPath | Should -BeTrue

        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Action | Should -Be 'blocked'
        $retry.Reason | Should -Be 'incomplete-worktree-creation'
        (& git -C $plan.Destination branch --show-current) | Should -Be 'feature/FEATURE-123'
        Test-Path -LiteralPath $markerPath | Should -BeTrue
    }

    It 'blocks reuse when an existing branch moved and the created worktree HEAD is wrong' {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-head-moved')
        & git -C $fixture.Path branch feature/FEATURE-123 $fixture.Head | Out-Null
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-head-moved-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.BranchMode | Should -Be 'existing'

        Set-Content -LiteralPath (Join-Path $fixture.Path 'README.md') -Value 'third'
        & git -C $fixture.Path commit -am third | Out-Null
        $moved = (& git -C $fixture.Path rev-parse HEAD).Trim()
        & git -C $fixture.Path branch -f feature/FEATURE-123 $moved | Out-Null

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*is not the reviewed commit*'
        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $markerPath | Should -BeTrue

        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Action | Should -Be 'blocked'
        $retry.Reason | Should -Be 'incomplete-worktree-creation'
        (& git -C $fixture.Path rev-parse feature/FEATURE-123).Trim() | Should -Be $moved -Because 'the user branch must not be reset or deleted'
    }

    It 'clears the marker when git fails before creating a worktree' -Skip:(-not $IsLinux) {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-git-failure')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-git-failure-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'

        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shimDir = Join-Path $TestDrive 'marker-git-shim'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $shimPath = Join-Path $shimDir 'git'
        @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            'case " $* " in'
            '  *" worktree add "*) echo "shim: forced failure" >&2; exit 1 ;;'
            'esac'
            'exec "$REAL_GIT" "$@"'
        ) | Set-Content -LiteralPath $shimPath
        & chmod +x $shimPath

        $savedPath = $env:PATH
        $env:PATH = "${shimDir}:${savedPath}"
        try {
            { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*git worktree add failed*'
        }
        finally { $env:PATH = $savedPath }

        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        Test-Path -LiteralPath $markerPath | Should -BeFalse

        # A failure that provably created no worktree must not strand a retry.
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        Test-Path -LiteralPath $plan.Destination -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $markerPath | Should -BeFalse
    }

    It 'blocks a plan on a marker left by an interruption until the marker is removed' {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-interrupted')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-interrupted-tasks'
        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
        '{"markerVersion":1}' | Set-Content -LiteralPath $markerPath -NoNewline

        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'blocked'
        $plan.Reason | Should -Be 'incomplete-worktree-creation'

        Remove-Item -LiteralPath $markerPath -Force
        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Action | Should -Be 'create-local'
    }

    It 'keeps the marker when a failed add leaves only the task branch' -Skip:(-not $IsLinux) {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-branch-only')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-branch-only-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.Action | Should -Be 'create-local'
        $plan.SourceCommit | Should -Be $fixture.Head

        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shimDir = Join-Path $TestDrive 'marker-branch-only-shim'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $shimPath = Join-Path $shimDir 'git'
        @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            "REPO='$($fixture.Path)'"
            'case " $* " in'
            '  *" worktree add "*) "$REAL_GIT" -C "$REPO" branch feature/FEATURE-123 "__REVIEWED__" >/dev/null 2>&1; echo "shim: branch-only failure" >&2; exit 1 ;;'
            'esac'
            'exec "$REAL_GIT" "$@"'
        ) | Set-Content -LiteralPath $shimPath
        # Substitute the reviewed commit so the shim reproduces a branch that
        # exists without a destination or a worktree registration.
        $shimText = (Get-Content -LiteralPath $shimPath -Raw) -replace '__REVIEWED__', $fixture.Head
        Set-Content -LiteralPath $shimPath -Value $shimText -NoNewline
        & chmod +x $shimPath

        $savedPath = $env:PATH
        $env:PATH = "${shimDir}:${savedPath}"
        try {
            { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*git worktree add failed*'
        }
        finally { $env:PATH = $savedPath }

        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        (& git -C $fixture.Path rev-parse refs/heads/feature/FEATURE-123).Trim() | Should -Be $fixture.Head -Because 'the task branch must be preserved'
        Test-Path -LiteralPath $markerPath | Should -BeTrue
        @(& git -C $fixture.Path worktree list --porcelain) -join "`n" | Should -Not -Match ([regex]::Escape($plan.Destination))

        # A branch left without a destination or registration still blocks a retry.
        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Action | Should -Be 'blocked'
        $retry.Reason | Should -Be 'incomplete-worktree-creation'
        Test-Path -LiteralPath $markerPath | Should -BeTrue
        (& git -C $fixture.Path rev-parse refs/heads/feature/FEATURE-123).Trim() | Should -Be $fixture.Head
    }

    It 'keeps the marker when a failed checkout leaves a worktree registration' -Skip:(-not $IsLinux) {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-registration')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-registration-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot

        $hooksDir = Join-Path $fixture.Path '.git/hooks'
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
        $hookPath = Join-Path $hooksDir 'post-checkout'
        # A failing hook can leave a registration (and branch) behind even when
        # its own cleanup removes the destination directory.
        @('#!/bin/sh', 'rm -rf "$PWD"', 'exit 1') | Set-Content -LiteralPath $hookPath
        & chmod +x $hookPath

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*git worktree add failed*'

        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $plan.Destination | Should -BeFalse
        @(& git -C $fixture.Path worktree list --porcelain) -join "`n" | Should -Match ([regex]::Escape($plan.Destination))
        (& git -C $fixture.Path rev-parse refs/heads/feature/FEATURE-123).Trim() | Should -Be $fixture.Head
        Test-Path -LiteralPath $markerPath | Should -BeTrue

        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Reason | Should -Be 'incomplete-worktree-creation'
    }

    It 'refuses and keeps the marker when a hook detaches HEAD at the reviewed commit' -Skip:(-not $IsLinux) {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-detached')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-detached-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $plan.SourceCommit | Should -Be $fixture.Head

        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $hookPath = Join-Path $fixture.Path '.git/hooks/post-checkout'
        @(
            '#!/bin/sh'
            "REAL_GIT='$realGit'"
            'if [ "$3" = "1" ]; then'
            '  "$REAL_GIT" -c core.hooksPath=/dev/null checkout -q --detach'
            'fi'
        ) | Set-Content -LiteralPath $hookPath
        & chmod +x $hookPath

        { Invoke-TaskWorktreePlan -Repository $repository -Plan $plan } | Should -Throw '*detached HEAD*'

        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $plan.Destination -PathType Container | Should -BeTrue
        (& git -C $plan.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
        (& git -C $fixture.Path rev-parse refs/heads/feature/FEATURE-123).Trim() | Should -Be $fixture.Head
        Test-Path -LiteralPath $markerPath | Should -BeTrue

        $retry = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $retry.Reason | Should -Be 'incomplete-worktree-creation'
    }

    It 'reuses a healthy destination and leaves no marker behind' {
        $fixture = New-MarkerRepository -Path (Join-Path $TestDrive 'marker-healthy-reuse')
        $repository = [pscustomobject]@{ Name = 'api'; Path = $fixture.Path; BaseBranch = 'main'; Branch = 'feature/FEATURE-123' }
        $tasksRoot = Join-Path $TestDrive 'marker-healthy-reuse-tasks'
        $plan = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        Invoke-TaskWorktreePlan -Repository $repository -Plan $plan
        $markerPath = Get-MarkerPath -TasksRoot $tasksRoot
        Test-Path -LiteralPath $markerPath | Should -BeFalse

        $reuse = New-TaskWorktreePlan -Repository $repository -TaskKey 'FEATURE-123' -TasksRoot $tasksRoot
        $reuse.Action | Should -Be 'reuse'
        Invoke-TaskWorktreePlan -Repository $repository -Plan $reuse

        Test-Path -LiteralPath $markerPath | Should -BeFalse
        (& git -C $reuse.Destination rev-parse HEAD).Trim() | Should -Be $fixture.Head
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

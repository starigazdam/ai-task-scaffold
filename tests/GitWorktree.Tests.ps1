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
        (@(& git -C $replacementRepositoryPath worktree list --porcelain) -join "`n") | Should -Match ([regex]::Escape($reusePlan.Destination))
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

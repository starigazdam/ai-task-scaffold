Describe 'Invoke-TaskTeardown' {
    BeforeEach {
        $script:fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:tasksRoot = Join-Path $script:fixtureRoot 'tasks'
        $script:taskKey = 'FEATURE-123'
        $script:taskPath = Join-Path $script:tasksRoot $script:taskKey
        $script:repositoryPath = Join-Path $script:fixtureRoot 'api'
        New-Item -ItemType Directory -Path $script:repositoryPath | Out-Null
        & git -C $script:repositoryPath init -b main | Out-Null
        & git -C $script:repositoryPath config user.name Test
        & git -C $script:repositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $script:repositoryPath 'README.md') -Value 'fixture'
        & git -C $script:repositoryPath add README.md
        & git -C $script:repositoryPath commit -m fixture | Out-Null

        New-Item -ItemType Directory -Path (Join-Path $script:taskPath 'artifacts') -Force | Out-Null
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = $script:taskKey; title = 'Fixture'; prdPath = 'PRD.md' }
            repositories = @([ordered]@{ name = 'api'; path = $script:repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
            phases = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:taskPath 'task.json') -NoNewline
        '# PRD' | Set-Content -LiteralPath (Join-Path $script:taskPath 'PRD.md') -NoNewline
        '# Plan' | Set-Content -LiteralPath (Join-Path $script:taskPath 'PLAN.md') -NoNewline
        '# Status' | Set-Content -LiteralPath (Join-Path $script:taskPath 'STATUS.md') -NoNewline
        $script:worktreePath = Join-Path $script:taskPath 'worktrees/api'
        & git -C $script:repositoryPath worktree add -b feature/FEATURE-123 $script:worktreePath main | Out-Null
        $script:scriptPath = Join-Path $PSScriptRoot '../scripts/Invoke-TaskTeardown.ps1'
    }

    It 'emits a removal plan without changing task state' {
        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'remove'
        $plan.WorktreeOperations.Count | Should -Be 1
        $plan.WorktreeOperations[0].Action | Should -Be 'remove'
        Test-Path -LiteralPath $script:taskPath | Should -BeTrue
        Test-Path -LiteralPath $script:worktreePath | Should -BeTrue
    }

    It 'removes only clean registered worktrees and task state after explicit confirmation' {
        & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey -Apply | Out-Null

        Test-Path -LiteralPath $script:taskPath | Should -BeFalse
        (& git -C $script:repositoryPath worktree list --porcelain) | Should -Not -Match ([regex]::Escape($script:worktreePath))
        (& git -C $script:repositoryPath branch --format '%(refname:short)') | Should -Contain 'feature/FEATURE-123'
    }

    It 'blocks teardown when a manifest worktree is missing' {
        Remove-Item -LiteralPath $script:worktreePath -Recurse -Force

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        $plan.TaskReason | Should -Be 'blocked-worktree'
        $plan.WorktreeOperations[0].Reason | Should -Be 'missing-worktree'
        Test-Path -LiteralPath $script:taskPath | Should -BeTrue
    }

    It 'blocks teardown when the manifest worktrees container is missing' {
        Remove-Item -LiteralPath (Join-Path $script:taskPath 'worktrees') -Recurse -Force

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        $plan.TaskReason | Should -Be 'blocked-worktree'
        $plan.WorktreeOperations[0].Reason | Should -Be 'missing-worktrees-container'
        Test-Path -LiteralPath $script:taskPath | Should -BeTrue
    }

    It 'removes each worktree immediately after revalidation' -Skip:(-not $IsLinux) {
        $secondWorktreePath = Join-Path $script:taskPath 'worktrees/api2'
        & git -C $script:repositoryPath worktree add -b feature/FEATURE-124 $secondWorktreePath main | Out-Null
        $manifestPath = Join-Path $script:taskPath 'task.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.repositories += [pscustomobject]@{ name = 'api2'; path = $script:repositoryPath; baseBranch = 'main'; branch = 'feature/FEATURE-124' }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -NoNewline

        $shimPath = Join-Path $script:fixtureRoot 'git'
        @'
#!/bin/sh
if [ "$1" = '-C' ] && [ "$3" = 'status' ] && [ "$4" = '--porcelain' ]; then
    count=$(cat "$GIT_SHIM_COUNT_FILE" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s' "$count" > "$GIT_SHIM_COUNT_FILE"
    if [ "$2" = "$GIT_SHIM_TRIGGER_PATH" ] && [ "$count" -eq 4 ] && [ -d "$GIT_SHIM_DIRTY_PATH" ]; then
        printf 'race\n' >> "$GIT_SHIM_DIRTY_PATH/README.md"
    fi
fi
exec "$GIT_REAL" "$@"
'@ | Set-Content -LiteralPath $shimPath -NoNewline
        & /bin/chmod +x $shimPath
        $originalPath = $env:PATH
        $env:GIT_REAL = (Get-Command git).Source
        $env:GIT_SHIM_COUNT_FILE = Join-Path $script:fixtureRoot 'git-call-count'
        $env:GIT_SHIM_TRIGGER_PATH = $secondWorktreePath
        $env:GIT_SHIM_DIRTY_PATH = $script:worktreePath
        $env:PATH = "$script:fixtureRoot$([IO.Path]::PathSeparator)$originalPath"

        try {
            { & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey -Apply } | Should -Not -Throw
        }
        finally {
            $env:PATH = $originalPath
            Remove-Item Env:GIT_REAL, Env:GIT_SHIM_COUNT_FILE, Env:GIT_SHIM_TRIGGER_PATH, Env:GIT_SHIM_DIRTY_PATH -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath $script:taskPath | Should -BeFalse
    }

    It 'refuses a task directory swapped after the final worktree removal on Linux' -Skip:(-not $IsLinux) {
        $externalTaskPath = Join-Path $script:fixtureRoot 'external-final-task'
        $shimPath = Join-Path $script:fixtureRoot 'git'
        @'
#!/bin/sh
"$GIT_REAL" "$@"
status=$?
if [ "$status" -eq 0 ] && [ "$1" = '-C' ] && [ "$3" = 'worktree' ] && [ "$4" = 'remove' ] && [ "$6" = "$GIT_SHIM_WORKTREE_PATH" ]; then
    mv "$GIT_SHIM_TASK_PATH" "$GIT_SHIM_EXTERNAL_TASK_PATH"
    ln -s "$GIT_SHIM_EXTERNAL_TASK_PATH" "$GIT_SHIM_TASK_PATH"
fi
exit "$status"
'@ | Set-Content -LiteralPath $shimPath -NoNewline
        & /bin/chmod +x $shimPath
        $originalPath = $env:PATH
        $env:GIT_REAL = (Get-Command git).Source
        $env:GIT_SHIM_WORKTREE_PATH = $script:worktreePath
        $env:GIT_SHIM_TASK_PATH = $script:taskPath
        $env:GIT_SHIM_EXTERNAL_TASK_PATH = $externalTaskPath
        $env:PATH = "$script:fixtureRoot$([IO.Path]::PathSeparator)$originalPath"

        try {
            { & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey -Apply } | Should -Throw '*unsafe-task-path*'
        }
        finally {
            $env:PATH = $originalPath
            Remove-Item Env:GIT_REAL, Env:GIT_SHIM_WORKTREE_PATH, Env:GIT_SHIM_TASK_PATH, Env:GIT_SHIM_EXTERNAL_TASK_PATH -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath (Join-Path $externalTaskPath 'task.json') | Should -BeTrue
    }

    It 'refuses dirty worktrees without deleting any task state' {
        Add-Content -LiteralPath (Join-Path $script:worktreePath 'README.md') -Value 'dirty'

        { & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey -Apply } | Should -Throw '*dirty-worktree*'
        Test-Path -LiteralPath $script:taskPath | Should -BeTrue
        Test-Path -LiteralPath $script:worktreePath | Should -BeTrue
    }

    It 'refuses an unregistered worktree without removing it' {
        $unregisteredPath = Join-Path $script:taskPath 'worktrees/unregistered'
        & git -C $script:repositoryPath worktree add -b feature/UNREGISTERED $unregisteredPath main | Out-Null

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        ($plan.WorktreeOperations | Where-Object Repository -eq 'unregistered').Reason | Should -Be 'unregistered-worktree'
        Test-Path -LiteralPath $unregisteredPath | Should -BeTrue
    }

    if ($IsLinux) {
    It 'refuses a case-distinct registered repository' {
        $upperRepositoryPath = Join-Path $script:fixtureRoot 'Api'
        New-Item -ItemType Directory -Path $upperRepositoryPath | Out-Null
        & git -C $upperRepositoryPath init -b main | Out-Null
        & git -C $upperRepositoryPath config user.name Test
        & git -C $upperRepositoryPath config user.email test@example.invalid
        Set-Content -LiteralPath (Join-Path $upperRepositoryPath 'README.md') -Value 'fixture'
        & git -C $upperRepositoryPath add README.md
        & git -C $upperRepositoryPath commit -m fixture | Out-Null

        $manifestPath = Join-Path $script:taskPath 'task.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.repositories[0].path = $upperRepositoryPath
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -NoNewline

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        $plan.WorktreeOperations[0].Reason | Should -Be 'repository-mismatch'
        Test-Path -LiteralPath $script:worktreePath | Should -BeTrue
    }
    }

    It 'refuses a symlinked task container on Linux' -Skip:(-not $IsLinux) {
        $externalTaskPath = Join-Path $script:fixtureRoot 'external-task'
        Move-Item -LiteralPath $script:taskPath -Destination $externalTaskPath
        New-Item -ItemType SymbolicLink -Path $script:taskPath -Target $externalTaskPath | Out-Null

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        $plan.TaskReason | Should -Be 'unsafe-task-path'
    }

    It 'refuses a symlinked worktrees container on Linux' -Skip:(-not $IsLinux) {
        $worktreesPath = Join-Path $script:taskPath 'worktrees'
        $externalWorktreesPath = Join-Path $script:fixtureRoot 'external-worktrees'
        Move-Item -LiteralPath $worktreesPath -Destination $externalWorktreesPath
        New-Item -ItemType SymbolicLink -Path $worktreesPath -Target $externalWorktreesPath | Out-Null

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        $plan.TaskReason | Should -Be 'unsafe-task-path'
    }

    It 'refuses a symlinked worktree entry without following it' {
        New-Item -ItemType SymbolicLink -Path (Join-Path $script:taskPath 'worktrees/external') -Target $script:repositoryPath | Out-Null

        $plan = & $script:scriptPath -TasksRoot $script:tasksRoot -TaskKey $script:taskKey | ConvertFrom-Json

        $plan.TaskOperation | Should -Be 'blocked'
        ($plan.WorktreeOperations | Where-Object Repository -eq 'external').Reason | Should -Be 'symlink-worktree-entry'
        Test-Path -LiteralPath $script:repositoryPath | Should -BeTrue
    }
}

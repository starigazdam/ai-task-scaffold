#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TasksRoot,
    [Parameter(Mandatory)][string]$TaskKey,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Private/GitWorktree.psm1') -Force

if ($TaskKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "invalid task key '$TaskKey'"
}

$taskPath = Join-Path $TasksRoot $TaskKey
$operations = @()
$taskOperation = 'blocked'
$taskReason = 'task-not-found'

if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey)) {
    $taskReason = 'unsafe-task-path'
}
elseif (Test-Path -LiteralPath $taskPath -PathType Container) {
    $expectedEntries = @('PRD.md', 'PLAN.md', 'STATUS.md', 'task.json', 'artifacts', 'worktrees')
    $unexpectedEntry = Get-ChildItem -LiteralPath $taskPath -Force |
        Where-Object Name -notin $expectedEntries |
        Select-Object -First 1
    $manifestPath = Join-Path $taskPath 'task.json'
    if ($unexpectedEntry) {
        $taskReason = "unexpected-task-entry:$($unexpectedEntry.Name)"
    }
    elseif (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $taskReason = 'missing-manifest'
    }
    else {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 5
        if ([string]$manifest.task.key -ne $TaskKey) {
            $taskReason = 'manifest-key-mismatch'
        }
        else {
            $worktreesPath = Join-Path $taskPath 'worktrees'
            if (Test-Path -LiteralPath $worktreesPath -PathType Container) {
                foreach ($entry in Get-ChildItem -LiteralPath $worktreesPath -Force) {
                    $action = 'blocked'
                    $reason = 'unexpected-worktree-entry'
                    $actualCommonDir = $null
                    $actualBranch = $null
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $reason = 'symlink-worktree-entry'
                    }
                    elseif (-not $entry.PSIsContainer) {
                        $reason = 'unexpected-worktree-entry'
                    }
                    else {
                        $registration = @($manifest.repositories | Where-Object { [string]$_.name -ceq $entry.Name })
                        if ($registration.Count -ne 1) {
                            $reason = 'unregistered-worktree'
                        }
                        else {
                            $isWorktree = (& git -C $entry.FullName rev-parse --is-inside-work-tree 2>$null) -eq 'true'
                            if (-not $isWorktree) {
                                $reason = 'not-a-git-worktree'
                            }
                            else {
                                $expectedCommonDir = Get-GitCommonDir -RepositoryPath ([string]$registration[0].path)
                                $actualCommonDir = Get-GitCommonDir -RepositoryPath $entry.FullName
                                $actualBranch = (& git -C $entry.FullName branch --show-current 2>$null | Select-Object -First 1)
                                if (-not $expectedCommonDir -or $expectedCommonDir -cne $actualCommonDir) {
                                    $reason = 'repository-mismatch'
                                }
                                elseif ([string]$registration[0].branch -cne [string]$actualBranch) {
                                    $reason = 'branch-mismatch'
                                }
                                else {
                                    $dirty = @(& git -C $entry.FullName status --porcelain)
                                    if ($dirty.Count -eq 0) {
                                        $action = 'remove'
                                        $reason = $null
                                    }
                                    else {
                                        $reason = 'dirty-worktree'
                                    }
                                }
                            }
                        }
                    }
                    $operations += [ordered]@{
                        Repository = $entry.Name
                        RepositoryPath = if ($registration.Count -eq 1) { [string]$registration[0].path } else { $null }
                        Path = $entry.FullName
                        CommonDir = $actualCommonDir
                        Branch = $actualBranch
                        Action = $action
                        Reason = $reason
                    }
                }
            }
            if ($operations | Where-Object Action -eq 'blocked') {
                $taskReason = 'blocked-worktree'
            }
            else {
                $taskOperation = 'remove'
                $taskReason = $null
            }
        }
    }
}

if ($Apply) {
    if ($taskOperation -ne 'remove') {
        $blocked = $operations | Where-Object Action -eq 'blocked' | Select-Object -First 1
        $reason = if ($blocked) { $blocked.Reason } else { $taskReason }
        throw "cannot teardown task '$TaskKey': $reason"
    }
    if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey)) {
        throw "cannot teardown task '$TaskKey': unsafe-task-path"
    }
    foreach ($operation in $operations) {
        if (-not (Test-TaskWorktreeOperationSafety -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $operation.Repository -RepositoryPath $operation.RepositoryPath -WorktreePath $operation.Path -Branch $operation.Branch -ExpectedCommonDir $operation.CommonDir)) {
            throw "cannot teardown task '$TaskKey': worktree changed since planning"
        }
        if (@(& git -C $operation.Path status --porcelain).Count -ne 0) {
            throw "cannot teardown task '$TaskKey': dirty-worktree"
        }
    }
    foreach ($operation in $operations) {
        & git -C $operation.RepositoryPath worktree remove -- $operation.Path
        if ($LASTEXITCODE -ne 0) {
            throw "failed to remove worktree '$($operation.Path)'"
        }
    }
    Remove-Item -LiteralPath $taskPath -Recurse -Force
}

[ordered]@{
    TaskKey = $TaskKey
    TaskPath = $taskPath
    TaskOperation = $taskOperation
    TaskReason = $taskReason
    WorktreeOperations = $operations
    RequiresConfirmation = $true
} | ConvertTo-Json -Depth 6

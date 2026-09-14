#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TasksRoot,
    [Parameter(Mandatory)][string]$TaskKey,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($TaskKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "invalid task key '$TaskKey'"
}

$taskPath = Join-Path $TasksRoot $TaskKey
$operations = @()
$taskOperation = 'blocked'
$taskReason = 'task-not-found'

if (Test-Path -LiteralPath $taskPath -PathType Container) {
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
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $reason = 'symlink-worktree-entry'
                    }
                    elseif ($entry.PSIsContainer) {
                        $isWorktree = (& git -C $entry.FullName rev-parse --is-inside-work-tree 2>$null) -eq 'true'
                        if ($isWorktree) {
                            $dirty = @(& git -C $entry.FullName status --porcelain)
                            if ($dirty.Count -eq 0) {
                                $action = 'remove'
                                $reason = $null
                            }
                            else {
                                $reason = 'dirty-worktree'
                            }
                        }
                        else {
                            $reason = 'not-a-git-worktree'
                        }
                    }
                    $operations += [ordered]@{ Repository = $entry.Name; Path = $entry.FullName; Action = $action; Reason = $reason }
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
    foreach ($operation in $operations) {
        & git -C $operation.Path worktree remove -- $operation.Path
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

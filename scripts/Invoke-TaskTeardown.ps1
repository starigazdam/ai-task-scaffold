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
Import-Module (Join-Path $PSScriptRoot 'Private/TaskContract.psm1') -Force

function Get-TaskRecordedTaskFiles {
    param([string]$ManifestPath)

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 10
    $property = $manifest.PSObject.Properties['taskFiles']
    if (-not $property -or $null -eq $property.Value) { return @() }
    if ($property.Value -isnot [array]) { throw "invalid recorded taskFiles in '$ManifestPath'" }

    $comparer = Get-TaskPathComparer
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $recorded = @()
    foreach ($entry in $property.Value) {
        if ($null -eq $entry -or $entry -isnot [string]) { throw "invalid recorded task file entry in '$ManifestPath'" }
        $normalized = ConvertTo-TaskRelativeFilePath -Path $entry
        if (Test-TaskManagedTaskFilePath -RelativePath $normalized) {
            throw "recorded task file '$normalized' collides with a scaffold-managed path"
        }
        if (-not $seen.Add($normalized)) { throw "duplicate recorded task file '$normalized'" }
        $recorded += $normalized
    }
    return $recorded
}

function Get-TaskRecordedFileLayoutProblem {
    param([string]$TaskPath, [string[]]$RecordedTaskFiles)

    $recorded = @($RecordedTaskFiles)
    if ($recorded.Count -eq 0) { return $null }
    $comparer = Get-TaskPathComparer

    $groups = [ordered]@{}
    foreach ($relative in $recorded) {
        $top = @($relative.Split('/'))[0]
        if (-not $groups.Contains($top)) { $groups[$top] = @() }
        $groups[$top] = @($groups[$top]) + @($relative)
    }

    foreach ($top in @($groups.Keys)) {
        $groupFiles = @($groups[$top])
        $topPath = Join-Path $TaskPath $top
        $topItem = Get-Item -LiteralPath $topPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $topItem) { return 'missing-recorded-task-file' }
        if ((($topItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return 'unsafe-task-file' }

        if (-not $topItem.PSIsContainer) {
            if (@($groupFiles | Where-Object { $_ -ceq $top }).Count -ne 1) { return 'unrecorded-task-file' }
            continue
        }

        $allowedFiles = [System.Collections.Generic.HashSet[string]]::new($comparer)
        foreach ($relative in $groupFiles) { [void]$allowedFiles.Add($relative) }
        $allowedDirectories = [System.Collections.Generic.HashSet[string]]::new($comparer)
        [void]$allowedDirectories.Add($top)
        foreach ($relative in $groupFiles) {
            $segments = @($relative.Split('/'))
            for ($index = 1; $index -lt ($segments.Count - 1); $index++) {
                [void]$allowedDirectories.Add((@($segments[0..$index]) -join '/'))
            }
        }

        $directories = [System.Collections.Generic.Stack[string]]::new()
        $directories.Push($top)
        while ($directories.Count -gt 0) {
            $directory = $directories.Pop()
            $directoryPath = Join-Path $TaskPath ($directory.Replace('/', [IO.Path]::DirectorySeparatorChar))
            foreach ($child in @(Get-ChildItem -LiteralPath $directoryPath -Force)) {
                if ((($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return 'unsafe-task-file' }
                $childRelative = "$directory/$($child.Name)"
                if ($child.PSIsContainer) {
                    if (-not $allowedDirectories.Contains($childRelative)) { return 'unrecorded-task-file' }
                    $directories.Push($childRelative)
                }
                elseif (-not $allowedFiles.Contains($childRelative)) {
                    return 'unrecorded-task-file'
                }
            }
        }

        foreach ($relative in $groupFiles) {
            $relativePath = Join-Path $TaskPath ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $item = Get-Item -LiteralPath $relativePath -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or $item.PSIsContainer) { return 'missing-recorded-task-file' }
        }
    }
    return $null
}

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
    $manifestPath = Join-Path $taskPath 'task.json'
    $recordedTaskFiles = @()
    $recordedProblem = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $recordedTaskFiles = @(Get-TaskRecordedTaskFiles -ManifestPath $manifestPath)
        }
        catch {
            $recordedProblem = 'invalid-recorded-task-file'
        }
    }
    if ($recordedProblem) {
        $taskReason = $recordedProblem
    }
    else {
        $expectedEntries = @('PRD.md', 'PLAN.md', 'STATUS.md', 'task.json', '.ctx', 'artifacts', 'worktrees')
        foreach ($recorded in $recordedTaskFiles) {
            $top = @($recorded.Split('/'))[0]
            if ($top -notin $expectedEntries) { $expectedEntries += $top }
        }
        $unexpectedEntry = Get-ChildItem -LiteralPath $taskPath -Force |
            Where-Object Name -notin $expectedEntries |
            Select-Object -First 1
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
            elseif ($layoutProblem = Get-TaskRecordedFileLayoutProblem -TaskPath $taskPath -RecordedTaskFiles $recordedTaskFiles) {
                $taskReason = $layoutProblem
            }
            else {
            $worktreesPath = Join-Path $taskPath 'worktrees'
            if (Test-Path -LiteralPath $worktreesPath -PathType Container) {
                $entries = @(Get-ChildItem -LiteralPath $worktreesPath -Force)
                $entryNames = @($entries | ForEach-Object { $_.Name })
                $registeredNames = @($manifest.repositories | ForEach-Object { [string]$_.name })
                foreach ($missingName in @($registeredNames | Where-Object { $_ -cnotin $entryNames })) {
                    $operations += [ordered]@{
                        Repository = $missingName
                        RepositoryPath = $null
                        Path = Join-Path $worktreesPath $missingName
                        CommonDir = $null
                        GitDir = $null
                        Branch = $null
                        Action = 'blocked'
                        Reason = 'missing-worktree'
                    }
                }
                foreach ($entry in $entries) {
                    $action = 'blocked'
                    $reason = 'unexpected-worktree-entry'
                    $actualCommonDir = $null
                    $actualGitDir = $null
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
                                $actualGitDir = Get-GitDir -RepositoryPath $entry.FullName
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
                        GitDir = $actualGitDir
                        Branch = $actualBranch
                        Action = $action
                        Reason = $reason
                    }
                }
            }
            else {
                foreach ($missingName in @($manifest.repositories | ForEach-Object { [string]$_.name })) {
                    $operations += [ordered]@{
                        Repository = $missingName
                        RepositoryPath = $null
                        Path = Join-Path $worktreesPath $missingName
                        CommonDir = $null
                        GitDir = $null
                        Branch = $null
                        Action = 'blocked'
                        Reason = 'missing-worktrees-container'
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
}

if ($Apply) {
    $mutationLock = Enter-TaskMutationLock -TasksRoot $TasksRoot
    try {
    $replanMarker = $env:AI_TASK_SCAFFOLD_REPLAN
    $env:AI_TASK_SCAFFOLD_REPLAN = '1'
    try {
        $lockedPlan = & $PSCommandPath -TasksRoot $TasksRoot -TaskKey $TaskKey | ConvertFrom-Json -Depth 8
    }
    finally {
        if ($null -eq $replanMarker) { Remove-Item Env:AI_TASK_SCAFFOLD_REPLAN -ErrorAction SilentlyContinue } else { $env:AI_TASK_SCAFFOLD_REPLAN = $replanMarker }
    }
    $operations = @($lockedPlan.WorktreeOperations)
    $taskOperation = [string]$lockedPlan.TaskOperation
    $taskReason = [string]$lockedPlan.TaskReason
    if ($taskOperation -ne 'remove') {
        $blocked = $operations | Where-Object Action -eq 'blocked' | Select-Object -First 1
        $reason = if ($blocked) { $blocked.Reason } else { $taskReason }
        throw "cannot teardown task '$TaskKey': $reason"
    }
    if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey)) {
        throw "cannot teardown task '$TaskKey': unsafe-task-path"
    }
    foreach ($operation in $operations) {
        if (-not (Test-TaskWorktreeOperationSafety -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $operation.Repository -RepositoryPath $operation.RepositoryPath -WorktreePath $operation.Path -Branch $operation.Branch -ExpectedCommonDir $operation.CommonDir -ExpectedGitDir $operation.GitDir)) {
            throw "cannot teardown task '$TaskKey': worktree changed since planning"
        }
        if (@(& git -C $operation.Path status --porcelain).Count -ne 0) {
            throw "cannot teardown task '$TaskKey': dirty-worktree"
        }
        & git -C $operation.RepositoryPath worktree remove -- $operation.Path
        if ($LASTEXITCODE -ne 0) {
            throw "failed to remove worktree '$($operation.Path)'"
        }
    }
    if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey)) {
        throw "cannot teardown task '$TaskKey': unsafe-task-path"
    }
    $lockedManifestPath = Join-Path $taskPath 'task.json'
    $finalRecordedTaskFiles = @()
    if (Test-Path -LiteralPath $lockedManifestPath -PathType Leaf) {
        $finalRecordedTaskFiles = @(Get-TaskRecordedTaskFiles -ManifestPath $lockedManifestPath)
    }
    $finalLayoutProblem = Get-TaskRecordedFileLayoutProblem -TaskPath $taskPath -RecordedTaskFiles $finalRecordedTaskFiles
    if ($finalLayoutProblem) {
        throw "cannot teardown task '$TaskKey': $finalLayoutProblem"
    }
    $allowedEntries = @('PRD.md', 'PLAN.md', 'STATUS.md', 'task.json', '.ctx', 'artifacts', 'worktrees')
    foreach ($recorded in $finalRecordedTaskFiles) {
        $top = @($recorded.Split('/'))[0]
        if ($top -notin $allowedEntries) { $allowedEntries += $top }
    }
    $requiredEntries = @('PRD.md', 'PLAN.md', 'STATUS.md', 'task.json', 'artifacts', 'worktrees')
    $finalEntries = @(Get-ChildItem -LiteralPath $taskPath -Force)
    if (@($finalEntries | Where-Object Name -notin $allowedEntries).Count -gt 0 -or
        @($finalEntries | Where-Object Name -in $requiredEntries).Count -ne $requiredEntries.Count -or
        @(Get-ChildItem -LiteralPath (Join-Path $taskPath 'worktrees') -Force).Count -ne 0) {
        throw "cannot teardown task '$TaskKey': task changed during removal"
    }
    Remove-Item -LiteralPath $taskPath -Recurse -Force
    }
    finally {
        $mutationLock.Dispose()
    }
}

[ordered]@{
    TaskKey = $TaskKey
    TaskPath = $taskPath
    TaskOperation = $taskOperation
    TaskReason = $taskReason
    WorktreeOperations = $operations
    RequiresConfirmation = $true
} | ConvertTo-Json -Depth 6

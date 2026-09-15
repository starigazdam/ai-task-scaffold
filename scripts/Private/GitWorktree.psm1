Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-GitRef {
    param([string]$RepositoryPath, [string]$Reference)

    & git -C $RepositoryPath rev-parse --verify --quiet "$Reference^{commit}" 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Get-GitCommonDir {
    param([string]$RepositoryPath)

    $output = & git -C $RepositoryPath rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Get-GitDir {
    param([string]$RepositoryPath)

    $output = & git -C $RepositoryPath rev-parse --path-format=absolute --git-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Test-TaskWorktreeIdentity {
    param(
        [string]$RepositoryPath,
        [string]$WorktreePath,
        [string]$Branch,
        [string]$ExpectedCommonDir,
        [string]$ExpectedGitDir
    )

    $repositoryCommonDir = if ($ExpectedCommonDir) { $ExpectedCommonDir } else { Get-GitCommonDir -RepositoryPath $RepositoryPath }
    $worktreeCommonDir = Get-GitCommonDir -RepositoryPath $WorktreePath
    $worktreeGitDir = Get-GitDir -RepositoryPath $WorktreePath
    $expectedWorktreeGitDir = if ($ExpectedGitDir) { $ExpectedGitDir } else { $worktreeGitDir }
    $worktreeBranch = (& git -C $WorktreePath branch --show-current 2>$null | Select-Object -First 1)
    return $repositoryCommonDir -and $repositoryCommonDir -ceq $worktreeCommonDir -and $worktreeGitDir -ceq $expectedWorktreeGitDir -and $worktreeBranch -ceq $Branch
}

function Test-TaskWorktreeOperationSafety {
    param(
        [string]$TasksRoot,
        [string]$TaskKey,
        [string]$RepositoryName,
        [string]$RepositoryPath,
        [string]$WorktreePath,
        [string]$Branch,
        [string]$ExpectedCommonDir,
        [string]$ExpectedGitDir
    )

    return (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $RepositoryName) -and
        (Get-GitCommonDir -RepositoryPath $RepositoryPath) -ceq $ExpectedCommonDir -and
        (Test-TaskWorktreeIdentity -RepositoryPath $RepositoryPath -WorktreePath $WorktreePath -Branch $Branch -ExpectedCommonDir $ExpectedCommonDir -ExpectedGitDir $ExpectedGitDir)
}

function Get-TaskWorktreeDestination {
    param([string]$TasksRoot, [string]$TaskKey, [string]$RepositoryName)

    return [IO.Path]::GetFullPath((Join-Path $TasksRoot (Join-Path (Join-Path $TaskKey 'worktrees') $RepositoryName)))
}

function Enter-TaskMutationLock {
    param([string]$TasksRoot)

    $tasksRootPath = [IO.Path]::GetFullPath($TasksRoot)
    New-Item -ItemType Directory -Path $tasksRootPath -Force | Out-Null
    $lockPath = Join-Path $tasksRootPath '.ai-task-scaffold.lock'
    return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Test-TaskPathSafety {
    param([string]$TasksRoot, [string]$TaskKey, [string]$RepositoryName)

    $tasksRootPath = [IO.Path]::GetFullPath($TasksRoot)
    $taskPath = [IO.Path]::GetFullPath((Join-Path $tasksRootPath $TaskKey))
    $worktreesPath = [IO.Path]::GetFullPath((Join-Path $taskPath 'worktrees'))
    $separator = [IO.Path]::DirectorySeparatorChar
    if (-not $taskPath.StartsWith("$tasksRootPath$separator", [StringComparison]::Ordinal) -or
        -not $worktreesPath.StartsWith("$taskPath$separator", [StringComparison]::Ordinal)) {
        return $false
    }

    $paths = @($tasksRootPath, $taskPath, $worktreesPath)
    if ($RepositoryName) { $paths += Get-TaskWorktreeDestination -TasksRoot $tasksRootPath -TaskKey $TaskKey -RepositoryName $RepositoryName }
    foreach ($path in $paths) {
        if ((Test-Path -LiteralPath $path) -and (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
    }
    return $true
}

function New-TaskWorktreePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Repository,
        [Parameter(Mandatory)][string]$TaskKey,
        [Parameter(Mandatory)][string]$TasksRoot
    )

    & git -C $Repository.Path rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "repository '$($Repository.Name)' is not a Git worktree"
    }

    $repositoryCommonDir = Get-GitCommonDir -RepositoryPath $Repository.Path
    $destination = Get-TaskWorktreeDestination -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $Repository.Name
    if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $Repository.Name)) {
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'unsafe-worktree-path'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }
    if (Test-Path -LiteralPath $destination) {
        if (Test-TaskWorktreeIdentity -RepositoryPath $Repository.Path -WorktreePath $destination -Branch $Repository.Branch -ExpectedCommonDir $repositoryCommonDir) {
            return [pscustomobject]@{ Action = 'reuse'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; RepositoryCommonDir = $repositoryCommonDir; WorktreeGitDir = (Get-GitDir -RepositoryPath $destination); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'destination-exists'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/heads/$($Repository.Branch)") {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/remotes/origin/$($Repository.Branch)") {
        return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = "origin/$($Repository.Branch)"; BranchMode = 'track'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/heads/$($Repository.BaseBranch)") {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.BaseBranch; BranchMode = 'new'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $remoteBase = if ($Repository.BaseBranch -match '^[^/]+/.+') { $Repository.BaseBranch } else { "origin/$($Repository.BaseBranch)" }
    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/remotes/$remoteBase") {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $remoteBase; BranchMode = 'new'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
}

function Invoke-TaskWorktreePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Repository,
        [Parameter(Mandatory)][psobject]$Plan
    )

    if ($Plan.Action -eq 'blocked') {
        throw "cannot apply blocked plan: $($Plan.Reason)"
    }
    $expectedDestination = Get-TaskWorktreeDestination -TasksRoot $Plan.TasksRoot -TaskKey $Plan.TaskKey -RepositoryName $Repository.Name
    if (-not (Test-TaskPathSafety -TasksRoot $Plan.TasksRoot -TaskKey $Plan.TaskKey -RepositoryName $Repository.Name) -or $Plan.Destination -cne $expectedDestination) {
        throw "refusing unsafe worktree destination '$($Plan.Destination)'"
    }
    if ($Plan.Action -eq 'reuse') {
        if ((Get-GitCommonDir -RepositoryPath $Repository.Path) -cne $Plan.RepositoryCommonDir -or
            -not (Test-TaskWorktreeIdentity -RepositoryPath $Repository.Path -WorktreePath $Plan.Destination -Branch $Plan.Source -ExpectedCommonDir $Plan.RepositoryCommonDir -ExpectedGitDir $Plan.WorktreeGitDir)) {
            throw "reused worktree changed since planning: '$($Plan.Destination)'"
        }
        return
    }
    if (Test-Path -LiteralPath $Plan.Destination) {
        throw "refusing to overwrite existing destination '$($Plan.Destination)'"
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Plan.Destination) -Force | Out-Null
    if ($Plan.Action -eq 'create-remote') {
        & git -C $Repository.Path worktree add --track -b $Repository.Branch $Plan.Destination $Plan.Source
    }
    elseif ($Plan.BranchMode -eq 'existing') {
        & git -C $Repository.Path worktree add $Plan.Destination $Plan.Source
    }
    elseif ($Plan.Action -eq 'create-local') {
        & git -C $Repository.Path worktree add -b $Repository.Branch $Plan.Destination $Plan.Source
    }
    else {
        throw "unsupported worktree action '$($Plan.Action)'"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed for '$($Repository.Name)'"
    }
}

Export-ModuleMember -Function Enter-TaskMutationLock, Get-GitCommonDir, Get-GitDir, Test-TaskWorktreeIdentity, Test-TaskWorktreeOperationSafety, Test-TaskPathSafety, New-TaskWorktreePlan, Invoke-TaskWorktreePlan

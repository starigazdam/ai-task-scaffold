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

    $destination = Join-Path $TasksRoot (Join-Path (Join-Path $TaskKey 'worktrees') $Repository.Name)
    if (Test-Path -LiteralPath $destination) {
        $repositoryCommonDir = Get-GitCommonDir -RepositoryPath $Repository.Path
        $destinationCommonDir = Get-GitCommonDir -RepositoryPath $destination
        $destinationBranch = (& git -C $destination branch --show-current 2>$null | Select-Object -First 1)
        if ($repositoryCommonDir -and $repositoryCommonDir -ceq $destinationCommonDir -and $destinationBranch -eq $Repository.Branch) {
            return [pscustomobject]@{ Action = 'reuse'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name }
        }
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'destination-exists'; Repository = $Repository.Name }
    }

    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/heads/$($Repository.Branch)") {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name }
    }

    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/remotes/origin/$($Repository.Branch)") {
        return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = "origin/$($Repository.Branch)"; BranchMode = 'track'; Repository = $Repository.Name }
    }

    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/heads/$($Repository.BaseBranch)") {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.BaseBranch; BranchMode = 'new'; Repository = $Repository.Name }
    }

    $remoteBase = if ($Repository.BaseBranch -match '^[^/]+/.+') { $Repository.BaseBranch } else { "origin/$($Repository.BaseBranch)" }
    if (Test-GitRef -RepositoryPath $Repository.Path -Reference "refs/remotes/$remoteBase") {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $remoteBase; BranchMode = 'new'; Repository = $Repository.Name }
    }

    return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name }
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
    if ($Plan.Action -eq 'reuse') {
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

Export-ModuleMember -Function Get-GitCommonDir, New-TaskWorktreePlan, Invoke-TaskWorktreePlan

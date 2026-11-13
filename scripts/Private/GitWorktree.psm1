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

function Start-TaskWorktreeGitProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$State,
        [System.Threading.SemaphoreSlim]$Gate
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($RepositoryPath)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }

    # The start itself is the gated step: a failure published after this point
    # cannot be followed by a new git start, and work started earlier is running.
    if ($Gate) {
        $Gate.Wait()
        try {
            if ($State.Failed) { return $null }
            return [System.Diagnostics.Process]::Start($startInfo)
        }
        finally { [void]$Gate.Release() }
    }
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Invoke-TaskWorktreePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Repository,
        [Parameter(Mandatory)][psobject]$Plan,
        [hashtable]$State,
        [System.Threading.SemaphoreSlim]$Gate
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

    $gitArguments = if ($Plan.Action -eq 'create-remote') { @('worktree', 'add', '--track', '-b', $Repository.Branch, $Plan.Destination, $Plan.Source) }
        elseif ($Plan.BranchMode -eq 'existing') { @('worktree', 'add', $Plan.Destination, $Plan.Source) }
        elseif ($Plan.Action -eq 'create-local') { @('worktree', 'add', '-b', $Repository.Branch, $Plan.Destination, $Plan.Source) }
        else { throw "unsupported worktree action '$($Plan.Action)'" }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Plan.Destination) -Force | Out-Null
    $process = Start-TaskWorktreeGitProcess -RepositoryPath $Repository.Path -Arguments $gitArguments -State $State -Gate $Gate
    if ($null -eq $process) { return $false }
    # Native stderr becomes a terminating error inside a parallel runspace, so
    # capture it here and report it with the failure instead of writing it out.
    $standardError = $null
    try {
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.StandardOutput.ReadToEndAsync() | Out-Null
        $process.WaitForExit()
        $gitOutput = @($standardError.GetAwaiter().GetResult() -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($process.ExitCode -ne 0) {
            $detail = $gitOutput -join '; '
            if ($detail) { throw "git worktree add failed for '$($Repository.Name)': $detail" }
            throw "git worktree add failed for '$($Repository.Name)'"
        }
    }
    finally {
        $process.Dispose()
    }
    return $true
}

function Get-TaskWorktreeConcurrencyLimit {
    param([string]$VariableName = 'AI_TASK_SCAFFOLD_WORKTREE_CONCURRENCY')

    $raw = [Environment]::GetEnvironmentVariable($VariableName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return 3 }
    $limit = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$limit) -or $limit -lt 1 -or $limit -gt 8) {
        throw "invalid $VariableName value '$raw': expected an integer from 1 to 8"
    }
    return $limit
}

function Invoke-TaskWorktreePlanItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Item,
        [hashtable]$State,
        [System.Threading.SemaphoreSlim]$Gate
    )

    try {
        $started = Invoke-TaskWorktreePlan -Repository $Item.Repository -Plan $Item.Plan -State $State -Gate $Gate
        if ($started -eq $false) {
            return [pscustomobject]@{ Index = $Item.Index; Repository = $Item.Repository.Name; Status = 'skipped'; Message = 'skipped after an earlier worktree failure' }
        }
        return [pscustomobject]@{ Index = $Item.Index; Repository = $Item.Repository.Name; Status = 'created'; Message = $null }
    }
    catch {
        return [pscustomobject]@{ Index = $Item.Index; Repository = $Item.Repository.Name; Status = 'failed'; Message = $_.Exception.Message }
    }
}

function Set-TaskWorktreeFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Threading.SemaphoreSlim]$Gate,
        [int]$Index
    )

    $Gate.Wait()
    try {
        $State.Failed = $true
        $State.FirstFailedIndex = $Index
    }
    finally { [void]$Gate.Release() }
}

function Invoke-TaskWorktreePlanBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$WorkItems,
        [Parameter(Mandatory)][ValidateRange(1, 8)][int]$Limit,
        [Parameter(Mandatory)][string]$ModulePath
    )

    if ($WorkItems.Count -eq 0) { return ,@() }

    if ($Limit -le 1 -or $WorkItems.Count -eq 1) {
        $serialResults = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $WorkItems) {
            $serialResults.Add((Invoke-TaskWorktreePlanItem -Item $item))
            if ($serialResults[$serialResults.Count - 1].Status -eq 'failed') { break }
        }
        return ,$serialResults.ToArray()
    }

    # Entries that share one Git common directory race on .git/worktrees and ref
    # locks, so each common directory becomes one chain that runs serially.
    $chains = [ordered]@{}
    foreach ($item in $WorkItems) {
        $key = Get-GitCommonDir -RepositoryPath $item.Repository.Path
        if (-not $key) { $key = [IO.Path]::GetFullPath($item.Repository.Path) }
        if (-not $chains.Contains($key)) { $chains[$key] = [System.Collections.Generic.List[object]]::new() }
        $chains[$key].Add($item)
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.Plan.Destination) -Force | Out-Null
    }
    $chainList = @($chains.Values | ForEach-Object { ,$_.ToArray() })

    $state = [hashtable]::Synchronized(@{ Failed = $false; FirstFailedIndex = -1 })
    $gate = [System.Threading.SemaphoreSlim]::new(1, 1)
    $parallelResults = $chainList | ForEach-Object -Parallel {
        $modulePath = $using:ModulePath
        $state = $using:state
        $gate = $using:gate
        Import-Module -Name $modulePath -Force
        foreach ($item in $_) {
            $result = Invoke-TaskWorktreePlanItem -Item $item -State $state -Gate $gate
            if ($result.Status -eq 'failed') { Set-TaskWorktreeFailure -State $state -Gate $gate -Index $result.Index }
            $result
        }
    } -ThrottleLimit $Limit

    return ,@($parallelResults | Sort-Object Index)
}

Export-ModuleMember -Function Enter-TaskMutationLock, Get-GitCommonDir, Get-GitDir, Test-TaskWorktreeIdentity, Test-TaskWorktreeOperationSafety, Test-TaskPathSafety, New-TaskWorktreePlan, Invoke-TaskWorktreePlan, Get-TaskWorktreeConcurrencyLimit, Invoke-TaskWorktreePlanItem, Invoke-TaskWorktreePlanBatch, Start-TaskWorktreeGitProcess, Set-TaskWorktreeFailure

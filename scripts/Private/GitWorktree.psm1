Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GitCommitWithoutLazyFetch {
    param([string]$RepositoryPath, [string]$Reference)

    # A partial clone can lazily fetch a missing object during rev-parse. These
    # planning lookups are read-only, so they must only resolve local objects.
    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('rev-parse', '--verify', '--quiet', "$Reference^{commit}") -NoLazyFetch
    if ($result.ExitCode -ne 0) { return $null }
    return ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
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
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'unsafe-worktree-path'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }
    $startCommit = if ($Repository.PSObject.Properties['StartCommit']) { $Repository.StartCommit } else { $null }
    if ($startCommit) {
        if ((Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference $startCommit) -cne $startCommit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
    }
    if (Test-Path -LiteralPath $destination) {
        if (Test-TaskWorktreeIdentity -RepositoryPath $Repository.Path -WorktreePath $destination -Branch $Repository.Branch -ExpectedCommonDir $repositoryCommonDir) {
            $reuseCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference "refs/heads/$($Repository.Branch)"
            return [pscustomobject]@{ Action = 'reuse'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $reuseCommit; RepositoryCommonDir = $repositoryCommonDir; WorktreeGitDir = (Get-GitDir -RepositoryPath $destination); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'destination-exists'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    # Every create operation binds an immutable commit. Apply starts the branch
    # from SourceCommit, never from a name that can resolve to another ref or move
    # between planning and the git start. Source keeps the reviewed display value.
    $localBranchRef = "refs/heads/$($Repository.Branch)"
    $remoteBranchRef = "refs/remotes/origin/$($Repository.Branch)"

    if ($startCommit) {
        $localCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference $localBranchRef
        if ($localCommit) {
            if ($localCommit -cne $startCommit) {
                return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-mismatch'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
            }
            return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $startCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }

        $remoteCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference $remoteBranchRef
        if ($remoteCommit) {
            if ($remoteCommit -cne $startCommit) {
                return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-mismatch'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
            }
            return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = $remoteBranchRef; BranchMode = 'track'; Repository = $Repository.Name; SourceCommit = $startCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }

        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $startCommit; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $startCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $localCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference $localBranchRef
    if ($localCommit) {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $localCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    # Resolve the remote branch only through its full ref: the shorthand
    # 'origin/<branch>' resolves a local branch of that name first.
    $remoteCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference $remoteBranchRef
    if ($remoteCommit) {
        return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = "origin/$($Repository.Branch)"; BranchMode = 'track'; Repository = $Repository.Name; SourceCommit = $remoteCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $localBaseRef = "refs/heads/$($Repository.BaseBranch)"
    $localBaseCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference $localBaseRef
    if ($localBaseCommit) {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.BaseBranch; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $localBaseCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $remoteBase = if ($Repository.BaseBranch -match '^[^/]+/.+') { $Repository.BaseBranch } else { "origin/$($Repository.BaseBranch)" }
    $remoteBaseCommit = Get-GitCommitWithoutLazyFetch -RepositoryPath $Repository.Path -Reference "refs/remotes/$remoteBase"
    if ($remoteBaseCommit) {
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $remoteBase; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $remoteBaseCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
}

function New-TaskGitStartInfo {
    param([string]$RepositoryPath, [string[]]$Arguments, [switch]$NoLazyFetch)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($RepositoryPath)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    if ($NoLazyFetch) {
        # Scoped to this child only: the calling process environment never changes,
        # and an actual checkout keeps its normal lazy-fetch behavior.
        $startInfo.Environment['GIT_NO_LAZY_FETCH'] = '1'
    }
    return $startInfo
}

function Get-TaskGitDiagnostic {
    param([string]$Text)

    # Bound the detail: git diagnostics are short, but a broken hook is not.
    return ((@($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 20) -join '; ')
}

function Invoke-TaskWorktreeGitCommand {
    param([string]$RepositoryPath, [string[]]$Arguments, [switch]$NoLazyFetch)

    $process = [System.Diagnostics.Process]::Start((New-TaskGitStartInfo -RepositoryPath $RepositoryPath -Arguments $Arguments -NoLazyFetch:$NoLazyFetch))
    try {
        # Native stderr becomes a terminating error inside a parallel runspace.
        $standardError = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $process.WaitForExit()
        $errorText = $standardError.GetAwaiter().GetResult()
        $outputText = $standardOutput.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $outputText
            Text = $errorText + $outputText
        }
    }
    finally { $process.Dispose() }
}

function Start-TaskWorktreeGitProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$State,
        [System.Threading.SemaphoreSlim]$Gate
    )

    $startInfo = New-TaskGitStartInfo -RepositoryPath $RepositoryPath -Arguments $Arguments

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

    $sourceCommit = if ($Plan.PSObject.Properties['SourceCommit']) { [string]$Plan.SourceCommit } else { $null }
    $createsBranch = $Plan.Action -eq 'create-remote' -or ($Plan.Action -eq 'create-local' -and $Plan.BranchMode -ne 'existing')
    if ($createsBranch -and [string]::IsNullOrWhiteSpace($sourceCommit)) {
        throw "cannot apply plan for '$($Repository.Name)': no reviewed source commit was bound"
    }

    # A branch is always created at the immutable commit bound by the plan, never
    # at a ref name that can resolve to another ref or move before the git start.
    $gitArguments =
        if ($Plan.Action -eq 'create-remote') { @('worktree', 'add', '-b', $Repository.Branch, $Plan.Destination, $sourceCommit) }
        elseif ($Plan.BranchMode -eq 'existing') { @('worktree', 'add', $Plan.Destination, $Plan.Source) }
        elseif ($Plan.Action -eq 'create-local') { @('worktree', 'add', '-b', $Repository.Branch, $Plan.Destination, $sourceCommit) }
        else { throw "unsupported worktree action '$($Plan.Action)'" }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Plan.Destination) -Force | Out-Null
    $process = Start-TaskWorktreeGitProcess -RepositoryPath $Repository.Path -Arguments $gitArguments -State $State -Gate $Gate
    if ($null -eq $process) { return $false }
    # Native stderr becomes a terminating error inside a parallel runspace, so
    # capture it here and report it with the failure instead of writing it out.
    try {
        # Drain both streams before the wait so a full pipe buffer cannot block git.
        $standardError = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $process.WaitForExit()
        $gitText = $standardError.GetAwaiter().GetResult() + $standardOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = Get-TaskGitDiagnostic -Text $gitText
            if ($detail) { throw "git worktree add failed for '$($Repository.Name)': $detail" }
            throw "git worktree add failed for '$($Repository.Name)'"
        }
    }
    finally {
        $process.Dispose()
    }

    if ($sourceCommit) {
        $headResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $Plan.Destination -Arguments @('rev-parse', 'HEAD^{commit}') -NoLazyFetch
        if ($headResult.ExitCode -ne 0) {
            $detail = Get-TaskGitDiagnostic -Text $headResult.Text
            if ($detail) { throw "cannot verify the new worktree HEAD for '$($Repository.Name)': $detail" }
            throw "cannot verify the new worktree HEAD for '$($Repository.Name)'"
        }
        $head = ([string](@($headResult.Output -split "`r?`n") | Select-Object -First 1)).Trim()
        if ($head -cne $sourceCommit) {
            throw "worktree HEAD '$head' for '$($Repository.Name)' is not the reviewed commit '$sourceCommit'"
        }
    }

    if ($Plan.Action -eq 'create-remote') {
        # Keep the upstream on the full, unambiguous remote ref even though the
        # branch itself starts at the bound commit.
        $upstreamRef = "refs/remotes/origin/$($Repository.Branch)"
        $upstreamResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $Plan.Destination -Arguments @('branch', "--set-upstream-to=$upstreamRef", $Repository.Branch)
        if ($upstreamResult.ExitCode -ne 0) {
            $detail = Get-TaskGitDiagnostic -Text $upstreamResult.Text
            if ($detail) { throw "git branch --set-upstream-to failed for '$($Repository.Name)': $detail" }
            throw "git branch --set-upstream-to failed for '$($Repository.Name)'"
        }
        $upstreamReadBack = Invoke-TaskWorktreeGitCommand -RepositoryPath $Plan.Destination -Arguments @('for-each-ref', '--format=%(upstream)', "refs/heads/$($Repository.Branch)")
        if ($upstreamReadBack.ExitCode -ne 0) {
            $detail = Get-TaskGitDiagnostic -Text $upstreamReadBack.Text
            if ($detail) { throw "cannot verify the upstream for '$($Repository.Name)': $detail" }
            throw "cannot verify the upstream for '$($Repository.Name)'"
        }
        $actualUpstream = ([string](@($upstreamReadBack.Output -split "`r?`n") | Select-Object -First 1)).Trim()
        if ($actualUpstream -cne $upstreamRef) {
            throw "created branch for '$($Repository.Name)' tracks '$actualUpstream' instead of '$upstreamRef'"
        }
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

Export-ModuleMember -Function Enter-TaskMutationLock, Get-GitCommitWithoutLazyFetch, Invoke-TaskWorktreeGitCommand, Get-GitCommonDir, Get-GitDir, Test-TaskWorktreeIdentity, Test-TaskWorktreeOperationSafety, Test-TaskPathSafety, New-TaskWorktreePlan, Invoke-TaskWorktreePlan, Get-TaskWorktreeConcurrencyLimit, Invoke-TaskWorktreePlanItem, Invoke-TaskWorktreePlanBatch, Start-TaskWorktreeGitProcess, Set-TaskWorktreeFailure

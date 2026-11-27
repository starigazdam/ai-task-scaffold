Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TaskRepositoryPath {
    param([string]$Path)

    # Native Git run from PowerShell resolves a relative -C path against the
    # PowerShell file-system location, while a child process inherits the
    # process working directory. Combine both once so every probe, child, and
    # identity read sees one path, and leave the raw value untouched in durable
    # manifests. The combination is not normalized: `..` and symlinks must keep
    # the meaning native chdir gives them (link/../repo is the repository
    # inside link's target, not a sibling), so a lexical GetFullPath could
    # select a different repository.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([IO.Path]::IsPathFullyQualified($Path)) {
        return [IO.Path]::TrimEndingDirectorySeparator($Path)
    }

    $location = $null
    try { $location = (Get-Location -PSProvider FileSystem -ErrorAction Stop).ProviderPath }
    catch { $location = [Environment]::CurrentDirectory }
    if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::Combine($location, $Path))
}

function Get-GitCommitWithoutLazyFetch {
    param([string]$RepositoryPath, [string]$Reference)

    # Full ref names are resolved exactly: revision DWIM can fall back to a tag
    # literally named like the ref (for example refs/tags/refs/remotes/origin/x).
    if ($Reference -clike 'refs/*') {
        return (Get-TaskGitRefCommit -RepositoryPath $RepositoryPath -Reference $Reference).Commit
    }

    # A partial clone can lazily fetch a missing object during rev-parse. These
    # planning lookups are read-only, so they must only resolve local objects.
    # Replacement refs must not stand in either: they can map a missing pinned
    # commit to a local one and make an absent object look present.
    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('--no-replace-objects', 'rev-parse', '--verify', '--quiet', "$Reference^{commit}") -NoLazyFetch
    if ($result.ExitCode -ne 0) { return $null }
    return ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
}

function Get-TaskGitRefCommit {
    param([string]$RepositoryPath, [string]$Reference)

    # Presence is decided by exact name checks that never run revision DWIM:
    # `show-ref --verify` and `symbolic-ref -q` accept only the full name, so a
    # lookalike tag cannot stand in. for-each-ref still lists the raw object ID.
    # A name that is present but whose tip cannot be read -- a dangling symbolic
    # ref, which for-each-ref omits and show-ref refuses -- stays present, so
    # callers fail closed instead of falling through to another ref.
    $presence = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('show-ref', '--verify', '--quiet', $Reference) -NoLazyFetch
    $present = $presence.ExitCode -eq 0
    if (-not $present -and $presence.ExitCode -eq 1) {
        # show-ref reports a dangling symbolic ref as absent (it cannot resolve
        # the target), so ask for the symbolic ref itself before giving up.
        $symbolic = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('symbolic-ref', '-q', $Reference) -NoLazyFetch
        $present = $symbolic.ExitCode -eq 0
    }
    elseif (-not $present) {
        # Any other exit is an unreadable ref, never an absent one.
        $present = $true
    }

    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('for-each-ref', '--format=%(refname) %(objectname)', $Reference) -NoLazyFetch
    if ($result.ExitCode -ne 0) {
        throw "cannot read ref '$Reference' in '$RepositoryPath': $(Get-TaskGitDiagnostic -Text $result.Text)"
    }

    $objectId = $null
    foreach ($line in @($result.Output -split "`r?`n")) {
        if (-not $line.StartsWith("$Reference ", [StringComparison]::Ordinal)) { continue }
        # Fixed-width parse: the remainder is exactly one raw object ID, never a
        # decorated or trimmed value.
        $candidate = $line.Substring($Reference.Length + 1)
        if ($candidate -cmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { $objectId = $candidate }
        $present = $true
        break
    }

    if (-not $present) { return [pscustomobject]@{ Exists = $false; Commit = $null } }
    if (-not $objectId) { return [pscustomobject]@{ Exists = $true; Commit = $null } }

    # Replacement refs can make an absent object read as a commit.
    $verify = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('--no-replace-objects', 'rev-parse', '--verify', '--quiet', "$objectId^{commit}") -NoLazyFetch
    if ($verify.ExitCode -ne 0) { return [pscustomobject]@{ Exists = $true; Commit = $null } }
    $commit = ([string](@($verify.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    return [pscustomobject]@{
        Exists = $true
        Commit = $(if ($commit -ceq $objectId) { $objectId } else { $null })
    }
}

function Get-GitCommonDir {
    param([string]$RepositoryPath)

    $resolvedPath = Resolve-TaskRepositoryPath -Path $RepositoryPath
    $output = & git -C $resolvedPath rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Get-GitDir {
    param([string]$RepositoryPath)

    $resolvedPath = Resolve-TaskRepositoryPath -Path $RepositoryPath
    $output = & git -C $resolvedPath rev-parse --path-format=absolute --git-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Test-TaskWorktreeRegistration {
    param([string]$RepositoryPath, [string]$WorktreePath)

    # A failed `git worktree add` can remove the destination yet leave the
    # worktree registered (for example when a post-checkout hook fails). Ask
    # Git for the registration instead of trusting the directory alone.
    try {
        $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('worktree', 'list', '--porcelain') -NoLazyFetch
    }
    catch { return $null }
    if ($result.ExitCode -ne 0) { return $null }

    $expected = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($WorktreePath))
    foreach ($line in @($result.Output -split "`r?`n")) {
        if ($line -cnotmatch '^worktree (?<path>.+)$') { continue }
        $candidate = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Matches['path']))
        # Case-insensitive on purpose: a false match keeps the marker (fails
        # closed), while a false miss could reopen a mutated destination.
        if ([string]::Equals($candidate, $expected, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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

# A creation marker records that worktree creation for one destination started
# but has not completed. It lives next to the destination inside the scaffold
# owned worktrees container, so no caller task file can ever collide with it.
$script:TaskWorktreeMarkerPrefix = '.ai-task-scaffold-incomplete.'

function Get-TaskWorktreeCreationMarkerPath {
    param([string]$TasksRoot, [string]$TaskKey, [string]$RepositoryName)

    $destination = Get-TaskWorktreeDestination -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $RepositoryName
    return Join-Path (Split-Path -Parent $destination) "$($script:TaskWorktreeMarkerPrefix)$RepositoryName"
}

function New-TaskWorktreeCreationMarker {
    param([string]$Path, [psobject]$Plan, [string]$Branch)

    $sourceCommit = if ($Plan.PSObject.Properties['SourceCommit']) { $Plan.SourceCommit } else { $null }
    $material = [ordered]@{
        markerVersion = 1
        repository = $Plan.Repository
        branch = $Branch
        action = $Plan.Action
        source = $Plan.Source
        sourceCommit = $sourceCommit
        destination = $Plan.Destination
        startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($material | ConvertTo-Json -Compress))
    # Exclusive create: an existing marker means another attempt owns this
    # destination, so it must never be overwritten.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}

function Get-TaskWorktreeMarkerRepository {
    param([string]$Name)

    if ($Name -notmatch '^\.ai-task-scaffold-incomplete\.(?<repository>[A-Za-z0-9][A-Za-z0-9._-]*)$') { return $null }
    return $Matches['repository']
}

function Clear-TaskWorktreeCreationMarkerIfNoWorktree {
    param(
        [string]$Path,
        [string]$Destination,
        [switch]$GitStarted,
        [string]$RepositoryPath,
        [string]$Branch,
        [switch]$BranchCreated
    )

    # A missing destination proves nothing on its own: Git can leave a task
    # branch and/or a worktree registration behind without the directory.
    # Before any Git process starts there is nothing to prove; afterwards the
    # marker may only go when every piece of state reads back as absent. An
    # unreadable state is unknown and keeps the marker.
    if (Test-Path -LiteralPath $Destination) { return }
    if (-not $GitStarted) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }

    if ((Test-TaskWorktreeRegistration -RepositoryPath $RepositoryPath -WorktreePath $Destination) -ne $false) { return }

    if ($BranchCreated) {
        try {
            $branchSnapshot = Get-TaskGitRefCommit -RepositoryPath $RepositoryPath -Reference "refs/heads/$Branch"
        }
        catch { return }
        if ($branchSnapshot.Exists) { return }
    }

    Remove-Item -LiteralPath $Path -Force
}

function Get-TaskRemoteTrackingBranchName {
    param([string]$Reference)

    # refs/remotes/<remote>/<name> -> <name>. Any other start point (a local
    # branch or a bare commit) never auto-tracks a new branch.
    if ($Reference -notmatch '^refs/remotes/[^/]+/(?<name>.+)$') { return $null }
    return $Matches['name']
}

function Get-TaskBranchAutoSetupMerge {
    param([string]$RepositoryPath)

    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--get', 'branch.autoSetupMerge')
    if ($result.ExitCode -eq 1) { return 'true' }
    if ($result.ExitCode -ne 0) {
        throw "cannot read branch.autoSetupMerge for '$RepositoryPath': $(Get-TaskGitDiagnostic -Text $result.Text)"
    }
    $value = ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return 'true' }
    return $value.ToLowerInvariant()
}

function Resolve-TaskSymbolicRef {
    param([string]$RepositoryPath, [string]$Reference)

    # A symbolic start point (a remote's HEAD, or a local alias branch) behaves
    # like its target for tracking: native git records the target ref. Keep the
    # name itself only when it is not symbolic.
    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('symbolic-ref', '-q', $Reference) -NoLazyFetch
    if ($result.ExitCode -eq 0) {
        $target = ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
        if ($target -clike 'refs/*') { return $target }
    }
    return $Reference
}

function Get-TaskRefUpstreamRef {
    param([string]$RepositoryPath, [string]$Reference)

    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('for-each-ref', '--format=%(upstream)', $Reference) -NoLazyFetch
    if ($result.ExitCode -ne 0) {
        throw "cannot read the upstream for '$Reference' in '$RepositoryPath': $(Get-TaskGitDiagnostic -Text $result.Text)"
    }
    $upstream = ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    if ($upstream -clike 'refs/*') { return $upstream }
    return $null
}

function Get-TaskNewBranchUpstreamRef {
    param([string]$RepositoryPath, [string]$Branch, [string]$StartRef)

    # Native `git worktree add -b <branch> <dest> <start>` sets an upstream from
    # the start point according to branch.autoSetupMerge. Applying that decision
    # here keeps native semantics after the start is pinned to a commit.
    if ($StartRef -notlike 'refs/*') { return $null }
    $startRef = Resolve-TaskSymbolicRef -RepositoryPath $RepositoryPath -Reference $StartRef

    $mode = Get-TaskBranchAutoSetupMerge -RepositoryPath $RepositoryPath
    if ($mode -ceq 'inherit') {
        # Copy the start point's tracking configuration, as git itself does.
        return Get-TaskRefUpstreamRef -RepositoryPath $RepositoryPath -Reference $startRef
    }

    $remoteBranch = Get-TaskRemoteTrackingBranchName -Reference $startRef
    if ($mode -ceq 'always') { return $startRef }
    if ($mode -in @('true', '1', 'yes', 'on')) { return $(if ($remoteBranch) { $startRef } else { $null }) }
    if ($mode -in @('false', '0', 'no', 'off')) { return $null }
    if ($mode -ceq 'simple') {
        # `simple` tracks only when the new branch name matches the tracked
        # remote branch name (origin/feature/x -> feature/x).
        return $(if ($remoteBranch -ceq $Branch) { $startRef } else { $null })
    }

    # git itself rejects an unknown value for every command, so planning must
    # fail rather than silently pick a default.
    throw "unsupported branch.autoSetupMerge value '$mode' for '$RepositoryPath'"
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

    $repositoryPath = Resolve-TaskRepositoryPath -Path $Repository.Path
    & git -C $repositoryPath rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "repository '$($Repository.Name)' is not a Git worktree"
    }

    $repositoryCommonDir = Get-GitCommonDir -RepositoryPath $repositoryPath
    $destination = Get-TaskWorktreeDestination -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $Repository.Name
    if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $Repository.Name)) {
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'unsafe-worktree-path'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }
    $startCommit = if ($Repository.PSObject.Properties['StartCommit']) { $Repository.StartCommit } else { $null }
    if ($startCommit) {
        if ((Get-GitCommitWithoutLazyFetch -RepositoryPath $repositoryPath -Reference $startCommit) -cne $startCommit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
    }
    # A marker outlives an interrupted or failed creation. It must win over the
    # destination check: a partially created worktree can look like a healthy
    # one, and reusing it would silently accept a half-applied plan.
    $markerPath = Get-TaskWorktreeCreationMarkerPath -TasksRoot $TasksRoot -TaskKey $TaskKey -RepositoryName $Repository.Name
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'incomplete-worktree-creation'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }
    if (Test-Path -LiteralPath $destination) {
        if (Test-TaskWorktreeIdentity -RepositoryPath $repositoryPath -WorktreePath $destination -Branch $Repository.Branch -ExpectedCommonDir $repositoryCommonDir) {
            $reuseCommit = (Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference "refs/heads/$($Repository.Branch)").Commit
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
        $localSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $localBranchRef
        if ($localSnapshot.Exists) {
            if (-not $localSnapshot.Commit -or $localSnapshot.Commit -cne $startCommit) {
                return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-mismatch'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
            }
            return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $startCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }

        $remoteSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $remoteBranchRef
        if ($remoteSnapshot.Exists) {
            if (-not $remoteSnapshot.Commit -or $remoteSnapshot.Commit -cne $startCommit) {
                return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-mismatch'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
            }
            return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = $remoteBranchRef; BranchMode = 'track'; Repository = $Repository.Name; SourceCommit = $startCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }

        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $startCommit; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $startCommit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $localSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $localBranchRef
    if ($localSnapshot.Exists) {
        if (-not $localSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $localSnapshot.Commit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    # Resolve the remote branch only through its exact ref: the shorthand
    # 'origin/<branch>' resolves a local branch of that name first, and revision
    # DWIM can fall back to a tag named like the full remote ref.
    $remoteSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $remoteBranchRef
    if ($remoteSnapshot.Exists) {
        if (-not $remoteSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = "origin/$($Repository.Branch)"; BranchMode = 'track'; Repository = $Repository.Name; SourceCommit = $remoteSnapshot.Commit; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $localBaseRef = "refs/heads/$($Repository.BaseBranch)"
    $localBaseSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $localBaseRef
    if ($localBaseSnapshot.Exists) {
        if (-not $localBaseSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        # `always` tracks a local start point and `inherit` copies its tracking
        # configuration, so a local base is not always upstream-less.
        $upstreamRef = Get-TaskNewBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch -StartRef $localBaseRef
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.BaseBranch; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $localBaseSnapshot.Commit; UpstreamRef = $upstreamRef; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $remoteBase = if ($Repository.BaseBranch -match '^[^/]+/.+') { $Repository.BaseBranch } else { "origin/$($Repository.BaseBranch)" }
    $remoteBaseRef = "refs/remotes/$remoteBase"
    $remoteBaseSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $remoteBaseRef
    if ($remoteBaseSnapshot.Exists) {
        if (-not $remoteBaseSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        # Starting a new branch from a remote-tracking base normally auto-tracks
        # it. That upstream decision is resolved from branch.autoSetupMerge and
        # bound into the identity, because apply starts from a bare commit.
        $upstreamRef = Get-TaskNewBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch -StartRef $remoteBaseRef
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $remoteBase; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $remoteBaseSnapshot.Commit; UpstreamRef = $upstreamRef; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
}

function New-TaskGitStartInfo {
    param([string]$RepositoryPath, [string[]]$Arguments, [switch]$NoLazyFetch)

    $resolvedPath = Resolve-TaskRepositoryPath -Path $RepositoryPath
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($resolvedPath)
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

$script:TaskGitNoLazyFetchSupport = @{}

function Test-TaskGitNoLazyFetchSupport {
    # Git before 2.45 supports partial clones but ignores GIT_NO_LAZY_FETCH.
    # Probe the global option itself; cache per resolved git executable so a
    # test shim added to PATH is not masked by an earlier real-git result.
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $key = [string]$git.Source
    if ($script:TaskGitNoLazyFetchSupport.ContainsKey($key)) {
        return [bool]$script:TaskGitNoLazyFetchSupport[$key]
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('git')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.ArgumentList.Add('--no-lazy-fetch')
    $startInfo.ArgumentList.Add('--version')
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $standardError = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $process.WaitForExit()
        [void]$standardError.GetAwaiter().GetResult()
        [void]$standardOutput.GetAwaiter().GetResult()
        $supported = $process.ExitCode -eq 0
    }
    finally { $process.Dispose() }
    $script:TaskGitNoLazyFetchSupport[$key] = $supported
    return $supported
}

function Test-TaskGitPartialClone {
    param([string]$RepositoryPath)

    # extensions.partialClone marks a filtered clone; remote.<name>.promisor=true
    # marks a promisor remote. Either can make an object read fetch.
    $extensions = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--get', 'extensions.partialClone')
    if ($extensions.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($extensions.Output)) { return $true }

    $promisors = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--bool', '--get-regexp', '^remote\..*\.promisor$')
    if ($promisors.ExitCode -ne 0) { return $false }
    foreach ($line in @($promisors.Output -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $separator = $line.IndexOfAny([char[]]@(' ', "`t"))
        if ($separator -le 0) { continue }
        $value = $line.Substring($separator + 1).Trim()
        if ($value -ceq 'true') { return $true }
    }
    return $false
}

function Assert-TaskNoLazyFetchAllowed {
    param([string]$RepositoryPath)

    if (Test-TaskGitNoLazyFetchSupport) { return }
    if (-not (Test-TaskGitPartialClone -RepositoryPath $RepositoryPath)) { return }
    throw "repository '$RepositoryPath' is a partial clone, but this Git does not support --no-lazy-fetch (Git 2.45 or later is required); refusing a read-only planning lookup that could fetch a missing object. Upgrade Git or use a full clone."
}

function Invoke-TaskWorktreeGitCommand {
    param([string]$RepositoryPath, [string[]]$Arguments, [switch]$NoLazyFetch)

    if ($NoLazyFetch) { Assert-TaskNoLazyFetchAllowed -RepositoryPath $RepositoryPath }
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
    $repositoryPath = Resolve-TaskRepositoryPath -Path $Repository.Path
    $expectedDestination = Get-TaskWorktreeDestination -TasksRoot $Plan.TasksRoot -TaskKey $Plan.TaskKey -RepositoryName $Repository.Name
    if (-not (Test-TaskPathSafety -TasksRoot $Plan.TasksRoot -TaskKey $Plan.TaskKey -RepositoryName $Repository.Name) -or $Plan.Destination -cne $expectedDestination) {
        throw "refusing unsafe worktree destination '$($Plan.Destination)'"
    }
    if ($Plan.Action -eq 'reuse') {
        if ((Get-GitCommonDir -RepositoryPath $repositoryPath) -cne $Plan.RepositoryCommonDir -or
            -not (Test-TaskWorktreeIdentity -RepositoryPath $repositoryPath -WorktreePath $Plan.Destination -Branch $Plan.Source -ExpectedCommonDir $Plan.RepositoryCommonDir -ExpectedGitDir $Plan.WorktreeGitDir)) {
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
    $markerPath = Get-TaskWorktreeCreationMarkerPath -TasksRoot $Plan.TasksRoot -TaskKey $Plan.TaskKey -RepositoryName $Repository.Name
    try {
        # Durable and exclusive before any Git side effect: an interruption at
        # any later point leaves a marker that blocks a blind retry.
        New-TaskWorktreeCreationMarker -Path $markerPath -Plan $Plan -Branch $Repository.Branch
    }
    catch {
        throw "worktree creation for '$($Repository.Name)' is incomplete at '$($Plan.Destination)'; inspect it and remove '$markerPath' only after recovery: $($_.Exception.Message)"
    }

    try {
        $process = Start-TaskWorktreeGitProcess -RepositoryPath $repositoryPath -Arguments $gitArguments -State $State -Gate $Gate
    }
    catch {
        Clear-TaskWorktreeCreationMarkerIfNoWorktree -Path $markerPath -Destination $Plan.Destination
        throw
    }
    if ($null -eq $process) {
        Clear-TaskWorktreeCreationMarkerIfNoWorktree -Path $markerPath -Destination $Plan.Destination
        return $false
    }
    # Native stderr becomes a terminating error inside a parallel runspace, so
    # capture it here and report it with the failure instead of writing it out.
    try {
        # Drain both streams before the wait so a full pipe buffer cannot block git.
        $standardError = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $process.WaitForExit()
        $gitText = $standardError.GetAwaiter().GetResult() + $standardOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            Clear-TaskWorktreeCreationMarkerIfNoWorktree -Path $markerPath -Destination $Plan.Destination -GitStarted -RepositoryPath $repositoryPath -Branch $Repository.Branch -BranchCreated:$createsBranch
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
            Clear-TaskWorktreeCreationMarkerIfNoWorktree -Path $markerPath -Destination $Plan.Destination -GitStarted -RepositoryPath $repositoryPath -Branch $Repository.Branch -BranchCreated:$createsBranch
            $detail = Get-TaskGitDiagnostic -Text $headResult.Text
            if ($detail) { throw "cannot verify the new worktree HEAD for '$($Repository.Name)': $detail" }
            throw "cannot verify the new worktree HEAD for '$($Repository.Name)'"
        }
        $head = ([string](@($headResult.Output -split "`r?`n") | Select-Object -First 1)).Trim()
        if ($head -cne $sourceCommit) {
            throw "worktree HEAD '$head' for '$($Repository.Name)' is not the reviewed commit '$sourceCommit'"
        }
    }

    # A commit match alone cannot prove the task branch is checked out: a hook
    # can detach HEAD or switch to another branch at the same commit.
    $headRefResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $Plan.Destination -Arguments @('symbolic-ref', '-q', 'HEAD') -NoLazyFetch
    $expectedHeadRef = "refs/heads/$($Repository.Branch)"
    if ($headRefResult.ExitCode -ne 0) {
        throw "worktree for '$($Repository.Name)' has a detached HEAD instead of '$expectedHeadRef'"
    }
    $headRef = ([string](@($headRefResult.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    if ($headRef -cne $expectedHeadRef) {
        throw "worktree HEAD for '$($Repository.Name)' is on '$headRef' instead of '$expectedHeadRef'"
    }

    # A tracking plan always keeps its upstream on the full, unambiguous remote
    # ref. A new branch from a remote-tracking base carries the decision git
    # itself would have made from branch.autoSetupMerge, resolved at plan time
    # and bound into the identity.
    $upstreamRef =
        if ($Plan.Action -eq 'create-remote') { "refs/remotes/origin/$($Repository.Branch)" }
        elseif ($Plan.PSObject.Properties['UpstreamRef'] -and $Plan.UpstreamRef) { [string]$Plan.UpstreamRef }
        else { $null }
    if ($upstreamRef) {
        $upstreamResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $Plan.Destination -Arguments @('branch', "--set-upstream-to=$upstreamRef", $Repository.Branch)
        if ($upstreamResult.ExitCode -ne 0) {
            Clear-TaskWorktreeCreationMarkerIfNoWorktree -Path $markerPath -Destination $Plan.Destination -GitStarted -RepositoryPath $repositoryPath -Branch $Repository.Branch -BranchCreated:$createsBranch
            $detail = Get-TaskGitDiagnostic -Text $upstreamResult.Text
            if ($detail) { throw "git branch --set-upstream-to failed for '$($Repository.Name)': $detail" }
            throw "git branch --set-upstream-to failed for '$($Repository.Name)'"
        }
        $upstreamReadBack = Invoke-TaskWorktreeGitCommand -RepositoryPath $Plan.Destination -Arguments @('for-each-ref', '--format=%(upstream)', "refs/heads/$($Repository.Branch)") -NoLazyFetch
        if ($upstreamReadBack.ExitCode -ne 0) {
            Clear-TaskWorktreeCreationMarkerIfNoWorktree -Path $markerPath -Destination $Plan.Destination -GitStarted -RepositoryPath $repositoryPath -Branch $Repository.Branch -BranchCreated:$createsBranch
            $detail = Get-TaskGitDiagnostic -Text $upstreamReadBack.Text
            if ($detail) { throw "cannot verify the upstream for '$($Repository.Name)': $detail" }
            throw "cannot verify the upstream for '$($Repository.Name)'"
        }
        $actualUpstream = ([string](@($upstreamReadBack.Output -split "`r?`n") | Select-Object -First 1)).Trim()
        if ($actualUpstream -cne $upstreamRef) {
            throw "created branch for '$($Repository.Name)' tracks '$actualUpstream' instead of '$upstreamRef'"
        }
    }

    # Every required check passed; the destination is complete.
    Remove-Item -LiteralPath $markerPath -Force
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
        if (-not $key) { $key = Resolve-TaskRepositoryPath -Path $item.Repository.Path }
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

Export-ModuleMember -Function Enter-TaskMutationLock, Resolve-TaskRepositoryPath, Get-GitCommitWithoutLazyFetch, Get-TaskGitRefCommit, Invoke-TaskWorktreeGitCommand, Get-GitCommonDir, Get-GitDir, Test-TaskWorktreeIdentity, Test-TaskWorktreeOperationSafety, Test-TaskPathSafety, New-TaskWorktreePlan, Invoke-TaskWorktreePlan, Get-TaskWorktreeConcurrencyLimit, Invoke-TaskWorktreePlanItem, Invoke-TaskWorktreePlanBatch, Start-TaskWorktreeGitProcess, Set-TaskWorktreeFailure, Get-TaskWorktreeMarkerRepository

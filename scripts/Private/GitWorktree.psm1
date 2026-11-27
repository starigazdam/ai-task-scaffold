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
    # Absence needs every signal: show-ref exit 1, symbolic-ref exit 1, no
    # listing row, and no for-each-ref warning. A malformed loose ref or a
    # cyclic symref must stay present-but-unreadable, never fall through to
    # another ref.
    $presence = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('show-ref', '--verify', '--quiet', $Reference) -NoLazyFetch
    $symbolic = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('symbolic-ref', '-q', $Reference) -NoLazyFetch

    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('for-each-ref', '--format=%(refname) %(objectname)', $Reference) -NoLazyFetch
    if ($result.ExitCode -ne 0) {
        throw "cannot read ref '$Reference' in '$RepositoryPath': $(Get-TaskGitDiagnostic -Text $result.Text)"
    }

    $objectId = $null
    $listed = $false
    foreach ($line in @($result.Output -split "`r?`n")) {
        if (-not $line.StartsWith("$Reference ", [StringComparison]::Ordinal)) { continue }
        # Fixed-width parse: the remainder is exactly one raw object ID, never a
        # decorated or trimmed value.
        $candidate = $line.Substring($Reference.Length + 1)
        if ($candidate -cmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { $objectId = $candidate }
        $listed = $true
        break
    }

    $warned = -not [string]::IsNullOrWhiteSpace($result.Error)
    if ($presence.ExitCode -eq 0 -or $symbolic.ExitCode -eq 0 -or $listed) {
        $present = $true
    }
    elseif ($presence.ExitCode -eq 1 -and $symbolic.ExitCode -eq 1 -and -not $warned) {
        $present = $false
    }
    else {
        # Another exit code, or a warning with an omitted row: present but
        # unreadable. Callers fail closed instead of resolving a different ref.
        $present = $true
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

function Get-TaskImmediateHeadRef {
    param([string]$RepositoryPath)

    # Reuse, create, and teardown all decide on HEAD's immediate target: a task
    # branch may itself be a symbolic alias, and a recursive read would compare
    # the alias's target instead. Git without --no-recurse cannot answer that
    # question, so it fails closed rather than resolving recursively.
    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('symbolic-ref', '-q', '--no-recurse', 'HEAD') -NoLazyFetch
    if ($result.ExitCode -eq 0) {
        return ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    }
    if ($result.Text -match 'unknown option|unrecognized option') {
        throw "cannot read the immediate HEAD target in '$RepositoryPath': this Git does not support 'symbolic-ref --no-recurse'; refusing to resolve HEAD recursively (Git 2.46 or later is required)"
    }
    return $null
}

function Resolve-TaskRefTarget {
    param([string]$RepositoryPath, [string]$Reference)

    # An upstream may be spelled as a symbolic remote ref (origin/HEAD, or a
    # symbolic remote task ref). Git stores and reads it back as its target, so
    # comparisons must use the resolved ref name, never the literal spelling.
    $current = $Reference
    for ($depth = 0; $depth -lt 8; $depth++) {
        $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('symbolic-ref', '-q', $current) -NoLazyFetch
        if ($result.ExitCode -ne 0) { break }
        $target = ([string](@($result.Output -split "`r?`n") | Select-Object -First 1)).Trim()
        if ($target -cnotlike 'refs/*' -or $target -ceq $current) { break }
        $current = $target
    }
    return $current
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
    # HEAD's immediate target, not a recursive alias resolution: the worktree
    # belongs to the task only when the checked-out branch is the requested one.
    $worktreeHeadRef = $null
    try { $worktreeHeadRef = Get-TaskImmediateHeadRef -RepositoryPath $WorktreePath }
    catch { return $false }
    return $repositoryCommonDir -and $repositoryCommonDir -ceq $worktreeCommonDir -and $worktreeGitDir -ceq $expectedWorktreeGitDir -and $worktreeHeadRef -ceq "refs/heads/$Branch"
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
    $raw = [string](@($result.Output -split "`r?`n") | Select-Object -First 1)
    # An explicitly empty value is boolean false to Git, not the implicit default.
    if ($raw -ceq '') { return 'false' }
    return $raw.Trim().ToLowerInvariant()
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

function Get-TaskExistingBranchUpstreamRef {
    param([string]$RepositoryPath, [string]$Branch)

    # An existing task branch should track the task's remote ref when that ref is
    # readable: that is the upstream a tracking add would have set, so a retry
    # can repair a lost or wrong one. Otherwise keep whatever the branch already
    # tracks, and expect nothing when it tracks nothing.
    $remoteRef = "refs/remotes/origin/$Branch"
    try {
        $remote = Get-TaskGitRefCommit -RepositoryPath $RepositoryPath -Reference $remoteRef
        if ($remote.Exists -and $remote.Commit) { return $remoteRef }
    }
    catch { }
    try { return Get-TaskRefUpstreamRef -RepositoryPath $RepositoryPath -Reference "refs/heads/$Branch" }
    catch { return $null }
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
    if (Test-Path -LiteralPath $destination) {
        # Reuse is proved at reuse time: the destination is this repository's
        # worktree, on the requested branch, with a readable branch tip. The
        # branch tip is bound into the plan, so apply can verify it later.
        if (-not (Test-TaskWorktreeIdentity -RepositoryPath $repositoryPath -WorktreePath $destination -Branch $Repository.Branch -ExpectedCommonDir $repositoryCommonDir)) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'destination-exists'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        $reuseSnapshot = $null
        try {
            $reuseSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference "refs/heads/$($Repository.Branch)"
        }
        catch { $reuseSnapshot = $null }
        if (-not $reuseSnapshot -or -not $reuseSnapshot.Exists -or -not $reuseSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'reuse-unreadable'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        return [pscustomobject]@{ Action = 'reuse'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $reuseSnapshot.Commit; UpstreamRef = (Get-TaskExistingBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch); RepositoryCommonDir = $repositoryCommonDir; WorktreeGitDir = (Get-GitDir -RepositoryPath $destination); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
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
            return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $startCommit; UpstreamRef = (Get-TaskExistingBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
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
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $localSnapshot.Commit; UpstreamRef = (Get-TaskExistingBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
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
            Error = $errorText
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

function Assert-TaskWorktreeBranchState {
    param(
        [string]$RepositoryName,
        [string]$WorktreePath,
        [string]$Branch,
        [string]$ExpectedCommit,
        [string]$UpstreamRef,
        [switch]$RepairUpstream
    )

    # Branch tip first: the branch must be at the reviewed commit, read exactly.
    $expectedHeadRef = "refs/heads/$Branch"
    $tip = $null
    try { $tip = Get-TaskGitRefCommit -RepositoryPath $WorktreePath -Reference $expectedHeadRef }
    catch { $tip = $null }
    if (-not $tip -or -not $tip.Exists -or -not $tip.Commit) {
        throw "cannot verify the branch tip '$expectedHeadRef' for '$RepositoryName' at '$WorktreePath'"
    }
    if ($ExpectedCommit -and $tip.Commit -cne $ExpectedCommit) {
        throw "branch '$Branch' tip '$($tip.Commit)' for '$RepositoryName' is not the reviewed commit '$ExpectedCommit'"
    }

    $headRef = Get-TaskImmediateHeadRef -RepositoryPath $WorktreePath
    if (-not $headRef) {
        throw "worktree for '$RepositoryName' has a detached HEAD instead of '$expectedHeadRef'"
    }
    if ($headRef -cne $expectedHeadRef) {
        throw "worktree HEAD for '$RepositoryName' is on '$headRef' instead of '$expectedHeadRef'"
    }

    if (-not $UpstreamRef) { return }

    $readBack = Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('for-each-ref', '--format=%(upstream)', $expectedHeadRef) -NoLazyFetch
    if ($readBack.ExitCode -ne 0) {
        throw "cannot verify the upstream for '$RepositoryName': $(Get-TaskGitDiagnostic -Text $readBack.Text)"
    }
    $actualUpstream = ([string](@($readBack.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    if ((Resolve-TaskRefTarget -RepositoryPath $WorktreePath -Reference $actualUpstream) -ceq
        (Resolve-TaskRefTarget -RepositoryPath $WorktreePath -Reference $UpstreamRef)) {
        return
    }
    if (-not $RepairUpstream) {
        throw "branch '$Branch' for '$RepositoryName' tracks '$actualUpstream' instead of '$UpstreamRef'"
    }

    $setResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('branch', "--set-upstream-to=$UpstreamRef", $Branch)
    if ($setResult.ExitCode -ne 0) {
        $detail = Get-TaskGitDiagnostic -Text $setResult.Text
        if ($detail) { throw "git branch --set-upstream-to failed for '$RepositoryName': $detail" }
        throw "git branch --set-upstream-to failed for '$RepositoryName'"
    }
    $readBack = Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('for-each-ref', '--format=%(upstream)', $expectedHeadRef) -NoLazyFetch
    if ($readBack.ExitCode -ne 0) {
        throw "cannot verify the upstream for '$RepositoryName': $(Get-TaskGitDiagnostic -Text $readBack.Text)"
    }
    $actualUpstream = ([string](@($readBack.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    if ((Resolve-TaskRefTarget -RepositoryPath $WorktreePath -Reference $actualUpstream) -cne
        (Resolve-TaskRefTarget -RepositoryPath $WorktreePath -Reference $UpstreamRef)) {
        throw "branch '$Branch' for '$RepositoryName' tracks '$actualUpstream' instead of '$UpstreamRef'"
    }
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
        $reuseCommit = if ($Plan.PSObject.Properties['SourceCommit']) { [string]$Plan.SourceCommit } else { $null }
        if ([string]::IsNullOrWhiteSpace($reuseCommit)) {
            throw "cannot verify the reused worktree for '$($Repository.Name)': no reviewed branch tip was bound"
        }
        $reuseUpstream =
            if ($Plan.PSObject.Properties['UpstreamRef'] -and $Plan.UpstreamRef) { [string]$Plan.UpstreamRef }
            else { $null }
        # The branch tip and the immediate HEAD target must already be right; the
        # only repairable mismatch is a lost or wrong upstream. A retry after a
        # failed attach or set-upstream therefore heals instead of stranding.
        Assert-TaskWorktreeBranchState -RepositoryName $Repository.Name -WorktreePath $Plan.Destination -Branch $Plan.Source -ExpectedCommit $reuseCommit -UpstreamRef $reuseUpstream -RepairUpstream
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
    $process = Start-TaskWorktreeGitProcess -RepositoryPath $repositoryPath -Arguments $gitArguments -State $State -Gate $Gate
    if ($null -eq $process) {
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
            $detail = Get-TaskGitDiagnostic -Text $gitText
            if ($detail) { throw "git worktree add failed for '$($Repository.Name)': $detail" }
            throw "git worktree add failed for '$($Repository.Name)'"
        }
    }
    finally {
        $process.Dispose()
    }

    # A tracking plan always keeps its upstream on the full, unambiguous remote
    # ref. A new branch from a remote-tracking base carries the decision git
    # itself would have made from branch.autoSetupMerge, resolved at plan time
    # and bound into the identity. An attach plan expects the task's remote ref
    # when it exists, so a failed tracking add is repaired on retry.
    $upstreamRef =
        if ($Plan.Action -eq 'create-remote') { "refs/remotes/origin/$($Repository.Branch)" }
        elseif ($Plan.PSObject.Properties['UpstreamRef'] -and $Plan.UpstreamRef) { [string]$Plan.UpstreamRef }
        else { $null }
    Assert-TaskWorktreeBranchState -RepositoryName $Repository.Name -WorktreePath $Plan.Destination -Branch $Repository.Branch -ExpectedCommit $sourceCommit -UpstreamRef $upstreamRef -RepairUpstream
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

Export-ModuleMember -Function Enter-TaskMutationLock, Resolve-TaskRepositoryPath, Get-GitCommitWithoutLazyFetch, Get-TaskGitRefCommit, Invoke-TaskWorktreeGitCommand, Get-GitCommonDir, Get-GitDir, Get-TaskImmediateHeadRef, Test-TaskWorktreeIdentity, Test-TaskWorktreeOperationSafety, Test-TaskPathSafety, New-TaskWorktreePlan, Invoke-TaskWorktreePlan, Get-TaskWorktreeConcurrencyLimit, Invoke-TaskWorktreePlanItem, Invoke-TaskWorktreePlanBatch, Start-TaskWorktreeGitProcess, Set-TaskWorktreeFailure

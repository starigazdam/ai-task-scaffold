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

    # Use Git's own boolean parser for the boolean spellings. It distinguishes a
    # bare key (true) from an explicitly empty value (false), which a raw read
    # cannot. The string modes simple/always/inherit are not booleans, so Git
    # exits with a bad-value error and we fall back to the raw string below.
    $boolean = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--type=bool', '--get', 'branch.autoSetupMerge')
    if ($boolean.ExitCode -eq 0) {
        $parsed = ([string](@($boolean.Output -split "`r?`n") | Select-Object -First 1)).Trim().ToLowerInvariant()
        if ($parsed -ceq 'true') { return 'true' }
        if ($parsed -ceq 'false') { return 'false' }
    }
    elseif ($boolean.ExitCode -eq 1) {
        # Unset keeps Git's default, which tracks a remote-tracking start point.
        return 'true'
    }

    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--get', 'branch.autoSetupMerge')
    if ($result.ExitCode -eq 1) { return 'true' }
    if ($result.ExitCode -ne 0) {
        throw "cannot read branch.autoSetupMerge for '$RepositoryPath': $(Get-TaskGitDiagnostic -Text $result.Text)"
    }
    $raw = [string](@($result.Output -split "`r?`n") | Select-Object -First 1)
    # An explicitly empty value is boolean false to Git, not the implicit default.
    if ($raw.Trim() -ceq '') { return 'false' }
    return $raw.Trim().ToLowerInvariant()
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
    # A symbolic start point resolves to its canonical target, which is what Git
    # stores and reads back as the upstream.
    $startRef = Resolve-TaskRefTarget -RepositoryPath $RepositoryPath -Reference $StartRef

    $mode = Get-TaskBranchAutoSetupMerge -RepositoryPath $RepositoryPath
    $upstream = $null
    if ($mode -ceq 'inherit') {
        # Copy the start point's tracking configuration, as git itself does.
        $upstream = Get-TaskRefUpstreamRef -RepositoryPath $RepositoryPath -Reference $startRef
    }
    else {
        $remoteBranch = Get-TaskRemoteTrackingBranchName -Reference $startRef
        if ($mode -ceq 'always') { $upstream = $startRef }
        elseif ($mode -in @('true', '1', 'yes', 'on')) { $upstream = $(if ($remoteBranch) { $startRef } else { $null }) }
        elseif ($mode -in @('false', '0', 'no', 'off')) { $upstream = $null }
        elseif ($mode -ceq 'simple') {
            # `simple` tracks only when the new branch name matches the tracked
            # remote branch name (origin/feature/x -> feature/x).
            $upstream = $(if ($remoteBranch -ceq $Branch) { $startRef } else { $null })
        }
        else {
            # git itself rejects an unknown value for every command, so planning
            # must fail rather than silently pick a default.
            throw "unsupported branch.autoSetupMerge value '$mode' for '$RepositoryPath'"
        }
    }
    if (-not $upstream) { return $null }
    return Resolve-TaskRefTarget -RepositoryPath $RepositoryPath -Reference $upstream
}

function Get-TaskInheritedUpstreamConfig {
    param([string]$RepositoryPath, [string]$StartRef)

    # Native `inherit` copies the start branch's branch.<name>.remote and
    # branch.<name>.merge values as written. A symbolic upstream such as
    # origin/alias stays symbolic, so rebuilding the values from the canonical
    # target would change what the branch follows. Only a local start branch
    # has this configuration; several merge values stay a #29 limit.
    if ((Get-TaskBranchAutoSetupMerge -RepositoryPath $RepositoryPath) -cne 'inherit') { return $null }
    # Read the branch that Get-TaskNewBranchUpstreamRef reads: the canonical
    # start, not a symbolic alias with its own configuration.
    $startRef = Resolve-TaskRefTarget -RepositoryPath $RepositoryPath -Reference $StartRef
    if (-not $startRef.StartsWith('refs/heads/', [StringComparison]::Ordinal)) { return $null }
    $name = $startRef.Substring('refs/heads/'.Length)
    $values = @{}
    foreach ($key in @('remote', 'merge')) {
        $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--get', "branch.$name.$key")
        if ($result.ExitCode -eq 1) { return $null }
        if ($result.ExitCode -ne 0) {
            throw "cannot read branch.$name.$key for '$RepositoryPath': $(Get-TaskGitDiagnostic -Text $result.Text)"
        }
        $values[$key] = ([string]$result.Output) -replace '\r?\n\z', ''
    }
    return [pscustomobject]@{ Remote = $values['remote']; Merge = $values['merge'] }
}

function Get-TaskBranchUpstreamRef {
    param([string]$RepositoryPath, [string]$Branch)

    # The branch's actual upstream, canonicalized, or none. Never invented from a
    # same-named remote ref: reuse and attach verify exactly what the branch
    # tracks. Reuse passes the destination so a worktree-local upstream
    # (extensions.worktreeConfig) is read from where apply reads it. Attach
    # passes the source because `git worktree add` copies the source
    # worktree's config.worktree into the new worktree, so both read the same
    # effective config.
    $current = Get-TaskRefUpstreamRef -RepositoryPath $RepositoryPath -Reference "refs/heads/$Branch"
    if (-not $current) { return $null }
    return Resolve-TaskRefTarget -RepositoryPath $RepositoryPath -Reference $current
}

function Get-TaskWorktreeConfigPath {
    param([string]$RepositoryPath)

    # Decode strictly: a path byte that is not UTF-8 would otherwise become
    # U+FFFD and name a different file, so fail closed. A literal U+FFFD in a
    # valid UTF-8 path stays valid.
    $startInfo = New-TaskGitStartInfo -RepositoryPath $RepositoryPath -Arguments @('rev-parse', '--path-format=absolute', '--git-path', 'config.worktree')
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $standardError = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $process.WaitForExit()
        [void]$standardError.GetAwaiter().GetResult()
        try { $output = $standardOutput.GetAwaiter().GetResult() }
        catch [System.Text.DecoderFallbackException] {
            throw "cannot read the worktree config path for '$RepositoryPath': Git returned a path that is not valid UTF-8"
        }
        if ($process.ExitCode -ne 0) { return $null }
    }
    finally { $process.Dispose() }
    # Remove only Git's final line terminator: a path can contain a newline.
    return ([string]$output) -replace '\r?\n\z', ''
}

function Get-TaskWorktreeConfigInclude {
    param([string]$RepositoryPath)

    # `git worktree add` copies the source worktree's config.worktree into the
    # new worktree. Any include in that file can resolve differently there: a
    # relative path resolves against the new file, and an includeIf condition
    # (onbranch, gitdir) sees the new worktree. The planner does not emulate
    # Git's include resolution: it scans the file Git copies and reports the
    # first include key. The file is scanned whatever extensions.worktreeConfig
    # says, so a stale file blocks too; that is a conservative refusal.
    $path = Get-TaskWorktreeConfigPath -RepositoryPath $RepositoryPath
    if (-not $path) { throw "cannot resolve the worktree config path for '$RepositoryPath'" }
    # A native check: Test-Path treats a backslash in a Linux path as a separator.
    if (-not [IO.File]::Exists($path)) { return $null }
    $result = Invoke-TaskWorktreeGitCommand -RepositoryPath $RepositoryPath -Arguments @('config', '--file', $path, '--null', '--name-only', '--get-regexp', '^include(if\..*)?\.path$')
    if ($result.ExitCode -eq 1) { return $null }
    if ($result.ExitCode -ne 0) {
        throw "cannot read the worktree config includes in '$path': $(Get-TaskGitDiagnostic -Text $result.Text)"
    }
    $key = @($result.Output -split "`0" | Where-Object { $_ }) | Select-Object -First 1
    if (-not $key) { return $null }
    return [pscustomobject]@{ Path = $path; Key = $key }
}

function New-TaskWorktreeAttachBlock {
    param(
        [Parameter(Mandatory)][psobject]$Repository,
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$TaskKey,
        [Parameter(Mandatory)][string]$TasksRoot
    )

    $include = Get-TaskWorktreeConfigInclude -RepositoryPath $RepositoryPath
    if (-not $include) { return $null }
    return [pscustomobject]@{
        Action = 'blocked'
        Destination = $Destination
        Reason = 'worktree-config-include'
        Repository = $Repository.Name
        SourceCommit = $null
        TaskKey = $TaskKey
        TasksRoot = $TasksRoot
        Message = "the worktree config '$($include.Path)' has '$($include.Key)'; git worktree add copies that file into the new worktree, where the include can resolve differently, so the inherited upstream cannot be verified before attach; move it to the shared repository config as an unconditional include, or remove it"
    }
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
        $reuseHeadRef = $null
        try { $reuseHeadRef = Get-TaskImmediateHeadRef -RepositoryPath $destination }
        catch { $reuseHeadRef = $null }
        if (-not $reuseHeadRef -or $reuseHeadRef -cne "refs/heads/$($Repository.Branch)") {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'reuse-unreadable'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        # The plan binds the captured tip, the immediate HEAD target, the
        # canonical upstream (or its absence) and the selected ref's canonical
        # target. The upstream is read from the destination, not the repository:
        # with extensions.worktreeConfig a worktree-local
        # branch.<branch>.remote/merge is the upstream that apply will verify.
        # Apply compares the live values against these, so a reviewed plan
        # cannot silently accept a different checkout.
        return [pscustomobject]@{ Action = 'reuse'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $reuseSnapshot.Commit; HeadRef = $reuseHeadRef; UpstreamRef = (Get-TaskBranchUpstreamRef -RepositoryPath $destination -Branch $Repository.Branch); SourceTarget = (Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference "refs/heads/$($Repository.Branch)"); RepositoryCommonDir = $repositoryCommonDir; WorktreeGitDir = (Get-GitDir -RepositoryPath $destination); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
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
            # Attach an existing task branch with the upstream the new destination
            # actually inherits, including none. `git worktree add` copies the
            # source worktree's config.worktree into the new worktree (see
            # copy_filtered_worktree_config in Git's builtin/worktree.c), so the
            # effective upstream at the source is what apply will read at the
            # destination; the shared config alone would be wrong when the source
            # has a worktree-local override. A same-named origin/<branch> ref is
            # not evidence that a tracking create was interrupted, so never infer
            # one. A relative include.path cannot survive that copy, so it blocks
            # before any worktree is created instead of leaving apply to fail.
            $attachBlock = New-TaskWorktreeAttachBlock -Repository $Repository -RepositoryPath $repositoryPath -Destination $destination -TaskKey $TaskKey -TasksRoot $TasksRoot
            if ($attachBlock) { return $attachBlock }
            return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $startCommit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = (Get-TaskBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch); SourceTarget = (Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference $localBranchRef); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }

        $remoteSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $remoteBranchRef
        if ($remoteSnapshot.Exists) {
            if (-not $remoteSnapshot.Commit -or $remoteSnapshot.Commit -cne $startCommit) {
                return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-mismatch'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
            }
            # Explicit tracking: a remote task ref is tracked regardless of
            # branch.autoSetupMerge, matching the native `worktree add --track`
            # this operation replaces. The upstream is the canonical target
            # resolved at plan time, bound so apply never re-resolves it.
            $remoteTarget = Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference $remoteBranchRef
            return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = $remoteBranchRef; BranchMode = 'track'; Repository = $Repository.Name; SourceCommit = $startCommit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = $remoteTarget; SourceTarget = $remoteTarget; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }

        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $startCommit; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $startCommit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = $null; SourceTarget = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $localSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $localBranchRef
    if ($localSnapshot.Exists) {
        if (-not $localSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        # Attach an existing task branch with the upstream the new destination
        # inherits, including none. Git copies the source worktree's
        # config.worktree on add, so the source's effective upstream is the
        # destination's; a matching origin/<branch> is never inferred as tracking.
        # A relative include.path cannot survive that copy, so it blocks before
        # any worktree is created instead of leaving apply to fail.
        $attachBlock = New-TaskWorktreeAttachBlock -Repository $Repository -RepositoryPath $repositoryPath -Destination $destination -TaskKey $TaskKey -TasksRoot $TasksRoot
        if ($attachBlock) { return $attachBlock }
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.Branch; BranchMode = 'existing'; Repository = $Repository.Name; SourceCommit = $localSnapshot.Commit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = (Get-TaskBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch); SourceTarget = (Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference $localBranchRef); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    # Resolve the remote branch only through its exact ref: the shorthand
    # 'origin/<branch>' resolves a local branch of that name first, and revision
    # DWIM can fall back to a tag named like the full remote ref.
    $remoteSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $remoteBranchRef
    if ($remoteSnapshot.Exists) {
        if (-not $remoteSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'start-commit-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        # Explicit tracking, same as the pinned create-remote path above.
        $remoteTarget = Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference $remoteBranchRef
        return [pscustomobject]@{ Action = 'create-remote'; Destination = $destination; Source = "origin/$($Repository.Branch)"; BranchMode = 'track'; Repository = $Repository.Name; SourceCommit = $remoteSnapshot.Commit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = $remoteTarget; SourceTarget = $remoteTarget; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
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
        $upstreamConfig = if ($upstreamRef) { Get-TaskInheritedUpstreamConfig -RepositoryPath $repositoryPath -StartRef $localBaseRef } else { $null }
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $Repository.BaseBranch; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $localBaseSnapshot.Commit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = $upstreamRef; UpstreamConfig = $upstreamConfig; SourceTarget = (Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference $localBaseRef); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
    }

    $remoteBase = if ($Repository.BaseBranch -match '^[^/]+/.+') { $Repository.BaseBranch } else { "origin/$($Repository.BaseBranch)" }
    $remoteBaseRef = "refs/remotes/$remoteBase"
    $remoteBaseSnapshot = Get-TaskGitRefCommit -RepositoryPath $repositoryPath -Reference $remoteBaseRef
    if ($remoteBaseSnapshot.Exists) {
        if (-not $remoteBaseSnapshot.Commit) {
            return [pscustomobject]@{ Action = 'blocked'; Destination = $destination; Reason = 'base-branch-missing'; Repository = $Repository.Name; SourceCommit = $null; TaskKey = $TaskKey; TasksRoot = $TasksRoot }
        }
        # Starting a new branch from a remote-tracking base normally auto-tracks
        # it. That implicit upstream decision is resolved from
        # branch.autoSetupMerge and bound into the identity, because apply starts
        # from a bare commit.
        $upstreamRef = Get-TaskNewBranchUpstreamRef -RepositoryPath $repositoryPath -Branch $Repository.Branch -StartRef $remoteBaseRef
        return [pscustomobject]@{ Action = 'create-local'; Destination = $destination; Source = $remoteBase; BranchMode = 'new'; Repository = $Repository.Name; SourceCommit = $remoteBaseSnapshot.Commit; HeadRef = "refs/heads/$($Repository.Branch)"; UpstreamRef = $upstreamRef; SourceTarget = (Resolve-TaskRefTarget -RepositoryPath $repositoryPath -Reference $remoteBaseRef); TaskKey = $TaskKey; TasksRoot = $TasksRoot }
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

function Get-TaskCanonicalBranchUpstream {
    param([string]$RepositoryName, [string]$WorktreePath, [string]$HeadRef)

    # The live upstream, canonicalized through the current ref graph; none when
    # the branch tracks nothing. This is always the live side of a comparison.
    $readBack = Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('for-each-ref', '--format=%(upstream)', $HeadRef) -NoLazyFetch
    if ($readBack.ExitCode -ne 0) {
        throw "cannot verify the upstream for '$RepositoryName': $(Get-TaskGitDiagnostic -Text $readBack.Text)"
    }
    $actualUpstream = ([string](@($readBack.Output -split "`r?`n") | Select-Object -First 1)).Trim()
    if (-not $actualUpstream) { return $null }
    return Resolve-TaskRefTarget -RepositoryPath $WorktreePath -Reference $actualUpstream
}

function Get-TaskVerifiedBranchState {
    param(
        [string]$RepositoryName,
        [string]$WorktreePath,
        [string]$Branch,
        [string]$ExpectedCommit,
        [string]$ExpectedHeadRef
    )

    # Branch tip first: the branch must be at the commit the plan bound, read
    # exactly. A live tip that differs from the reviewed plan is a replan case.
    $tip = $null
    try { $tip = Get-TaskGitRefCommit -RepositoryPath $WorktreePath -Reference "refs/heads/$Branch" }
    catch { $tip = $null }
    if (-not $tip -or -not $tip.Exists -or -not $tip.Commit) {
        throw "cannot verify the branch tip 'refs/heads/$Branch' for '$RepositoryName' at '$WorktreePath'"
    }
    if ($ExpectedCommit -and $tip.Commit -cne $ExpectedCommit) {
        throw "branch '$Branch' tip '$($tip.Commit)' for '$RepositoryName' is not the planned commit '$ExpectedCommit'; replan and approve again"
    }

    # HEAD's immediate target must equal the ref the plan bound, never merely
    # resolve to it through an alias chain.
    $headRef = Get-TaskImmediateHeadRef -RepositoryPath $WorktreePath
    if (-not $headRef) {
        throw "worktree for '$RepositoryName' has a detached HEAD instead of '$ExpectedHeadRef'"
    }
    if ($headRef -cne $ExpectedHeadRef) {
        throw "worktree HEAD for '$RepositoryName' is on '$headRef' instead of the planned '$ExpectedHeadRef'; replan and approve again"
    }

    return (Get-TaskCanonicalBranchUpstream -RepositoryName $RepositoryName -WorktreePath $WorktreePath -HeadRef $ExpectedHeadRef)
}

function Assert-TaskWorktreeBranchState {
    param(
        [string]$RepositoryName,
        [string]$WorktreePath,
        [string]$Branch,
        [string]$ExpectedCommit,
        [string]$UpstreamRef,
        [string]$ExpectedHeadRef,
        [switch]$RepairUpstream,
        [switch]$UpstreamMustExist,
        [psobject]$UpstreamConfig
    )

    $expectedHeadRef = if ($ExpectedHeadRef) { $ExpectedHeadRef } else { "refs/heads/$Branch" }
    # The planned upstream is the canonical name captured at plan time. It is
    # compared as stored; re-resolving it here would let a post-plan symref
    # retarget change the expected value along with the live one.
    $expectedUpstream = if ($UpstreamRef) { $UpstreamRef } else { $null }
    $actualCanonical = Get-TaskVerifiedBranchState -RepositoryName $RepositoryName -WorktreePath $WorktreePath -Branch $Branch -ExpectedCommit $ExpectedCommit -ExpectedHeadRef $expectedHeadRef
    if ($actualCanonical -ceq $expectedUpstream) { return }

    if (-not $expectedUpstream) {
        throw "branch '$Branch' for '$RepositoryName' tracks '$actualCanonical' but the plan expects no upstream; replan and approve again"
    }
    if ($actualCanonical) {
        throw "branch '$Branch' for '$RepositoryName' tracks '$actualCanonical' instead of the planned '$UpstreamRef'; replan and approve again (a nonempty upstream is never retargeted)"
    }
    if (-not $RepairUpstream) {
        throw "branch '$Branch' for '$RepositoryName' is missing its required upstream '$UpstreamRef'; set the upstream by hand and replan, or replan to accept no upstream (attach and reuse never write an upstream)"
    }

    # Repair is limited to the one safe direction: a required upstream is absent.
    # The guard re-read is best effort, not a lock: it runs in a separate Git
    # command, so an external writer can still land between the read and the
    # write. The post-write verification below detects a mismatch that remains
    # visible after the write; it cannot detect an external overwrite that
    # replaced the upstream with exactly the planned value.
    $guard = Get-TaskCanonicalBranchUpstream -RepositoryName $RepositoryName -WorktreePath $WorktreePath -HeadRef $expectedHeadRef
    if ($guard) {
        throw "branch '$Branch' for '$RepositoryName' acquired upstream '$guard' while apply was preparing to set '$UpstreamRef'; replan and approve again"
    }
    # `git branch --set-upstream-to` resolves its argument with ref DWIM, so a
    # tag spelled like the full remote ref makes it ambiguous. Check the exact
    # ref, then write branch.<name>.remote/merge directly under the default
    # fetch mapping; the post-write verification proves the mapping (#29).
    # The existence check applies when the upstream is the start ref itself:
    # the plan read that ref, so its absence means it was pruned after the
    # plan. An inherit upstream is copied configuration, and native Git copies
    # it even when the ref is already gone.
    $exists = if ($UpstreamMustExist) { Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('show-ref', '--verify', '--quiet', $UpstreamRef) } else { $null }
    if ($exists -and $exists.ExitCode -ne 0) {
        throw "cannot set upstream for '$RepositoryName': the planned upstream '$UpstreamRef' does not exist; replan and approve again"
    }
    if ($UpstreamConfig) {
        # An inherited upstream is written exactly as the start branch has it.
        $remote = [string]$UpstreamConfig.Remote
        $merge = [string]$UpstreamConfig.Merge
    }
    elseif ($UpstreamRef.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
        $remote = '.'
        $merge = $UpstreamRef
    }
    else {
        $remotes = Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('remote')
        $matching = @(@($remotes.Output -split "`r?`n") | Where-Object { $_ -and $UpstreamRef.StartsWith("refs/remotes/$_/", [StringComparison]::Ordinal) })
        if ($remotes.ExitCode -ne 0 -or $matching.Count -ne 1) {
            throw "cannot set upstream for '$RepositoryName': no single remote maps to '$UpstreamRef'; replan and approve again"
        }
        $remote = $matching[0]
        $merge = 'refs/heads/' + $UpstreamRef.Substring("refs/remotes/$remote/".Length)
    }
    foreach ($entry in @(@('remote', $remote), @('merge', $merge))) {
        # --replace-all: an absent upstream can still leave several values of
        # one key, and plain `git config` refuses to overwrite them.
        $setResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $WorktreePath -Arguments @('config', '--replace-all', "branch.$Branch.$($entry[0])", $entry[1])
        if ($setResult.ExitCode -ne 0) {
            $detail = Get-TaskGitDiagnostic -Text $setResult.Text
            throw "cannot set upstream for '$RepositoryName': git config branch.$Branch.$($entry[0]) failed: $detail"
        }
    }

    # Re-verify the tip, immediate HEAD target and upstream after the write; the
    # gate may release only once this finishes.
    $afterWrite = Get-TaskVerifiedBranchState -RepositoryName $RepositoryName -WorktreePath $WorktreePath -Branch $Branch -ExpectedCommit $ExpectedCommit -ExpectedHeadRef $expectedHeadRef
    if ($afterWrite -cne $expectedUpstream) {
        throw "branch '$Branch' for '$RepositoryName' tracks '$afterWrite' instead of the planned '$UpstreamRef' after the upstream write; replan and approve again"
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
        # A queued reuse is a mutation admission point even though verification
        # writes nothing: after a failure is published it must not run. A reuse
        # that already reached this point finishes, so the gate is released as
        # soon as admission is decided.
        if ($State -and $Gate) {
            $Gate.Wait()
            try {
                if ($State.Failed) { return $false }
            }
            finally { [void]$Gate.Release() }
        }
        if ((Get-GitCommonDir -RepositoryPath $repositoryPath) -cne $Plan.RepositoryCommonDir -or
            -not (Test-TaskWorktreeIdentity -RepositoryPath $repositoryPath -WorktreePath $Plan.Destination -Branch $Plan.Source -ExpectedCommonDir $Plan.RepositoryCommonDir -ExpectedGitDir $Plan.WorktreeGitDir)) {
            throw "reused worktree changed since planning: '$($Plan.Destination)'"
        }
        $reuseCommit = if ($Plan.PSObject.Properties['SourceCommit']) { [string]$Plan.SourceCommit } else { $null }
        if ([string]::IsNullOrWhiteSpace($reuseCommit)) {
            throw "cannot verify the reused worktree for '$($Repository.Name)': no planned branch tip was bound"
        }
        $reuseHead =
            if ($Plan.PSObject.Properties['HeadRef'] -and $Plan.HeadRef) { [string]$Plan.HeadRef }
            else { "refs/heads/$($Plan.Source)" }
        $reuseUpstream =
            if ($Plan.PSObject.Properties['UpstreamRef'] -and $Plan.UpstreamRef) { [string]$Plan.UpstreamRef }
            else { $null }
        # Reuse verifies the plan's captured tip, immediate HEAD target and
        # canonical upstream. It never writes: a missing or different upstream
        # is a replan case, not a repair.
        Assert-TaskWorktreeBranchState -RepositoryName $Repository.Name -WorktreePath $Plan.Destination -Branch $Plan.Source -ExpectedCommit $reuseCommit -ExpectedHeadRef $reuseHead -UpstreamRef $reuseUpstream
        return $true
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
    # A bare object ID is not enough: worktree add resolves a branch literally
    # named after the ID first. `<id>^{commit}` is a revision expression that
    # names the object, and --no-track leaves tracking to the explicit upstream
    # write below.
    $gitArguments =
        if ($Plan.Action -eq 'create-remote') { @('worktree', 'add', '--no-track', '-b', $Repository.Branch, $Plan.Destination, "$sourceCommit^{commit}") }
        elseif ($Plan.BranchMode -eq 'existing') { @('worktree', 'add', $Plan.Destination, $Plan.Source) }
        elseif ($Plan.Action -eq 'create-local') { @('worktree', 'add', '--no-track', '-b', $Repository.Branch, $Plan.Destination, "$sourceCommit^{commit}") }
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

    # A create writes an upstream only from the value captured at plan time. The
    # plan already resolved branch.autoSetupMerge and canonicalized the target;
    # apply never re-derives it from the live remote ref. Attaching an existing
    # branch is not a create: it verifies the upstream the new worktree inherits
    # (the source worktree's effective config, which Git copies on add) and never
    # writes tracking.
    $upstreamRef =
        if ($Plan.PSObject.Properties['UpstreamRef'] -and $Plan.UpstreamRef) { [string]$Plan.UpstreamRef }
        else { $null }
    $headRef =
        if ($Plan.PSObject.Properties['HeadRef'] -and $Plan.HeadRef) { [string]$Plan.HeadRef }
        else { "refs/heads/$($Repository.Branch)" }
    $sourceTarget = if ($Plan.PSObject.Properties['SourceTarget']) { [string]$Plan.SourceTarget } else { $null }
    $upstreamMustExist = [bool]($upstreamRef -and $upstreamRef -ceq $sourceTarget)
    $upstreamConfig = if ($Plan.PSObject.Properties['UpstreamConfig']) { $Plan.UpstreamConfig } else { $null }
    # This operation already started (its git add was admitted), so it finishes
    # its upstream write even if another chain published a failure meanwhile. The
    # gate still excludes a concurrent publication from interleaving with it.
    if ($Gate) {
        $Gate.Wait()
        try {
            Assert-TaskWorktreeBranchState -RepositoryName $Repository.Name -WorktreePath $Plan.Destination -Branch $Repository.Branch -ExpectedCommit $sourceCommit -ExpectedHeadRef $headRef -UpstreamRef $upstreamRef -RepairUpstream:$createsBranch -UpstreamMustExist:$upstreamMustExist -UpstreamConfig $upstreamConfig
        }
        finally { [void]$Gate.Release() }
    }
    else {
        Assert-TaskWorktreeBranchState -RepositoryName $Repository.Name -WorktreePath $Plan.Destination -Branch $Repository.Branch -ExpectedCommit $sourceCommit -ExpectedHeadRef $headRef -UpstreamRef $upstreamRef -RepairUpstream:$createsBranch -UpstreamMustExist:$upstreamMustExist -UpstreamConfig $upstreamConfig
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

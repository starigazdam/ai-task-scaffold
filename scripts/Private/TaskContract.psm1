Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-TaskRepositoryName {
    param([string]$Name)

    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Test-GitBranchName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    & git check-ref-format --branch $Name 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-AIProfileName {
    param([string]$Name)

    return -not [string]::IsNullOrWhiteSpace($Name) -and $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Get-TaskPathComparer {
    if ([OperatingSystem]::IsWindows()) { return [System.StringComparer]::OrdinalIgnoreCase }
    return [System.StringComparer]::Ordinal
}

function ConvertTo-TaskRelativeFilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'task file path is required' }
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') {
        throw "task file path must be relative: '$Path'"
    }
    $segments = @($Path.Replace('\', '/').Split('/'))
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -ceq '.' -or $segment -ceq '..' -or $segment.Contains([char]0)) {
            throw "invalid task file path '$Path'"
        }
    }
    return ($segments -join '/')
}

function Get-TaskCustomFileDestination {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $platformPath = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    return [IO.Path]::GetFullPath((Join-Path $TaskPath $platformPath))
}

function Test-TaskCustomPathSafety {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $current = [IO.Path]::GetFullPath($TaskPath)
    foreach ($segment in $RelativePath.Split('/')) {
        $current = [IO.Path]::GetFullPath((Join-Path $current $segment))
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
    }
    return $true
}

function Get-TaskCustomFileState {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $destination = Get-TaskCustomFileDestination -TaskPath $TaskPath -RelativePath $RelativePath
    $state = [ordered]@{
        Path = $destination
        Exists = $false
        IsFile = $false
        IsReparsePoint = $false
        Sha256 = $null
    }
    $item = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        $state.Exists = $true
        $state.IsReparsePoint = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        if (-not $item.PSIsContainer -and -not $state.IsReparsePoint) {
            $state.IsFile = $true
            $state.Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return [pscustomobject]$state
}

function Get-TaskFileContentBytes {
    param([string]$Content)

    return [Text.UTF8Encoding]::new($false).GetBytes($Content)
}

function Get-TaskFileContentHash {
    param([string]$Content)

    $bytes = Get-TaskFileContentBytes -Content $Content
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-TaskManagedTaskFilePath {
    param([string]$RelativePath)

    $comparer = Get-TaskPathComparer
    $managedEntries = @('task.json', 'PRD.md', 'PLAN.md', 'STATUS.md', '.ctx', 'artifacts', 'worktrees')
    $firstSegment = @($RelativePath.Split('/'))[0]
    foreach ($entry in $managedEntries) {
        if ($comparer.Equals($firstSegment, $entry)) { return $true }
    }
    return $false
}

function Test-TaskFilePathIsAncestor {
    param(
        [Parameter(Mandatory)][string]$Ancestor,
        [Parameter(Mandatory)][string]$Descendant
    )

    $ancestorSegments = @($Ancestor.Split('/'))
    $descendantSegments = @($Descendant.Split('/'))
    if ($ancestorSegments.Count -ge $descendantSegments.Count) { return $false }
    $comparer = Get-TaskPathComparer
    for ($index = 0; $index -lt $ancestorSegments.Count; $index++) {
        if (-not $comparer.Equals($ancestorSegments[$index], $descendantSegments[$index])) { return $false }
    }
    return $true
}

function ConvertTo-TaskTaskFiles {
    param([object]$Request)

    $property = $Request.PSObject.Properties['taskFiles']
    if (-not $property -or $null -eq $property.Value) { return @() }
    if ($property.Value -isnot [array]) { throw 'taskFiles must be an array' }

    $comparer = Get-TaskPathComparer
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $files = @()
    foreach ($descriptor in $property.Value) {
        if ($null -eq $descriptor) { throw 'invalid task file descriptor: expected path and content' }
        $pathProperty = $descriptor.PSObject.Properties['path']
        $contentProperty = $descriptor.PSObject.Properties['content']
        if (-not $pathProperty -or -not $contentProperty) { throw 'invalid task file descriptor: expected path and content' }
        if ($null -eq $pathProperty.Value) { throw 'task file path is required' }
        $normalized = ConvertTo-TaskRelativeFilePath -Path ([string]$pathProperty.Value)
        if (Test-TaskManagedTaskFilePath -RelativePath $normalized) {
            throw "task file path '$normalized' collides with a scaffold-managed path"
        }
        if ($null -eq $contentProperty.Value -or $contentProperty.Value -isnot [string]) {
            throw "task file '$normalized' content must be a string"
        }
        if (-not $seen.Add($normalized)) { throw "duplicate task file path '$normalized'" }
        $files += [pscustomobject]@{ Path = $normalized; Content = [string]$contentProperty.Value }
    }

    for ($outer = 0; $outer -lt $files.Count; $outer++) {
        for ($inner = 0; $inner -lt $files.Count; $inner++) {
            if ($outer -eq $inner) { continue }
            if (Test-TaskFilePathIsAncestor -Ancestor $files[$outer].Path -Descendant $files[$inner].Path) {
                throw "task file path '$($files[$outer].Path)' conflicts with '$($files[$inner].Path)'"
            }
        }
    }
    return $files
}

function ConvertTo-TaskProfiles {
    param([object]$Request)

    $profilesProperty = $Request.PSObject.Properties['profiles']
    if (-not $profilesProperty) { return @() }
    if ($profilesProperty.Value -isnot [array]) { throw 'profiles must be an array' }

    $pathComparer = if ([OperatingSystem]::IsWindows()) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $profiles = @()
    foreach ($profile in $profilesProperty.Value) {
        if ($null -eq $profile) { throw 'invalid profile descriptor: expected name and path' }
        $nameProperty = $profile.PSObject.Properties['name']
        $pathProperty = $profile.PSObject.Properties['path']
        $name = if ($nameProperty) { [string]$nameProperty.Value } else { '' }
        $path = if ($pathProperty) { [string]$pathProperty.Value } else { '' }
        if (-not (Test-AIProfileName -Name $name)) { throw "invalid profile name '$name'" }
        if ($name -ieq 'task-scaffold') { throw "profile name 'task-scaffold' is reserved" }
        if (-not $seenNames.Add($name)) { throw "duplicate profile name '$name'" }
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
            throw "profile '$name' path must be an absolute resolved directory"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "profile '$name' directory does not exist: $path" }

        $resolvedPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path -ErrorAction Stop).Path))
        if (-not $seenPaths.Add($resolvedPath)) { throw "duplicate profile path '$resolvedPath'" }
        if (-not (Test-Path -LiteralPath (Join-Path $resolvedPath 'AGENTS.md') -PathType Leaf)) {
            throw "invalid profile '$name': AGENTS.md is required"
        }

        $agentsPath = Join-Path $resolvedPath '.agents'
        if ((Test-Path -LiteralPath $agentsPath) -and -not (Test-Path -LiteralPath $agentsPath -PathType Container)) {
            throw "invalid profile '$name': .agents must be a directory"
        }
        $skillsPath = Join-Path $agentsPath 'skills'
        if (Test-Path -LiteralPath $skillsPath) {
            if (-not (Test-Path -LiteralPath $skillsPath -PathType Container)) {
                throw "invalid profile '$name': .agents/skills must be a directory"
            }
            foreach ($skill in Get-ChildItem -LiteralPath $skillsPath -Force) {
                if (-not $skill.PSIsContainer -or -not (Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -PathType Leaf)) {
                    throw "invalid profile '$name': each entry in .agents/skills must be a skill directory containing SKILL.md"
                }
            }
        }

        $profiles += [pscustomobject]@{ Name = $name; Path = $resolvedPath }
    }
    return $profiles
}

function ConvertTo-TaskRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $request = $raw | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    if ([int]$request.schemaVersion -notin @(1, 2)) {
        throw "unsupported schemaVersion '$($request.schemaVersion)'"
    }
    $profiles = @(ConvertTo-TaskProfiles -Request $request)
    $taskFiles = @(ConvertTo-TaskTaskFiles -Request $request)
    $key = [string]$request.task.key
    if ($key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "invalid task key '$key'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.task.title)) {
        throw 'task title is required'
    }
    $prdPath = ''
    $prdPathProperty = $request.task.PSObject.Properties['prdPath']
    if ($prdPathProperty -and $null -ne $prdPathProperty.Value) {
        $prdPath = [string]$prdPathProperty.Value
    }

    $repositories = @($request.repositories)
    if ($repositories.Count -eq 0) {
        throw 'at least one repository is required'
    }
    foreach ($repository in $repositories) {
        if (-not (Test-TaskRepositoryName -Name ([string]$repository.name))) {
            throw "invalid repository name '$($repository.name)'"
        }
        if ([string]::IsNullOrWhiteSpace([string]$repository.path)) {
            throw "repository '$($repository.name)' path is required"
        }
        if (-not (Test-GitBranchName -Name ([string]$repository.baseBranch))) {
            throw "invalid Git base branch '$($repository.baseBranch)'"
        }
        if (-not (Test-GitBranchName -Name ([string]$repository.branch))) {
            throw "invalid Git branch '$($repository.branch)'"
        }
    }
    $duplicate = $repositories | Group-Object name | Where-Object Count -gt 1 | Select-Object -First 1
    if ($duplicate) {
        throw "duplicate repository name '$($duplicate.Name)'"
    }

    [pscustomobject]@{
        SchemaVersion = 2
        Task = [pscustomobject]@{
            Key = $key
            Title = [string]$request.task.title
            PrdPath = $prdPath
        }
        Repositories = @($repositories | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.name
                Path = [string]$_.path
                BaseBranch = [string]$_.baseBranch
                Branch = [string]$_.branch
            }
        })
        Profiles = $profiles
        TaskFiles = @($taskFiles)
        Workspace = if ($request.PSObject.Properties['workspace'] -and -not [string]::IsNullOrWhiteSpace([string]$request.workspace.file)) {
            [pscustomobject]@{ File = [string]$request.workspace.file }
        }
        else {
            $null
        }
    }
}

Export-ModuleMember -Function ConvertTo-TaskRequest, Test-GitBranchName, Test-TaskRepositoryName, ConvertTo-TaskTaskFiles, ConvertTo-TaskRelativeFilePath, Get-TaskPathComparer, Get-TaskCustomFileDestination, Get-TaskCustomFileState, Test-TaskCustomPathSafety, Test-TaskManagedTaskFilePath, Get-TaskFileContentBytes, Get-TaskFileContentHash

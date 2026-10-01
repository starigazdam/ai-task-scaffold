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
        Workspace = if ($request.PSObject.Properties['workspace'] -and -not [string]::IsNullOrWhiteSpace([string]$request.workspace.file)) {
            [pscustomobject]@{ File = [string]$request.workspace.file }
        }
        else {
            $null
        }
    }
}

Export-ModuleMember -Function ConvertTo-TaskRequest, Test-GitBranchName, Test-TaskRepositoryName

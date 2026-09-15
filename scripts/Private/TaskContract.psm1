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

function ConvertTo-TaskRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $request = $raw | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    if ([int]$request.schemaVersion -ne 1) {
        throw "unsupported schemaVersion '$($request.schemaVersion)'"
    }
    $key = [string]$request.task.key
    if ($key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "invalid task key '$key'"
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.task.title)) {
        throw 'task title is required'
    }
    if ([string]::IsNullOrWhiteSpace([string]$request.task.prdPath)) {
        throw 'task PRD path is required'
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
        Task = [pscustomobject]@{
            Key = $key
            Title = [string]$request.task.title
            PrdPath = [string]$request.task.prdPath
        }
        Repositories = @($repositories | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.name
                Path = [string]$_.path
                BaseBranch = [string]$_.baseBranch
                Branch = [string]$_.branch
            }
        })
        Workspace = if ($request.PSObject.Properties['workspace'] -and -not [string]::IsNullOrWhiteSpace([string]$request.workspace.file)) {
            [pscustomobject]@{ File = [string]$request.workspace.file }
        }
        else {
            $null
        }
    }
}

Export-ModuleMember -Function ConvertTo-TaskRequest, Test-GitBranchName, Test-TaskRepositoryName

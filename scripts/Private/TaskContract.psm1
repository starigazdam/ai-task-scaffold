Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-TaskRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $request = $raw | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    $key = [string]$request.task.key
    if ($key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "invalid task key '$key'"
    }

    $repositories = @($request.repositories)
    $duplicate = $repositories | Group-Object name | Where-Object Count -gt 1 | Select-Object -First 1
    if ($duplicate) {
        throw "duplicate repository name '$($duplicate.Name)'"
    }

    [pscustomobject]@{
        Task = [pscustomobject]@{
            Key = [string]$request.task.key
            Title = [string]$request.task.title
            PrdPath = [string]$request.task.prdPath
        }
        Repositories = @($request.repositories | ForEach-Object {
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

Export-ModuleMember -Function ConvertTo-TaskRequest

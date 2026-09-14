#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRootPath = (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).Path
$settingsPath = Join-Path $workspaceRootPath 'task-scaffold.settings.json'
$canonsPath = Join-Path $workspaceRootPath 'canons'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "settings file '$settingsPath' does not exist"
}
if (-not (Test-Path -LiteralPath $canonsPath -PathType Container)) {
    throw "canons directory '$canonsPath' does not exist"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $workspaceRootPath 'task-request.json'
}
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $workspaceRootPath $OutputPath
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "refusing to overwrite existing request '$OutputPath'"
}

$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -Depth 10
$available = @(
    Get-ChildItem -LiteralPath $canonsPath -Directory |
    Where-Object { $settings.repositories.PSObject.Properties.Name -contains $_.Name } |
    Sort-Object Name
)
if ($available.Count -eq 0) {
    throw "no configured canons found under '$canonsPath'"
}

Write-Host "Configured canons: $($available.Name -join ', ')"
$key = Read-Host 'Task key'
if ($key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "invalid task key '$key'"
}
$title = Read-Host 'Task title'
$prdPath = Read-Host 'PRD path'
$selectedNames = @(
    (Read-Host 'Repositories (comma-separated)') -split ',' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
)
if ($selectedNames.Count -eq 0) {
    throw 'select at least one configured canon'
}
$unknown = @($selectedNames | Where-Object { $_ -notin $available.Name })
if ($unknown.Count -gt 0) {
    throw "unknown configured canon '$($unknown -join ', ')}'"
}
if (($selectedNames | Select-Object -Unique).Count -ne $selectedNames.Count) {
    throw 'duplicate repository selection'
}

$repositories = @($selectedNames | Sort-Object | ForEach-Object {
    $name = $_
    $configuration = $settings.repositories.$name
    $baseBranch = [string]$configuration.baseBranch
    if ([string]::IsNullOrWhiteSpace($baseBranch)) {
        throw "configured canon '$name' has no baseBranch"
    }
    [ordered]@{
        name = $name
        path = Join-Path $canonsPath $name
        baseBranch = $baseBranch
        branch = "feature/$key"
    }
})
$request = [ordered]@{
    schemaVersion = 1
    task = [ordered]@{ key = $key; title = $title; prdPath = $prdPath }
    repositories = $repositories
}
if ($settings.PSObject.Properties['workspace'] -and -not [string]::IsNullOrWhiteSpace([string]$settings.workspace.file)) {
    $workspaceFile = [string]$settings.workspace.file
    if (-not [IO.Path]::IsPathRooted($workspaceFile)) {
        $workspaceFile = Join-Path $workspaceRootPath $workspaceFile
    }
    $request.workspace = [ordered]@{ file = $workspaceFile }
}

$json = $request | ConvertTo-Json -Depth 8
Write-Host $json
if ((Read-Host "Write reviewed request to '$OutputPath'? [y/N]") -notmatch '^(?i:y|yes)$') {
    throw 'request was not written'
}
$json | Set-Content -LiteralPath $OutputPath -NoNewline
[pscustomobject]@{ RequestPath = $OutputPath; RequiresApply = $false } | ConvertTo-Json

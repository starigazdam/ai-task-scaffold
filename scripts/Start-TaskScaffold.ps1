#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$RequestPath,
    [string]$TasksRoot,
    [string[]]$RepositoryNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRootPath = (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($RequestPath)) {
    $RequestPath = Join-Path $workspaceRootPath 'task-request.json'
}
elseif (-not [IO.Path]::IsPathRooted($RequestPath)) {
    $RequestPath = Join-Path $workspaceRootPath $RequestPath
}
if ([string]::IsNullOrWhiteSpace($TasksRoot)) {
    $TasksRoot = Join-Path $workspaceRootPath 'tasks'
}
elseif (-not [IO.Path]::IsPathRooted($TasksRoot)) {
    $TasksRoot = Join-Path $workspaceRootPath $TasksRoot
}

Write-Host ''
Write-Host '=== Task Scaffold ==='
if ((Read-Host 'Is PRD.md ready to copy into the task? [y/N]') -notmatch '^(?i:y|yes)$') {
    Write-Host 'Cancelled: prepare the PRD, then run this wizard again.'
    return
}

$builder = Join-Path $PSScriptRoot 'Invoke-TaskRequestBuilder.ps1'
$builderParameters = @{ WorkspaceRoot = $workspaceRootPath; OutputPath = $RequestPath }
if ($PSBoundParameters.ContainsKey('RepositoryNames') -and $null -ne $RepositoryNames) {
    $builderParameters.RepositoryNames = $RepositoryNames
}
& $builder @builderParameters | Out-Null

$scaffold = Join-Path $PSScriptRoot 'Invoke-TaskScaffold.ps1'
$plan = & $scaffold -RequestPath $RequestPath -TasksRoot $TasksRoot | ConvertFrom-Json
Write-Host ''
Write-Host '=== Reviewed scaffold plan ==='
Write-Host ($plan | ConvertTo-Json -Depth 8)
$blocked = @($plan.WorktreeOperations | Where-Object Action -eq 'blocked')
if ($blocked.Count -gt 0) {
    Write-Host 'Not applied: resolve blocked worktree operations and rerun.'
    return
}

if ((Read-Host "Apply this plan and copy PRD.md into '$($plan.TaskKey)'? [y/N]") -notmatch '^(?i:y|yes)$') {
    Write-Host "Not applied. Review '$RequestPath' and rerun when ready."
    return
}

& $scaffold -RequestPath $RequestPath -TasksRoot $TasksRoot -Apply

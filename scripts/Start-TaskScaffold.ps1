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
switch ($plan.PrdOperation.Action) {
    'copy-source' { Write-Host "PRD source '$($plan.PrdOperation.SourcePath)' will be copied to PRD.md." }
    'create-starter' {
        if ([string]::IsNullOrWhiteSpace([string]$plan.PrdOperation.SourcePath)) {
            Write-Host 'No PRD source supplied; a starter PRD.md will be created.'
        }
        else {
            Write-Host "PRD source '$($plan.PrdOperation.SourcePath)' was not found; a starter PRD.md will be created."
        }
    }
    'reuse-existing' { Write-Host 'The existing task PRD.md will be reused.' }
    'compare-existing' { Write-Host 'The existing task PRD.md will be checked against the source.' }
    'blocked' { Write-Host "PRD operation blocked: $($plan.PrdOperation.Reason)" }
}
$blocked = @($plan.WorktreeOperations | Where-Object Action -eq 'blocked')
if ($plan.PrdOperation.Action -eq 'blocked') {
    Write-Host 'Not applied: resolve the blocked PRD operation and rerun.'
    return
}
if ($blocked.Count -gt 0) {
    Write-Host 'Not applied: resolve blocked worktree operations and rerun.'
    return
}

$prdConfirmation = switch ($plan.PrdOperation.Action) {
    'copy-source' { 'copy the source PRD' }
    'create-starter' { 'create a starter PRD' }
    'reuse-existing' { 'reuse the existing PRD' }
    'compare-existing' { 'verify the existing PRD' }
}
if ((Read-Host "Apply this plan, $prdConfirmation, and create task/worktree state? [y/N]") -notmatch '^(?i:y|yes)$') {
    Write-Host "Not applied. Review '$RequestPath' and rerun when ready."
    return
}

& $scaffold -RequestPath $RequestPath -TasksRoot $TasksRoot -Apply -ExpectedPlanIdentity $plan.PlanIdentity

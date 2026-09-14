#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$TasksRoot,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Private/TaskContract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Private/GitWorktree.psm1') -Force

$request = ConvertTo-TaskRequest -Path $RequestPath
$worktreeOperations = @($request.Repositories |
    Sort-Object Name |
    ForEach-Object { New-TaskWorktreePlan -Repository $_ -TaskKey $request.Task.Key -TasksRoot $TasksRoot })
$workspaceFolderPlan = $null
if ($request.Workspace) {
    $folders = @($worktreeOperations |
        Where-Object Action -ne 'blocked' |
        ForEach-Object { [ordered]@{ path = $_.Destination; name = "🔧 worktree: $($request.Task.Key) $($_.Repository)" } })
    if ($folders.Count -gt 0) {
        $workspaceScript = Join-Path $PSScriptRoot 'Update-WorkspaceFolders.ps1'
        $workspaceFolderPlan = & $workspaceScript -WorkspaceFile $request.Workspace.File -FoldersJson ($folders | ConvertTo-Json -Compress) | ConvertFrom-Json
    }
}
$taskPath = Join-Path $TasksRoot $request.Task.Key

if ($Apply) {
    if (-not (Test-Path -LiteralPath $request.Task.PrdPath -PathType Leaf)) {
        throw "PRD '$($request.Task.PrdPath)' does not exist"
    }
    $blockedOperation = $worktreeOperations | Where-Object Action -eq 'blocked' | Select-Object -First 1
    if ($blockedOperation) {
        throw "cannot apply blocked worktree plan for '$($blockedOperation.Repository)': $($blockedOperation.Reason)"
    }

    $prdDestination = Join-Path $taskPath 'PRD.md'
    if (Test-Path -LiteralPath $taskPath) {
        if (-not (Test-Path -LiteralPath $prdDestination -PathType Leaf)) {
            throw "existing task '$($request.Task.Key)' has no PRD.md"
        }
        if ((Get-FileHash -LiteralPath $request.Task.PrdPath).Hash -ne (Get-FileHash -LiteralPath $prdDestination).Hash) {
            throw "existing task '$($request.Task.Key)' has a different PRD.md"
        }
    }
    else {
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Copy-Item -LiteralPath $request.Task.PrdPath -Destination $prdDestination -ErrorAction Stop
    }

    $planPath = Join-Path $taskPath 'PLAN.md'
    if (-not (Test-Path -LiteralPath $planPath)) {
        @"
# $($request.Task.Key) — $($request.Task.Title)

Source PRD: PRD.md

## Phases
"@ | Set-Content -LiteralPath $planPath -NoNewline
    }

    $statusPath = Join-Path $taskPath 'STATUS.md'
    if (-not (Test-Path -LiteralPath $statusPath)) {
        $repositoryLines = @($request.Repositories | ForEach-Object { "  - $($_.Name): $($_.Branch)" }) -join "`n"
        @"
# $($request.Task.Key) — $($request.Task.Title)
state: not-started
plan: PLAN.md
repos:
$repositoryLines
phases:
"@ | Set-Content -LiteralPath $statusPath -NoNewline
    }

    $manifestPath = Join-Path $taskPath 'task.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        [ordered]@{
            schemaVersion = 1
            task = [ordered]@{ key = $request.Task.Key; title = $request.Task.Title; prdPath = 'PRD.md' }
            repositories = @($request.Repositories | ForEach-Object { [ordered]@{ name = $_.Name; branch = $_.Branch; baseBranch = $_.BaseBranch } })
            phases = @()
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -NoNewline
    }
    New-Item -ItemType Directory -Path (Join-Path $taskPath 'artifacts') -Force | Out-Null
    foreach ($operation in $worktreeOperations) {
        Invoke-TaskWorktreePlan -Repository ($request.Repositories | Where-Object Name -eq $operation.Repository) -Plan $operation
    }
}

[ordered]@{
    TaskKey = $request.Task.Key
    TaskOperation = if (Test-Path -LiteralPath $taskPath) { 'reuse' } else { 'create' }
    WorktreeOperations = $worktreeOperations
    WorkspaceFolderPlan = $workspaceFolderPlan
    RequiresConfirmation = $true
} | ConvertTo-Json -Depth 8

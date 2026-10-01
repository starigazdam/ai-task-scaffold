#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$TasksRoot,
    [switch]$Apply,
    [string]$ExpectedPlanIdentity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Private/TaskContract.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Private/GitWorktree.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Private/TaskPlanIdentity.psm1') -Force

$TasksRoot = [IO.Path]::GetFullPath($TasksRoot)
$scaffoldRoot = Split-Path -Parent $PSScriptRoot

$request = ConvertTo-TaskRequest -Path $RequestPath
$taskScaffoldProfilePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../agent-profile') -ErrorAction Stop).Path
$taskScaffoldProfile = [pscustomobject]@{ Name = 'task-scaffold'; Path = $taskScaffoldProfilePath }
$pathComparer = if ([OperatingSystem]::IsWindows()) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
foreach ($profile in $request.Profiles) {
    if ($pathComparer.Equals([IO.Path]::GetFullPath($profile.Path), [IO.Path]::GetFullPath($taskScaffoldProfilePath))) {
        throw "duplicate profile path '$taskScaffoldProfilePath'"
    }
}
$effectiveProfiles = @($request.Profiles) + @($taskScaffoldProfile)
$worktreeOperations = @($request.Repositories |
    Sort-Object Name |
    ForEach-Object { New-TaskWorktreePlan -Repository $_ -TaskKey $request.Task.Key -TasksRoot $TasksRoot })
$workspaceFolderPlan = $null
$taskPath = Join-Path $TasksRoot $request.Task.Key
$taskExists = Test-Path -LiteralPath $taskPath
$prdTemplatePath = Join-Path $PSScriptRoot '../templates/PRD.md'
$manifestPath = Join-Path $taskPath 'task.json'
$expectedRepositories = @($request.Repositories | Sort-Object Name | ForEach-Object {
    [ordered]@{ name = $_.Name; path = $_.Path; branch = $_.Branch; baseBranch = $_.BaseBranch }
})
$expectedContract = [ordered]@{
    schemaVersion = 1
    task = [ordered]@{ key = $request.Task.Key; title = $request.Task.Title; prdPath = 'PRD.md' }
    repositories = $expectedRepositories
}
$expectedProfiles = @($effectiveProfiles | ForEach-Object {
    [ordered]@{ name = $_.Name; path = $_.Path }
})
$ctxPath = Join-Path $taskPath '.ctx'
$ctxContent = (@($effectiveProfiles | ForEach-Object { "$($_.Name):$($_.Path)" }) -join "`n") + "`n"

function Get-TaskWorkspaceFolderPlan {
    param(
        [object]$Request,
        [object[]]$EffectiveProfiles,
        [object[]]$WorktreeOperations,
        [string]$ScriptsRoot
    )

    if (-not $Request.Workspace) { return $null }
    $folders = @($EffectiveProfiles |
        ForEach-Object { [ordered]@{ path = $_.Path; name = "[AI] $($_.Name)" } })
    $folders += @($WorktreeOperations |
        Where-Object Action -ne 'blocked' |
        ForEach-Object { [ordered]@{ path = $_.Destination; name = "🔧 worktree: $($Request.Task.Key) $($_.Repository)" } })
    if ($folders.Count -eq 0) { return $null }

    $workspaceScript = Join-Path $ScriptsRoot 'Update-WorkspaceFolders.ps1'
    return (& $workspaceScript -WorkspaceFile $Request.Workspace.File -FoldersJson ($folders | ConvertTo-Json -Compress) | ConvertFrom-Json)
}

function Get-TaskCtxFilePlan {
    param([string]$Path, [string]$Content)

    $action = 'create'
    $existing = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.PSIsContainer -or (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "task .ctx must be a regular file: $Path"
        }
        $action = if ([IO.File]::ReadAllText($Path) -ceq $Content) { 'noop' } else { 'update' }
    }
    return [ordered]@{ Path = $Path; Action = $action; Content = $Content }
}

function Assert-TaskPathSafety {
    if (-not (Test-TaskPathSafety -TasksRoot $TasksRoot -TaskKey $request.Task.Key)) {
        throw "cannot scaffold task '$($request.Task.Key)': unsafe-task-path"
    }
}

function Normalize-TaskProfilePath {
    param([string]$Path)

    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

function Get-TaskProfileState {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ IdentityMatches = $true; PathDrift = @(); RequiresMigration = $false }
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 10
    $profilesProperty = $manifest.PSObject.Properties['profiles']
    $requiresMigration = -not $profilesProperty
    if ($profilesProperty) {
        if ($profilesProperty.Value -isnot [array]) { throw "existing task manifest has invalid profiles: '$ManifestPath'" }
        $existingProfiles = @($profilesProperty.Value)
    }
    else {
        $existingProfiles = @([pscustomobject]@{ name = 'task-scaffold'; path = $null })
    }

    $identityMatches = $existingProfiles.Count -eq $expectedProfiles.Count
    if ($identityMatches) {
        for ($index = 0; $index -lt $expectedProfiles.Count; $index++) {
            if ([string]$existingProfiles[$index].name -ine [string]$expectedProfiles[$index].name) {
                $identityMatches = $false
                break
            }
        }
    }

    $pathDrift = @()
    if ($identityMatches -and $profilesProperty) {
        for ($index = 0; $index -lt $expectedProfiles.Count; $index++) {
            $existingPath = [string]$existingProfiles[$index].path
            $expectedPath = [string]$expectedProfiles[$index].path
            if ([string]::IsNullOrWhiteSpace($existingPath) -or
                -not $pathComparer.Equals((Normalize-TaskProfilePath $existingPath), (Normalize-TaskProfilePath $expectedPath))) {
                $pathDrift += [pscustomobject]@{
                    Name = [string]$expectedProfiles[$index].name
                    ExistingPath = $existingPath
                    RequestedPath = $expectedPath
                }
            }
        }
    }

    [pscustomobject]@{
        IdentityMatches = $identityMatches
        PathDrift = $pathDrift
        RequiresMigration = $requiresMigration
    }
}

function Get-TaskPrdOperation {
    param([bool]$TaskExists)

    $sourcePath = $request.Task.PrdPath
    $sourceProvided = -not [string]::IsNullOrWhiteSpace($sourcePath)
    $sourceExists = $sourceProvided -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)

    if ($TaskExists) {
        if (-not $sourceProvided) {
            return [pscustomobject]@{ Action = 'reuse-existing'; SourcePath = $null; Destination = 'PRD.md'; Reason = $null }
        }
        if ($sourceExists) {
            return [pscustomobject]@{ Action = 'compare-existing'; SourcePath = $sourcePath; Destination = 'PRD.md'; Reason = $null }
        }
        return [pscustomobject]@{ Action = 'blocked'; SourcePath = $sourcePath; Destination = 'PRD.md'; Reason = "PRD source '$sourcePath' does not exist" }
    }

    if ($sourceExists) {
        return [pscustomobject]@{ Action = 'copy-source'; SourcePath = $sourcePath; Destination = 'PRD.md'; Reason = $null }
    }

    if (-not (Test-Path -LiteralPath $prdTemplatePath -PathType Leaf)) {
        throw "PRD starter template '$prdTemplatePath' does not exist"
    }
    $reason = if ($sourceProvided) { "PRD source '$sourcePath' does not exist" } else { 'No PRD source was supplied' }
    return [pscustomobject]@{ Action = 'create-starter'; SourcePath = $sourcePath; Destination = 'PRD.md'; TemplatePath = $prdTemplatePath; Reason = $reason }
}

function New-TaskScaffoldPlan {
    param(
        [bool]$TaskExists,
        [object]$PrdOperation,
        [object]$ProfileState,
        [object[]]$WorktreeOperations,
        [object]$WorkspaceFolderPlan,
        [object]$CtxFilePlan
    )

    return [ordered]@{
        TaskKey = $request.Task.Key
        TaskOperation = if ($TaskExists) { 'reuse' } else { 'create' }
        PrdOperation = $PrdOperation
        RequestedProfiles = @($request.Profiles)
        InjectedProfiles = @($taskScaffoldProfile)
        EffectiveProfiles = $effectiveProfiles
        ProfileIdentityMatches = $ProfileState.IdentityMatches
        ProfilePathDrift = $ProfileState.PathDrift
        ProfileManifestMigrationRequired = $ProfileState.RequiresMigration
        WorktreeOperations = $WorktreeOperations
        WorkspaceFolderPlan = $WorkspaceFolderPlan
        CtxFilePlan = $CtxFilePlan
        RequiresConfirmation = $true
    }
}

$prdOperation = Get-TaskPrdOperation -TaskExists $taskExists
$profileState = Get-TaskProfileState -ManifestPath $manifestPath
$workspaceFolderPlan = Get-TaskWorkspaceFolderPlan -Request $request -EffectiveProfiles $effectiveProfiles -WorktreeOperations $worktreeOperations -ScriptsRoot $PSScriptRoot
$ctxFilePlan = Get-TaskCtxFilePlan -Path $ctxPath -Content $ctxContent
$plan = New-TaskScaffoldPlan -TaskExists $taskExists -PrdOperation $prdOperation -ProfileState $profileState -WorktreeOperations $worktreeOperations -WorkspaceFolderPlan $workspaceFolderPlan -CtxFilePlan $ctxFilePlan
$planIdentity = Get-TaskPlanIdentity -Request $request -TasksRoot $TasksRoot -ScaffoldRoot $scaffoldRoot -EffectiveProfiles $effectiveProfiles -WorktreeOperations $worktreeOperations -Plan $plan

if ($Apply) {
    if ([string]::IsNullOrWhiteSpace($ExpectedPlanIdentity)) {
        throw 'Apply requires ExpectedPlanIdentity from the reviewed plan'
    }
    if ($ExpectedPlanIdentity -cnotmatch '^[a-f0-9]{64}$') {
        throw 'ExpectedPlanIdentity must be a SHA-256 plan identity from the reviewed plan'
    }
    if ($ExpectedPlanIdentity -cne $planIdentity) {
        throw 'task-scaffold plan identity changed since review; replan and approve again'
    }
    if ($taskExists) {
        if (-not $profileState.IdentityMatches) {
            throw "existing task '$($request.Task.Key)' manifest profiles differ from the request"
        }
        if ($profileState.PathDrift.Count -gt 0) {
            throw "existing task '$($request.Task.Key)' profile paths changed; reconciliation is required before apply"
        }
    }
}

if ($Apply) {
    $mutationLock = Enter-TaskMutationLock -TasksRoot $TasksRoot
    try {
    $worktreeOperations = @($request.Repositories |
        Sort-Object Name |
        ForEach-Object { New-TaskWorktreePlan -Repository $_ -TaskKey $request.Task.Key -TasksRoot $TasksRoot })
    $taskPath = Join-Path $TasksRoot $request.Task.Key
    $taskExists = Test-Path -LiteralPath $taskPath
    $prdOperation = Get-TaskPrdOperation -TaskExists $taskExists
    $manifestPath = Join-Path $taskPath 'task.json'
    $profileState = Get-TaskProfileState -ManifestPath $manifestPath
    $workspaceFolderPlan = Get-TaskWorkspaceFolderPlan -Request $request -EffectiveProfiles $effectiveProfiles -WorktreeOperations $worktreeOperations -ScriptsRoot $PSScriptRoot
    $ctxFilePlan = Get-TaskCtxFilePlan -Path $ctxPath -Content $ctxContent
    $plan = New-TaskScaffoldPlan -TaskExists $taskExists -PrdOperation $prdOperation -ProfileState $profileState -WorktreeOperations $worktreeOperations -WorkspaceFolderPlan $workspaceFolderPlan -CtxFilePlan $ctxFilePlan
    $currentPlanIdentity = Get-TaskPlanIdentity -Request $request -TasksRoot $TasksRoot -ScaffoldRoot $scaffoldRoot -EffectiveProfiles $effectiveProfiles -WorktreeOperations $worktreeOperations -Plan $plan
    if ($ExpectedPlanIdentity -cne $currentPlanIdentity) {
        throw 'task-scaffold plan identity changed before apply; no task state was changed; replan and approve again'
    }
    Assert-TaskPathSafety
    if ($prdOperation.Action -eq 'blocked') {
        throw "cannot apply task '$($request.Task.Key)': $($prdOperation.Reason)"
    }
    $blockedOperation = $worktreeOperations | Where-Object Action -eq 'blocked' | Select-Object -First 1
    if ($blockedOperation) {
        throw "cannot apply blocked worktree plan for '$($blockedOperation.Repository)': $($blockedOperation.Reason)"
    }

    if ($taskExists) {
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "existing task '$($request.Task.Key)' has no task.json"
        }
        $existingManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 6
        $existingContract = [ordered]@{
            schemaVersion = [int]$existingManifest.schemaVersion
            task = [ordered]@{
                key = [string]$existingManifest.task.key
                title = [string]$existingManifest.task.title
                prdPath = [string]$existingManifest.task.prdPath
            }
            repositories = @($existingManifest.repositories | Sort-Object name | ForEach-Object {
                [ordered]@{ name = [string]$_.name; path = [string]$_.path; branch = [string]$_.branch; baseBranch = [string]$_.baseBranch }
            })
        }
        if (($existingContract | ConvertTo-Json -Depth 6 -Compress) -cne ($expectedContract | ConvertTo-Json -Depth 6 -Compress)) {
            throw "existing task '$($request.Task.Key)' manifest differs from the request"
        }
        if (-not $profileState.IdentityMatches) {
            throw "existing task '$($request.Task.Key)' manifest profiles differ from the request"
        }
        if ($profileState.PathDrift.Count -gt 0) {
            throw "existing task '$($request.Task.Key)' profile paths changed; reconciliation is required before apply"
        }
    }

    $prdDestination = Join-Path $taskPath 'PRD.md'
    if ($taskExists) {
        if (-not (Test-Path -LiteralPath $prdDestination -PathType Leaf)) {
            throw "existing task '$($request.Task.Key)' has no PRD.md"
        }
        if ($prdOperation.Action -eq 'compare-existing' -and (Get-FileHash -LiteralPath $prdOperation.SourcePath).Hash -ne (Get-FileHash -LiteralPath $prdDestination).Hash) {
            throw "existing task '$($request.Task.Key)' has a different PRD.md"
        }
    }
    else {
        New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
        Assert-TaskPathSafety
        if ($prdOperation.Action -eq 'copy-source') {
            Copy-Item -LiteralPath $prdOperation.SourcePath -Destination $prdDestination -ErrorAction Stop
        }
        else {
            Assert-TaskPathSafety
            $template = Get-Content -LiteralPath $prdOperation.TemplatePath -Raw
            $starter = $template.Replace('{{TASK_TITLE}}', $request.Task.Title)
            Set-Content -LiteralPath $prdDestination -Value $starter -NoNewline
        }
    }

    $planPath = Join-Path $taskPath 'PLAN.md'
    if (-not (Test-Path -LiteralPath $planPath)) {
        Assert-TaskPathSafety
        @"
# $($request.Task.Key) — $($request.Task.Title)

Source PRD: PRD.md

## Phases
"@ | Set-Content -LiteralPath $planPath -NoNewline
    }

    $statusPath = Join-Path $taskPath 'STATUS.md'
    if (-not (Test-Path -LiteralPath $statusPath)) {
        Assert-TaskPathSafety
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

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Assert-TaskPathSafety
        [ordered]@{
            schemaVersion = $expectedContract.schemaVersion
            task = $expectedContract.task
            repositories = $expectedContract.repositories
            profiles = $expectedProfiles
            phases = @()
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -NoNewline
    }
    elseif ($profileState.RequiresMigration) {
        Assert-TaskPathSafety
        $existingManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 10
        $existingManifest | Add-Member -NotePropertyName profiles -NotePropertyValue $expectedProfiles
        $existingManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -NoNewline
    }
    Assert-TaskPathSafety
    $currentCtx = Get-Item -LiteralPath $ctxPath -Force -ErrorAction SilentlyContinue
    if ($currentCtx) {
        if ($currentCtx.PSIsContainer -or (($currentCtx.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "task .ctx must be a regular file: $ctxPath"
        }
        if ([IO.File]::ReadAllText($ctxPath) -cne $ctxContent) {
            [IO.File]::WriteAllText($ctxPath, $ctxContent, [Text.UTF8Encoding]::new($false))
        }
    }
    else {
        [IO.File]::WriteAllText($ctxPath, $ctxContent, [Text.UTF8Encoding]::new($false))
    }
    New-Item -ItemType Directory -Path (Join-Path $taskPath 'artifacts') -Force | Out-Null
    foreach ($operation in $worktreeOperations) {
        Invoke-TaskWorktreePlan -Repository ($request.Repositories | Where-Object Name -eq $operation.Repository) -Plan $operation
    }
    }
    finally {
        $mutationLock.Dispose()
    }
}

$plan['PlanIdentity'] = $planIdentity
$plan | ConvertTo-Json -Depth 8

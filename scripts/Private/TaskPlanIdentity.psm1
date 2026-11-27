Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PlanGitCommonDir {
    param([string]$RepositoryPath)

    $output = & git -C $RepositoryPath rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Get-PlanGitDir {
    param([string]$RepositoryPath)

    $output = & git -C $RepositoryPath rev-parse --path-format=absolute --git-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Get-TaskFileIdentity {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ Path = [IO.Path]::GetFullPath($Path); Exists = $false; Sha256 = $null }
    }
    [ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Exists = $true
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-TaskProfileIdentity {
    param([object[]]$Profiles)

    @($Profiles | ForEach-Object {
        $skillsRoot = Join-Path $_.Path '.agents/skills'
        $skills = @()
        if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
            $skills = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | Sort-Object Name | ForEach-Object {
                [ordered]@{
                    Name = $_.Name
                    Skill = Get-TaskFileIdentity -Path (Join-Path $_.FullName 'SKILL.md')
                }
            })
        }
        [ordered]@{
            Name = $_.Name
            Path = [IO.Path]::GetFullPath($_.Path)
            Instructions = Get-TaskFileIdentity -Path (Join-Path $_.Path 'AGENTS.md')
            Skills = $skills
        }
    })
}

function Get-TaskGitCommit {
    param([string]$RepositoryPath, [string]$Reference)

    # Identity lookups are read-only planning reads: never let them lazily fetch.
    return Get-GitCommitWithoutLazyFetch -RepositoryPath $RepositoryPath -Reference $Reference
}

function Get-TaskRepositoryIdentity {
    param([object[]]$Repositories, [object[]]$WorktreeOperations)

    @($Repositories | Sort-Object Name | ForEach-Object {
        $repository = $_
        $operation = $WorktreeOperations | Where-Object Repository -eq $repository.Name | Select-Object -First 1
        $remoteBase = if ($repository.BaseBranch -match '^[^/]+/.+') { $repository.BaseBranch } else { "origin/$($repository.BaseBranch)" }
        $worktree = $null
        if ($operation -and (Test-Path -LiteralPath $operation.Destination -PathType Container)) {
            # Read-only: a partial clone must not fetch just to answer this lookup.
            $headResult = Invoke-TaskWorktreeGitCommand -RepositoryPath $operation.Destination -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}') -NoLazyFetch
            $head = if ($headResult.ExitCode -eq 0) { ([string](@($headResult.Output -split "`r?`n") | Select-Object -First 1)).Trim() } else { $null }
            $branch = & git -C $operation.Destination branch --show-current 2>$null
            $worktree = [ordered]@{
                CommonDir = Get-PlanGitCommonDir -RepositoryPath $operation.Destination
                GitDir = Get-PlanGitDir -RepositoryPath $operation.Destination
                Head = $head
                Branch = ([string]($branch | Select-Object -First 1)).Trim()
            }
        }
        [ordered]@{
            Name = $repository.Name
            Path = [IO.Path]::GetFullPath($repository.Path)
            CommonDir = Get-PlanGitCommonDir -RepositoryPath $repository.Path
            RequestedBranch = $repository.Branch
            BaseBranch = $repository.BaseBranch
            StartCommit = if ($repository.PSObject.Properties['StartCommit']) { $repository.StartCommit } else { $null }
            LocalBranchCommit = Get-TaskGitCommit -RepositoryPath $repository.Path -Reference "refs/heads/$($repository.Branch)"
            RemoteBranchCommit = Get-TaskGitCommit -RepositoryPath $repository.Path -Reference "refs/remotes/origin/$($repository.Branch)"
            LocalBaseCommit = Get-TaskGitCommit -RepositoryPath $repository.Path -Reference "refs/heads/$($repository.BaseBranch)"
            RemoteBaseCommit = Get-TaskGitCommit -RepositoryPath $repository.Path -Reference "refs/remotes/$remoteBase"
            SelectedSource = if ($operation -and $operation.PSObject.Properties['Source']) { $operation.Source } else { $null }
            # Bind the commit selected at plan time. Re-resolving a ref here would
            # let a moved remote ref, or a local branch named like the shorthand,
            # change the reviewed identity and the applied start point.
            SelectedSourceCommit = if ($operation -and $operation.PSObject.Properties['SourceCommit'] -and $operation.SourceCommit) {
                [string]$operation.SourceCommit
            }
            elseif ($operation -and $operation.PSObject.Properties['Source'] -and $operation.Source) {
                Get-TaskGitCommit -RepositoryPath $repository.Path -Reference $operation.Source
            }
            else { $null }
            Operation = $operation
            Worktree = $worktree
        }
    })
}

function Get-TaskScaffoldIdentityMaterial {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$TasksRoot,
        [Parameter(Mandatory)][string]$ScaffoldRoot,
        [Parameter(Mandatory)][object[]]$EffectiveProfiles,
        [Parameter(Mandatory)][object[]]$WorktreeOperations,
        [Parameter(Mandatory)][object]$Plan,
        [string]$CtxConfigRoot,
        [string]$CtxExternalProfilesRoot
    )

    $taskPath = Join-Path $TasksRoot $Request.Task.Key
    $taskFiles = @('task.json', 'PRD.md', 'PLAN.md', 'STATUS.md', '.ctx') | ForEach-Object {
        Get-TaskFileIdentity -Path (Join-Path $taskPath $_)
    }
    $requestTaskFiles = if ($Request.PSObject.Properties['TaskFiles']) { @($Request.TaskFiles) } else { @() }
    $customTaskFiles = @($requestTaskFiles | ForEach-Object {
        if (Test-TaskCustomPathSafety -TaskPath $taskPath -RelativePath $_.Path) {
            $destinationState = Get-TaskCustomFileState -TaskPath $taskPath -RelativePath $_.Path
            $destinationMaterial = [ordered]@{
                Path = $destinationState.Path
                Exists = $destinationState.Exists
                IsFile = $destinationState.IsFile
                IsReparsePoint = $destinationState.IsReparsePoint
                Sha256 = $destinationState.Sha256
            }
        }
        else {
            $destinationMaterial = [ordered]@{
                Path = Get-TaskCustomFileDestination -TaskPath $taskPath -RelativePath $_.Path
                Exists = $true
                IsFile = $false
                IsReparsePoint = $true
                Sha256 = $null
            }
        }
        [ordered]@{
            Path = $_.Path
            ContentSha256 = Get-TaskFileContentHash -Content $_.Content
            Destination = $destinationMaterial
        }
    })
    $engineFiles = @(
        (Join-Path $ScaffoldRoot 'scripts/Invoke-TaskScaffold.ps1'),
        (Join-Path $ScaffoldRoot 'scripts/Private/TaskPlanIdentity.psm1'),
        (Join-Path $ScaffoldRoot 'scripts/Private/TaskContract.psm1'),
        (Join-Path $ScaffoldRoot 'scripts/Private/GitWorktree.psm1'),
        (Join-Path $ScaffoldRoot 'scripts/Update-WorkspaceFolders.ps1'),
        (Join-Path $ScaffoldRoot 'templates/PRD.md')
    ) | ForEach-Object { Get-TaskFileIdentity -Path $_ }

    $normalizedRequest = [ordered]@{
        SchemaVersion = 2
        Task = [ordered]@{
            Key = $Request.Task.Key
            Title = $Request.Task.Title
            PrdPath = $Request.Task.PrdPath
        }
        Repositories = @($Request.Repositories | ForEach-Object {
            $startCommit = if ($_.PSObject.Properties['StartCommit']) { $_.StartCommit } else { $null }
            [ordered]@{ Name = $_.Name; Path = [IO.Path]::GetFullPath($_.Path); BaseBranch = $_.BaseBranch; Branch = $_.Branch; StartCommit = $startCommit }
        })
        Profiles = @($Request.Profiles | ForEach-Object {
            [ordered]@{ Name = $_.Name; Path = [IO.Path]::GetFullPath($_.Path) }
        })
        TaskFiles = @($requestTaskFiles | ForEach-Object {
            [ordered]@{ Path = $_.Path; ContentSha256 = Get-TaskFileContentHash -Content $_.Content }
        })
        Workspace = if ($Request.Workspace) { [ordered]@{ File = [IO.Path]::GetFullPath($Request.Workspace.File) } } else { $null }
    }
    $prdSource = if (-not [string]::IsNullOrWhiteSpace($Request.Task.PrdPath)) {
        Get-TaskFileIdentity -Path $Request.Task.PrdPath
    }
    else { $null }

    [ordered]@{
        IdentityVersion = 1
        Request = $normalizedRequest
        TasksRoot = [IO.Path]::GetFullPath($TasksRoot)
        CtxConfigRoot = if ($PSBoundParameters.ContainsKey('CtxConfigRoot')) { $CtxConfigRoot } else { $null }
        CtxExternalProfilesRoot = if ($PSBoundParameters.ContainsKey('CtxExternalProfilesRoot')) { $CtxExternalProfilesRoot } else { $null }
        TaskExists = Test-Path -LiteralPath $taskPath -PathType Container
        TaskFiles = $taskFiles
        CustomTaskFiles = $customTaskFiles
        ArtifactsDirectoryExists = Test-Path -LiteralPath (Join-Path $taskPath 'artifacts') -PathType Container
        PrdSource = $prdSource
        Plan = $Plan
        Profiles = Get-TaskProfileIdentity -Profiles $EffectiveProfiles
        Repositories = Get-TaskRepositoryIdentity -Repositories $Request.Repositories -WorktreeOperations $WorktreeOperations
        EngineFiles = @($engineFiles)
    }
}

function Get-TaskPlanIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$TasksRoot,
        [Parameter(Mandatory)][string]$ScaffoldRoot,
        [Parameter(Mandatory)][object[]]$EffectiveProfiles,
        [Parameter(Mandatory)][object[]]$WorktreeOperations,
        [Parameter(Mandatory)][object]$Plan,
        [string]$CtxConfigRoot,
        [string]$CtxExternalProfilesRoot
    )

    $material = Get-TaskScaffoldIdentityMaterial @PSBoundParameters
    $json = ConvertTo-Json -InputObject $material -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $digest = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($digest).ToLowerInvariant()
}

Export-ModuleMember -Function Get-TaskPlanIdentity
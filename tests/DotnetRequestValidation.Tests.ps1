BeforeAll {
    $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:ProjectPath = Join-Path $script:RepositoryRoot 'src/TaskScaffold/TaskScaffold.csproj'

    function Invoke-RequestValidation {
        param(
            [Parameter(Mandatory)][string]$RequestPath,
            [string]$WorkingDirectory,
            [string]$CliHome
        )

        if (-not $WorkingDirectory) { $WorkingDirectory = $script:RepositoryRoot }
        if (-not $CliHome) { $CliHome = Join-Path $TestDrive 'dotnet-cli-home' }
        if (-not (Test-Path -LiteralPath $CliHome)) {
            New-Item -ItemType Directory -Path $CliHome -Force | Out-Null
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'dotnet'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.Environment['DOTNET_CLI_HOME'] = $CliHome
        $startInfo.Environment['DOTNET_NOLOGO'] = '1'
        $startInfo.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
        $startInfo.Environment['DOTNET_SKIP_FIRST_TIME_EXPERIENCE'] = '1'

        foreach ($argument in @('run', '--project', $script:ProjectPath, '--', 'request', 'validate', '--request', $RequestPath)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }

    function New-Profile {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Name,
            [switch]$WithSkill,
            [switch]$WithoutAgents,
            [switch]$LooseSkillFile,
            [switch]$SkillWithoutManifest,
            [string]$SkillName = 'skill-one'
        )

        $path = Join-Path $Root $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        if (-not $WithoutAgents) {
            Set-Content -LiteralPath (Join-Path $path 'AGENTS.md') -Value "# $Name" -NoNewline
        }
        if ($WithSkill) {
            $skillPath = Join-Path $path ".agents/skills/$SkillName"
            New-Item -ItemType Directory -Path $skillPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $skillPath 'SKILL.md') -Value '# skill' -NoNewline
        }
        if ($LooseSkillFile) {
            $skillsPath = Join-Path $path '.agents/skills'
            New-Item -ItemType Directory -Path $skillsPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $skillsPath 'loose.txt') -Value 'not a skill' -NoNewline
        }
        if ($SkillWithoutManifest) {
            New-Item -ItemType Directory -Path (Join-Path $path '.agents/skills/incomplete') -Force | Out-Null
        }
        return $path
    }

    function New-BaseRequest {
        param(
            [Parameter(Mandatory)][string]$RepositoryPath,
            [object[]]$Profiles,
            [string]$RepositoryName = 'api',
            [string]$BaseBranch = 'main',
            [string]$Branch = 'feature/FEATURE-123',
            [string]$Title = 'Add endpoint',
            [string]$Key = 'FEATURE-123',
            [int]$SchemaVersion = 3
        )

        $request = [ordered]@{
            schemaVersion = $SchemaVersion
            task = [ordered]@{ key = $Key; title = $Title }
            repositories = @([ordered]@{ name = $RepositoryName; path = $RepositoryPath; baseBranch = $BaseBranch; branch = $Branch })
        }
        if ($null -ne $Profiles) { $request.profiles = @($Profiles) }
        return $request
    }

    function Write-Request {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object]$Request
        )

        $content = if ($Request -is [string]) { $Request } else { $Request | ConvertTo-Json -Depth 12 }
        Set-Content -LiteralPath $Path -Value $content -NoNewline
        return $Path
    }

    function Assert-CommandFailure {
        param(
            [Parameter(Mandatory)]$Run,
            [Parameter(Mandatory)][string]$Case
        )

        $Run.ExitCode | Should -Be 2 -Because "$Case should be rejected (stderr: $($Run.StdErr.Trim()))"
        $Run.StdOut.Trim() | Should -Be '' -Because "$Case should not write stdout"
        $Run.StdErr.Trim() | Should -Not -BeNullOrEmpty -Because "$Case should explain the failure"
        $Run.StdErr | Should -Not -Match '(?m)^\s+at\s' -Because "$Case should not emit a stack trace"
        $Run.StdErr | Should -Not -Match 'Unhandled exception' -Because "$Case should not emit an unhandled exception"
    }

    function Assert-SuccessJson {
        param(
            [Parameter(Mandatory)]$Run,
            [Parameter(Mandatory)][string]$Case
        )

        $Run.ExitCode | Should -Be 0 -Because "$Case should validate (stderr: $($Run.StdErr.Trim()))"
        $text = $Run.StdOut.Trim()
        $text | Should -Match '(?s)^\{.*\}$' -Because "$Case should emit exactly one JSON object"
        return ($text | ConvertFrom-Json)
    }

    function Assert-PropertySet {
        param(
            [Parameter(Mandatory)]$Object,
            [Parameter(Mandatory)][string[]]$Expected,
            [string]$Case = 'the object'
        )

        @($Object.PSObject.Properties.Name | Sort-Object) | Should -Be @($Expected | Sort-Object) -Because "$Case should expose exactly the contract properties"
    }

    function Get-TreeSnapshot {
        param([Parameter(Mandatory)][string]$Root)

        $entries = foreach ($item in (Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)) {
            $relative = [IO.Path]::GetRelativePath($Root, $item.FullName)
            if ($item.PSIsContainer) {
                "D:$relative"
            }
            else {
                "F:${relative}:$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
            }
        }
        return @($entries)
    }
}

Describe 'dotnet request validate' {
    Context 'when the request is a valid schemaVersion 3 document' {
        It 'emits the exact JSON shape with normalized metadata' {
            $root = Join-Path $TestDrive 'valid'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $prd = Join-Path $root 'prd.md'
            Set-Content -LiteralPath $prd -Value '# PRD' -NoNewline
            $workspaceFile = Join-Path $root 'team.code-workspace'
            $team = New-Profile -Root $root -Name 'profiles/team' -WithSkill -SkillName 'team-skill'
            $dotnet = New-Profile -Root $root -Name 'profiles/dotnet'
            $request = New-BaseRequest -RepositoryPath $repository.FullName -Profiles @(
                [ordered]@{ name = 'team'; path = $team },
                [ordered]@{ name = 'dotnet'; path = $dotnet }
            )
            $request.task['prdPath'] = $prd
            $request['workspace'] = [ordered]@{ file = $workspaceFile }
            $requestPath = Write-Request -Path (Join-Path $root 'task-request.json') -Request $request

            $result = Assert-SuccessJson -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case 'valid v3 request'

            Assert-PropertySet -Object $result -Expected @('valid', 'schemaVersion', 'taskKey', 'repositories', 'prdPath', 'profiles', 'workspaceFile') -Case 'the success payload'
            $result.valid | Should -BeTrue
            $result.schemaVersion | Should -Be 3
            $result.taskKey | Should -Be 'FEATURE-123'
            $result.prdPath | Should -Be ([IO.Path]::GetFullPath($prd))
            $result.workspaceFile | Should -Be ([IO.Path]::GetFullPath($workspaceFile))
            @($result.repositories).Count | Should -Be 1
            Assert-PropertySet -Object $result.repositories[0] -Expected @('name', 'path') -Case 'the repository entry'
            $result.repositories[0].name | Should -Be 'api'
            $result.repositories[0].path | Should -Be ([IO.Path]::GetFullPath($repository.FullName))
            @($result.profiles).Count | Should -Be 2
            Assert-PropertySet -Object $result.profiles[0] -Expected @('name', 'path') -Case 'the profile entry'
            $result.profiles.name | Should -Be @('team', 'dotnet')
            $result.profiles[0].path | Should -Be ([IO.Path]::GetFullPath($team))
            $result.profiles[1].path | Should -Be ([IO.Path]::GetFullPath($dotnet))
        }

        It 'allows an omitted optional PRD and workspace and reports them as null' {
            $root = Join-Path $TestDrive 'no-optional'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $request = New-BaseRequest -RepositoryPath $repository.FullName
            $requestPath = Write-Request -Path (Join-Path $root 'task-request.json') -Request $request

            $result = Assert-SuccessJson -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case 'request without PRD or workspace'

            $result.prdPath | Should -BeNullOrEmpty
            $result.workspaceFile | Should -BeNullOrEmpty
            @($result.profiles).Count | Should -Be 0
        }
    }

    Context 'when repository, PRD, and workspace paths are relative' {
        It 'resolves them against the request file directory independent of the process CWD' {
            $root = Join-Path $TestDrive 'resolution'
            $requestDir = New-Item -ItemType Directory -Path (Join-Path $root 'requests') -Force
            $otherCwd = New-Item -ItemType Directory -Path (Join-Path $root 'elsewhere') -Force
            New-Item -ItemType Directory -Path (Join-Path $requestDir.FullName 'canons/api') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $requestDir.FullName 'prd.md') -Value '# PRD' -NoNewline
            $request = New-BaseRequest -RepositoryPath 'canons/api'
            $request.task['prdPath'] = 'prd.md'
            $request['workspace'] = [ordered]@{ file = 'team.code-workspace' }
            $requestPath = Write-Request -Path (Join-Path $requestDir.FullName 'task-request.json') -Request $request

            $fromRepositoryRoot = Assert-SuccessJson -Run (Invoke-RequestValidation -RequestPath $requestPath -WorkingDirectory $script:RepositoryRoot) -Case 'relative paths from the repository root'
            $fromOtherCwd = Assert-SuccessJson -Run (Invoke-RequestValidation -RequestPath $requestPath -WorkingDirectory $otherCwd.FullName) -Case 'relative paths from another CWD'

            $expectedRepository = [IO.Path]::GetFullPath((Join-Path $requestDir.FullName 'canons/api'))
            $expectedPrd = [IO.Path]::GetFullPath((Join-Path $requestDir.FullName 'prd.md'))
            $expectedWorkspace = [IO.Path]::GetFullPath((Join-Path $requestDir.FullName 'team.code-workspace'))

            foreach ($result in @($fromRepositoryRoot, $fromOtherCwd)) {
                $result.repositories[0].path | Should -Be $expectedRepository
                $result.prdPath | Should -Be $expectedPrd
                $result.workspaceFile | Should -Be $expectedWorkspace
            }
        }
    }

    Context 'when profiles are requested' {
        It 'preserves requested order and accepts AGENTS.md with valid skill directories' {
            $root = Join-Path $TestDrive 'ordered-profiles'
            $zeta = New-Profile -Root $root -Name 'zeta' -WithSkill -SkillName 'zeta-skill'
            $alpha = New-Profile -Root $root -Name 'alpha'
            New-Item -ItemType Directory -Path (Join-Path $alpha '.agents/skills/alpha-skill') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $alpha '.agents/skills/alpha-skill/SKILL.md') -Value '# alpha' -NoNewline
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $request = New-BaseRequest -RepositoryPath $repository.FullName -Profiles @(
                [ordered]@{ name = 'zeta'; path = $zeta },
                [ordered]@{ name = 'alpha'; path = $alpha }
            )
            $requestPath = Write-Request -Path (Join-Path $root 'task-request.json') -Request $request

            $result = Assert-SuccessJson -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case 'ordered profiles'

            $result.profiles.name | Should -Be @('zeta', 'alpha')
            $result.profiles[0].path | Should -Be ([IO.Path]::GetFullPath($zeta))
            $result.profiles[1].path | Should -Be ([IO.Path]::GetFullPath($alpha))
        }
    }

    Context 'when schemaVersion is unsupported' {
        It 'rejects schemaVersion 1 and 2' {
            $root = Join-Path $TestDrive 'schema-version'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force

            foreach ($version in 1, 2) {
                $request = New-BaseRequest -RepositoryPath $repository.FullName -SchemaVersion $version
                $requestPath = Write-Request -Path (Join-Path $root "request-v$version.json") -Request $request
                Assert-CommandFailure -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case "schemaVersion $version"
            }
        }
    }

    Context 'when unknown fields are present' {
        It 'rejects unknown root and nested fields including taskFiles' {
            $root = Join-Path $TestDrive 'unknown-fields'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $profile = New-Profile -Root $root -Name 'team'

            $rootTaskFiles = New-BaseRequest -RepositoryPath $repository.FullName
            $rootTaskFiles['taskFiles'] = @()
            $rootUnexpected = New-BaseRequest -RepositoryPath $repository.FullName
            $rootUnexpected['unexpectedRoot'] = 'value'
            $taskUnexpected = New-BaseRequest -RepositoryPath $repository.FullName
            $taskUnexpected.task['unexpected'] = 'value'
            $repositoryUnexpected = New-BaseRequest -RepositoryPath $repository.FullName
            $repositoryUnexpected.repositories[0]['unexpected'] = 'value'
            $profileUnexpected = New-BaseRequest -RepositoryPath $repository.FullName -Profiles @([ordered]@{ name = 'team'; path = $profile; unexpected = 'value' })
            $workspaceUnexpected = New-BaseRequest -RepositoryPath $repository.FullName
            $workspaceUnexpected['workspace'] = [ordered]@{ file = 'team.code-workspace'; unexpected = 'value' }

            $cases = [ordered]@{
                'root field taskFiles'          = $rootTaskFiles
                'unexpected root field'         = $rootUnexpected
                'unexpected task field'         = $taskUnexpected
                'unexpected repository field'   = $repositoryUnexpected
                'unexpected profile field'      = $profileUnexpected
                'unexpected workspace field'    = $workspaceUnexpected
            }

            $index = 0
            foreach ($name in $cases.Keys) {
                $requestPath = Write-Request -Path (Join-Path $root "unknown-$index.json") -Request $cases[$name]
                Assert-CommandFailure -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case $name
                $index++
            }
        }
    }

    Context 'when required fields are malformed or invalid' {
        It 'rejects malformed JSON, missing or invalid fields, zero or duplicate repositories, and invalid branches' {
            $root = Join-Path $TestDrive 'invalid-core'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $repositoryPath = $repository.FullName

            $missingKey = New-BaseRequest -RepositoryPath $repositoryPath
            $missingKey.task.Remove('key')
            $missingTitle = New-BaseRequest -RepositoryPath $repositoryPath
            $missingTitle.task.Remove('title')
            $zeroRepositories = New-BaseRequest -RepositoryPath $repositoryPath
            $zeroRepositories.repositories = @()
            $missingRepositoryName = New-BaseRequest -RepositoryPath $repositoryPath
            $missingRepositoryName.repositories[0].Remove('name')
            $missingRepositoryPath = New-BaseRequest -RepositoryPath $repositoryPath
            $missingRepositoryPath.repositories[0].Remove('path')
            $missingBaseBranch = New-BaseRequest -RepositoryPath $repositoryPath
            $missingBaseBranch.repositories[0].Remove('baseBranch')
            $missingBranch = New-BaseRequest -RepositoryPath $repositoryPath
            $missingBranch.repositories[0].Remove('branch')
            $duplicateSameCase = New-BaseRequest -RepositoryPath $repositoryPath
            $duplicateSameCase.repositories = @(
                [ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/one' },
                [ordered]@{ name = 'api'; path = (Join-Path $repositoryPath 'other'); baseBranch = 'main'; branch = 'feature/two' }
            )
            $duplicateIgnoringCase = New-BaseRequest -RepositoryPath $repositoryPath
            $duplicateIgnoringCase.repositories = @(
                [ordered]@{ name = 'api'; path = $repositoryPath; baseBranch = 'main'; branch = 'feature/one' },
                [ordered]@{ name = 'API'; path = (Join-Path $repositoryPath 'other'); baseBranch = 'main'; branch = 'feature/two' }
            )

            $cases = [ordered]@{
                'malformed JSON'                       = '{ "schemaVersion": 3, '
                'missing task key'                     = $missingKey
                'missing task title'                   = $missingTitle
                'blank task title'                     = (New-BaseRequest -RepositoryPath $repositoryPath -Title '   ')
                'invalid task key'                     = (New-BaseRequest -RepositoryPath $repositoryPath -Key 'bad key')
                'escaping task key'                    = (New-BaseRequest -RepositoryPath $repositoryPath -Key '../escape')
                'zero repositories'                    = $zeroRepositories
                'invalid repository name'              = (New-BaseRequest -RepositoryPath $repositoryPath -RepositoryName '../outside')
                'missing repository name'              = $missingRepositoryName
                'missing repository path'              = $missingRepositoryPath
                'missing base branch'                  = $missingBaseBranch
                'missing branch'                       = $missingBranch
                'invalid base branch name'             = (New-BaseRequest -RepositoryPath $repositoryPath -BaseBranch 'bad..ref')
                'invalid branch name'                  = (New-BaseRequest -RepositoryPath $repositoryPath -Branch 'feature/a..b')
                'duplicate repository name'            = $duplicateSameCase
                'duplicate repository name ignoring case' = $duplicateIgnoringCase
                'trailing newline task key'            = (New-BaseRequest -RepositoryPath $repositoryPath -Key "FEATURE-123`n")
                'trailing newline repository name'     = (New-BaseRequest -RepositoryPath $repositoryPath -RepositoryName "api`n")
            }

            $index = 0
            foreach ($name in $cases.Keys) {
                $requestPath = Write-Request -Path (Join-Path $root "invalid-$index.json") -Request $cases[$name]
                Assert-CommandFailure -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case $name
                $index++
            }
        }
    }

    Context 'when profiles are invalid' {
        It 'rejects missing AGENTS.md, duplicate or reserved names, and malformed skill entries' {
            $root = Join-Path $TestDrive 'invalid-profiles'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $repositoryPath = $repository.FullName
            $valid = New-Profile -Root $root -Name 'valid'
            $other = New-Profile -Root $root -Name 'other'
            $withoutAgents = New-Profile -Root $root -Name 'without-agents' -WithoutAgents
            $looseSkill = New-Profile -Root $root -Name 'loose-skill' -LooseSkillFile
            $incompleteSkill = New-Profile -Root $root -Name 'incomplete-skill' -SkillWithoutManifest

            $cases = [ordered]@{
                'missing AGENTS.md'                 = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $withoutAgents }))
                'relative profile path'             = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = 'relative/profile' }))
                'missing profile directory'         = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = (Join-Path $root 'absent') }))
                'invalid profile name'              = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'bad name'; path = $valid }))
                'duplicate profile name'            = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $valid }, [ordered]@{ name = 'team'; path = $other }))
                'duplicate profile name ignoring case' = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $valid }, [ordered]@{ name = 'TEAM'; path = $other }))
                'reserved profile name'             = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'task-scaffold'; path = $valid }))
                'reserved profile name config-root'             = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'config-root'; path = $valid }))
                'reserved profile name external-profiles-root'  = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'external-profiles-root'; path = $valid }))
                'loose file under .agents/skills'   = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $looseSkill }))
                'skill directory without SKILL.md'  = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = 'team'; path = $incompleteSkill }))
                'trailing newline profile name'     = (New-BaseRequest -RepositoryPath $repositoryPath -Profiles @([ordered]@{ name = "team`n"; path = $valid }))
            }

            $index = 0
            foreach ($name in $cases.Keys) {
                $requestPath = Write-Request -Path (Join-Path $root "profile-$index.json") -Request $cases[$name]
                Assert-CommandFailure -Run (Invoke-RequestValidation -RequestPath $requestPath) -Case $name
                $index++
            }
        }

        It 'rejects drive-relative profile paths as not fully qualified' -Skip:(-not $IsWindows) {
            $root = Join-Path $TestDrive 'windows-profile-path'
            $workingDirectory = Join-Path $root 'process-cwd'
            New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
            $request = New-BaseRequest -RepositoryPath 'canons/api' -Profiles @(
                [ordered]@{ name = 'team'; path = 'C:relative-profile' }
            )
            $requestPath = Write-Request -Path (Join-Path $root 'task-request.json') -Request $request

            $run = Invoke-RequestValidation -RequestPath $requestPath -WorkingDirectory $workingDirectory
            Assert-CommandFailure -Run $run -Case 'drive-relative profile path'
            $run.StdErr | Should -Match 'absolute' -Because "the rejection must name the absolute-path requirement (stderr: $($run.StdErr.Trim()))"
        }
    }

    Context 'when validation runs' {
        It 'leaves fixture files and directories unchanged' {
            $root = Join-Path $TestDrive 'immutable'
            $profile = New-Profile -Root $root -Name 'team' -WithSkill -SkillName 'team-skill'
            $repository = New-Item -ItemType Directory -Path (Join-Path $root 'canons/api') -Force
            $prd = Join-Path $root 'prd.md'
            Set-Content -LiteralPath $prd -Value '# unchanged' -NoNewline
            $request = New-BaseRequest -RepositoryPath $repository.FullName -Profiles @([ordered]@{ name = 'team'; path = $profile })
            $request.task['prdPath'] = $prd
            $requestPath = Write-Request -Path (Join-Path $root 'task-request.json') -Request $request

            $beforeValid = Get-TreeSnapshot -Root $root
            [void](Assert-SuccessJson -Run (Invoke-RequestValidation -RequestPath $requestPath -WorkingDirectory $root) -Case 'immutable valid request')
            $afterValid = Get-TreeSnapshot -Root $root
            $afterValid | Should -Be $beforeValid

            $invalid = New-BaseRequest -RepositoryPath $repository.FullName
            $invalid['taskFiles'] = @()
            $invalidPath = Write-Request -Path (Join-Path $root 'invalid.json') -Request $invalid

            $beforeInvalid = Get-TreeSnapshot -Root $root
            Assert-CommandFailure -Run (Invoke-RequestValidation -RequestPath $invalidPath -WorkingDirectory $root) -Case 'immutable invalid request'
            $afterInvalid = Get-TreeSnapshot -Root $root
            $afterInvalid | Should -Be $beforeInvalid
        }
    }
}

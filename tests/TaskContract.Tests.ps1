BeforeAll {
    $module = Join-Path $PSScriptRoot '../scripts/Private/TaskContract.psm1'
    Import-Module $module -Force
}

Describe 'ConvertTo-TaskRequest' {
    It 'preserves an explicit branch for each repository' {
        $requestPath = Join-Path $TestDrive 'task-request.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" },
    { "name": "web", "path": "C:/work/canons/web", "baseBranch": "origin/develop", "branch": "bump-version-1.2" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        $request = ConvertTo-TaskRequest -Path $requestPath

        $request.Task.Key | Should -Be 'FEATURE-123'
        $request.Repositories.Name | Should -Be @('api', 'web')
        $request.Repositories[0].Branch | Should -Be 'feature/FEATURE-123'
        $request.Repositories[1].Branch | Should -Be 'bump-version-1.2'
    }

      It 'accepts ordered resolved profiles and normalizes legacy requests' {
        $profilePaths = @('team', 'dotnet') | ForEach-Object {
          $profilePath = Join-Path $TestDrive $_
          New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
          Set-Content -LiteralPath (Join-Path $profilePath 'AGENTS.md') -Value "# $_"
          $profilePath
        }
        $requestPath = Join-Path $TestDrive 'profiles-request.json'
        [ordered]@{
          schemaVersion = 2
          task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
          repositories = @([ordered]@{ name = 'api'; path = 'C:/work/canons/api'; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
          profiles = @(
            [ordered]@{ name = 'team'; path = $profilePaths[0] },
            [ordered]@{ name = 'dotnet'; path = $profilePaths[1] }
          )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline

        $request = ConvertTo-TaskRequest -Path $requestPath

        $request.SchemaVersion | Should -Be 2
        $request.Profiles.Name | Should -Be @('team', 'dotnet')
        $request.Profiles[0].Path | Should -Be ([IO.Path]::GetFullPath($profilePaths[0]))

        $legacyRequestPath = Join-Path $TestDrive 'legacy-request.json'
        [ordered]@{
          schemaVersion = 1
          task = [ordered]@{ key = 'FEATURE-124'; title = 'Legacy request' }
          repositories = @([ordered]@{ name = 'api'; path = 'C:/work/canons/api'; baseBranch = 'main'; branch = 'feature/FEATURE-124' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $legacyRequestPath -NoNewline

        $legacyRequest = ConvertTo-TaskRequest -Path $legacyRequestPath
        $legacyRequest.SchemaVersion | Should -Be 2
        $legacyRequest.Profiles | Should -BeNullOrEmpty
      }

      It 'rejects invalid profile roots and duplicate profile identities or paths' {
        $profilePath = Join-Path $TestDrive 'valid-profile'
        New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profilePath 'AGENTS.md') -Value '# Team'
        $missingAgentsPath = Join-Path $TestDrive 'missing-agents'
        New-Item -ItemType Directory -Path $missingAgentsPath -Force | Out-Null
        $otherProfilePath = Join-Path $TestDrive 'other-profile'
        New-Item -ItemType Directory -Path $otherProfilePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $otherProfilePath 'AGENTS.md') -Value '# Other'
        $invalidSkillsPath = Join-Path $TestDrive 'invalid-skills-profile'
        New-Item -ItemType Directory -Path (Join-Path $invalidSkillsPath '.agents/skills/incomplete') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $invalidSkillsPath 'AGENTS.md') -Value '# Invalid skills'
        $requestPath = Join-Path $TestDrive 'invalid-profile-request.json'
        $baseRequest = [ordered]@{
          schemaVersion = 2
          task = [ordered]@{ key = 'FEATURE-123'; title = 'Add endpoint' }
          repositories = @([ordered]@{ name = 'api'; path = 'C:/work/canons/api'; baseBranch = 'main'; branch = 'feature/FEATURE-123' })
        }
        $cases = @(
          [pscustomobject]@{ Profiles = @([ordered]@{ name = 'team'; path = (Join-Path $TestDrive 'missing-profile') }); Error = '*directory does not exist*' },
          [pscustomobject]@{ Profiles = @([ordered]@{ name = 'team'; path = $missingAgentsPath }); Error = '*AGENTS.md is required*' },
          [pscustomobject]@{ Profiles = @([ordered]@{ name = 'team'; path = $profilePath }, [ordered]@{ name = 'TEAM'; path = $otherProfilePath }); Error = '*duplicate profile name*' },
            [pscustomobject]@{ Profiles = @([ordered]@{ name = 'team'; path = $profilePath }, [ordered]@{ name = 'dotnet'; path = (Join-Path $profilePath '../valid-profile') }); Error = '*duplicate profile path*' },
          [pscustomobject]@{ Profiles = @([ordered]@{ name = 'task-scaffold'; path = $profilePath }); Error = '*reserved*' },
            [pscustomobject]@{ Profiles = @([ordered]@{ name = 'team'; path = $invalidSkillsPath }); Error = '*each entry in .agents/skills*' },
          [pscustomobject]@{ Profiles = @([ordered]@{ name = 'team' }); Error = '*absolute resolved directory*' }
        )

        foreach ($case in $cases) {
          $invalidRequest = [ordered]@{
            schemaVersion = $baseRequest.schemaVersion
            task = $baseRequest.task
            repositories = $baseRequest.repositories
            profiles = $case.Profiles
          }
          $invalidRequest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -NoNewline
          { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw $case.Error
        }
      }

    It 'accepts an omitted or blank PRD source path' {
        $requestPath = Join-Path $TestDrive 'optional-prd-request.json'
        $requestJson = @(
            @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
'@,
            @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
'@
        )

        foreach ($json in $requestJson) {
            $json | Set-Content -LiteralPath $requestPath -NoNewline
            $request = ConvertTo-TaskRequest -Path $requestPath
            $request.Task.PrdPath | Should -BeNullOrEmpty
        }
    }

    It 'rejects duplicate repository names' {
        $requestPath = Join-Path $TestDrive 'duplicate-repository.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" },
    { "name": "api", "path": "C:/work/canons/web", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*duplicate repository name*'
    }

    It 'rejects a task key that escapes its task directory' {
        $requestPath = Join-Path $TestDrive 'unsafe-key.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "../escape", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "origin/main", "branch": "feature/FEATURE-123" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*invalid task key*'
    }
    It 'rejects repository names that escape the worktrees directory' {
        $requestPath = Join-Path $TestDrive 'unsafe-repository.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "../../outside", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/FEATURE-123" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*invalid repository name*'
    }

    It 'rejects invalid Git branch names' {
        $requestPath = Join-Path $TestDrive 'unsafe-branch.json'
        @'
{
  "schemaVersion": 1,
  "task": { "key": "FEATURE-123", "title": "Add endpoint", "prdPath": "C:/input/FEATURE-123.md" },
  "repositories": [
    { "name": "api", "path": "C:/work/canons/api", "baseBranch": "main", "branch": "feature/a..b" }
  ]
}
'@ | Set-Content -LiteralPath $requestPath -NoNewline

        { ConvertTo-TaskRequest -Path $requestPath } | Should -Throw '*invalid Git branch*'
    }
}

Describe 'Invoke-TaskRequestBuilder' {
    It 'selects repositories interactively when RepositoryNames is omitted' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $canonsPath = Join-Path $workspaceRoot 'canons'
        New-Item -ItemType Directory -Path (Join-Path $canonsPath 'api') -Force | Out-Null
        @'
{
  "schemaVersion": 1,
  "repositories": { "api": { "baseBranch": "develop" } }
}
'@ | Set-Content -LiteralPath (Join-Path $workspaceRoot 'task-scaffold.settings.json') -NoNewline
        $outputPath = Join-Path $workspaceRoot 'omitted-request.json'
        Import-Module (Join-Path $PSScriptRoot '../scripts/Private/TerminalSelector.psm1') -Force
        $global:taskRequestBuilderEvents = @()
        Mock Select-TaskRepositories { $global:taskRequestBuilderEvents += 'selector'; @('api') }
        Mock Write-Host {
            if ($Object -eq 'Choose repositories:') { $global:taskRequestBuilderEvents += 'picker heading' }
        }
        $global:taskRequestBuilderAnswers = @('FEATURE-123', 'Add endpoint', '', 'y')
        Mock Read-Host {
            param($Prompt)
            $global:taskRequestBuilderEvents += "prompt:$Prompt"
            $answer = $global:taskRequestBuilderAnswers[0]
            $global:taskRequestBuilderAnswers = @($global:taskRequestBuilderAnswers | Select-Object -Skip 1)
            $answer
        }

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskRequestBuilder.ps1'
        & $script -WorkspaceRoot $workspaceRoot -OutputPath $outputPath | Out-Null

        $request = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $request.schemaVersion | Should -Be 2
        $request.repositories.Name | Should -Be 'api'
        $request.task.prdPath | Should -BeNullOrEmpty
        $global:taskRequestBuilderEvents[0..2] | Should -Be @('prompt:Task key', 'prompt:Task title', 'prompt:PRD path (leave blank to create a starter)')
        $global:taskRequestBuilderEvents[3] | Should -Be 'picker heading'
        $global:taskRequestBuilderEvents[4] | Should -Be 'selector'
    }

    It 'suggests configured canons and writes a reviewed request without applying task state' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $canonsPath = Join-Path $workspaceRoot 'canons'
        New-Item -ItemType Directory -Path (Join-Path $canonsPath 'api') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $canonsPath 'web') -Force | Out-Null
        $prdPath = Join-Path $TestDrive 'prd.md'
        Set-Content -LiteralPath $prdPath -Value '# Add endpoint'
        @'
{
  "schemaVersion": 1,
  "repositories": {
    "api": { "baseBranch": "develop" },
    "web": { "baseBranch": "main" }
  },
  "workspace": { "file": "team.code-workspace" }
}
'@ | Set-Content -LiteralPath (Join-Path $workspaceRoot 'task-scaffold.settings.json') -NoNewline
        $outputPath = Join-Path $workspaceRoot 'task-request.json'
        $global:taskRequestBuilderAnswers = @('FEATURE-123', 'Add endpoint', $prdPath, 'y')
        Mock Read-Host {
            $answer = $global:taskRequestBuilderAnswers[0]
            $global:taskRequestBuilderAnswers = @($global:taskRequestBuilderAnswers | Select-Object -Skip 1)
            $answer
        }

        $script = Join-Path $PSScriptRoot '../scripts/Invoke-TaskRequestBuilder.ps1'
        & $script -WorkspaceRoot $workspaceRoot -OutputPath $outputPath -RepositoryNames api, web | Out-Null
        $request = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

        $request.task.key | Should -Be 'FEATURE-123'
        $request.schemaVersion | Should -Be 2
        $request.repositories.Name | Should -Be @('api', 'web')
        $request.repositories[0].path | Should -Be (Join-Path $canonsPath 'api')
        $request.repositories[0].baseBranch | Should -Be 'develop'
        $request.repositories[0].branch | Should -Be 'feature/FEATURE-123'
        $request.workspace.file | Should -Be (Join-Path $workspaceRoot 'team.code-workspace')
        Test-Path -LiteralPath (Join-Path $workspaceRoot 'tasks/FEATURE-123') | Should -BeFalse
    }
}

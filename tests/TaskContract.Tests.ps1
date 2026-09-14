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
}

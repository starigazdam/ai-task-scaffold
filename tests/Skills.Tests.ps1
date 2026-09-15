Describe 'scaffold skill surfaces' {
    It 'has a short valid skill for every public workflow script' {
        $skillsRoot = Join-Path $PSScriptRoot '../.github/skills'
        $scriptsRoot = Join-Path $PSScriptRoot '../scripts'
        $expected = [ordered]@{
            'task-scaffold' = 'Start-TaskScaffold.ps1'
            'task-request-builder' = 'Invoke-TaskRequestBuilder.ps1'
            'task-worktree-plan' = 'Invoke-TaskScaffold.ps1'
            'task-teardown' = 'Invoke-TaskTeardown.ps1'
            'workspace-folders' = 'Update-WorkspaceFolders.ps1'
        }

        foreach ($name in $expected.Keys) {
            $path = Join-Path $skillsRoot "$name/SKILL.md"
            Test-Path -LiteralPath $path | Should -BeTrue
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match '^---\r?\n'
            $content | Should -Match '\r?\n---\r?\n'
            $content | Should -Match "(?m)^name: $name\r?`$"
            $description = [regex]::Match($content, '(?m)^description: "?(.+?)"?\r?$').Groups[1].Value
            $description.Length | Should -BeLessOrEqual 60
            ($content -split '\r?\n').Count | Should -BeLessOrEqual 100
            $content | Should -Match ([regex]::Escape("./scripts/$($expected[$name])"))
            Test-Path -LiteralPath (Join-Path $scriptsRoot $expected[$name]) | Should -BeTrue
        }
    }
}
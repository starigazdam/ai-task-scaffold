Describe 'TerminalSelector' {
    It 'shows repository candidates before reading redirected selection' {
        $module = Join-Path $PSScriptRoot '../scripts/Private/TerminalSelector.psm1'
        Import-Module $module -Force

        InModuleScope TerminalSelector {
            Mock Read-Host { 'api, web' }
            Mock Write-Host {}

            $selected = Read-TaskRepositorySelection -Names @('api', 'web')

            $selected | Should -Be @('api', 'web')
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'Available repositories: api, web' }
        }
    }

    It 'restores the locked Terminal.Gui dependency before loading the picker' {
        $restore = Join-Path $PSScriptRoot '../scripts/Restore-TaskScaffoldDependencies.ps1'
        & $restore

        $packagesRoot = ((& dotnet nuget locals global-packages --list) -replace '^global-packages:\s*', '').Trim()
        Test-Path (Join-Path $packagesRoot 'terminal.gui/1.17.1/lib/netstandard2.0/Terminal.Gui.dll') | Should -BeTrue
        Test-Path (Join-Path $packagesRoot 'nstack.core/1.1.1/lib/netstandard2.0/NStack.dll') | Should -BeTrue
    }

    It 'selects the highlighted repository after Down, Space, Enter' {
        $module = Join-Path $PSScriptRoot '../scripts/Private/TerminalSelector.psm1'
        Import-Module $module -Force
        Initialize-TerminalGui

        $selected = [TaskScaffold.RepositoryPicker]::SelectForKeys(
            [string[]]@('api', 'web'),
            [ConsoleKey[]]@([ConsoleKey]::DownArrow, [ConsoleKey]::Spacebar, [ConsoleKey]::Enter)
        )

        $selected | Should -Be @('web')
    }
}

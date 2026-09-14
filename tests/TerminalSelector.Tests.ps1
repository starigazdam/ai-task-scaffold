Describe 'TerminalSelector' {
    It 'restores the locked Terminal.Gui dependency before loading the picker' {
        $restore = Join-Path $PSScriptRoot '../scripts/Restore-TaskScaffoldDependencies.ps1'
        & $restore

        $packagesRoot = ((& dotnet nuget locals global-packages --list) -replace '^global-packages:\s*', '').Trim()
        Test-Path (Join-Path $packagesRoot 'terminal.gui/1.17.1/lib/net8.0/Terminal.Gui.dll') | Should -BeTrue
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

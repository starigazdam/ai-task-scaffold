Describe 'TerminalSelector' {
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

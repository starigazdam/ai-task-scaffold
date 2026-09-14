Describe 'TerminalSelector' {
    It 'loads the bundled Terminal.Gui repository picker' {
        $module = Join-Path $PSScriptRoot '../scripts/Private/TerminalSelector.psm1'
        Import-Module $module -Force

        Initialize-TerminalGui

        ('TaskScaffold.RepositoryPicker' -as [type]).FullName | Should -Be 'TaskScaffold.RepositoryPicker'
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TaskScaffoldDependencyPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'Terminal.Gui dependencies are missing; add dotnet to PATH and run ./scripts/Restore-TaskScaffoldDependencies.ps1'
    }
    $packageRoot = ((& dotnet nuget locals global-packages --list) -replace '^global-packages:\s*', '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($packageRoot)) {
        throw 'cannot locate the NuGet package cache; run ./scripts/Restore-TaskScaffoldDependencies.ps1'
    }
    $path = Join-Path $packageRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Terminal.Gui dependencies are missing; run ./scripts/Restore-TaskScaffoldDependencies.ps1"
    }
    return $path
}

function Initialize-TerminalGui {
    $nstack = Get-TaskScaffoldDependencyPath -RelativePath 'nstack.core/1.1.1/lib/netstandard2.0/NStack.dll'
    $terminalGui = Get-TaskScaffoldDependencyPath -RelativePath 'terminal.gui/1.17.1/lib/net8.0/Terminal.Gui.dll'
    if (-not ('Terminal.Gui.Application' -as [type])) {
        Add-Type -Path $nstack
        Add-Type -Path $terminalGui
    }
    if ('TaskScaffold.RepositoryPicker' -as [type]) {
        return
    }
    Add-Type -ReferencedAssemblies $terminalGui, $nstack, ([System.Linq.Enumerable].Assembly.Location), ([System.Runtime.GCSettings].Assembly.Location), ([System.Console].Assembly.Location) -TypeDefinition @'
using System;
using System.Linq;
using Terminal.Gui;

namespace TaskScaffold {
    public static class RepositoryPicker {
        public static string[] SelectForKeys(string[] names, ConsoleKey[] keys) {
            var marked = new bool[names.Length];
            var highlighted = 0;
            foreach (var key in keys) {
                if (key == ConsoleKey.DownArrow && highlighted < names.Length - 1) highlighted++;
                else if (key == ConsoleKey.UpArrow && highlighted > 0) highlighted--;
                else if (key == ConsoleKey.Spacebar) marked[highlighted] = !marked[highlighted];
                else if (key == ConsoleKey.Enter) return names.Where((name, index) => marked[index]).ToArray();
                else if (key == ConsoleKey.Escape) return Array.Empty<string>();
            }
            return Array.Empty<string>();
        }

        public static string[] Select(string[] names) {
            Application.Init();
            var selected = Array.Empty<string>();
            var window = new Window("Choose repositories") { X = 0, Y = 1, Width = Dim.Fill(), Height = Dim.Fill(1) };
            window.Add(new Label("↑/↓ navigate · Space check/uncheck · Enter continue · Esc cancel") { X = 0, Y = 0 });
            var list = new ListView(names) { X = 0, Y = 1, Width = Dim.Fill(), Height = Dim.Fill(2), AllowsMultipleSelection = true };
            var continueButton = new Button("Review request") { X = Pos.Center() - 17, Y = Pos.Bottom(list), IsDefault = true };
            var cancelButton = new Button("Cancel") { X = Pos.Right(continueButton) + 2, Y = Pos.Bottom(list) };
            Action accept = () => {
                selected = names.Where((name, index) => list.Source.IsMarked(index)).ToArray();
                Application.RequestStop();
            };
            continueButton.Clicked += accept;
            window.KeyPress += args => {
                if (args.KeyEvent.Key == Key.Enter) {
                    accept();
                    args.Handled = true;
                }
            };
            cancelButton.Clicked += () => Application.RequestStop();
            window.Add(list, continueButton, cancelButton);
            Application.Top.Add(window);
            Application.Run();
            Application.Shutdown();
            return selected;
        }
    }
}
'@
}

function Select-TaskRepositories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Names)

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return @((Read-Host 'Repositories (comma-separated names)') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    Initialize-TerminalGui

    return @([TaskScaffold.RepositoryPicker]::Select($Names))
}

Export-ModuleMember -Function Initialize-TerminalGui, Select-TaskRepositories

#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$project = Join-Path $PSScriptRoot '../TaskScaffold.Dependencies.csproj'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet SDK is required; install an SDK or add dotnet to PATH'
}

& dotnet restore $project --locked-mode
if ($LASTEXITCODE -ne 0) {
    throw 'locked dependency restore failed'
}

#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceFile,
    [Parameter(Mandatory)][string]$FoldersJson,
    [switch]$Apply,
    [string]$ExpectedSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsoncMask {
    param([string]$Text)

    $masked = [System.Text.StringBuilder]::new($Text.Length)
    $state = 'normal'
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($state -eq 'string') {
            [void]$masked.Append($character)
            if ($character -eq '\') {
                if ($index + 1 -lt $Text.Length) { $index++; [void]$masked.Append($Text[$index]) }
            }
            elseif ($character -eq '"') { $state = 'normal' }
            continue
        }
        if ($state -eq 'line-comment') {
            $replacement = if ($character -in "`r", "`n") { $character } else { ' ' }
            [void]$masked.Append($replacement)
            if ($character -eq "`n") { $state = 'normal' }
            continue
        }
        if ($state -eq 'block-comment') {
            $replacement = if ($character -in "`r", "`n") { $character } else { ' ' }
            [void]$masked.Append($replacement)
            if ($character -eq '*' -and $next -eq '/') { $index++; [void]$masked.Append(' '); $state = 'normal' }
            continue
        }
        if ($character -eq '"') { [void]$masked.Append($character); $state = 'string'; continue }
        if ($character -eq '/' -and $next -eq '/') { [void]$masked.Append(' '); $index++; [void]$masked.Append(' '); $state = 'line-comment'; continue }
        if ($character -eq '/' -and $next -eq '*') { [void]$masked.Append(' '); $index++; [void]$masked.Append(' '); $state = 'block-comment'; continue }
        [void]$masked.Append($character)
    }
    return $masked.ToString()
}

function Find-MatchingBracket {
    param([string]$Text, [int]$Start)

    $depth = 0
    $inString = $false
    for ($index = $Start; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($inString) {
            if ($character -eq '\') { $index++; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; continue }
        if ($character -eq '[') { $depth++; continue }
        if ($character -eq ']') { $depth--; if ($depth -eq 0) { return $index } }
    }
    throw 'workspace folders array is not closed'
}

function Find-FoldersArray {
    param([string]$MaskedText)

    $depth = 0
    for ($index = 0; $index -lt $MaskedText.Length; $index++) {
        $character = $MaskedText[$index]
        if ($character -eq '"') {
            $end = $index + 1
            while ($end -lt $MaskedText.Length -and $MaskedText[$end] -ne '"') {
                if ($MaskedText[$end] -eq '\') { $end++ }
                $end++
            }
            if ($end -ge $MaskedText.Length) { throw 'workspace contains an unterminated string' }
            $name = $MaskedText.Substring($index + 1, $end - $index - 1)
            if ($depth -eq 1 -and $name -eq 'folders') {
                $cursor = $end + 1
                while ($cursor -lt $MaskedText.Length -and [char]::IsWhiteSpace($MaskedText[$cursor])) { $cursor++ }
                if ($cursor -ge $MaskedText.Length -or $MaskedText[$cursor] -ne ':') { throw 'invalid folders property' }
                $cursor++
                while ($cursor -lt $MaskedText.Length -and [char]::IsWhiteSpace($MaskedText[$cursor])) { $cursor++ }
                if ($cursor -ge $MaskedText.Length -or $MaskedText[$cursor] -ne '[') { throw 'workspace folders must be an array' }
                return [pscustomobject]@{ Start = $cursor; End = Find-MatchingBracket -Text $MaskedText -Start $cursor }
            }
            $index = $end
            continue
        }
        if ($character -eq '{') { $depth++ }
        elseif ($character -eq '}') { $depth-- }
    }
    throw 'workspace has no top-level folders array'
}

if (-not (Test-Path -LiteralPath $WorkspaceFile -PathType Leaf)) { throw "workspace file not found: $WorkspaceFile" }
$workspacePath = (Resolve-Path -LiteralPath $WorkspaceFile).Path
$original = Get-Content -LiteralPath $workspacePath -Raw
$folders = @($FoldersJson | ConvertFrom-Json -Depth 4 -ErrorAction Stop)
if ($folders.Count -eq 0) { throw 'at least one folder is required' }
foreach ($folder in $folders) {
    if ([string]::IsNullOrWhiteSpace([string]$folder.path) -or [string]::IsNullOrWhiteSpace([string]$folder.name)) {
        throw 'each folder requires non-empty path and name'
    }
}

$masked = Get-JsoncMask -Text $original
$array = Find-FoldersArray -MaskedText $masked
$interior = $original.Substring($array.Start + 1, $array.End - $array.Start - 1)
$maskedInterior = $masked.Substring($array.Start + 1, $array.End - $array.Start - 1)
$existingPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($match in [regex]::Matches($maskedInterior, '"path"\s*:\s*"((?:\\.|[^"\\])*)"')) {
    [void]$existingPaths.Add([regex]::Unescape($match.Groups[1].Value))
}
$requestedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$toAdd = @()
foreach ($folder in $folders) {
    if (-not $requestedPaths.Add([string]$folder.path)) { throw "duplicate requested folder path '$($folder.path)'" }
    if (-not $existingPaths.Contains([string]$folder.path)) { $toAdd += $folder }
}

$originalHash = (Get-FileHash -LiteralPath $workspacePath -Algorithm SHA256).Hash
if ($toAdd.Count -eq 0) {
    [ordered]@{ Action = 'noop'; WorkspaceFile = $workspacePath; OriginalSha256 = $originalHash; ProposedContent = $original; RequiresConfirmation = $false } | ConvertTo-Json -Depth 5
    return
}

$last = ($maskedInterior.TrimEnd() | ForEach-Object { if ($_.Length) { $_[$_.Length - 1] } })
$entries = @($toAdd | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ",`n    "
if ([string]::IsNullOrWhiteSpace($maskedInterior)) {
    $proposed = $original.Substring(0, $array.End) + "`n    $entries`n" + $original.Substring($array.End)
}
elseif ($last -eq ',') {
    $proposed = $original.Substring(0, $array.End) + "`n    $entries`n" + $original.Substring($array.End)
}
else {
    $lastIndex = $array.End - 1
    while ([char]::IsWhiteSpace($masked[$lastIndex])) { $lastIndex-- }
    $proposed = $original.Substring(0, $lastIndex + 1) + ',' + $original.Substring($lastIndex + 1, $array.End - $lastIndex - 1) + "    $entries`n" + $original.Substring($array.End)
}

if ($Apply) {
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { throw 'Apply requires ExpectedSha256 from the reviewed plan' }
    if ($ExpectedSha256 -ne $originalHash) { throw 'workspace changed since planning' }
    Copy-Item -LiteralPath $workspacePath -Destination "$workspacePath.bak" -Force
    Set-Content -LiteralPath $workspacePath -Value $proposed -NoNewline -Encoding utf8
    if ((Get-Content -LiteralPath $workspacePath -Raw) -ne $proposed) { throw 'workspace read-back verification failed' }
}

[ordered]@{ Action = 'add'; WorkspaceFile = $workspacePath; OriginalSha256 = $originalHash; ProposedContent = $proposed; RequiresConfirmation = -not $Apply } | ConvertTo-Json -Depth 5

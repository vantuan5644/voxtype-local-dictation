[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'all',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$configDir = if ($env:VOXTYPE_CONFIG_ROOT) {
    $env:VOXTYPE_CONFIG_ROOT
} else { Join-Path $env:APPDATA 'VoxType' }
$installedFile = Join-Path $configDir 'vocabulary.conf'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("voxtype-vocab: $Message")
    exit 1
}

function Get-VocabularyPath {
    $override = [Environment]::GetEnvironmentVariable('VOXTYPE_VOCAB_FILE')
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    if (Test-Path -LiteralPath $installedFile -PathType Leaf) { return $installedFile }
    $repoCopy = Join-Path $PSScriptRoot '..\vocabulary.conf'
    return $repoCopy
}

function Read-Sections {
    param([string]$Path)
    $sections = [ordered]@{ misheard = [System.Collections.Generic.List[string]]::new();
        misspelled = [System.Collections.Generic.List[string]]::new() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $sections }
    $current = ''
    $seen = @{}
    foreach ($sourceLine in [IO.File]::ReadAllLines($Path)) {
        $line = $sourceLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[([^\[\]]+)\]$') {
            $current = $Matches[1].ToLowerInvariant()
            continue
        }
        if (-not $sections.Contains($current)) { continue }
        $key = $line.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $sections[$current].Add($line)
        }
    }
    return $sections
}

function Write-Sections {
    param([string]$Path, [System.Collections.IDictionary]$Sections)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($section in @('misheard', 'misspelled')) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add("[$section]")
        foreach ($term in $Sections[$section]) { $lines.Add($term) }
    }
    $temp = Join-Path $parent ('.vocabulary.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllLines($temp, $lines, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Write-Terms {
    param([System.Collections.Generic.List[string]]$Terms)
    [Console]::Out.Write(($Terms -join ', '))
}

function Test-Term {
    param([string]$Term)
    if ([string]::IsNullOrWhiteSpace($Term)) { Fail 'add: empty term' }
    if ($Term.Contains(',')) { Fail "add: a term cannot contain a comma: $Term" }
    if ($Term.StartsWith('#')) { Fail "add: a term cannot start with '#': $Term" }
    if ($Term -match '^\[.*\]$') { Fail "add: a term cannot look like a section header: $Term" }
}

function Invoke-Apply {
    param([string]$Path)
    $sections = Read-Sections $Path
    if ($sections.misheard.Count -gt 40) {
        [Console]::Error.WriteLine(
            "voxtype-vocab: warning: [misheard] is $($sections.misheard.Count) terms (over 40)")
    }
    $voxtypePath = $null
    if (-not [string]::IsNullOrWhiteSpace($env:VOXTYPE_EXE) -and
        (Test-Path -LiteralPath $env:VOXTYPE_EXE -PathType Leaf)) {
        $voxtypePath = (Resolve-Path -LiteralPath $env:VOXTYPE_EXE).Path
    } else {
        $voxtype = Get-Command voxtype.exe -ErrorAction SilentlyContinue
        if ($null -ne $voxtype) { $voxtypePath = $voxtype.Source }
    }
    if ($null -eq $voxtypePath) {
        Fail 'voxtype.exe is unavailable; vocabulary was saved but not applied'
    }
    $prompt = $sections.misheard -join ', '
    & $voxtypePath config set whisper.initial_prompt $prompt
    if ($LASTEXITCODE -ne 0) { Fail 'voxtype rejected whisper.initial_prompt' }
}

function Show-Usage {
    @'
Usage: voxtype-local vocab <command>

  all | misheard | misspelled       print a comma-joined list
  add [-m|--misheard] [-n|--no-apply] <term>...
  edit                              edit the active vocabulary, then apply it
  apply                             update whisper.initial_prompt
  list                              show both sections
  path                              show the active file
'@
}

$path = Get-VocabularyPath
switch ($Command.ToLowerInvariant()) {
    { $_ -in @('all', 'misheard', 'misspelled') } {
        $sections = Read-Sections $path
        if ($_ -eq 'all') {
            $all = [System.Collections.Generic.List[string]]::new()
            foreach ($term in $sections.misheard) { $all.Add($term) }
            foreach ($term in $sections.misspelled) { $all.Add($term) }
            Write-Terms $all
        } else { Write-Terms $sections[$_] }
    }
    'add' {
        $section = 'misspelled'
        $apply = $true
        $terms = [System.Collections.Generic.List[string]]::new()
        foreach ($arg in @($Remaining)) {
            switch ($arg) {
                { $_ -in @('-m', '--misheard') } { $section = 'misheard'; continue }
                { $_ -in @('-s', '--misspelled') } { $section = 'misspelled'; continue }
                { $_ -in @('-n', '--no-apply') } { $apply = $false; continue }
                default {
                    if ($arg.StartsWith('-')) { Fail "add: unknown flag '$arg'" }
                    $terms.Add($arg.Trim())
                }
            }
        }
        if ($terms.Count -eq 0) { Fail 'add: needs at least one term' }
        $sections = Read-Sections $path
        $known = @{}
        foreach ($name in @('misheard', 'misspelled')) {
            foreach ($term in $sections[$name]) { $known[$term.ToLowerInvariant()] = $name }
        }
        $added = 0
        foreach ($term in $terms) {
            Test-Term $term
            $key = $term.ToLowerInvariant()
            if ($known.ContainsKey($key)) {
                [Console]::Error.WriteLine("voxtype-vocab: warning: already in [$($known[$key])]: $term")
                continue
            }
            $sections[$section].Add($term)
            $known[$key] = $section
            $added++
        }
        if ($added -gt 0) {
            Write-Sections -Path $path -Sections $sections
            if ($apply) { Invoke-Apply $path }
        }
    }
    'edit' {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $empty = [ordered]@{ misheard = [System.Collections.Generic.List[string]]::new();
                misspelled = [System.Collections.Generic.List[string]]::new() }
            Write-Sections -Path $path -Sections $empty
        }
        $editor = [Environment]::GetEnvironmentVariable('VISUAL')
        if ([string]::IsNullOrWhiteSpace($editor)) {
            $editor = [Environment]::GetEnvironmentVariable('EDITOR')
        }
        if ([string]::IsNullOrWhiteSpace($editor)) { $editor = 'notepad.exe' }
        $before = [IO.File]::ReadAllText($path)
        $process = Start-Process -FilePath $editor -ArgumentList @($path) -PassThru -Wait
        if ($process.ExitCode -ne 0) { Fail "editor exited $($process.ExitCode)" }
        if ([IO.File]::ReadAllText($path) -ne $before) { Invoke-Apply $path }
    }
    'apply' { Invoke-Apply $path }
    'list' {
        $sections = Read-Sections $path
        [Console]::Out.WriteLine("in use: $path")
        foreach ($name in @('misheard', 'misspelled')) {
            [Console]::Out.WriteLine("[$name] ($($sections[$name].Count))")
            foreach ($term in $sections[$name]) { [Console]::Out.WriteLine("  $term") }
        }
    }
    { $_ -in @('path', 'where') } { [Console]::Out.WriteLine($path) }
    { $_ -in @('-h', '--help', 'help') } { Show-Usage }
    default { Fail "unknown command '$Command'" }
}

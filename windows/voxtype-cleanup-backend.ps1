# Shared by voxtype-setup.ps1 and voxtype-cleanup.ps1, which dot-source it.
#
# The cleanup backend is an ordered, comma-separated chain of opencode, anthropic, groq, pi,
# local, openai, claude and codex, or the single value off. anthropic is Claude through
# Anthropic's own API on the user's key; claude is the Claude Code command. Cleanup tries each link in turn;
# any failure falls through to the next link and finally to the raw
# transcription. local may only be the last link: a local server that is merely
# down must never hand the text to a hosted backend.
#
# Precedence: VOXTYPE_CLEANUP_BACKEND when set, then the UTF-8 text file
# <data root>\cleanup-backend written by voxtype-setup.ps1 -CleanupBackend, then
# local (the behaviour before the choice existed). The data root is
# VOXTYPE_DATA_ROOT or %LOCALAPPDATA%\VoxType. packaging\CleanupBackend.cs
# applies the same rules for the launchers.

$CleanupBackendNames = @('opencode', 'anthropic', 'groq', 'pi', 'local', 'openai', 'claude', 'codex')
$CleanupBackendFileName = 'cleanup-backend'
$CleanupBackendDefault = 'local'

# Returns the canonical chain (lower case, no spaces, such as 'opencode,local') or
# throws with the rule the value breaks.
function ConvertTo-CleanupBackendChain {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $text = if ($null -eq $Value) { '' } else { $Value.Trim() }
    if ($text.Length -eq 0) {
        throw 'the cleanup backend is empty; use off or a chain such as opencode,local'
    }
    $links = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $text.Split(',')) {
        $link = $part.Trim().ToLowerInvariant()
        if ($link.Length -eq 0) { throw "cleanup backend '$text' has an empty link" }
        if ($link -ne 'off' -and $CleanupBackendNames -notcontains $link) {
            throw "unknown cleanup backend '$link' (use opencode, anthropic, groq, pi, local, openai, claude, codex, or off)"
        }
        if ($links.Contains($link)) { throw "cleanup backend '$link' appears twice in '$text'" }
        $links.Add($link)
    }
    if ($links.Contains('off') -and $links.Count -gt 1) {
        throw "'off' cannot be combined with other cleanup backends (got '$text')"
    }
    $localIndex = $links.IndexOf('local')
    if ($localIndex -ge 0 -and $localIndex -ne $links.Count - 1) {
        throw "'local' may only be the last cleanup backend (got '$text'); " +
            'a local failure must never send the text to a hosted backend'
    }
    return ($links.ToArray() -join ',')
}

# OpenCode Go's key: VOXTYPE_CLEANUP_OPENCODE_KEY, else the file
# VOXTYPE_CLEANUP_OPENCODE_KEY_FILE names (an app that keeps the key, as for Groq), else the
# one pi keeps in its auth.json, each read in place. Empty when there is none or it cannot be
# read. Setup only asks whether there is one; the key is never printed.
function Get-OpenCodeKey {
    $key = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_OPENCODE_KEY')
    if (-not [string]::IsNullOrEmpty($key)) { return $key }
    $file = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_OPENCODE_KEY_FILE')
    if (-not [string]::IsNullOrEmpty($file) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
        try {
            $key = ([IO.File]::ReadAllText($file)).Trim()
            if (-not [string]::IsNullOrEmpty($key)) { return $key }
        } catch { }
    }
    $agent = [Environment]::GetEnvironmentVariable('PI_CODING_AGENT_DIR')
    if ([string]::IsNullOrEmpty($agent)) {
        $agent = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pi\agent'
    }
    $path = Join-Path $agent 'auth.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        $entry = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).PSObject.Properties['opencode-go']
        if ($null -eq $entry -or $null -eq $entry.Value.PSObject.Properties['key']) { return '' }
        return [string]$entry.Value.key
    } catch {
        return ''
    }
}

# Groq's key: VOXTYPE_CLEANUP_GROQ_KEY, else the file VOXTYPE_CLEANUP_GROQ_KEY_FILE names,
# read in place each time, so an app that keeps the key can change it without a restart.
# Empty when there is neither or that file cannot be read; the key is never printed.
function Get-GroqKey {
    $key = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_GROQ_KEY')
    if (-not [string]::IsNullOrEmpty($key)) { return $key.Trim() }
    $path = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_GROQ_KEY_FILE')
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return ([IO.File]::ReadAllText($path)).Trim() } catch { return '' }
}

# Anthropic's key, as Groq's: VOXTYPE_CLEANUP_ANTHROPIC_KEY, else the file
# VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE names, read in place each time. Empty when there is
# neither or that file cannot be read; the key is never printed.
function Get-AnthropicKey {
    $key = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_ANTHROPIC_KEY')
    if (-not [string]::IsNullOrEmpty($key)) { return $key.Trim() }
    $path = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE')
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return ([IO.File]::ReadAllText($path)).Trim() } catch { return '' }
}

function Get-CleanupDataRoot {
    if ($env:VOXTYPE_DATA_ROOT) { return $env:VOXTYPE_DATA_ROOT }
    return (Join-Path $env:LOCALAPPDATA 'VoxType')
}

# The configured value before validation, following the precedence above.
function Get-CleanupBackendSetting {
    param([string]$DataRoot)
    $fromEnvironment = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_BACKEND')
    if (-not [string]::IsNullOrEmpty($fromEnvironment)) { return $fromEnvironment }
    $path = Join-Path $DataRoot $CleanupBackendFileName
    if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.File]::ReadAllText($path) }
    return $CleanupBackendDefault
}

function Test-CleanupChainHasLocal {
    param([string]$Chain)
    return @($Chain.Split(',')) -contains 'local'
}

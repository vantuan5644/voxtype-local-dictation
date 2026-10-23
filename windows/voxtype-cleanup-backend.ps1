# Shared by voxtype-setup.ps1 and voxtype-cleanup.ps1, which dot-source it.
#
# The cleanup backend is an ordered, comma-separated chain of pi, local, openai,
# claude and codex, or the single value off. Cleanup tries each link in turn;
# any failure falls through to the next link and finally to the raw
# transcription. local may only be the last link: a local server that is merely
# down must never hand the text to a hosted backend.
#
# Precedence: VOXTYPE_CLEANUP_BACKEND when set, then the UTF-8 text file
# <data root>\cleanup-backend written by voxtype-setup.ps1 -CleanupBackend, then
# local (the behaviour before the choice existed). The data root is
# VOXTYPE_DATA_ROOT or %LOCALAPPDATA%\VoxType. packaging\CleanupBackend.cs
# applies the same rules for the launchers.

$CleanupBackendNames = @('pi', 'local', 'openai', 'claude', 'codex')
$CleanupBackendFileName = 'cleanup-backend'
$CleanupBackendDefault = 'local'

# Returns the canonical chain (lower case, no spaces, such as 'pi,local') or
# throws with the rule the value breaks.
function ConvertTo-CleanupBackendChain {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $text = if ($null -eq $Value) { '' } else { $Value.Trim() }
    if ($text.Length -eq 0) {
        throw 'the cleanup backend is empty; use off or a chain such as pi,local'
    }
    $links = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $text.Split(',')) {
        $link = $part.Trim().ToLowerInvariant()
        if ($link.Length -eq 0) { throw "cleanup backend '$text' has an empty link" }
        if ($link -ne 'off' -and $CleanupBackendNames -notcontains $link) {
            throw "unknown cleanup backend '$link' (use pi, local, openai, claude, codex, or off)"
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

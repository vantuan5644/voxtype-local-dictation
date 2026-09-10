[CmdletBinding()]
param(
    [string]$Hotkey,
    [string]$CleanupModelPath,
    [string]$WhisperModelPath,
    [string]$AudioDevice,
    [switch]$EnableStartup,
    [switch]$DisableStartup,
    [switch]$SetupVad,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$roaming = if ($env:VOXTYPE_CONFIG_ROOT) {
    $env:VOXTYPE_CONFIG_ROOT
} else { Join-Path $env:APPDATA 'VoxType' }
$local = if ($env:VOXTYPE_DATA_ROOT) {
    $env:VOXTYPE_DATA_ROOT
} else { Join-Path $env:LOCALAPPDATA 'VoxType' }
$vocabSource = Join-Path $PSScriptRoot '..\vocabulary.conf'
$vocabTarget = Join-Path $roaming 'vocabulary.conf'
$defaultModel = Join-Path $local 'models\Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
$modelPathFile = Join-Path $local 'cleanup-model.path'
$startupMarker = Join-Path $local 'startup.enabled'
if ([string]::IsNullOrWhiteSpace($CleanupModelPath)) { $CleanupModelPath = $defaultModel }
if ($EnableStartup -and $DisableStartup) {
    throw '-EnableStartup and -DisableStartup cannot be used together'
}

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { Write-Host "[dry] $Description"; return }
    & $Action
}

Write-Host 'VoxType Windows setup'
Write-Host "  config: $roaming"
Write-Host "  models: $(Split-Path -Parent $CleanupModelPath)"

Invoke-Step "create $roaming and $local" {
    New-Item -ItemType Directory -Path $roaming, $local,
        (Split-Path -Parent $CleanupModelPath) -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $vocabTarget -PathType Leaf)) {
    Invoke-Step "install starter vocabulary at $vocabTarget" {
        if (Test-Path -LiteralPath $vocabSource -PathType Leaf) {
            Copy-Item -LiteralPath $vocabSource -Destination $vocabTarget
        } else {
            [IO.File]::WriteAllText($vocabTarget, "[misheard]`r`n`r`n[misspelled]`r`n",
                [Text.UTF8Encoding]::new($false))
        }
    }
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
    Write-Warning 'voxtype.exe is unavailable. Install the MSIX or add the upstream build to PATH.'
} else {
    $settings = [ordered]@{
        'hotkey.enabled' = if ($Hotkey) { 'true' } else { 'false' }
        'hotkey.mode' = 'push_to_talk'
        'whisper.language' = 'en'
        'text.filter_filler_words' = 'true'
        'vad.enabled' = 'true'
        'vad.backend' = 'whisper'
        'meeting.enabled' = 'false'
        'audio.pause_media' = 'false'
        'output.notification.on_recording_start' = 'true'
        'output.notification.on_recording_stop' = 'true'
        'output.notification.on_transcription' = 'true'
        'osd.enabled' = 'false'
        'output.post_process.command' = 'voxtype-local.exe cleanup'
    }
    if ($Hotkey) { $settings['hotkey.key'] = $Hotkey.ToUpperInvariant() }
    if ($WhisperModelPath) { $settings['whisper.model'] = $WhisperModelPath }
    if ($AudioDevice) { $settings['audio.device'] = $AudioDevice }
    foreach ($entry in $settings.GetEnumerator()) {
        $current = & $voxtypePath config get $entry.Key 2>$null
        $readSucceeded = $LASTEXITCODE -eq 0
        if ($readSucceeded -and ([string]$current).Trim() -ceq $entry.Value) {
            Write-Host "[same] $($entry.Key)=$($entry.Value)"
        } else {
            Invoke-Step "set $($entry.Key)=$($entry.Value)" {
                & $voxtypePath config set $entry.Key $entry.Value
                if ($LASTEXITCODE -ne 0) { throw "voxtype rejected $($entry.Key)" }
            }
        }
    }
    if (-not $Hotkey) {
        Write-Warning 'No push-to-talk key was selected; hotkey.enabled remains false.'
        Write-Host 'Re-run: voxtype-local setup -Hotkey <key>'
    }
    if (-not $DryRun -and (Test-Path -LiteralPath $vocabTarget -PathType Leaf)) {
        & (Join-Path $PSScriptRoot 'voxtype-vocab.ps1') apply
    }
    if ($SetupVad) {
        Invoke-Step 'download and configure Silero VAD' {
            & $voxtypePath setup vad
            if ($LASTEXITCODE -ne 0) { throw 'voxtype setup vad failed' }
        }
    }
}

Invoke-Step "record cleanup model path at $modelPathFile" {
    [IO.File]::WriteAllText($modelPathFile, $CleanupModelPath,
        [Text.UTF8Encoding]::new($false))
}
if ($EnableStartup) {
    Invoke-Step 'enable per-user startup' {
        [IO.File]::WriteAllText($startupMarker, 'enabled', [Text.Encoding]::ASCII)
    }
} elseif ($DisableStartup) {
    Invoke-Step 'disable per-user startup' {
        Remove-Item -LiteralPath $startupMarker -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $CleanupModelPath -PathType Leaf)) {
    Write-Warning "Cleanup model is missing: $CleanupModelPath"
    Write-Host 'Download it explicitly with:'
    Write-Host '  hf download unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
    Write-Host "  Move the downloaded file to: $CleanupModelPath"
    Write-Host 'Until then, cleanup returns the original transcript unchanged.'
}

if (-not $WhisperModelPath) {
    Write-Host 'Select/download a Whisper model through `voxtype configure`.'
}
if (-not $SetupVad) { Write-Host 'Run `voxtype setup vad` to install voice activity detection.' }
Write-Host 'Startup can also be managed under Task Manager > Startup apps.'

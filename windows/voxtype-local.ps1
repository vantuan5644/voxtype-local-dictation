[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

switch ($Command.ToLowerInvariant()) {
    'cleanup' {
        & (Join-Path $PSScriptRoot 'voxtype-cleanup.ps1') @Remaining
        if ($?) { exit 0 } else { exit 1 }
    }
    'cleanup-server' {
        & (Join-Path $PSScriptRoot 'voxtype-server.ps1')
        if ($?) { exit 0 } else { exit 1 }
    }
    'vocab' {
        & (Join-Path $PSScriptRoot 'voxtype-vocab.ps1') @Remaining
        if ($?) { exit 0 } else { exit 1 }
    }
    'setup' {
        $setupParameters = @{}
        for ($index = 0; $index -lt @($Remaining).Count; $index++) {
            switch ($Remaining[$index]) {
                '-DryRun' { $setupParameters.DryRun = $true }
                '-Hotkey' {
                    $index++
                    if ($index -ge $Remaining.Count) { throw '-Hotkey needs a value' }
                    $setupParameters.Hotkey = $Remaining[$index]
                }
                '-CleanupModelPath' {
                    $index++
                    if ($index -ge $Remaining.Count) { throw '-CleanupModelPath needs a value' }
                    $setupParameters.CleanupModelPath = $Remaining[$index]
                }
                '-WhisperModelPath' {
                    $index++
                    if ($index -ge $Remaining.Count) { throw '-WhisperModelPath needs a value' }
                    $setupParameters.WhisperModelPath = $Remaining[$index]
                }
                '-AudioDevice' {
                    $index++
                    if ($index -ge $Remaining.Count) { throw '-AudioDevice needs a value' }
                    $setupParameters.AudioDevice = $Remaining[$index]
                }
                '-EnableStartup' { $setupParameters.EnableStartup = $true }
                '-DisableStartup' { $setupParameters.DisableStartup = $true }
                '-SetupVad' { $setupParameters.SetupVad = $true }
                default { throw "setup: unknown argument '$($Remaining[$index])'" }
            }
        }
        & (Join-Path $PSScriptRoot 'voxtype-setup.ps1') @setupParameters
        if ($?) { exit 0 } else { exit 1 }
    }
    { $_ -in @('help', '-h', '--help') } {
        @'
Usage: voxtype-local <command>

  setup [-Hotkey KEY] [-WhisperModelPath PATH] [-CleanupModelPath PATH]
        [-AudioDevice NAME] [-EnableStartup|-DisableStartup] [-SetupVad] [-DryRun]
  cleanup                  post-process stdin and write the chosen text
  cleanup-server           run the resident llama.cpp cleanup server
  vocab <command>          maintain vocabulary.conf
'@
    }
    default {
        [Console]::Error.WriteLine("voxtype-local: unknown command '$Command'")
        exit 2
    }
}

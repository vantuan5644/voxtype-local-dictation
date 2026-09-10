[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configRoot = if ($env:VOXTYPE_DATA_ROOT) {
    $env:VOXTYPE_DATA_ROOT
} else { Join-Path $env:LOCALAPPDATA 'VoxType' }
$modelDefault = Join-Path $configRoot 'models\Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
$modelPathFile = Join-Path $configRoot 'cleanup-model.path'
$logDir = Join-Path $configRoot 'logs'
$recordedModel = if (Test-Path -LiteralPath $modelPathFile -PathType Leaf) {
    [IO.File]::ReadAllText($modelPathFile).Trim()
} else { '' }
$model = if ($env:VOXTYPE_CLEANUP_MODEL_PATH) {
    $env:VOXTYPE_CLEANUP_MODEL_PATH
} elseif ($recordedModel) { $recordedModel } else { $modelDefault }
$endpoint = if ($env:VOXTYPE_CLEANUP_ENDPOINT) { $env:VOXTYPE_CLEANUP_ENDPOINT } else { 'http://127.0.0.1:8088' }
$modelAlias = if ($env:VOXTYPE_CLEANUP_LOCAL_MODEL) {
    $env:VOXTYPE_CLEANUP_LOCAL_MODEL
} else { 'qwen3-4b-instruct-2507' }

try { $endpointUri = [Uri]$endpoint } catch { exit 0 }
if ($endpointUri.Scheme -cne 'http' -or
    $endpointUri.Host -notin @('127.0.0.1', 'localhost', '::1')) { exit 0 }

if (-not (Test-Path -LiteralPath $model -PathType Leaf)) {
    exit 0
}
try {
    Invoke-WebRequest -UseBasicParsing -Uri ($endpoint.TrimEnd('/') + '/health') -TimeoutSec 1 |
        Out-Null
    exit 0
} catch {
    # A refused connection is the expected reason to continue.
}

$packaged = Join-Path $PSScriptRoot 'bin\llama-server.exe'
if (-not [string]::IsNullOrWhiteSpace($env:LLAMA_SERVER_EXE) -and
    (Test-Path -LiteralPath $env:LLAMA_SERVER_EXE -PathType Leaf)) {
    $server = (Resolve-Path -LiteralPath $env:LLAMA_SERVER_EXE).Path
} elseif (Test-Path -LiteralPath $packaged -PathType Leaf) {
    $server = $packaged
} else {
    $command = Get-Command llama-server.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { exit 0 }
    $server = $command.Source
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir 'llama-server.log'
$arguments = [System.Collections.Generic.List[string]]::new()
foreach ($value in @('--model', $model, '--alias', $modelAlias, '--host',
        '127.0.0.1', '--port', [string]$endpointUri.Port, '--ctx-size', '4096', '--temp', '0', '--top-p',
        '1', '--parallel', '1', '--no-webui')) { $arguments.Add($value) }
$devices = & $server --list-devices 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    [IO.File]::AppendAllText($logPath,
        "$(Get-Date -Format o) llama-server could not enumerate compute devices`r`n")
    exit 0
}
$device = $env:LLAMA_DEVICE
if ([string]::IsNullOrWhiteSpace($device)) {
    $match = [regex]::Match($devices, '(?im)^\s*(Vulkan\d+)\s*:')
    if (-not $match.Success) {
        [IO.File]::AppendAllText($logPath,
            "$(Get-Date -Format o) no Vulkan device was enumerated`r`n")
        exit 0
    }
    $device = $match.Groups[1].Value
} elseif (-not $devices.Contains($device)) {
        [IO.File]::AppendAllText($logPath,
            "$(Get-Date -Format o) configured device '$device' was not enumerated`r`n")
        exit 0
}
$arguments.Add('--device')
$arguments.Add($device)

# The package's hidden launcher owns this process. A stopped server stays stopped;
# the startup task tries once on the next logon and dictation safely passes through.
& $server @arguments *>> $logPath
exit $LASTEXITCODE

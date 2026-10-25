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
# Windows PowerShell 5.1, which the package runs this with, turns each line a native
# program writes to a redirected stderr into an error record, and under 'Stop' the first
# one ends this script and the server with it. llama-server logs to stderr.
$ErrorActionPreference = 'Continue'
try {
    $devices = (& $server --list-devices 2>&1 | ForEach-Object { "$_" }) -join "`n"
} catch {
    # Windows refuses a packaged exe the manifest does not declare; say so in the log.
    [IO.File]::AppendAllText($logPath,
        "$(Get-Date -Format o) llama-server could not start: $($_.Exception.Message)`r`n")
    exit 0
}
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

# A new server's first request took about 7 s on an RTX 4090, against about 1 s
# after: past cleanup's 5 s local timeout, so that dictation came back raw.
# Once it answers, two fixed sentences go through the real cleanup path, local only,
# which also caches the prompt every cleanup shares. They never reach the history.
$warmUp = [PowerShell]::Create().AddScript({
    param([string]$Endpoint, [string]$Alias, [string]$Cleanup, [string]$Shell)
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    $ready = $false
    while (-not $ready -and [DateTime]::UtcNow -lt $deadline) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri ($Endpoint.TrimEnd('/') + '/health') `
                -TimeoutSec 1 -ErrorAction Stop | Out-Null
            $ready = $true
        } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $ready) { return }
    foreach ($sentence in @('um so can you uh check the status of the build',
            'okay so the tests are passing now right')) {
        $start = [Diagnostics.ProcessStartInfo]::new($Shell,
            "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Cleanup`"")
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['VOXTYPE_CLEANUP_BACKEND'] = 'local'
        $start.EnvironmentVariables['VOXTYPE_CLEANUP_ENDPOINT'] = $Endpoint
        $start.EnvironmentVariables['VOXTYPE_CLEANUP_LOCAL_MODEL'] = $Alias
        $start.EnvironmentVariables['VOXTYPE_CLEANUP_TIMEOUT'] = '60'
        $start.EnvironmentVariables['VOXTYPE_HISTORY_DISABLED'] = '1'
        $child = [Diagnostics.Process]::Start($start)
        $errors = $child.StandardError.ReadToEndAsync()
        $child.StandardInput.Write($sentence)
        $child.StandardInput.Close()
        $null = $child.StandardOutput.ReadToEnd()
        $null = $errors.Result
        $child.WaitForExit()
    }
})
$null = $warmUp.AddArgument($endpoint).AddArgument($modelAlias).AddArgument(
    (Join-Path $PSScriptRoot 'voxtype-cleanup.ps1')).AddArgument((Get-Process -Id $PID).Path)
$null = $warmUp.BeginInvoke()

# The package's hidden launcher owns this process. A stopped server stays stopped;
# the startup task tries once on the next logon and dictation safely passes through.
& $server @arguments 2>&1 | ForEach-Object { [IO.File]::AppendAllText($logPath, "$_`r`n") }
exit $LASTEXITCODE

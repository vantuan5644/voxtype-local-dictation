[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$windowsRoot = Split-Path -Parent $PSScriptRoot
$cleanup = Join-Path $windowsRoot 'voxtype-cleanup.ps1'
$vocab = Join-Path $windowsRoot 'voxtype-vocab.ps1'
$localTools = Join-Path $windowsRoot 'voxtype-local.ps1'
$setup = Join-Path $windowsRoot 'voxtype-setup.ps1'
$serverScript = Join-Path $windowsRoot 'voxtype-server.ps1'
$builder = Join-Path $windowsRoot 'build-msix.ps1'
$preparer = Join-Path $windowsRoot 'prepare-windows-release.ps1'
$bootstrapBuilder = Join-Path $windowsRoot 'build-bootstrap.ps1'
$bootstrapSource = Join-Path $windowsRoot 'packaging\BootstrapInstaller.cs'
$offlineBuilder = Join-Path $windowsRoot 'build-offline-bundle.ps1'
$dependencyLock = Join-Path $windowsRoot 'dependencies.lock.json'
$releaseWorkflow = Join-Path $windowsRoot 'release-windows.yml'
if (-not (Test-Path -LiteralPath $releaseWorkflow -PathType Leaf)) {
    $releaseWorkflow = Join-Path (Split-Path -Parent $windowsRoot) `
        '.github\workflows\release-windows.yml'
}
$shell = (Get-Process -Id $PID).Path
$failures = [System.Collections.Generic.List[string]]::new()

function Quote-Argument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-Cleanup {
    param(
        [string]$Raw,
        [AllowEmptyString()][string]$Candidate,
        [switch]$CallBackend
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $shell
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $cleanup)
    if (-not $CallBackend) { $args += @('-ValidateCandidate', '-Candidate', $Candidate) }
    $start.Arguments = ($args | ForEach-Object { Quote-Argument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Raw)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $output = $outTask.GetAwaiter().GetResult()
    $errorText = $errTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "cleanup exited $($process.ExitCode): $errorText" }
    return $output
}

function Assert-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -cne $Actual) {
        $failures.Add("$Name`n  expected: <$Expected>`n  actual:   <$Actual>")
    }
}

$helpText = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $builder -Help | Out-String
if ($LASTEXITCODE -ne 0 -or $helpText -notlike '*Required payload directory contents:*') {
    $failures.Add('MSIX builder help failed')
}
$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $noArgumentText = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $builder 2>&1 | Out-String
    $noArgumentExit = $LASTEXITCODE
} finally { $ErrorActionPreference = $savedPreference }
if ($noArgumentExit -ne 2 -or $noArgumentText -notlike '*-PayloadDirectory is required*') {
    $failures.Add('MSIX builder missing-argument guidance failed')
}
$prepareText = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $preparer -VoxtypeExe 'C:\build\voxtype.exe' | Out-String
if ($LASTEXITCODE -ne 0 -or $prepareText -notlike '*Dry run complete*') {
    $failures.Add('release preparer dry run failed')
}
try {
    $dependencyData = Get-Content -LiteralPath $dependencyLock -Raw | ConvertFrom-Json
    if ($dependencyData.schemaVersion -ne 1 -or @($dependencyData.models).Count -ne 2) {
        $failures.Add('dependency lock shape is invalid')
    }
    foreach ($model in $dependencyData.models) {
        if ($model.url -notmatch '^https://' -or $model.sha256 -notmatch '^[0-9a-f]{64}$') {
            $failures.Add("dependency model is not pinned: $($model.id)")
        }
    }
} catch { $failures.Add("dependency lock failed to parse: $($_.Exception.Message)") }
try {
    [xml](Get-Content -LiteralPath (Join-Path $windowsRoot `
        'packaging\AppxManifest.xml.in') -Raw) | Out-Null
} catch { $failures.Add("MSIX manifest template failed to parse: $($_.Exception.Message)") }
try {
    $releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflow -Raw
    if ($releaseWorkflowText -match 'HF_TOKEN|voxtype-windows-offline') {
        $failures.Add('release workflow contains the removed hosted offline path')
    }
    if ($releaseWorkflowText -notmatch [regex]::Escape('Cert:\LocalMachine\TrustedPeople')) {
        $failures.Add('release workflow does not trust the self-signed certificate during verification')
    }
} catch { $failures.Add("release workflow failed to parse: $($_.Exception.Message)") }
try {
    $bootstrapSourceText = Get-Content -LiteralPath $bootstrapSource -Raw
    if ($bootstrapSourceText -notmatch
            'ServicePointManager\.SecurityProtocol\s*\|=\s*SecurityProtocolType\.Tls12') {
        $failures.Add('bootstrap downloader does not explicitly enable TLS 1.2')
    }
} catch { $failures.Add("bootstrap source failed to parse: $($_.Exception.Message)") }

function Start-FakeCleanupServer {
    param([string]$ResponseText)
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reservation.Start()
    $port = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $reservation.Stop()
    $job = Start-Job -ArgumentList $port, $ResponseText -ScriptBlock {
        param($Port, $ResponseText)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        Write-Output 'ready'
        try {
            for ($requestIndex = 0; $requestIndex -lt 2; $requestIndex++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false,
                        1024, $true)
                    $contentLength = 0
                    while (($line = $reader.ReadLine()) -ne '') {
                        if ($line -match '^Content-Length:\s*(\d+)$') {
                            $contentLength = [int]$Matches[1]
                        }
                    }
                    if ($contentLength -gt 0) {
                        $buffer = [char[]]::new($contentLength)
                        $read = 0
                        while ($read -lt $contentLength) {
                            $count = $reader.Read($buffer, $read, $contentLength - $read)
                            if ($count -le 0) { break }
                            $read += $count
                        }
                    }
                    if ($requestIndex -eq 0) {
                        $body = '{"status":"ok"}'
                    } else {
                        $body = @{ choices = @(@{ message = @{ content = $ResponseText } }) } |
                            ConvertTo-Json -Depth 5 -Compress
                    }
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body)
                    $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n" +
                        "Content-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                } finally { $client.Dispose() }
            }
        } finally { $listener.Stop() }
    }
    $ready = ''
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($ready -notcontains 'ready' -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
        $ready = @($ready) + @(Receive-Job -Job $job)
    }
    if ($ready -notcontains 'ready') {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw 'fake cleanup server did not start'
    }
    return [pscustomobject]@{ Job = $job; Port = $port }
}

$raw = 'um so can you check the tailscale status on the mini pc you know'
Assert-Equal 'valid cleanup accepted' 'So can you check the Tailscale status on the mini PC?' `
    (Invoke-Cleanup $raw 'So can you check the Tailscale status on the mini PC?')
Assert-Equal 'empty answer rejected' $raw (Invoke-Cleanup $raw '')
Assert-Equal 'large growth rejected' $raw `
    (Invoke-Cleanup $raw (($raw + ' extra explanation ') * 4))
Assert-Equal 'large shrink rejected' $raw (Invoke-Cleanup $raw 'Check status.')
Assert-Equal 'lost content words rejected' $raw `
    (Invoke-Cleanup $raw 'Please inspect whether everything works correctly today.')

$grammarRaw = 'how can i use this controller as a to control my mouse'
Assert-Equal 'invented word rejected' $grammarRaw `
    (Invoke-Cleanup $grammarRaw 'How can I use this controller as a way to control my mouse?')
Assert-Equal 'broken grammar preserved' 'How can I use this controller as a to control my mouse?' `
    (Invoke-Cleanup $grammarRaw 'How can I use this controller as a to control my mouse?')
Assert-Equal 'thinking block removed' 'Check the Tailscale status on the mini PC.' `
    (Invoke-Cleanup 'check the tailscale status on the mini pc' `
        '<think>reasoning that must never be typed</think> Check the Tailscale status on the mini PC.')
Assert-Equal 'wrapper quotes removed' 'Check the Tailscale status on the mini PC.' `
    (Invoke-Cleanup 'check the tailscale status on the mini pc' `
        '"Check the Tailscale status on the mini PC."')

$oldBackend = $env:VOXTYPE_CLEANUP_BACKEND
try {
    $env:VOXTYPE_CLEANUP_BACKEND = 'off'
    Assert-Equal 'off backend is exact passthrough' "keep this exact`nincluding newline" `
        (Invoke-Cleanup "keep this exact`nincluding newline" '' -CallBackend)
    $dispatched = "dispatcher keeps stdin exact" |
        & $shell -NoLogo -NoProfile -NonInteractive -File $localTools cleanup
    Assert-Equal 'local command dispatch' 'dispatcher keeps stdin exact' ([string]$dispatched)
    $env:VOXTYPE_CLEANUP_BACKEND = 'local'
    $env:VOXTYPE_CLEANUP_ENDPOINT = 'http://127.0.0.1:1'
    Assert-Equal 'unavailable local server is exact passthrough' $raw `
        (Invoke-Cleanup $raw '' -CallBackend)

    $httpCandidate = 'So can you check the Tailscale status on the mini PC?'
    $fake = Start-FakeCleanupServer $httpCandidate
    try {
        $env:VOXTYPE_CLEANUP_ENDPOINT = "http://127.0.0.1:$($fake.Port)"
        Assert-Equal 'local HTTP response accepted' $httpCandidate `
            (Invoke-Cleanup $raw '' -CallBackend)
        Wait-Job -Job $fake.Job -Timeout 5 | Out-Null
        if ($fake.Job.State -ne 'Completed') { $failures.Add('fake cleanup server did not finish') }
    } finally {
        Stop-Job $fake.Job -ErrorAction SilentlyContinue
        Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:VOXTYPE_CLEANUP_BACKEND = $oldBackend
    Remove-Item Env:VOXTYPE_CLEANUP_ENDPOINT -ErrorAction SilentlyContinue
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-windows-test-' + [guid]::NewGuid().ToString('N'))
$oldVocab = $env:VOXTYPE_VOCAB_FILE
$oldExecutable = $env:VOXTYPE_EXE
$oldConfigRoot = $env:VOXTYPE_CONFIG_ROOT
$oldDataRoot = $env:VOXTYPE_DATA_ROOT
$oldTestLog = $env:VOXTYPE_TEST_LOG
$oldServerExecutable = $env:LLAMA_SERVER_EXE
$oldModelPath = $env:VOXTYPE_CLEANUP_MODEL_PATH
$oldEndpoint = $env:VOXTYPE_CLEANUP_ENDPOINT
$oldDevice = $env:LLAMA_DEVICE
try {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testVocab = Join-Path $tempDir 'vocabulary.conf'
    [IO.File]::WriteAllText($testVocab,
        "[misheard]`r`nHyprland`r`n`r`n[misspelled]`r`nPyTorch`r`n",
        [Text.UTF8Encoding]::new($false))
    $env:VOXTYPE_VOCAB_FILE = $testVocab
    $all = & $shell -NoLogo -NoProfile -NonInteractive -File $vocab all
    Assert-Equal 'vocabulary read order' 'Hyprland, PyTorch' ([string]$all)
    & $shell -NoLogo -NoProfile -NonInteractive -File $vocab add --no-apply llama.cpp |
        Out-Null
    $after = & $shell -NoLogo -NoProfile -NonInteractive -File $vocab misspelled
    Assert-Equal 'vocabulary add' 'PyTorch, llama.cpp' ([string]$after)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $shell -NoLogo -NoProfile -NonInteractive -File $vocab add --no-apply PYTORCH `
            2>$null | Out-Null
    } finally { $ErrorActionPreference = $savedPreference }
    $deduped = & $shell -NoLogo -NoProfile -NonInteractive -File $vocab misspelled
    Assert-Equal 'vocabulary duplicate ignored' 'PyTorch, llama.cpp' ([string]$deduped)

    $fakeExecutable = Join-Path $tempDir 'fake-voxtype.cmd'
    $testLog = Join-Path $tempDir 'voxtype-calls.log'
    $testConfigRoot = Join-Path $tempDir 'config'
    $testDataRoot = Join-Path $tempDir 'data'
    $fakeSource = @'
@echo off
>>"%VOXTYPE_TEST_LOG%" echo %*
if "%~1"=="config" if "%~2"=="get" (
  if "%~3"=="meeting.enabled" (
    echo false
    exit /b 0
  )
  exit /b 1
)
exit /b 0
'@
    [IO.File]::WriteAllText($fakeExecutable, $fakeSource,
        [Text.Encoding]::ASCII)
    $env:VOXTYPE_EXE = $fakeExecutable
    $env:VOXTYPE_CONFIG_ROOT = $testConfigRoot
    $env:VOXTYPE_DATA_ROOT = $testDataRoot
    $env:VOXTYPE_VOCAB_FILE = Join-Path $testConfigRoot 'vocabulary.conf'
    $env:VOXTYPE_TEST_LOG = $testLog
    $fakeWhisper = Join-Path $tempDir 'whisper.bin'
    [IO.File]::WriteAllText($fakeWhisper, 'test whisper model', [Text.Encoding]::ASCII)
    $setupOutput = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $setup -Hotkey F13 -WhisperModelPath $fakeWhisper `
        -AudioDevice 'Test Microphone' -EnableStartup -SetupVad 6>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("setup exited $LASTEXITCODE`n$setupOutput")
    } else {
        $calls = [IO.File]::ReadAllText($testLog)
        foreach ($expectedCall in @('config set hotkey.enabled true',
                'config set hotkey.key F13', 'config set whisper.initial_prompt',
                "config set whisper.model $fakeWhisper", 'config set audio.device',
                'setup vad')) {
            if (-not $calls.Contains($expectedCall)) {
                $failures.Add("setup did not issue: $expectedCall")
            }
        }
        if ($calls.Contains('config set meeting.enabled false')) {
            $failures.Add('setup rewrote a configuration value that already matched')
        }
        if (-not (Test-Path -LiteralPath $env:VOXTYPE_VOCAB_FILE -PathType Leaf)) {
            $failures.Add('setup did not install the starter vocabulary')
        }
        $recordedModelPath = Join-Path $testDataRoot 'cleanup-model.path'
        $expectedModelPath = Join-Path $testDataRoot `
            'models\Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
        if (Test-Path -LiteralPath $recordedModelPath -PathType Leaf) {
            Assert-Equal 'setup records cleanup model path' $expectedModelPath `
                ([IO.File]::ReadAllText($recordedModelPath))
        } else {
            $failures.Add('setup did not record the cleanup model path')
        }
        if (-not $calls.Contains('Test Microphone')) {
            $failures.Add('setup did not pass the selected microphone name')
        }
        if (-not (Test-Path -LiteralPath (Join-Path $testDataRoot 'startup.enabled'))) {
            $failures.Add('setup did not record the startup preference')
        }
    }

    $fakeMsix = Join-Path $tempDir 'VoxType-test.msix'
    [IO.File]::WriteAllText($fakeMsix, 'test package', [Text.Encoding]::ASCII)
    $bootstrapOutput = Join-Path $tempDir 'release'
    & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $bootstrapBuilder -MsixPath $fakeMsix -Version 0.0.0.1 `
        -Publisher 'CN=VoxType Test' -OutputDirectory $bootstrapOutput -SkipSigning |
        Out-Null
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $bootstrapOutput `
            'VoxTypeSetup-0.0.0.1-x64.exe') -PathType Leaf)) {
        $failures.Add('unsigned bootstrap build failed')
    }
    [IO.File]::WriteAllText((Join-Path $bootstrapOutput `
        'VoxType-0.0.0.1-signing.cer'), 'test public certificate', [Text.Encoding]::ASCII)
    $fakeModels = Join-Path $tempDir 'models'
    New-Item -ItemType Directory -Path $fakeModels | Out-Null
    $fakeModelEntries = @()
    foreach ($modelName in @('whisper.bin', 'cleanup.gguf')) {
        $modelPath = Join-Path $fakeModels $modelName
        [IO.File]::WriteAllText($modelPath, "model $modelName", [Text.Encoding]::ASCII)
        $fakeModelEntries += [ordered]@{
            id = $modelName
            fileName = $modelName
            sha256 = (Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $fakeLock = Join-Path $tempDir 'dependencies.lock.json'
    @{ models = $fakeModelEntries } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $fakeLock -Encoding UTF8
    & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $offlineBuilder -ReleaseDirectory $bootstrapOutput `
        -ModelDirectory $fakeModels -Version 0.0.0.1 -DependencyLock $fakeLock | Out-Null
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $bootstrapOutput `
            'VoxType-0.0.0.1-windows-x64-offline.zip') -PathType Leaf)) {
        $failures.Add('offline bundle build failed')
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $offlineArchive = Join-Path $bootstrapOutput `
            'VoxType-0.0.0.1-windows-x64-offline.zip'
        $zip = [IO.Compression.ZipFile]::OpenRead($offlineArchive)
        try {
            $archiveEntries = @($zip.Entries | ForEach-Object {
                $_.FullName.Replace('\', '/')
            })
            if (-not ($archiveEntries -contains `
                    'VoxType-0.0.0.1-offline/VoxType-0.0.0.1-signing.cer')) {
                $failures.Add('offline bundle omitted the public signing certificate')
            }
        } finally { $zip.Dispose() }
    }
    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
        /reference:System.Web.Extensions.dll `
        "/out:$(Join-Path $tempDir 'voxtype-configure.exe')" `
        (Join-Path $windowsRoot 'packaging\ConfigureLauncher.cs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('guided setup failed to compile') }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        "/out:$(Join-Path $tempDir 'voxtype-startup.exe')" `
        (Join-Path $windowsRoot 'packaging\StartupLauncher.cs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('startup launcher failed to compile') }

    $fakeServer = Join-Path $tempDir 'fake-llama-server.cmd'
    $serverCallLog = Join-Path $tempDir 'llama-server-calls.log'
    $fakeServerSource = @'
@echo off
>>"%VOXTYPE_TEST_LOG%" echo %*
if "%~1"=="--list-devices" echo Vulkan0: Test GPU
exit /b 0
'@
    [IO.File]::WriteAllText($fakeServer, $fakeServerSource, [Text.Encoding]::ASCII)
    $fakeModel = Join-Path $tempDir 'cleanup.gguf'
    [IO.File]::WriteAllText($fakeModel, 'test model', [Text.Encoding]::ASCII)
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reservation.Start()
    $serverPort = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $reservation.Stop()
    $env:LLAMA_SERVER_EXE = $fakeServer
    $env:VOXTYPE_CLEANUP_MODEL_PATH = $fakeModel
    $env:VOXTYPE_CLEANUP_ENDPOINT = "http://127.0.0.1:$serverPort"
    $env:VOXTYPE_TEST_LOG = $serverCallLog
    Remove-Item Env:LLAMA_DEVICE -ErrorAction SilentlyContinue
    & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $serverScript | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("cleanup server exited $LASTEXITCODE")
    } else {
        $serverCalls = [IO.File]::ReadAllText($serverCallLog)
        if (-not $serverCalls.Contains('--list-devices')) {
            $failures.Add('cleanup server did not enumerate compute devices')
        }
        if (-not $serverCalls.Contains("--port $serverPort")) {
            $failures.Add('cleanup server ignored the configured endpoint port')
        }
        if (-not $serverCalls.Contains('--device Vulkan0')) {
            $failures.Add('cleanup server did not select the first Vulkan device')
        }
    }
} finally {
    $env:VOXTYPE_VOCAB_FILE = $oldVocab
    $env:VOXTYPE_EXE = $oldExecutable
    $env:VOXTYPE_CONFIG_ROOT = $oldConfigRoot
    $env:VOXTYPE_DATA_ROOT = $oldDataRoot
    $env:VOXTYPE_TEST_LOG = $oldTestLog
    $env:LLAMA_SERVER_EXE = $oldServerExecutable
    $env:VOXTYPE_CLEANUP_MODEL_PATH = $oldModelPath
    $env:VOXTYPE_CLEANUP_ENDPOINT = $oldEndpoint
    $env:LLAMA_DEVICE = $oldDevice
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}

foreach ($script in Get-ChildItem -LiteralPath $windowsRoot -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens,
        [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failures.Add("PowerShell syntax: $($script.Name): $($errors -join '; ')")
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine($failure) }
    exit 1
}
Write-Host 'VoxType Windows tests passed.'

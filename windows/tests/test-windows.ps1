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
$offlineBuilder = Join-Path $windowsRoot 'build-offline-bundle.ps1'
$dependencyLock = Join-Path $windowsRoot 'dependencies.lock.json'
$releaseWorkflow = Join-Path $windowsRoot 'release-windows.yml'
if (-not (Test-Path -LiteralPath $releaseWorkflow -PathType Leaf)) {
    $releaseWorkflow = Join-Path (Split-Path -Parent $windowsRoot) `
        '.github\workflows\release-windows.yml'
}
$shell = (Get-Process -Id $PID).Path
$failures = [System.Collections.Generic.List[string]]::new()
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
# The cleanup script reads the recorded backend choice from the data root; keep this
# machine's choice and environment out of every test below.
$env:VOXTYPE_DATA_ROOT = Join-Path ([IO.Path]::GetTempPath()) `
    ('voxtype-windows-data-' + [guid]::NewGuid().ToString('N'))
Remove-Item Env:VOXTYPE_CLEANUP_BACKEND -ErrorAction SilentlyContinue
# Nor may any test find this machine's OpenCode Go, Anthropic or Groq key and send a dictation away.
Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_KEY, Env:VOXTYPE_CLEANUP_GROQ_KEY, `
    Env:VOXTYPE_CLEANUP_GROQ_KEY_FILE, Env:VOXTYPE_CLEANUP_ANTHROPIC_KEY, `
    Env:VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE -ErrorAction SilentlyContinue
$env:PI_CODING_AGENT_DIR = Join-Path ([IO.Path]::GetTempPath()) `
    ('voxtype-windows-pi-' + [guid]::NewGuid().ToString('N'))

# Runs a compiled test program and records its output as a failure unless it exits 0.
function Invoke-TestProgram {
    param([string]$Path, [string]$Name, [int]$TimeoutSeconds = 120)
    $start = [Diagnostics.ProcessStartInfo]::new($Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        $failures.Add("$Name did not finish within $TimeoutSeconds seconds")
        return
    }
    $output = $outTask.GetAwaiter().GetResult() + $errTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { $failures.Add("$Name exited $($process.ExitCode):`n$output") }
}

function Quote-Argument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-Cleanup {
    param(
        [string]$Raw,
        [AllowEmptyString()][string]$Candidate,
        [switch]$CallBackend,
        [string]$Link = ''
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $shell
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $cleanup)
    if (-not $CallBackend) { $args += @('-ValidateCandidate', '-Candidate', $Candidate) }
    if ($Link) { $args += @('-Link', $Link) }
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
    if ($dependencyData.schemaVersion -ne 1 -or @($dependencyData.models).Count -ne 3) {
        $failures.Add('dependency lock shape is invalid')
    }
    # Recordings run Parakeet and dictation Whisper, with Qwen for cleanup.
    $modelIds = @($dependencyData.models | ForEach-Object { [string]$_.id }) -join ','
    Assert-Equal 'dependency lock pins Parakeet, Whisper and the cleanup model' 'parakeet,whisper,cleanup' $modelIds
    foreach ($model in $dependencyData.models) {
        # A model of several files lists them under files, in its own folder.
        $modelFiles = if ($null -ne $model.PSObject.Properties['files']) {
            if ([string]$model.directory -notmatch '^[A-Za-z0-9._-]+$') {
                $failures.Add("dependency model has no plain folder name: $($model.id)")
            }
            @($model.files)
        } else { @($model) }
        foreach ($file in $modelFiles) {
            if ($file.url -notmatch '^https://' -or $file.sha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$file.fileName -notmatch '^[A-Za-z0-9._-]+$') {
                $failures.Add("dependency model is not pinned: $($model.id) $($file.fileName)")
            }
            # The size lets setup verify an already complete .partial without a request.
            $size = $file.PSObject.Properties['size']
            if ($null -eq $size -or [string]$size.Value -notmatch '^[1-9][0-9]*$') {
                $failures.Add("dependency model has no positive byte size: $($model.id) $($file.fileName)")
            }
        }
    }
} catch { $failures.Add("dependency lock failed to parse: $($_.Exception.Message)") }
try {
    $manifestTemplate = [xml](Get-Content -LiteralPath (Join-Path $windowsRoot `
        'packaging\AppxManifest.xml.in') -Raw)
    # Windows refuses to start a packaged exe that no Application names (win32 error 5),
    # even from inside the package, so every exe the builder stages needs one.
    $declared = @($manifestTemplate.Package.Applications.Application |
        ForEach-Object { $_.Executable })
    $builderText = Get-Content -LiteralPath (Join-Path $windowsRoot 'build-msix.ps1') -Raw
    $staged = @([regex]::Matches($builderText,
            "(?:Copy-RequiredFile|Join-Path \`$staging) '([^']+\.exe)'") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($staged.Count -lt 7) {
        $failures.Add("found only $($staged.Count) of the exes build-msix.ps1 stages")
    }
    foreach ($name in $staged) {
        if ($name -notin $declared) {
            $failures.Add("MSIX manifest has no Application for $name, so Windows would refuse to start it")
        }
    }
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
# The launchers are built by the .NET Framework csc without a TargetFrameworkAttribute,
# so they run with .NET 4.0 TLS defaults (SSL 3.0 and TLS 1.0 only). GitHub, Hugging Face
# and its CDN refuse those, and SystemDefault throws in that mode, so every source that
# makes an HTTP request must add TLS 1.2 explicitly. All downloads go through
# ResumableDownload.cs, which both build scripts compile next to their launcher.
$downloaders = [System.Collections.Generic.List[string]]::new()
foreach ($launcherSource in Get-ChildItem -LiteralPath (Join-Path $windowsRoot 'packaging') `
        -Filter '*.cs' -File) {
    try {
        $launcherText = Get-Content -LiteralPath $launcherSource.FullName -Raw
    } catch {
        $failures.Add("$($launcherSource.Name) failed to read: $($_.Exception.Message)")
        continue
    }
    if ($launcherText -notmatch 'WebRequest|WebClient|HttpClient') { continue }
    $downloaders.Add($launcherSource.Name)
    if ($launcherText -notmatch
            'ServicePointManager\.SecurityProtocol\s*\|=\s*SecurityProtocolType\.Tls12') {
        $failures.Add("$($launcherSource.Name) downloads without explicitly enabling TLS 1.2")
    }
    if ($launcherText -match 'SecurityProtocolType\.SystemDefault') {
        $failures.Add("$($launcherSource.Name) uses SystemDefault, which csc-built launchers reject")
    }
}
if (-not $downloaders.Contains('ResumableDownload.cs')) {
    $failures.Add('TLS check no longer recognizes ResumableDownload.cs as a downloader')
}
foreach ($launcherName in @('BootstrapInstaller.cs', 'ConfigureLauncher.cs')) {
    $launcherText = Get-Content -LiteralPath (Join-Path $windowsRoot "packaging\$launcherName") -Raw
    if ($launcherText -notmatch 'new ResumableDownload') {
        $failures.Add("$launcherName no longer downloads through ResumableDownload")
    }
}
# Shared sources must be compiled, and shared scripts packaged, by the real build scripts.
$msixBuilderText = Get-Content -LiteralPath $builder -Raw
$bootstrapBuilderText = Get-Content -LiteralPath $bootstrapBuilder -Raw
foreach ($requirement in @(
        @($msixBuilderText, 'packaging\ResumableDownload.cs', 'build-msix.ps1'),
        @($msixBuilderText, 'packaging\CleanupBackend.cs', 'build-msix.ps1'),
        @($msixBuilderText, "'voxtype-cleanup-backend.ps1'", 'build-msix.ps1'),
        @($msixBuilderText, "'cleanup.json'", 'build-msix.ps1'),
        @($bootstrapBuilderText, 'packaging\ResumableDownload.cs', 'build-bootstrap.ps1'))) {
    if (-not $requirement[0].Contains($requirement[1])) {
        $failures.Add("$($requirement[2]) does not include $($requirement[1])")
    }
}

# Cleanup backend chain rules, shared by voxtype-setup.ps1 and voxtype-cleanup.ps1.
. (Join-Path $windowsRoot 'voxtype-cleanup-backend.ps1')
foreach ($case in @(@('pi', 'pi'), @(' Pi , LOCAL ', 'pi,local'), @(' OpenCode , local ', 'opencode,local'),
        @(' Groq , local ', 'groq,local'), @(' Anthropic , local ', 'anthropic,local'), @('off', 'off'),
        @('local', 'local'), @('claude,codex,openai,local', 'claude,codex,openai,local'))) {
    try {
        Assert-Equal "cleanup chain <$($case[0])>" $case[1] `
            (ConvertTo-CleanupBackendChain $case[0])
    } catch { $failures.Add("cleanup chain <$($case[0])> was rejected: $($_.Exception.Message)") }
}
foreach ($invalid in @('', '  ', 'local,pi', 'off,pi', 'pi,off', 'pi,,local', 'pi,pi', 'bogus',
        'local,opencode', 'opencode,opencode', 'local,groq')) {
    $accepted = $true
    try { ConvertTo-CleanupBackendChain $invalid | Out-Null } catch { $accepted = $false }
    if ($accepted) { $failures.Add("cleanup chain <$invalid> was accepted") }
}

function Start-FakeCleanupServer {
    # RequestFile, when given, receives the body of the completion request. -Messages answers
    # one Messages API request, as OpenCode Go does, with no health check first, and keeps its
    # headers in RequestFile.headers. -Chat answers one chat request the same way, as Groq
    # does, with reasoning beside the answer. Placement, when given, is sent as Cf-Placement.
    param([string]$ResponseText, [string]$RequestFile = '', [switch]$Messages, [string]$Placement = '',
        [switch]$Chat)
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reservation.Start()
    $port = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $reservation.Stop()
    $job = Start-Job -ArgumentList $port, $ResponseText, $RequestFile, ([bool]$Messages), $Placement,
            ([bool]$Chat) -ScriptBlock {
        param($Port, $ResponseText, $RequestFile, $Messages, $Placement, $Chat)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        Write-Output 'ready'
        try {
            $requests = if ($Messages -or $Chat) { 1 } else { 2 }
            for ($requestIndex = 0; $requestIndex -lt $requests; $requestIndex++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false,
                        1024, $true)
                    $contentLength = 0
                    $headerLines = [System.Collections.Generic.List[string]]::new()
                    while (($line = $reader.ReadLine()) -ne '') {
                        $headerLines.Add($line)
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
                    $completion = $Messages -or $Chat -or $requestIndex -eq 1
                    if ($completion -and $RequestFile -and $contentLength -gt 0) {
                        [IO.File]::WriteAllText($RequestFile, [string]::new($buffer, 0, $read))
                        if ($Messages -or $Chat) { [IO.File]::WriteAllLines($RequestFile + '.headers', $headerLines) }
                    }
                    $extra = ''
                    if (-not $completion) {
                        $body = '{"status":"ok"}'
                    } elseif ($Messages) {
                        # A thinking block first, which is never the answer, and the usage.
                        $body = @{ content = @(@{ type = 'thinking'; thinking = 'Not the answer.' },
                                @{ type = 'text'; text = $ResponseText })
                            usage = @{ input_tokens = 791; output_tokens = 18
                                opencode = @{ tokens = @{ reasoning = 0 } } } } |
                            ConvertTo-Json -Depth 6 -Compress
                        if ($Placement) { $extra = "Cf-Placement: $Placement`r`n" }
                    } elseif ($Chat) {
                        $body = @{ choices = @(@{ message = @{ role = 'assistant'; content = $ResponseText
                                    reasoning = 'Not the answer.' } })
                            usage = @{ prompt_tokens = 802; completion_tokens = 41
                                completion_tokens_details = @{ reasoning_tokens = 23 } } } |
                            ConvertTo-Json -Depth 6 -Compress
                    } else {
                        $body = @{ choices = @(@{ message = @{ content = $ResponseText } }) } |
                            ConvertTo-Json -Depth 5 -Compress
                    }
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body)
                    $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n$extra" +
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

# The guard answers every port must give, from the shared cases file.
$rulesPath = Join-Path (Split-Path -Parent $windowsRoot) 'cleanup.json'
$casesPath = Join-Path (Split-Path -Parent $windowsRoot) 'cleanup-cases.json'
try {
    $cases = @((Get-Content -LiteralPath $casesPath -Raw -Encoding UTF8 | ConvertFrom-Json).cases)
    if ($cases.Count -lt 12) { $failures.Add("cleanup-cases.json has only $($cases.Count) cases") }
    foreach ($case in $cases) {
        Assert-Equal "cleanup case: $($case.name)" $case.expect `
            (Invoke-Cleanup $case.raw $case.cleaned -Link $case.link)
    }
} catch { $failures.Add("cleanup cases failed to run: $($_.Exception.Message)") }

$raw = 'um so can you check the tailscale status on the mini pc you know'
$oldRulesFile = $env:VOXTYPE_CLEANUP_FILE
try {
    # Without the rules there is no guard to pass, so even a good answer leaves the text as said.
    $env:VOXTYPE_CLEANUP_FILE = Join-Path ([IO.Path]::GetTempPath()) 'voxtype-no-such-cleanup.json'
    Assert-Equal 'missing cleanup rules keep the text' $raw `
        (Invoke-Cleanup $raw 'So can you check the Tailscale status on the mini PC?')
} finally {
    if ($null -eq $oldRulesFile) { Remove-Item Env:VOXTYPE_CLEANUP_FILE -ErrorAction SilentlyContinue }
    else { $env:VOXTYPE_CLEANUP_FILE = $oldRulesFile }
}

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
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-request-' + [guid]::NewGuid().ToString('N'))
    $fake = Start-FakeCleanupServer $httpCandidate $requestFile
    try {
        $env:VOXTYPE_CLEANUP_ENDPOINT = "http://127.0.0.1:$($fake.Port)"
        Assert-Equal 'local HTTP response accepted' $httpCandidate `
            (Invoke-Cleanup $raw '' -CallBackend)
        Wait-Job -Job $fake.Job -Timeout 5 | Out-Null
        if ($fake.Job.State -ne 'Completed') { $failures.Add('fake cleanup server did not finish') }
        # What the server was sent comes from the shared rules: their prompt and examples.
        $rules = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sent = Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json
        $messages = @($sent.messages)
        if (-not ([string]$messages[0].content).StartsWith(@($rules.instructions) -join "`n")) {
            $failures.Add('the local request does not start with the shared instructions')
        }
        Assert-Equal 'local request carries every example' ([string](2 + 2 * @($rules.examples).Count)) `
            ([string]$messages.Count)
        Assert-Equal 'local request wraps an example' `
            ($rules.transcript.Replace('{text}', $rules.examples[0].raw)) ([string]$messages[1].content)
        Assert-Equal 'local request wraps the dictation' `
            ($rules.transcript.Replace('{text}', $raw)) ([string]$messages[-1].content)
        $budget = [regex]::Matches($raw, '\S+').Count * $rules.request.max_tokens_per_word +
            $rules.request.max_tokens_extra
        Assert-Equal 'local request token budget' ([string]$budget) ([string]$sent.max_tokens)
    } finally {
        Remove-Item -LiteralPath $requestFile -ErrorAction SilentlyContinue
        Stop-Job $fake.Job -ErrorAction SilentlyContinue
        Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:VOXTYPE_CLEANUP_BACKEND = $oldBackend
    Remove-Item Env:VOXTYPE_CLEANUP_ENDPOINT -ErrorAction SilentlyContinue
}

# opencode: one Messages API request to OpenCode Go, the key read in place from pi's store
# (never this machine's: PI_CODING_AGENT_DIR points at a temporary one), sent as a header.
$oldBackend = $env:VOXTYPE_CLEANUP_BACKEND
$oldAgent = $env:PI_CODING_AGENT_DIR
$piAgent = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-pi-' + [guid]::NewGuid().ToString('N'))
try {
    $env:VOXTYPE_CLEANUP_BACKEND = 'opencode'
    $env:PI_CODING_AGENT_DIR = $piAgent
    Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_KEY -ErrorAction SilentlyContinue
    $env:VOXTYPE_CLEANUP_OPENCODE_ENDPOINT = 'http://127.0.0.1:1/v1/messages'
    Assert-Equal 'opencode without a key keeps the text' $raw (Invoke-Cleanup $raw '' -CallBackend)
    [IO.Directory]::CreateDirectory($piAgent) | Out-Null
    [IO.File]::WriteAllText((Join-Path $piAgent 'auth.json'),
        '{"zai":{"type":"api_key","key":"other"},"opencode-go":{"type":"api_key","key":"from-pi"}}')
    $httpCandidate = 'So can you check the Tailscale status on the mini PC?'
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-request-' + [guid]::NewGuid().ToString('N'))
    $timingFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-timing-' + [guid]::NewGuid().ToString('N'))
    $fake = Start-FakeCleanupServer $httpCandidate $requestFile -Messages
    try {
        $env:VOXTYPE_CLEANUP_OPENCODE_ENDPOINT = "http://127.0.0.1:$($fake.Port)/v1/messages"
        $env:VOXTYPE_CLEANUP_TIMING_FILE = $timingFile
        Assert-Equal 'opencode answer accepted, its text blocks only' $httpCandidate `
            (Invoke-Cleanup $raw '' -CallBackend)
        Wait-Job -Job $fake.Job -Timeout 5 | Out-Null
        $rules = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sent = Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json
        $headers = @(Get-Content -LiteralPath ($requestFile + '.headers'))
        Assert-Equal "opencode reads pi's key" 'from-pi' `
            ((@($headers | Where-Object { $_ -match '^x-api-key:' }) -join '|') -replace '^x-api-key:\s*', '')
        Assert-Equal 'opencode names itself' 'voxtype-cleanup/1.0' `
            ((@($headers | Where-Object { $_ -match '^User-Agent:' }) -join '|') -replace '^User-Agent:\s*', '')
        if (-not (@($headers | Where-Object { $_ -match '^x-opencode-session:\s*voxtype-[0-9a-f]{32}$' }).Count -eq 1)) {
            $failures.Add('opencode request has no session ID')
        }
        Assert-Equal 'opencode model' 'qwen3.8-flash' ([string]$sent.model)
        Assert-Equal 'opencode turns thinking off' 'disabled' ([string]$sent.thinking.type)
        if (-not ([string]$sent.system).StartsWith(@($rules.instructions) -join "`n")) {
            $failures.Add('the opencode request does not start with the shared instructions')
        }
        Assert-Equal 'opencode carries every example' ([string](1 + 2 * @($rules.examples).Count)) `
            ([string]@($sent.messages).Count)
        Assert-Equal 'opencode sends no system turn' '0' `
            ([string]@($sent.messages | Where-Object { $_.role -eq 'system' }).Count)
        $budget = [regex]::Matches($raw, '\S+').Count * $rules.request.max_tokens_per_word +
            $rules.request.max_tokens_extra + $rules.request.max_tokens_thinking
        Assert-Equal 'opencode token budget has the thinking room' ([string]$budget) ([string]$sent.max_tokens)
        $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
        Assert-Equal 'timing: opencode answered' 'opencode' ([string]$timed.link)
        Assert-Equal 'timing: changed' 'changed' ([string]$timed.outcome)
        Assert-Equal 'timing: tokens in' '791' ([string]$timed.server.usage.input_tokens)
        if ($null -ne $timed.server.PSObject.Properties['served_from']) {
            $failures.Add('timing: a request without Cf-Placement has a served_from')
        }
        Assert-Equal 'timing: steps in order' 'began rules opencode:built opencode:answered opencode:guarded done' `
            (@($timed.marks | ForEach-Object { $_.name }) -join ' ')
        $ats = @($timed.marks | ForEach-Object { [long]$_.at })
        $sorted = @($ats | Sort-Object)
        if (($ats -join ',') -ne ($sorted -join ',')) { $failures.Add('timing marks go back in time') }
    } finally {
        Remove-Item -LiteralPath $requestFile, ($requestFile + '.headers'), $timingFile -ErrorAction SilentlyContinue
        Stop-Job $fake.Job -ErrorAction SilentlyContinue
        Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
    }
    # Cloudflare's placement, when the request ran away from the edge that took it.
    $fake = Start-FakeCleanupServer $httpCandidate '' -Messages -Placement 'remote-DUB'
    try {
        $env:VOXTYPE_CLEANUP_OPENCODE_ENDPOINT = "http://127.0.0.1:$($fake.Port)/v1/messages"
        Assert-Equal 'opencode answer from a placed request' $httpCandidate (Invoke-Cleanup $raw '' -CallBackend)
        $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
        Assert-Equal 'timing: served from' 'remote-DUB' ([string]$timed.server.served_from)
    } finally {
        Remove-Item -LiteralPath $timingFile -ErrorAction SilentlyContinue
        Stop-Job $fake.Job -ErrorAction SilentlyContinue
        Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:VOXTYPE_CLEANUP_BACKEND = $oldBackend
    $env:PI_CODING_AGENT_DIR = $oldAgent
    Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_ENDPOINT, Env:VOXTYPE_CLEANUP_TIMING_FILE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $piAgent -Recurse -Force -ErrorAction SilentlyContinue
}

# The OpenCode Go key, like Groq's, is read in place from the file
# VOXTYPE_CLEANUP_OPENCODE_KEY_FILE names, after VOXTYPE_CLEANUP_OPENCODE_KEY.
$openCodeKeyFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-opencode-key-' + [guid]::NewGuid().ToString('N'))
$oldOpenCodeKey = $env:VOXTYPE_CLEANUP_OPENCODE_KEY
try {
    Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_KEY -ErrorAction SilentlyContinue
    $env:VOXTYPE_CLEANUP_OPENCODE_KEY_FILE = $openCodeKeyFile
    [IO.File]::WriteAllText($openCodeKeyFile, "from-file`r`n")
    Assert-Equal 'the OpenCode Go key is read from its file' 'from-file' (Get-OpenCodeKey)
    $env:VOXTYPE_CLEANUP_OPENCODE_KEY = 'from-environment'
    Assert-Equal 'VOXTYPE_CLEANUP_OPENCODE_KEY comes first' 'from-environment' (Get-OpenCodeKey)
} finally {
    Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_KEY_FILE -ErrorAction SilentlyContinue
    if ($null -ne $oldOpenCodeKey) { $env:VOXTYPE_CLEANUP_OPENCODE_KEY = $oldOpenCodeKey }
    else { Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_KEY -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $openCodeKeyFile -Force -ErrorAction SilentlyContinue
}

# anthropic: one Messages API request to Anthropic with the user's own key, read in place from
# the file VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE names, or VOXTYPE_CLEANUP_ANTHROPIC_KEY, sent as
# a header. Claude Haiku 5.5 refuses temperature and top_p, so neither is sent.
$oldBackend = $env:VOXTYPE_CLEANUP_BACKEND
$oldAnthropicKey = $env:VOXTYPE_CLEANUP_ANTHROPIC_KEY
$anthropicKeyFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-anthropic-key-' + [guid]::NewGuid().ToString('N'))
try {
    $env:VOXTYPE_CLEANUP_BACKEND = 'anthropic'
    Remove-Item Env:VOXTYPE_CLEANUP_ANTHROPIC_KEY -ErrorAction SilentlyContinue
    $env:VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE = $anthropicKeyFile
    $env:VOXTYPE_CLEANUP_ANTHROPIC_ENDPOINT = 'http://127.0.0.1:1/v1/messages'
    Assert-Equal 'anthropic without a key keeps the text' $raw (Invoke-Cleanup $raw '' -CallBackend)
    Assert-Equal 'no Anthropic key without its file' '' (Get-AnthropicKey)
    [IO.File]::WriteAllText($anthropicKeyFile, "from-file`r`n")
    Assert-Equal 'the Anthropic key is read from its file' 'from-file' (Get-AnthropicKey)
    $env:VOXTYPE_CLEANUP_ANTHROPIC_KEY = 'from-environment'
    try { Assert-Equal 'VOXTYPE_CLEANUP_ANTHROPIC_KEY comes first' 'from-environment' (Get-AnthropicKey) }
    finally { Remove-Item Env:VOXTYPE_CLEANUP_ANTHROPIC_KEY -ErrorAction SilentlyContinue }
    $httpCandidate = 'So can you check the Tailscale status on the mini PC?'
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-request-' + [guid]::NewGuid().ToString('N'))
    $timingFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-timing-' + [guid]::NewGuid().ToString('N'))
    $fake = Start-FakeCleanupServer $httpCandidate $requestFile -Messages
    try {
        $env:VOXTYPE_CLEANUP_ANTHROPIC_ENDPOINT = "http://127.0.0.1:$($fake.Port)/v1/messages"
        $env:VOXTYPE_CLEANUP_TIMING_FILE = $timingFile
        Assert-Equal 'anthropic answer accepted, its text blocks only' $httpCandidate `
            (Invoke-Cleanup $raw '' -CallBackend)
        Wait-Job -Job $fake.Job -Timeout 5 | Out-Null
        $rules = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sent = Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json
        $headers = @(Get-Content -LiteralPath ($requestFile + '.headers'))
        Assert-Equal 'anthropic sends the key from its file' 'from-file' `
            ((@($headers | Where-Object { $_ -match '^x-api-key:' }) -join '|') -replace '^x-api-key:\s*', '')
        Assert-Equal 'anthropic names its API version' '2023-06-01' `
            ((@($headers | Where-Object { $_ -match '^anthropic-version:' }) -join '|') -replace '^anthropic-version:\s*', '')
        if (@($headers | Where-Object { $_ -match '^x-opencode-session:' }).Count -ne 0) {
            $failures.Add('anthropic was sent an OpenCode Go session')
        }
        Assert-Equal 'anthropic model' 'claude-haiku-5-5' ([string]$sent.model)
        Assert-Equal 'anthropic turns thinking off' 'disabled' ([string]$sent.thinking.type)
        foreach ($name in @('temperature', 'top_p')) {
            if ($null -ne $sent.PSObject.Properties[$name]) { $failures.Add("anthropic was sent $name") }
        }
        if (-not ([string]$sent.system).StartsWith(@($rules.instructions) -join "`n")) {
            $failures.Add('the anthropic request does not start with the shared instructions')
        }
        Assert-Equal 'anthropic carries every example' ([string](1 + 2 * @($rules.examples).Count)) `
            ([string]@($sent.messages).Count)
        # Claude honours thinking off, so it gets no thinking room.
        $budget = [regex]::Matches($raw, '\S+').Count * $rules.request.max_tokens_per_word +
            $rules.request.max_tokens_extra
        Assert-Equal 'anthropic token budget has no thinking room' ([string]$budget) ([string]$sent.max_tokens)
        $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
        Assert-Equal 'timing: anthropic answered' 'anthropic' ([string]$timed.link)
        Assert-Equal 'timing: anthropic tokens in' '791' ([string]$timed.server.usage.input_tokens)
        Assert-Equal 'timing: anthropic steps in order' `
            'began rules anthropic:built anthropic:answered anthropic:guarded done' `
            (@($timed.marks | ForEach-Object { $_.name }) -join ' ')
    } finally {
        Remove-Item -LiteralPath $requestFile, ($requestFile + '.headers'), $timingFile -ErrorAction SilentlyContinue
        Stop-Job $fake.Job -ErrorAction SilentlyContinue
        Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:VOXTYPE_CLEANUP_BACKEND = $oldBackend
    if ($null -ne $oldAnthropicKey) { $env:VOXTYPE_CLEANUP_ANTHROPIC_KEY = $oldAnthropicKey }
    Remove-Item Env:VOXTYPE_CLEANUP_ANTHROPIC_ENDPOINT, Env:VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE, `
        Env:VOXTYPE_CLEANUP_TIMING_FILE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $anthropicKeyFile -ErrorAction SilentlyContinue
}

# groq: one chat request to Groq with the user's own key, read in place from the file
# VOXTYPE_CLEANUP_GROQ_KEY_FILE names, or VOXTYPE_CLEANUP_GROQ_KEY, sent as a header.
$oldBackend = $env:VOXTYPE_CLEANUP_BACKEND
$groqKeyFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-groq-key-' + [guid]::NewGuid().ToString('N'))
try {
    $env:VOXTYPE_CLEANUP_BACKEND = 'groq'
    $env:VOXTYPE_CLEANUP_GROQ_KEY_FILE = $groqKeyFile
    $env:VOXTYPE_CLEANUP_GROQ_ENDPOINT = 'http://127.0.0.1:1/openai/v1/chat/completions'
    Assert-Equal 'groq without a key keeps the text' $raw (Invoke-Cleanup $raw '' -CallBackend)
    Assert-Equal 'no Groq key without its file' '' (Get-GroqKey)
    [IO.File]::WriteAllText($groqKeyFile, "from-file`r`n")
    Assert-Equal 'the Groq key is read from its file' 'from-file' (Get-GroqKey)
    $env:VOXTYPE_CLEANUP_GROQ_KEY = 'from-environment'
    try { Assert-Equal 'VOXTYPE_CLEANUP_GROQ_KEY comes first' 'from-environment' (Get-GroqKey) }
    finally { Remove-Item Env:VOXTYPE_CLEANUP_GROQ_KEY -ErrorAction SilentlyContinue }
    $httpCandidate = 'So can you check the Tailscale status on the mini PC?'
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-request-' + [guid]::NewGuid().ToString('N'))
    $timingFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-timing-' + [guid]::NewGuid().ToString('N'))
    $fake = Start-FakeCleanupServer $httpCandidate $requestFile -Chat
    try {
        $env:VOXTYPE_CLEANUP_GROQ_ENDPOINT = "http://127.0.0.1:$($fake.Port)/openai/v1/chat/completions"
        $env:VOXTYPE_CLEANUP_TIMING_FILE = $timingFile
        Assert-Equal 'groq answer accepted, its content only' $httpCandidate (Invoke-Cleanup $raw '' -CallBackend)
        Wait-Job -Job $fake.Job -Timeout 5 | Out-Null
        $rules = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sent = Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json
        $headers = @(Get-Content -LiteralPath ($requestFile + '.headers'))
        Assert-Equal 'groq sends the key from its file' 'Bearer from-file' `
            ((@($headers | Where-Object { $_ -match '^Authorization:' }) -join '|') -replace '^Authorization:\s*', '')
        Assert-Equal 'groq model' 'openai/gpt-oss-20b' ([string]$sent.model)
        Assert-Equal 'groq reasons at low effort' 'low' ([string]$sent.reasoning_effort)
        Assert-Equal 'groq starts with the system turn' 'system' ([string]@($sent.messages)[0].role)
        if (-not ([string]@($sent.messages)[0].content).StartsWith(@($rules.instructions) -join "`n")) {
            $failures.Add('the groq request does not start with the shared instructions')
        }
        Assert-Equal 'groq carries every example' ([string](2 + 2 * @($rules.examples).Count)) `
            ([string]@($sent.messages).Count)
        $budget = [regex]::Matches($raw, '\S+').Count * $rules.request.max_tokens_per_word +
            $rules.request.max_tokens_extra + $rules.request.max_tokens_thinking
        Assert-Equal 'groq token budget has the thinking room' ([string]$budget) `
            ([string]$sent.max_completion_tokens)
        if ($null -ne $sent.PSObject.Properties['max_tokens']) { $failures.Add('groq was sent max_tokens') }
        $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
        Assert-Equal 'timing: groq answered' 'groq' ([string]$timed.link)
        Assert-Equal 'timing: groq tokens in' '802' ([string]$timed.server.usage.prompt_tokens)
        Assert-Equal 'timing: groq steps in order' 'began rules groq:built groq:answered groq:guarded done' `
            (@($timed.marks | ForEach-Object { $_.name }) -join ' ')
    } finally {
        Remove-Item -LiteralPath $requestFile, ($requestFile + '.headers'), $timingFile -ErrorAction SilentlyContinue
        Stop-Job $fake.Job -ErrorAction SilentlyContinue
        Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:VOXTYPE_CLEANUP_BACKEND = $oldBackend
    Remove-Item Env:VOXTYPE_CLEANUP_GROQ_ENDPOINT, Env:VOXTYPE_CLEANUP_GROQ_KEY_FILE, `
        Env:VOXTYPE_CLEANUP_TIMING_FILE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $groqKeyFile -ErrorAction SilentlyContinue
}

# A timed test that keeps the text says why: here, the local server is down, cleanup is
# off, and the dictation is too short to send.
$oldBackend = $env:VOXTYPE_CLEANUP_BACKEND
$timingFile = Join-Path ([IO.Path]::GetTempPath()) ('voxtype-timing-' + [guid]::NewGuid().ToString('N'))
try {
    $env:VOXTYPE_CLEANUP_BACKEND = 'local'
    $env:VOXTYPE_CLEANUP_ENDPOINT = 'http://127.0.0.1:1'
    $env:VOXTYPE_CLEANUP_TIMING_FILE = $timingFile
    Assert-Equal 'timed passthrough' $raw (Invoke-Cleanup $raw '' -CallBackend)
    $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
    Assert-Equal 'timing: kept' 'kept' ([string]$timed.outcome)
    if (@($timed.why).Count -ne 1 -or -not ([string]@($timed.why)[0]).StartsWith('local: ')) {
        $failures.Add("timing: the reason names the link: <$(@($timed.why) -join '; ')>")
    }
    Remove-Item -LiteralPath $timingFile -ErrorAction SilentlyContinue
    $env:VOXTYPE_CLEANUP_BACKEND = 'off'
    Assert-Equal 'timed off' $raw (Invoke-Cleanup $raw '' -CallBackend)
    $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
    Assert-Equal 'timing: off says so' 'cleanup is off' (@($timed.why) -join '; ')
    Remove-Item -LiteralPath $timingFile -ErrorAction SilentlyContinue
    $env:VOXTYPE_CLEANUP_BACKEND = 'local'
    Assert-Equal 'timed short' 'restart it' (Invoke-Cleanup 'restart it' '' -CallBackend)
    $timed = Get-Content -LiteralPath $timingFile -Raw | ConvertFrom-Json
    Assert-Equal 'timing: too short to send' 'short' ([string]$timed.outcome)
} finally {
    $env:VOXTYPE_CLEANUP_BACKEND = $oldBackend
    Remove-Item Env:VOXTYPE_CLEANUP_ENDPOINT, Env:VOXTYPE_CLEANUP_TIMING_FILE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $timingFile -ErrorAction SilentlyContinue
}

# A recorded chain is tried link by link: a stubbed pi CLI first, then the fake local
# server. Every failure, including an answer a guard rejects, falls through, and the
# last resort is the raw text.
$chainRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('voxtype-chain-test-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$oldChainDataRoot = $env:VOXTYPE_DATA_ROOT
$oldChainLog = $env:VOXTYPE_TEST_LOG
try {
    $stubBin = Join-Path $chainRoot 'bin'
    New-Item -ItemType Directory -Path $stubBin -Force | Out-Null
    $piLog = Join-Path $chainRoot 'pi-calls.log'
    $piStub = @'
@echo off
>>"%VOXTYPE_TEST_LOG%" echo pi
if "%PI_STUB_MODE%"=="fail" exit /b 1
if "%PI_STUB_MODE%"=="invent" goto invent
echo So, can you check the Tailscale status on the mini PC?
exit /b 0
:invent
echo So can you check the Tailscale status on the mini PC and reboot the router tonight?
exit /b 0
'@
    [IO.File]::WriteAllText((Join-Path $stubBin 'pi.cmd'), ($piStub -replace "`r?`n", "`r`n"),
        [Text.Encoding]::ASCII)
    $env:PATH = "$stubBin;$oldPath"
    $env:VOXTYPE_DATA_ROOT = $chainRoot
    $env:VOXTYPE_TEST_LOG = $piLog
    $piAnswer = 'So, can you check the Tailscale status on the mini PC?'
    $localAnswer = 'So can you check the Tailscale status on the mini PC?'

    function Test-CleanupChain {
        param([string]$Name, [string]$Recorded, [string]$PiMode, [string]$LocalAnswer,
            [string]$Expected, [int]$ExpectedPiCalls, [string]$BackendVariable)
        [IO.File]::WriteAllText((Join-Path $chainRoot 'cleanup-backend'), $Recorded,
            [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $piLog -ErrorAction SilentlyContinue
        $env:PI_STUB_MODE = $PiMode
        if ($BackendVariable) { $env:VOXTYPE_CLEANUP_BACKEND = $BackendVariable }
        else { Remove-Item Env:VOXTYPE_CLEANUP_BACKEND -ErrorAction SilentlyContinue }
        $fake = $null
        if ($LocalAnswer) {
            $fake = Start-FakeCleanupServer $LocalAnswer
            $env:VOXTYPE_CLEANUP_ENDPOINT = "http://127.0.0.1:$($fake.Port)"
        } else { $env:VOXTYPE_CLEANUP_ENDPOINT = 'http://127.0.0.1:1' }
        try {
            Assert-Equal "cleanup chain: $Name" $Expected (Invoke-Cleanup $raw '' -CallBackend)
            $piCalls = if (Test-Path -LiteralPath $piLog) { @(Get-Content -LiteralPath $piLog).Count } else { 0 }
            if ($piCalls -ne $ExpectedPiCalls) {
                $failures.Add("cleanup chain: $Name called pi $piCalls time(s), expected $ExpectedPiCalls")
            }
        } finally {
            if ($null -ne $fake) {
                Stop-Job $fake.Job -ErrorAction SilentlyContinue
                Remove-Job $fake.Job -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Test-CleanupChain 'pi fails, local answers' 'pi,local' 'fail' $localAnswer $localAnswer 1
    Test-CleanupChain 'pi answers first' 'pi,local' 'ok' '' $piAnswer 1
    Test-CleanupChain 'rejected pi answer falls through' 'pi,local' 'invent' $localAnswer $localAnswer 1
    Test-CleanupChain 'every link fails' 'pi,local' 'fail' '' $raw 1
    Test-CleanupChain 'pi alone fails' 'pi' 'fail' '' $raw 1
    Test-CleanupChain 'environment wins over the file' 'local' 'ok' '' $piAnswer 1 'pi'
    Test-CleanupChain 'invalid file keeps the text here' 'local,pi' 'ok' '' $raw 0
    Test-CleanupChain 'off' 'off' 'ok' '' $raw 0
} finally {
    $env:PATH = $oldPath
    $env:VOXTYPE_DATA_ROOT = $oldChainDataRoot
    $env:VOXTYPE_TEST_LOG = $oldChainLog
    Remove-Item Env:PI_STUB_MODE, Env:VOXTYPE_CLEANUP_ENDPOINT, Env:VOXTYPE_CLEANUP_BACKEND `
        -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $chainRoot) { Remove-Item -LiteralPath $chainRoot -Recurse -Force }
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
        if (-not $calls.Contains('config set engine whisper')) {
            $failures.Add('setup with a Whisper model did not select the Whisper engine')
        }
    }

    # -ParakeetModelPath sets the model folder, then the engine.
    $fakeParakeet = Join-Path $tempDir 'parakeet-model'
    New-Item -ItemType Directory -Path $fakeParakeet | Out-Null
    [IO.File]::WriteAllText($testLog, '', [Text.Encoding]::ASCII)
    $parakeetOutput = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $setup -Hotkey F13 -ParakeetModelPath $fakeParakeet 6>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("setup -ParakeetModelPath exited $LASTEXITCODE`n$parakeetOutput")
    } else {
        $calls = [IO.File]::ReadAllText($testLog)
        $modelCall = $calls.IndexOf("config set parakeet.model $fakeParakeet")
        $engineCall = $calls.IndexOf('config set engine parakeet')
        if ($modelCall -lt 0 -or $engineCall -lt $modelCall) {
            $failures.Add("setup did not set the Parakeet model, then the engine`n$calls")
        }
        if ($calls.Contains('config set whisper.model')) {
            $failures.Add('setup -ParakeetModelPath also set a Whisper model')
        }
    }
    # Both models: both are set, then the engine, Whisper unless -Engine names Parakeet.
    foreach ($case in @(@{ Arguments = @(); Engine = 'whisper' },
            @{ Arguments = @('-Engine', 'Parakeet'); Engine = 'parakeet' })) {
        [IO.File]::WriteAllText($testLog, '', [Text.Encoding]::ASCII)
        $bothOutput = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup `
            -Hotkey F13 -WhisperModelPath $fakeWhisper -ParakeetModelPath $fakeParakeet @($case.Arguments) `
            6>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("setup with both models exited $LASTEXITCODE`n$bothOutput")
            continue
        }
        $calls = [IO.File]::ReadAllText($testLog)
        $engineCall = $calls.IndexOf("config set engine $($case.Engine)")
        $lastModel = [Math]::Max($calls.IndexOf("config set whisper.model $fakeWhisper"),
            $calls.IndexOf("config set parakeet.model $fakeParakeet"))
        if ($calls.IndexOf("config set whisper.model $fakeWhisper") -lt 0 -or
                $calls.IndexOf("config set parakeet.model $fakeParakeet") -lt 0 -or $engineCall -lt $lastModel) {
            $failures.Add("setup with both models did not set both, then engine $($case.Engine)`n$calls")
        }
    }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup `
            -Engine moonshine 2>&1 | Out-Null
        $badEngineExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($badEngineExit -eq 0) { $failures.Add('setup accepted an engine other than whisper or parakeet') }

    # -CleanupBackend: validated before anything changes, recorded only when given, and
    # the missing-Qwen warning only for a chain that can use the local model.
    $backendFile = Join-Path $testDataRoot 'cleanup-backend'
    function Invoke-BackendSetup {
        param([string[]]$Arguments)
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $text = & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $setup -WhisperModelPath $fakeWhisper @Arguments 2>&1 | Out-String
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $text }
        } finally { $ErrorActionPreference = $savedPreference }
    }
    function Get-RecordedBackend {
        if (-not (Test-Path -LiteralPath $backendFile -PathType Leaf)) { return '<absent>' }
        return [IO.File]::ReadAllText($backendFile)
    }
    # opencode needs a key: a warning without one, none once there is one, and never the key.
    $run = Invoke-BackendSetup @('-CleanupBackend', 'OpenCode')
    Assert-Equal 'setup records the opencode backend' 'opencode' (Get-RecordedBackend)
    if ($run.Text -notmatch 'No OpenCode Go key') {
        $failures.Add("setup did not warn that opencode has no key`n$($run.Text)")
    }
    $env:VOXTYPE_CLEANUP_OPENCODE_KEY = 'setup-test-key'
    try { $run = Invoke-BackendSetup @('-CleanupBackend', 'opencode,local') }
    finally { Remove-Item Env:VOXTYPE_CLEANUP_OPENCODE_KEY -ErrorAction SilentlyContinue }
    if ($run.Text -match 'No OpenCode Go key') { $failures.Add('setup warned about a key it has') }
    if ($run.Text -match 'setup-test-key') { $failures.Add('setup printed the OpenCode Go key') }
    # anthropic too, and its key is never printed.
    $run = Invoke-BackendSetup @('-CleanupBackend', 'Anthropic')
    Assert-Equal 'setup records the anthropic backend' 'anthropic' (Get-RecordedBackend)
    if ($run.Text -notmatch 'No Anthropic key') {
        $failures.Add("setup did not warn that anthropic has no key`n$($run.Text)")
    }
    $env:VOXTYPE_CLEANUP_ANTHROPIC_KEY = 'setup-test-anthropic-key'
    try { $run = Invoke-BackendSetup @('-CleanupBackend', 'anthropic,local') }
    finally { Remove-Item Env:VOXTYPE_CLEANUP_ANTHROPIC_KEY -ErrorAction SilentlyContinue }
    if ($run.Text -match 'No Anthropic key') { $failures.Add('setup warned about an Anthropic key it has') }
    if ($run.Text -match 'setup-test-anthropic-key') { $failures.Add('setup printed the Anthropic key') }
    # groq too, and its key is never printed.
    $run = Invoke-BackendSetup @('-CleanupBackend', 'Groq,local')
    Assert-Equal 'setup records the groq backend' 'groq,local' (Get-RecordedBackend)
    if ($run.Text -notmatch 'No Groq key') { $failures.Add("setup did not warn that groq has no key`n$($run.Text)") }
    $env:VOXTYPE_CLEANUP_GROQ_KEY = 'setup-test-groq-key'
    try { $run = Invoke-BackendSetup @('-CleanupBackend', 'groq') }
    finally { Remove-Item Env:VOXTYPE_CLEANUP_GROQ_KEY -ErrorAction SilentlyContinue }
    if ($run.Text -match 'No Groq key') { $failures.Add('setup warned about a Groq key it has') }
    if ($run.Text -match 'setup-test-groq-key') { $failures.Add('setup printed the Groq key') }
    $run = Invoke-BackendSetup @('-CleanupBackend', 'Pi')
    if ($run.Exit -ne 0) { $failures.Add("setup -CleanupBackend Pi exited $($run.Exit)`n$($run.Text)") }
    Assert-Equal 'setup records the cleanup backend' 'pi' (Get-RecordedBackend)
    if ($run.Text -match 'Cleanup model is missing') {
        $failures.Add('setup warned about the Qwen model for a chain without local')
    }
    $run = Invoke-BackendSetup @('-CleanupBackend', 'pi,local', '-DryRun')
    if ($run.Exit -ne 0 -or
        -not $run.Text.Contains("[dry] record cleanup backend pi,local at $backendFile")) {
        $failures.Add("setup -DryRun did not report the cleanup backend`n$($run.Text)")
    }
    if ($run.Text -notmatch 'Cleanup model is missing') {
        $failures.Add('setup did not warn about the missing Qwen model for a chain with local')
    }
    Assert-Equal 'setup -DryRun leaves the recorded backend' 'pi' (Get-RecordedBackend)
    foreach ($invalid in @('local,pi', 'off,pi', 'pi,bogus')) {
        $run = Invoke-BackendSetup @('-CleanupBackend', $invalid)
        if ($run.Exit -eq 0) { $failures.Add("setup accepted -CleanupBackend $invalid") }
        Assert-Equal "setup keeps the backend after rejecting $invalid" 'pi' (Get-RecordedBackend)
    }
    $run = Invoke-BackendSetup @()
    if ($run.Exit -ne 0 -or $run.Text -notmatch 'cleanup: pi') {
        $failures.Add("setup without -CleanupBackend did not keep the recorded choice`n$($run.Text)")
    }
    Assert-Equal 'setup without -CleanupBackend leaves the file' 'pi' (Get-RecordedBackend)

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
    foreach ($modelName in @('cleanup.gguf')) {
        $modelPath = Join-Path $fakeModels $modelName
        [IO.File]::WriteAllText($modelPath, "model $modelName", [Text.Encoding]::ASCII)
        $fakeModelEntries += [ordered]@{
            id = $modelName
            fileName = $modelName
            sha256 = (Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    # A model of several files is a folder, in -ModelDirectory and in the bundle.
    $fakeParakeetFolder = Join-Path $fakeModels 'parakeet-test'
    New-Item -ItemType Directory -Path $fakeParakeetFolder | Out-Null
    $fakeParakeetFiles = @()
    foreach ($modelName in @('encoder-model.onnx', 'vocab.txt')) {
        $modelPath = Join-Path $fakeParakeetFolder $modelName
        [IO.File]::WriteAllText($modelPath, "model $modelName", [Text.Encoding]::ASCII)
        $fakeParakeetFiles += [ordered]@{
            fileName = $modelName
            sha256 = (Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $fakeModelEntries += [ordered]@{
        id = 'parakeet'
        directory = 'parakeet-test'
        files = $fakeParakeetFiles
    }
    $fakeLock = Join-Path $tempDir 'dependencies.lock.json'
    @{ models = $fakeModelEntries } | ConvertTo-Json -Depth 6 |
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
            foreach ($expected in @('models/cleanup.gguf', 'models/parakeet-test/encoder-model.onnx',
                    'models/parakeet-test/vocab.txt')) {
                if (-not ($archiveEntries -contains "VoxType-0.0.0.1-offline/$expected")) {
                    $failures.Add("offline bundle has no $expected")
                }
            }
        } finally { $zip.Dispose() }
    }
    $packaging = Join-Path $windowsRoot 'packaging'
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
        /reference:System.Web.Extensions.dll `
        "/out:$(Join-Path $tempDir 'voxtype-configure.exe')" `
        (Join-Path $packaging 'ConfigureLauncher.cs') `
        (Join-Path $packaging 'ResumableDownload.cs') `
        (Join-Path $packaging 'CleanupBackend.cs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('guided setup failed to compile') }
    else {
        # Which pinned models the setup window fetches. Loaded from bytes, so the file stays
        # deletable.
        $configure = [Reflection.Assembly]::Load(
            [IO.File]::ReadAllBytes((Join-Path $tempDir 'voxtype-configure.exe')))
        $needed = $configure.GetType('ConfigureForm').GetMethod('ModelNeeded',
            [Reflection.BindingFlags]'NonPublic, Static', $null,
            [Type[]]@([string], [string], [bool], [bool]), $null)
        if ($null -eq $needed) { $failures.Add('guided setup has no ModelNeeded rule to test') }
        else {
            # id, chain, Parakeet optional, Parakeet ticked, fetched
            foreach ($case in @(
                    @('parakeet', 'local', $true, $false, $false),
                    @('parakeet', 'pi', $true, $true, $true),
                    @('parakeet', 'pi', $false, $false, $true),
                    @('whisper', 'pi', $true, $false, $true),
                    @('cleanup', 'pi', $true, $true, $false),
                    @('cleanup', 'pi,local', $true, $false, $true),
                    @('cleanup', 'opencode', $true, $false, $false),
                    @('cleanup', 'opencode,local', $true, $false, $true))) {
                $fetched = $needed.Invoke($null, [object[]]@($case[0], $case[1], $case[2], $case[3]))
                if ($fetched -ne $case[4]) {
                    $failures.Add("guided setup fetches $($case[0]) for $($case[1]) " +
                        "(optional $($case[2]), ticked $($case[3])): $fetched")
                }
            }
        }
    }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        "/out:$(Join-Path $tempDir 'voxtype-startup.exe')" `
        (Join-Path $packaging 'StartupLauncher.cs') (Join-Path $packaging 'CleanupBackend.cs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('startup launcher failed to compile') }

    # The shared downloader against a scripted loopback server: resume, a partial that is
    # already complete (by pinned size or 416), stalls, early closes, digest failures.
    $downloadTests = Join-Path $tempDir 'download-tests.exe'
    & $csc /nologo /target:exe /platform:x64 /optimize+ "/out:$downloadTests" `
        (Join-Path $PSScriptRoot 'DownloadTests.cs') (Join-Path $packaging 'ResumableDownload.cs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('download tests failed to compile') }
    else { Invoke-TestProgram $downloadTests 'download tests' }
    $backendTests = Join-Path $tempDir 'cleanup-backend-tests.exe'
    & $csc /nologo /target:exe /platform:x64 /optimize+ "/out:$backendTests" `
        (Join-Path $PSScriptRoot 'CleanupBackendTests.cs') (Join-Path $packaging 'CleanupBackend.cs')
    if ($LASTEXITCODE -ne 0) { $failures.Add('cleanup backend tests failed to compile') }
    else { Invoke-TestProgram $backendTests 'cleanup backend tests' }

    $fakeServer = Join-Path $tempDir 'fake-llama-server.cmd'
    $serverCallLog = Join-Path $tempDir 'llama-server-calls.log'
    # Like llama-server, the fake logs to stderr. Serving, it answers /health and chat
    # completions on its port until the warm-up's two requests are in.
    $fakeServerSource = @'
@echo off
>>"%VOXTYPE_TEST_LOG%" echo %*
>&2 echo fake server log line
if "%~1"=="--list-devices" (
    echo Vulkan0: Test GPU
    exit /b 0
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-llama-http.ps1" %*
exit /b %ERRORLEVEL%
'@
    [IO.File]::WriteAllText($fakeServer, $fakeServerSource, [Text.Encoding]::ASCII)
    $fakeHttpSource = @'
$port = [int]$args[[Array]::IndexOf($args, '--port') + 1]
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
$listener.Start()
$completions = 0
$deadline = [DateTime]::UtcNow.AddSeconds(30)
try {
    while ($completions -lt 2 -and [DateTime]::UtcNow -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 20; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $head = [Collections.Generic.List[byte]]::new()
            while ($head.Count -lt 4 -or $head[$head.Count - 4] -ne 13 -or
                    $head[$head.Count - 3] -ne 10 -or $head[$head.Count - 2] -ne 13 -or
                    $head[$head.Count - 1] -ne 10) {
                $value = $stream.ReadByte()
                if ($value -lt 0) { break }
                $head.Add([byte]$value)
            }
            $headers = [Text.Encoding]::ASCII.GetString($head.ToArray())
            $body = ''
            if ($headers -match '(?im)^Content-Length:\s*(\d+)') {
                $bytes = [byte[]]::new([int]$matches[1])
                $read = 0
                while ($read -lt $bytes.Length) {
                    $count = $stream.Read($bytes, $read, $bytes.Length - $read)
                    if ($count -le 0) { break }
                    $read += $count
                }
                $body = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
            }
            if ($headers.StartsWith('POST /v1/chat/completions')) {
                $completions++
                [IO.File]::AppendAllText($env:VOXTYPE_TEST_LOG, "completion $body`r`n")
                $answer = '{"choices":[{"message":{"content":"Warm."}}]}'
            } else { $answer = '{"status":"ok"}' }
            $payload = [Text.Encoding]::UTF8.GetBytes($answer)
            $reply = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`n" +
                "Content-Type: application/json`r`nContent-Length: $($payload.Length)`r`n" +
                "Connection: close`r`n`r`n")
            $stream.Write($reply, 0, $reply.Length)
            $stream.Write($payload, 0, $payload.Length)
            $stream.Flush()
        } catch {
            # A client that gave up, such as a health check past its 1 s timeout, resets
            # its connection. llama-server serves the next one, and so does this.
        } finally { $client.Close() }
    }
} finally { $listener.Stop() }
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $tempDir 'fake-llama-http.ps1'), $fakeHttpSource,
        [Text.Encoding]::ASCII)
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
    # The package runs this with Windows PowerShell 5.1, whose handling of a native
    # program's stderr differs from PowerShell 7's.
    $packagedShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # The warm-up must leave a registered history inbox empty.
    $warmUpInbox = Join-Path $tempDir 'warm-up-inbox'
    [IO.Directory]::CreateDirectory($env:VOXTYPE_DATA_ROOT) | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:VOXTYPE_DATA_ROOT 'dictation-history.json'),
        (@{ schema = 1; inbox = $warmUpInbox } | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false))
    & $packagedShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $serverScript | Out-Null
    $serverLog = Join-Path $env:VOXTYPE_DATA_ROOT 'logs\llama-server.log'
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("cleanup server exited $LASTEXITCODE")
    } elseif (-not (Test-Path -LiteralPath $serverLog) -or
        -not [IO.File]::ReadAllText($serverLog).Contains('fake server log line')) {
        $failures.Add('cleanup server output did not reach llama-server.log')
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
        $warmUps = [regex]::Matches($serverCalls, '(?m)^completion ').Count
        if ($warmUps -ne 2) {
            $failures.Add("cleanup server warm-up sent $warmUps of its 2 requests")
        } elseif (-not $serverCalls.Contains('"model":"qwen3-4b-instruct-2507"')) {
            $failures.Add('cleanup server warm-up did not ask for the local model')
        }
        # The second warm-up cleanup may still be finishing.
        Start-Sleep -Milliseconds 1500
        if ((Test-Path -LiteralPath $warmUpInbox) -and
            @(Get-ChildItem -LiteralPath $warmUpInbox -File).Count -gt 0) {
            $failures.Add('cleanup server warm-up reached the dictation history')
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

[CmdletBinding()]
param(
    [Parameter(DontShow)]
    [switch]$ValidateCandidate,

    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$Candidate = '',

    # With -ValidateCandidate: whose limits to apply (local, opencode, anthropic, groq, pi or
    # hosted); else the chain's first.
    [Parameter(DontShow)]
    [string]$Link = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Raw transcription enters on stdin and the only stdout is the chosen text.
# Any setup, network, process, parsing, or validation failure returns the raw
# transcription unchanged.
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# A timed test (VOXTYPE_CLEANUP_TIMING_FILE): when each step ended, which link answered, and
# why a text was kept as said, written as JSON beside the text. Marks are microseconds since
# 1970: one clock reading as the script begins (as fine as the Windows timer, 1 to 15 ms),
# then a stopwatch from it, so the steps themselves are exact.
$timingFile = [Environment]::GetEnvironmentVariable('VOXTYPE_CLEANUP_TIMING_FILE')
$timing = $null
if (-not [string]::IsNullOrEmpty($timingFile)) {
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $timing = @{
        Began = [long](([DateTime]::UtcNow - $epoch).Ticks / 10)
        Clock = [Diagnostics.Stopwatch]::StartNew()
        Marks = [Collections.Generic.List[object]]::new()
        Why = [Collections.Generic.List[string]]::new()
        Link = $null
        Server = $null
        Short = $false
    }
    $timing.Marks.Add([ordered]@{ name = 'began'; at = $timing.Began })
}
$currentLink = ''
$rejected = ''

function Add-Mark {
    param([string]$Name)
    if ($null -eq $timing) { return }
    $timing.Marks.Add([ordered]@{ name = $Name; at = $timing.Began + [long]($timing.Clock.Elapsed.Ticks / 10) })
}

function Add-Why {
    param([string]$Reason)
    if ($null -ne $timing) { $timing.Why.Add($Reason) }
}

function Write-Timing {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $timing) { return }
    Add-Mark 'done'
    $outcome = if ($null -ne $timing.Link) {
        if ($Text -ceq $rawText) { 'unchanged' } else { 'changed' }
    } elseif ($timing.Why.Count -eq 0 -and $timing.Short) { 'short' } else { 'kept' }
    $record = [ordered]@{ schema = 1; marks = @($timing.Marks); outcome = $outcome
        why = @($timing.Why); link = $timing.Link; server = $timing.Server }
    try {
        [IO.File]::WriteAllText($timingFile, (ConvertTo-Json -InputObject $record -Depth 6 -Compress),
            [Text.UTF8Encoding]::new($false))
    } catch {
        [Console]::Error.WriteLine('Cleanup timing could not be saved.')
    }
}

function Get-EnvValue {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

function Get-EnvInt {
    param([string]$Name, [int]$Default)
    $value = Get-EnvValue -Name $Name -Default ([string]$Default)
    $parsed = 0
    if (-not [int]::TryParse($value, [ref]$parsed)) { return $Default }
    return $parsed
}

function Write-Result {
    param([AllowEmptyString()][string]$Text)
    # The app registers a local inbox. Storage failure must never stop insertion.
    if (-not $ValidateCandidate -and $env:VOXTYPE_HISTORY_DISABLED -ne '1' -and
        -not [string]::IsNullOrWhiteSpace($Text)) {
        $temporary = $null
        try {
            $root = if ($env:VOXTYPE_DATA_ROOT) { $env:VOXTYPE_DATA_ROOT }
                    else { Join-Path $env:LOCALAPPDATA 'VoxType' }
            $registration = Join-Path $root 'dictation-history.json'
            if (Test-Path -LiteralPath $registration -PathType Leaf) {
                $history = [IO.File]::ReadAllText($registration) | ConvertFrom-Json
                if ($history.schema -eq 1 -and [IO.Path]::IsPathRooted($history.inbox)) {
                    [IO.Directory]::CreateDirectory($history.inbox) | Out-Null
                    $id = [guid]::NewGuid().ToString('N')
                    $event = @{schema = 1; id = $id; text = $Text; raw_text = $rawText
                        created_at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0}
                    $temporary = Join-Path $history.inbox ($id + '.tmp')
                    $final = Join-Path $history.inbox ($id + '.json')
                    [IO.File]::WriteAllText($temporary, ($event | ConvertTo-Json -Compress),
                        [Text.UTF8Encoding]::new($false))
                    [IO.File]::Move($temporary, $final)
                }
            }
        } catch {
            [Console]::Error.WriteLine('Dictation history could not be saved.')
        } finally {
            if ($temporary -and [IO.File]::Exists($temporary)) {
                try { [IO.File]::Delete($temporary) } catch {}
            }
        }
    }
    [Console]::Out.Write($Text)
    Write-Timing $Text
}

function Get-WordCount {
    param([string]$Text)
    return [regex]::Matches($Text, '\S+').Count
}

# The cleanup every port shares, from cleanup.json one directory up (the repo and the
# package alike): the prompt, its examples, the request and the guards. VOXTYPE_CLEANUP_*
# variables still override the numbers. Throws when the file is missing or malformed.
function Get-CleanupRules {
    $path = Get-EnvValue VOXTYPE_CLEANUP_FILE (Join-Path $PSScriptRoot '..\cleanup.json')
    $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($data.schema -ne 1) { throw "unsupported cleanup rules in $path" }
    $links = @{}
    foreach ($name in @('local', 'opencode', 'anthropic', 'groq', 'pi', 'hosted')) {
        # Rules from before Groq or Anthropic had a link of its own give it OpenCode Go's limits.
        $limits = if ($name -in @('groq', 'anthropic') -and
            $null -eq $data.links.PSObject.Properties[$name]) { $data.links.opencode } else { $data.links.$name }
        $links[$name] = @{
            MinWords = Get-EnvInt VOXTYPE_CLEANUP_MIN_WORDS ([int]$limits.min_words)
            Timeout = Get-EnvInt VOXTYPE_CLEANUP_TIMEOUT ([int]$limits.timeout_s)
            MinShrink = Get-EnvInt VOXTYPE_CLEANUP_MIN_SHRINK ([int]$limits.min_shrink)
        }
    }
    $fillers = @{}
    foreach ($word in @($data.guards.fillers)) { $fillers[[string]$word] = $true }
    return @{
        Instructions = @($data.instructions) -join "`n"
        Spellings = [string]$data.spellings
        Context = [string]$data.context
        Transcript = [string]$data.transcript
        Examples = @($data.examples | ForEach-Object {
            @{ Raw = [string]$_.raw; Cleaned = [string]$_.cleaned } })
        Temperature = [double]$data.request.temperature
        TopP = [double]$data.request.top_p
        TokensPerWord = [int]$data.request.max_tokens_per_word
        TokensExtra = [int]$data.request.max_tokens_extra
        TokensThinking = [int]$data.request.max_tokens_thinking
        MaxGrowth = Get-EnvInt VOXTYPE_CLEANUP_MAX_GROWTH ([int]$data.guards.max_growth)
        KeepWords = Get-EnvInt VOXTYPE_CLEANUP_KEEP_WORDS ([int]$data.guards.keep_words)
        MaxNewWords = Get-EnvInt VOXTYPE_CLEANUP_MAX_NEW_WORDS ([int]$data.guards.max_new_words)
        ContentWordLength = [int]$data.guards.content_word_length
        ContentWordsNeeded = [int]$data.guards.content_words_needed
        Fillers = $fillers
        Links = $links
    }
}

# A text as the model receives it: wrapped, so it reads as data and never as an instruction.
function Format-Transcript {
    param([AllowEmptyString()][string]$Text)
    return $rules.Transcript.Replace('{text}', $Text)
}

function Get-Vocabulary {
    $configured = [Environment]::GetEnvironmentVariable('VOXTYPE_VOCAB_FILE')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $path = $configured
    } else {
        $configRoot = if ($env:VOXTYPE_CONFIG_ROOT) {
            $env:VOXTYPE_CONFIG_ROOT
        } else { Join-Path $env:APPDATA 'VoxType' }
        $installed = Join-Path $configRoot 'vocabulary.conf'
        $sibling = Join-Path $PSScriptRoot '..\vocabulary.conf'
        if (Test-Path -LiteralPath $installed -PathType Leaf) { $path = $installed }
        elseif (Test-Path -LiteralPath $sibling -PathType Leaf) { $path = $sibling }
        else { return '' }
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $seen = @{}
    $terms = [System.Collections.Generic.List[string]]::new()
    foreach ($lineValue in [IO.File]::ReadAllLines($path)) {
        $line = $lineValue.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#') -or
            ($line.StartsWith('[') -and $line.EndsWith(']'))) { continue }
        $key = $line.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $terms.Add($line)
        }
    }
    return $terms -join ', '
}

function Quote-ProcessArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $slashes++
            continue
        }
        if ($char -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
        } else {
            [void]$builder.Append(('\' * $slashes))
            [void]$builder.Append($char)
        }
        $slashes = 0
    }
    [void]$builder.Append(('\' * ($slashes * 2)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-CliBackend {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [string]$StandardInput,
        [int]$TimeoutSeconds
    )

    $command = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw "$FileName is unavailable" }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $command.Source
    $start.Arguments = ($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.EnvironmentVariables.Remove('VOXTYPE_CONTEXT')

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "failed to start $FileName" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($StandardInput)
    $process.StandardInput.Close()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        & taskkill.exe /PID $process.Id /T /F *> $null
        throw "$FileName timed out after $TimeoutSeconds seconds"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "$FileName exited $($process.ExitCode): $($stderr.Trim())"
    }
    return $stdout
}

function Invoke-HttpBackend {
    param(
        [string]$Endpoint,
        [string]$Model,
        [string]$SystemPrompt,
        [string]$Text,
        [int]$MaxTokens,
        [int]$TimeoutSeconds,
        [bool]$CachePrompt,
        [string]$ApiKey
    )

    # The examples go in as real earlier turns, the strongest lever on a small model.
    $messages = [System.Collections.Generic.List[object]]::new()
    $messages.Add(@{ role = 'system'; content = $SystemPrompt })
    foreach ($example in $rules.Examples) {
        $messages.Add(@{ role = 'user'; content = Format-Transcript $example.Raw })
        $messages.Add(@{ role = 'assistant'; content = $example.Cleaned })
    }
    $messages.Add(@{ role = 'user'; content = Format-Transcript $Text })
    $body = @{
        model = $Model
        messages = $messages
        temperature = $rules.Temperature
        top_p = $rules.TopP
        max_tokens = $MaxTokens
        stream = $false
    }
    if ($CachePrompt) { $body.cache_prompt = $true }
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $headers.Authorization = "Bearer $ApiKey"
    }
    $json = $body | ConvertTo-Json -Depth 8 -Compress
    Add-Mark "$($currentLink):built"
    $response = Invoke-RestMethod -Method Post `
        -Uri ($Endpoint.TrimEnd('/') + '/v1/chat/completions') `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body $json -TimeoutSec $TimeoutSeconds
    if ($null -ne $timing) {
        # The server's own count: tokens in and out and, from llama.cpp, the time it took.
        $timing.Server = [ordered]@{}
        foreach ($name in @('usage', 'timings')) {
            $property = $response.PSObject.Properties[$name]
            if ($null -ne $property) { $timing.Server[$name] = $property.Value }
        }
    }
    return [string]$response.choices[0].message.content
}

# OpenCode Go asks a client for its own user agent and a stable session ID per conversation
# (opencode.ai/docs/go). One ID is kept in the temp folder: every dictation sends the same
# instructions and examples, which is what its prompt cache keys on.
function Get-OpenCodeSession {
    $file = Join-Path ([IO.Path]::GetTempPath()) 'voxtype-opencode-session'
    try { $id = [IO.File]::ReadAllText($file) } catch { $id = '' }
    if ($id -notmatch '^voxtype-[0-9a-f]{32}$') {
        $id = 'voxtype-' + [guid]::NewGuid().ToString('N')
        try { [IO.File]::WriteAllText($file, $id) } catch { }
    }
    return $id
}

# One request to OpenCode Go's Anthropic Messages API: the system prompt apart from the
# turns, the examples as real earlier turns, and thinking off. qwen3.8-flash honours that; a
# thinking-only model is refused with a 400 rather than thinking anyway. The body goes as
# UTF-8 bytes and the answer is read as UTF-8, which Windows PowerShell 5.1 does neither of
# for a string body or a reply without a charset.
function Invoke-OpenCodeBackend {
    param(
        [string]$SystemPrompt,
        [string]$Text,
        [int]$MaxTokens,
        [int]$TimeoutSeconds
    )

    $key = Get-OpenCodeKey
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'no OpenCode Go key' }
    $messages = [System.Collections.Generic.List[object]]::new()
    foreach ($example in $rules.Examples) {
        $messages.Add(@{ role = 'user'; content = Format-Transcript $example.Raw })
        $messages.Add(@{ role = 'assistant'; content = $example.Cleaned })
    }
    $messages.Add(@{ role = 'user'; content = Format-Transcript $Text })
    $body = @{
        model = Get-EnvValue VOXTYPE_CLEANUP_OPENCODE_MODEL 'qwen3.8-flash'
        system = $SystemPrompt
        messages = $messages
        temperature = $rules.Temperature
        top_p = $rules.TopP
        max_tokens = $MaxTokens
        stream = $false
        thinking = @{ type = 'disabled' }
    }
    $headers = @{
        'x-api-key' = $key
        'anthropic-version' = '2023-06-01'
        'x-opencode-session' = Get-OpenCodeSession
    }
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
    Add-Mark 'opencode:built'
    $response = Invoke-WebRequest -UseBasicParsing -Method Post `
        -Uri (Get-EnvValue VOXTYPE_CLEANUP_OPENCODE_ENDPOINT `
            'https://opencode.ai/inference/go/anthropic/v1/messages') `
        -Headers $headers -UserAgent 'voxtype-cleanup/1.0' `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSeconds
    $answer = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($null -ne $timing) {
        # The server's count, and Cloudflare's placement (such as remote-IAD) when the request
        # ran away from the edge that took it.
        $timing.Server = [ordered]@{}
        $usage = $answer.PSObject.Properties['usage']
        if ($null -ne $usage) { $timing.Server.usage = $usage.Value }
        if ($response.Headers.ContainsKey('Cf-Placement')) {
            $timing.Server.served_from = [string](@($response.Headers['Cf-Placement'])[0])
        }
    }
    return (@($answer.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
}

# One request to Anthropic's own Messages API with the user's key, in OpenCode Go's shape but
# without temperature or top_p, which Claude Haiku 5.5 refuses at any value but its default.
# Thinking is off, so the budget needs no room for it. Bytes in and out as UTF-8, as for
# OpenCode Go.
function Invoke-AnthropicBackend {
    param(
        [string]$SystemPrompt,
        [string]$Text,
        [int]$MaxTokens,
        [int]$TimeoutSeconds
    )

    $key = Get-AnthropicKey
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'no Anthropic key' }
    $messages = [System.Collections.Generic.List[object]]::new()
    foreach ($example in $rules.Examples) {
        $messages.Add(@{ role = 'user'; content = Format-Transcript $example.Raw })
        $messages.Add(@{ role = 'assistant'; content = $example.Cleaned })
    }
    $messages.Add(@{ role = 'user'; content = Format-Transcript $Text })
    $body = @{
        model = Get-EnvValue VOXTYPE_CLEANUP_ANTHROPIC_MODEL 'claude-haiku-5-5'
        system = $SystemPrompt
        messages = $messages
        max_tokens = $MaxTokens
        stream = $false
        thinking = @{ type = 'disabled' }
    }
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
    Add-Mark 'anthropic:built'
    $response = Invoke-WebRequest -UseBasicParsing -Method Post `
        -Uri (Get-EnvValue VOXTYPE_CLEANUP_ANTHROPIC_ENDPOINT 'https://api.anthropic.com/v1/messages') `
        -Headers @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' } -UserAgent 'voxtype-cleanup/1.0' `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSeconds
    $answer = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($null -ne $timing) {
        $timing.Server = [ordered]@{}
        $usage = $answer.PSObject.Properties['usage']
        if ($null -ne $usage) { $timing.Server.usage = $usage.Value }
    }
    return (@($answer.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ''
}

# One request to Groq's chat completions API with the user's own key: the system prompt as
# the first turn, then the examples and the text. gpt-oss cannot stop reasoning, so it
# reasons at low effort with the thinking room in its budget, and its reasoning comes back
# apart from the answer (message.reasoning), which is never read. Bytes in and out as UTF-8,
# as for OpenCode Go.
function Invoke-OpenAIBackend {
    param([string]$SystemPrompt, [string]$Text, [int]$MaxTokens, [int]$TimeoutSeconds)
    $key = Get-EnvValue VOXTYPE_CLEANUP_API_KEY ''
    $keyFile = Get-EnvValue VOXTYPE_CLEANUP_OPENAI_KEY_FILE ''
    if (-not $key -and $keyFile -and (Test-Path -LiteralPath $keyFile)) {
        $key = [IO.File]::ReadAllText($keyFile).Trim()
    }
    if (-not $key) { throw 'No OpenAI key; enter it in Libre Settings' }
    $model = Get-EnvValue VOXTYPE_CLEANUP_OPENAI_MODEL 'gpt-6-luna'
    $messages = @(@{ role = 'system'; content = $SystemPrompt })
    foreach ($example in $rules.Examples) {
        $messages += @{ role = 'user'; content = Format-Transcript $example.Raw }
        $messages += @{ role = 'assistant'; content = $example.Cleaned }
    }
    $messages += @{ role = 'user'; content = Format-Transcript $Text }
    $effort = if ($model -eq 'gpt-6-luna') { 'none' } else { 'low' }
    $body = @{ model = $model; input = $messages; store = $false; max_output_tokens = $MaxTokens;
               reasoning = @{ effort = $effort } }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
    Add-Mark 'openai:built'
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://api.openai.com/v1/responses' `
            -Headers @{ Authorization = "Bearer $key" } -UserAgent 'voxtype-cleanup/1.0' `
            -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSeconds
    } catch {
        # Provider error bodies may echo request content. Keep them out of timing/history.
        $code = 0
        $reply = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $reply -and $null -ne $reply.Value) { $code = [int]$reply.Value.StatusCode }
        switch ($code) {
            401 { throw 'OpenAI refused the key; check Settings' }
            403 { throw 'OpenAI refused access; check the project permissions' }
            404 { throw 'The OpenAI model is unavailable to this account' }
            429 { throw 'OpenAI quota or rate limit reached; check billing and retry later' }
            default { throw 'OpenAI could not complete the request; check the connection and retry' }
        }
    }
    try { $answer = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json }
    catch { throw 'OpenAI returned an unreadable answer' }
    if ($answer.status -ne 'completed') { throw 'OpenAI did not complete the response' }
    if ($null -ne $timing) { $timing.Server = @{ usage = $answer.usage } }
    return (@($answer.output) | Where-Object { $_.type -eq 'message' } | ForEach-Object {
        $_.content | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }
    }) -join ''
}

function Invoke-GroqBackend {
    param(
        [string]$SystemPrompt,
        [string]$Text,
        [int]$MaxTokens,
        [int]$TimeoutSeconds
    )

    $key = Get-GroqKey
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'no Groq key' }
    $messages = [System.Collections.Generic.List[object]]::new()
    $messages.Add(@{ role = 'system'; content = $SystemPrompt })
    foreach ($example in $rules.Examples) {
        $messages.Add(@{ role = 'user'; content = Format-Transcript $example.Raw })
        $messages.Add(@{ role = 'assistant'; content = $example.Cleaned })
    }
    $messages.Add(@{ role = 'user'; content = Format-Transcript $Text })
    $body = @{
        model = Get-EnvValue VOXTYPE_CLEANUP_GROQ_MODEL 'openai/gpt-oss-20b'
        messages = $messages
        temperature = $rules.Temperature
        top_p = $rules.TopP
        max_completion_tokens = $MaxTokens
        stream = $false
        reasoning_effort = 'low'
    }
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
    Add-Mark 'groq:built'
    $response = Invoke-WebRequest -UseBasicParsing -Method Post `
        -Uri (Get-EnvValue VOXTYPE_CLEANUP_GROQ_ENDPOINT 'https://api.groq.com/openai/v1/chat/completions') `
        -Headers @{ Authorization = "Bearer $key" } -UserAgent 'voxtype-cleanup/1.0' `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSeconds
    $answer = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($null -ne $timing) {
        $timing.Server = [ordered]@{}
        $usage = $answer.PSObject.Properties['usage']
        if ($null -ne $usage) { $timing.Server.usage = $usage.Value }
    }
    return [string]$answer.choices[0].message.content
}

# The cleaned text when it passes every guard of the rules, or $null when it must be
# rejected. cleanup-cases.json holds the answers every port must give.
function Get-AcceptedCandidate {
    param(
        [string]$Raw,
        [AllowEmptyString()][string]$Cleaned,
        [int]$MinShrink
    )

    $value = [regex]::Replace($Cleaned, '<think>.*?</think>', '',
        [Text.RegularExpressions.RegexOptions]::Singleline).Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"') -and
        -not $Raw.StartsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    # Each rejection says which guard, for a timed test.
    if ([string]::IsNullOrEmpty($value)) { $script:rejected = 'the answer was empty'; return $null }
    if ($value.Length -gt ($Raw.Length * $rules.MaxGrowth)) { $script:rejected = 'the answer grew'; return $null }
    if (($value.Length * 100) -lt ($Raw.Length * $MinShrink)) {
        $script:rejected = 'the answer shrank too far'
        return $null
    }

    $outputLower = $value.ToLowerInvariant()
    $content = [regex]::Matches($Raw.ToLowerInvariant(), '[a-z0-9]+') |
        ForEach-Object { $_.Value } |
        Where-Object { $_.Length -ge $rules.ContentWordLength -and -not $rules.Fillers.ContainsKey($_) }
    if (@($content).Count -ge $rules.ContentWordsNeeded) {
        $kept = @($content | Where-Object { $outputLower.Contains($_) }).Count
        $score = [math]::Floor($kept * 100 / @($content).Count)
        if ($score -lt $rules.KeepWords) { $script:rejected = 'the answer lost words'; return $null }
    }
    if ((Get-WordCount $value) -gt ((Get-WordCount $Raw) + $rules.MaxNewWords)) {
        $script:rejected = 'the answer added words'
        return $null
    }
    return $value
}

# Per-link limits: local, opencode, anthropic, groq, pi, and hosted for every other link. The
# local server answers in about a second, OpenCode Go in about one and a half and pi in about
# two, so they take shorter utterances and timeouts than the hosted CLIs, as Groq and
# Anthropic do; the local model removes less filler, hence its stricter shrink limit.
function Get-LinkSettings {
    param([string]$Backend)
    if ($Backend -in @('local', 'opencode', 'anthropic', 'groq', 'pi')) { return $rules.Links[$Backend] }
    return $rules.Links['hosted']
}

$rawText = [Console]::In.ReadToEnd()
# A byte order mark is the writer's encoding, never something said: Windows PowerShell 5.1
# starts a child's stdin with one when its console is UTF-8. Compared as a char: a culture
# comparison ignores U+FEFF, so StartsWith would match every text.
if ($rawText.Length -gt 0 -and $rawText[0] -eq [char]0xFEFF) { $rawText = $rawText.Substring(1) }
if ([string]::IsNullOrWhiteSpace($rawText)) { Add-Why 'nothing was said'; Write-Result $rawText; exit 0 }

. (Join-Path $PSScriptRoot 'voxtype-cleanup-backend.ps1')
try {
    $chain = @((ConvertTo-CleanupBackendChain `
        (Get-CleanupBackendSetting (Get-CleanupDataRoot))).Split(','))
} catch {
    # An unreadable or invalid choice cannot say where the text may go: keep it here.
    [Console]::Error.WriteLine("voxtype-cleanup: $($_.Exception.Message)")
    Add-Why $_.Exception.Message
    Write-Result $rawText
    exit 0
}
if ($chain[0] -eq 'off' -and -not $ValidateCandidate) {
    Add-Why 'cleanup is off'
    Write-Result $rawText
    exit 0
}
try {
    $rules = Get-CleanupRules
} catch {
    # Without the shared rules there is no prompt and no guard: type the text as said.
    [Console]::Error.WriteLine("voxtype-cleanup: no cleanup rules: $($_.Exception.Message)")
    Add-Why 'no cleanup rules'
    Write-Result $rawText
    exit 0
}

if ($ValidateCandidate) {
    $first = Get-LinkSettings $(if ($Link) { $Link } else { $chain[0] })
    $accepted = Get-AcceptedCandidate -Raw $rawText -Cleaned $Candidate -MinShrink $first.MinShrink
    Write-Result $(if ($null -eq $accepted) { $rawText } else { $accepted })
    exit 0
}

$instructions = $rules.Instructions
$vocabulary = Get-Vocabulary
if ($vocabulary.Length -gt 0) { $instructions += "`n" + $rules.Spellings.Replace('{terms}', $vocabulary) }
$context = Get-EnvValue VOXTYPE_CLEANUP_CONTEXT ''
$contextLocalOnly = (Get-EnvValue VOXTYPE_CONTEXT_LOCAL_ONLY '1') -eq '1'

# One link's answer as text. Throws when the backend is unavailable, fails or times out.
function Invoke-CleanupBackend {
    param(
        [string]$Backend,
        [string]$Text,
        [string]$Instructions,
        [int]$TimeoutSeconds,
        [int]$MaxTokens
    )
    switch ($Backend) {
        'local' {
            $endpoint = Get-EnvValue VOXTYPE_CLEANUP_ENDPOINT 'http://127.0.0.1:8088'
            Invoke-WebRequest -UseBasicParsing -Uri ($endpoint.TrimEnd('/') + '/health') `
                -TimeoutSec 1 | Out-Null
            Add-Mark 'local:checked'
            $cleaned = Invoke-HttpBackend -Endpoint $endpoint `
                -Model (Get-EnvValue VOXTYPE_CLEANUP_LOCAL_MODEL 'qwen3-4b-instruct-2507') `
                -SystemPrompt $Instructions -Text $Text -MaxTokens $MaxTokens `
                -TimeoutSeconds $TimeoutSeconds -CachePrompt $true -ApiKey ''
        }
        'opencode' {
            # The thinking room too, as the rules give it: a model chosen instead may think.
            $cleaned = Invoke-OpenCodeBackend -SystemPrompt $Instructions -Text $Text `
                -MaxTokens ($MaxTokens + $rules.TokensThinking) -TimeoutSeconds $TimeoutSeconds
        }
        'anthropic' {
            $cleaned = Invoke-AnthropicBackend -SystemPrompt $Instructions -Text $Text `
                -MaxTokens $MaxTokens -TimeoutSeconds $TimeoutSeconds
        }
        'openai' {
            $cleaned = Invoke-OpenAIBackend -SystemPrompt $Instructions -Text $Text `
                -MaxTokens ($MaxTokens + $rules.TokensThinking) -TimeoutSeconds $TimeoutSeconds
        }
        'groq' {
            $cleaned = Invoke-GroqBackend -SystemPrompt $Instructions -Text $Text `
                -MaxTokens ($MaxTokens + $rules.TokensThinking) -TimeoutSeconds $TimeoutSeconds
        }
        'pi' {
            # The same OpenCode Go model as opencode, through pi, which adds its startup; this
            # link is for pi's other providers. pi -p is one user message, so the examples
            # follow the instructions as text.
            $examples = ($rules.Examples | ForEach-Object {
                "Input:`n$(Format-Transcript $_.Raw)`nOutput:`n$($_.Cleaned)" }) -join "`n`n"
            $cleaned = Invoke-CliBackend -FileName 'pi' -TimeoutSeconds $TimeoutSeconds `
                -StandardInput (Format-Transcript $Text) -Arguments @(
                    '-p', '--offline', '--model',
                    (Get-EnvValue VOXTYPE_CLEANUP_PI_MODEL 'opencode-go/qwen3.8-flash'),
                    '--thinking', 'off', '--no-tools', '--no-extensions', '--no-skills',
                    '--no-prompt-templates', '--no-themes', '--no-context-files',
                    '--no-session', '--no-approve', '--system-prompt',
                    "$Instructions`n`nExamples:`n`n$examples")
        }
        'claude' {
            $cleaned = Invoke-CliBackend -FileName 'claude' -TimeoutSeconds $TimeoutSeconds `
                -StandardInput (Format-Transcript $Text) -Arguments @(
                    '-p', '--model', (Get-EnvValue VOXTYPE_CLEANUP_MODEL 'haiku'),
                    '--strict-mcp-config', '--tools', '', '--safe-mode',
                    '--system-prompt', $Instructions)
        }
        'codex' {
            $cleaned = Invoke-CliBackend -FileName 'codex' -TimeoutSeconds $TimeoutSeconds `
                -StandardInput (Format-Transcript $Text) -Arguments @(
                    '--ask-for-approval', 'never', 'exec', '--profile',
                    (Get-EnvValue VOXTYPE_CLEANUP_CODEX_PROFILE 'luna'), '--sandbox',
                    'read-only', '--ephemeral', '--skip-git-repo-check', $Instructions)
        }
        default { throw "unknown backend: $Backend" }
    }
    return [string]$cleaned
}

# Each link in order. A link that is unavailable, times out, fails, or returns text
# that breaks a guard falls through to the next; the last resort is the raw text.
$wordCount = Get-WordCount $rawText
# A token budget the model cannot talk its way past. The thinking room in cleanup.json is
# for a model that thinks: opencode, whose model can be changed, and groq, whose model
# reasons, are given it.
$maxTokens = $wordCount * $rules.TokensPerWord + $rules.TokensExtra
Add-Mark 'rules'
foreach ($link in $chain) {
    $settings = Get-LinkSettings $link
    if ($wordCount -lt $settings.MinWords) {
        if ($null -ne $timing) { $timing.Short = $true }
        continue
    }
    $linkInstructions = $instructions
    if ($context.Length -gt 0 -and ($link -eq 'local' -or -not $contextLocalOnly)) {
        $linkInstructions += $rules.Context.Replace('{context}', $context)
    }
    $currentLink = $link
    $rejected = ''
    if ($null -ne $timing) { $timing.Server = $null }
    try {
        $cleaned = Invoke-CleanupBackend -Backend $link -Text $rawText `
            -Instructions $linkInstructions -TimeoutSeconds $settings.Timeout -MaxTokens $maxTokens
        Add-Mark "$($link):answered"
        $accepted = Get-AcceptedCandidate -Raw $rawText -Cleaned $cleaned -MinShrink $settings.MinShrink
        Add-Mark "$($link):guarded"
        if ($null -eq $accepted) { Add-Why "$($link): $rejected" }
    } catch {
        Add-Mark "$($link):failed"
        Add-Why "$($link): $($_.Exception.Message)"
        $accepted = $null
    }
    if ($null -ne $accepted) {
        if ($null -ne $timing) { $timing.Link = $link }
        Write-Result $accepted
        exit 0
    }
}
Write-Result $rawText

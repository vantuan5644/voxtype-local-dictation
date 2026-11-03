# Network-free OpenAI cleanup request regression test; no installed configuration is used.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../voxtype-cleanup.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Cleanup script has parse errors' }
$names = @('Get-EnvValue', 'Format-Transcript', 'Add-Mark', 'Invoke-OpenAIBackend')
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($names -contains $node.Name) { Invoke-Expression $node.Extent.Text }
}
$timing = $null
$rules = @{ Transcript = '<transcript>{text}</transcript>'; Examples = @(@{ Raw = 'hello'; Cleaned = 'Hello.' }) }
$script:status = 'completed'
$script:request = $null
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $UserAgent, $ContentType, $Body, $TimeoutSec)
    if ($Uri -ne 'https://api.openai.com/v1/responses') { throw 'Wrong OpenAI endpoint' }
    if ($Headers.Authorization -ne 'Bearer sk-fixture') { throw 'Wrong credential source' }
    $script:request = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
    $json = @{ status = $script:status; output = @(@{ type = 'message'; content = @(@{ type = 'output_text'; text = 'Hello.' }) }) } | ConvertTo-Json -Depth 8
    return @{ RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json)) }
}
$folder = Join-Path ([IO.Path]::GetTempPath()) ('libre-openai-' + [guid]::NewGuid().ToString('N'))
$names = @('VOXTYPE_CLEANUP_API_KEY', 'VOXTYPE_CLEANUP_OPENAI_KEY_FILE', 'VOXTYPE_CLEANUP_OPENAI_MODEL')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    New-Item -ItemType Directory $folder | Out-Null
    $key = Join-Path $folder 'key'
    [IO.File]::WriteAllText($key, 'sk-fixture')
    $env:VOXTYPE_CLEANUP_API_KEY = ''
    $env:VOXTYPE_CLEANUP_OPENAI_KEY_FILE = $key
    foreach ($model in @('gpt-6-luna', 'gpt-6.1-sol')) {
        $env:VOXTYPE_CLEANUP_OPENAI_MODEL = $model
        $answer = Invoke-OpenAIBackend -SystemPrompt 'Clean text' -Text 'hello' -MaxTokens 100 -TimeoutSeconds 20
        if ($answer -ne 'Hello.') { throw 'Output text was not extracted' }
        if ($script:request.store -ne $false -or $script:request.model -ne $model) { throw 'Wrong model or storage setting' }
        if ($script:request.PSObject.Properties['temperature']) { throw 'Unsupported temperature sent' }
        if ($script:request.input.Count -ne 4) { throw 'Prompt examples lost' }
    }
    $script:status = 'incomplete'
    $refused = $false
    try { Invoke-OpenAIBackend -SystemPrompt 'Clean text' -Text 'hello' -MaxTokens 100 -TimeoutSeconds 20 | Out-Null }
    catch { $refused = $true }
    if (-not $refused) { throw 'Incomplete response accepted' }
    Write-Output 'OpenAI cleanup request tests passed'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    Remove-Item -LiteralPath $folder -Recurse -Force
}

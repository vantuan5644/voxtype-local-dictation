[CmdletBinding(DefaultParameterSetName = 'PinnedRelease')]
param(
    [Parameter(ParameterSetName = 'ExistingBinary')]
    [string]$VoxtypeExe,

    [Parameter(ParameterSetName = 'SourceBuild')]
    [string]$VoxtypeSource,

    [string]$OutputDirectory,
    [string]$DependencyLock,
    [switch]$InstallTools,
    [switch]$Apply,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist\payload'
}
if ([string]::IsNullOrWhiteSpace($DependencyLock)) {
    $DependencyLock = Join-Path $PSScriptRoot 'dependencies.lock.json'
}

function Resolve-FullPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Assert-HashText {
    param([AllowNull()][string]$Value, [string]$Name, [switch]$AllowMissing)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowMissing) { return }
        throw "$Name has no SHA-256 value in $DependencyLock"
    }
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Name has an invalid SHA-256 value in $DependencyLock"
    }
}

function Assert-HttpsUrl {
    param([string]$Value, [string]$Name)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https') {
        throw "$Name must be an absolute HTTPS URL"
    }
}

function Assert-X64Pe {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "file is not a PE executable: $Path"
    }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or
        $bytes[$offset] -ne 0x50 -or $bytes[$offset + 1] -ne 0x45) {
        throw "file has an invalid PE header: $Path"
    }
    if ([BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) {
        throw "file is not an x64 PE executable: $Path"
    }
}

function Assert-FileHash {
    param([string]$Path, [string]$Expected, [string]$Name)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $Expected.ToLowerInvariant()) {
        throw "$Name digest mismatch. Expected $Expected; received $actual"
    }
}

function Receive-LockedFile {
    param([object]$Entry, [string]$Destination, [string]$Name)
    Assert-HttpsUrl ([string]$Entry.url) "$Name.url"
    Assert-HashText ([string]$Entry.sha256) "$Name.sha256"
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Assert-FileHash $Destination ([string]$Entry.sha256) $Name
        Write-Host "[same] $Name"
        return
    }

    $partial = "$Destination.partial"
    Write-Host "[download] $Name"
    $request = [Net.HttpWebRequest]::Create([string]$Entry.url)
    $request.UserAgent = 'VoxType-Windows-Release-Builder/1.0'
    $existing = if (Test-Path -LiteralPath $partial -PathType Leaf) {
        (Get-Item -LiteralPath $partial).Length
    } else { 0L }
    if ($existing -gt 0) { $request.AddRange($existing) }
    $response = $request.GetResponse()
    try {
        $append = $existing -gt 0 -and [int]$response.StatusCode -eq 206
        if (-not $append) { $existing = 0L }
        $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $target = [IO.FileStream]::new($partial, $mode, [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            $source = $response.GetResponseStream()
            try { $source.CopyTo($target) } finally { $source.Dispose() }
        } finally { $target.Dispose() }
    } finally { $response.Dispose() }
    try {
        Assert-FileHash $partial ([string]$Entry.sha256) $Name
    } catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}

function Find-InstalledTool {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    if ($Name -ceq 'makeappx.exe') {
        $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
        $found = Get-ChildItem -LiteralPath $sdkRoot -Filter $Name -File -Recurse `
            -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($null -ne $found) { return $found.FullName }
    }
    if ($Name -ceq 'cl.exe') {
        $vsRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022'
        $found = Get-ChildItem -LiteralPath $vsRoot -Filter $Name -File -Recurse `
            -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Hostx64\\x64\\' } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($null -ne $found) { return $found.FullName }
    }
    if ($Name -ceq 'glslc.exe') {
        $found = Get-ChildItem -LiteralPath 'C:\VulkanSDK' -Filter $Name -File -Recurse `
            -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($null -ne $found) { return $found.FullName }
    }
    return $null
}

function Install-RequiredTools {
    param([object[]]$Tools, [switch]$SourceBuild)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) { throw 'winget.exe is required to install build tools' }
    foreach ($tool in $Tools) {
        if ([bool]$tool.sourceBuildOnly -and -not $SourceBuild) { continue }
        $command = Find-InstalledTool ([string]$tool.command)
        if ($null -ne $command) {
            Write-Host "[same] $($tool.id)"
            continue
        }
        $arguments = @('install', '--id', [string]$tool.id, '--exact',
            '--accept-package-agreements', '--accept-source-agreements', '--silent')
        if ($null -ne $tool.PSObject.Properties['override'] -and $tool.override) {
            $arguments += @('--override', [string]$tool.override)
        }
        Write-Host "[install] $($tool.id)"
        & $winget.Source @arguments
        if ($LASTEXITCODE -ne 0) { throw "winget failed for $($tool.id)" }
        Refresh-ProcessPath
        if ($null -eq (Find-InstalledTool ([string]$tool.command))) {
            throw "installation completed but $($tool.command) was not found"
        }
    }
}

function Get-VoxtypeFromSource {
    param([string]$Source, [string]$Destination)
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'Cargo.toml') -PathType Leaf)) {
        throw "VoxType source has no Cargo.toml: $sourceRoot"
    }
    $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if ($null -eq $cargo) { throw 'cargo.exe is required for -VoxtypeSource' }
    Push-Location $sourceRoot
    try {
        & $cargo.Source build --locked --release --target x86_64-pc-windows-msvc `
            --features gpu-vulkan
        if ($LASTEXITCODE -ne 0) { throw 'VoxType source build failed' }
    } finally { Pop-Location }
    $built = Join-Path $sourceRoot 'target\x86_64-pc-windows-msvc\release\voxtype.exe'
    if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
        throw "VoxType build returned without $built"
    }
    Copy-Item -LiteralPath $built -Destination $Destination
}

if (-not (Test-Path -LiteralPath $DependencyLock -PathType Leaf)) {
    throw "dependency lock is missing: $DependencyLock"
}
try {
    $lock = Get-Content -LiteralPath $DependencyLock -Raw | ConvertFrom-Json
} catch {
    throw "dependency lock is invalid JSON: $($_.Exception.Message)"
}
if ($lock.schemaVersion -ne 1) { throw 'unsupported dependency lock schemaVersion' }
Assert-HttpsUrl ([string]$lock.voxtype.url) 'voxtype.url'
Assert-HashText ([string]$lock.voxtype.sha256) 'voxtype.sha256' `
    -AllowMissing:($PSCmdlet.ParameterSetName -ne 'PinnedRelease' -or -not $Apply)
Assert-HttpsUrl ([string]$lock.llamaCpp.url) 'llamaCpp.url'
Assert-HashText ([string]$lock.llamaCpp.sha256) 'llamaCpp.sha256'
foreach ($model in $lock.models) {
    Assert-HttpsUrl ([string]$model.url) "models.$($model.id).url"
    Assert-HashText ([string]$model.sha256) "models.$($model.id).sha256"
}

$output = Resolve-FullPath $OutputDirectory
if ([string]::IsNullOrWhiteSpace((Split-Path -Leaf $output))) {
    throw 'OutputDirectory must name a directory below a filesystem root'
}
$sourceDescription = switch ($PSCmdlet.ParameterSetName) {
    'ExistingBinary' { "existing executable $VoxtypeExe" }
    'SourceBuild' { "source build $VoxtypeSource" }
    default { "pinned release $($lock.voxtype.version)" }
}
Write-Host 'VoxType Windows release preparation'
Write-Host "  source: $sourceDescription"
Write-Host "  llama.cpp: $($lock.llamaCpp.version)"
Write-Host "  output: $output"
if (-not $Apply) {
    if ($PSCmdlet.ParameterSetName -eq 'PinnedRelease' -and
        [string]::IsNullOrWhiteSpace([string]$lock.voxtype.sha256)) {
        Write-Warning 'The pinned VoxType fork artifact still needs its release digest.'
    }
    Write-Host 'Dry run complete. Re-run with -Apply to download, build, or copy files.'
    if ($InstallTools) { Write-Host 'Build tools would be installed through winget.' }
    exit 0
}

if ($InstallTools) {
    Install-RequiredTools @($lock.tools) `
        -SourceBuild:($PSCmdlet.ParameterSetName -eq 'SourceBuild')
}
if (Test-Path -LiteralPath $output) {
    $contents = @(Get-ChildItem -LiteralPath $output -Force)
    if ($contents.Count -gt 0 -and -not $Force) {
        throw "output directory is not empty: $output. Choose another path or pass -Force."
    }
    if ($contents.Count -gt 0 -and $Force -and
        -not (Test-Path -LiteralPath (Join-Path $output '.voxtype-payload') -PathType Leaf)) {
        throw "refusing to replace an unrecognized output directory: $output"
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('voxtype-release-' + [Guid]::NewGuid().ToString('N'))
$payloadStage = Join-Path $temporaryRoot 'payload'
$downloadRoot = Join-Path $temporaryRoot 'downloads'
$extractRoot = Join-Path $temporaryRoot 'extract'
New-Item -ItemType Directory -Path $payloadStage, $downloadRoot, $extractRoot -Force | Out-Null
try {
    $voxtypeTarget = Join-Path $payloadStage 'voxtype.exe'
    switch ($PSCmdlet.ParameterSetName) {
        'ExistingBinary' {
            $existingPath = (Resolve-Path -LiteralPath $VoxtypeExe).Path
            Copy-Item -LiteralPath $existingPath -Destination $voxtypeTarget
        }
        'SourceBuild' { Get-VoxtypeFromSource $VoxtypeSource $voxtypeTarget }
        default {
            Assert-HashText ([string]$lock.voxtype.sha256) 'voxtype.sha256'
            $archive = Join-Path $downloadRoot 'voxtype.zip'
            Receive-LockedFile $lock.voxtype $archive 'VoxType'
            $voxtypeExtract = Join-Path $extractRoot 'voxtype'
            Expand-Archive -LiteralPath $archive -DestinationPath $voxtypeExtract
            $candidate = Get-ChildItem -LiteralPath $voxtypeExtract -File -Recurse |
                Where-Object { $_.Name -ceq [string]$lock.voxtype.archiveEntry } |
                Select-Object -First 1
            if ($null -eq $candidate) { throw 'VoxType archive has no voxtype.exe' }
            Copy-Item -LiteralPath $candidate.FullName -Destination $voxtypeTarget
        }
    }
    Assert-X64Pe $voxtypeTarget

    $llamaArchive = Join-Path $downloadRoot 'llama.zip'
    Receive-LockedFile $lock.llamaCpp $llamaArchive 'llama.cpp Vulkan runtime'
    $llamaExtract = Join-Path $extractRoot 'llama'
    Expand-Archive -LiteralPath $llamaArchive -DestinationPath $llamaExtract
    $llamaServer = Get-ChildItem -LiteralPath $llamaExtract -File -Recurse |
        Where-Object { $_.Name -ceq [string]$lock.llamaCpp.archiveEntry } |
        Select-Object -First 1
    if ($null -eq $llamaServer) { throw 'llama.cpp archive has no llama-server.exe' }
    Copy-Item -LiteralPath $llamaServer.FullName -Destination `
        (Join-Path $payloadStage 'llama-server.exe')
    Get-ChildItem -LiteralPath $llamaServer.Directory.FullName -Filter '*.dll' -File |
        Copy-Item -Destination $payloadStage
    Assert-X64Pe (Join-Path $payloadStage 'llama-server.exe')
    foreach ($dll in Get-ChildItem -LiteralPath $payloadStage -Filter '*.dll' -File) {
        Assert-X64Pe $dll.FullName
    }

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD_PARTY_NOTICES.txt.in') `
        -Destination (Join-Path $payloadStage 'THIRD_PARTY_NOTICES.txt')
    Copy-Item -LiteralPath $DependencyLock `
        -Destination (Join-Path $payloadStage 'dependencies.lock.json')
    [IO.File]::WriteAllText((Join-Path $payloadStage '.voxtype-payload'), 'managed',
        [Text.Encoding]::ASCII)

    $voxtypeSource = if ($PSCmdlet.ParameterSetName -eq 'PinnedRelease') {
        [string]$lock.voxtype.url
    } elseif ($PSCmdlet.ParameterSetName -eq 'SourceBuild') {
        'https://github.com/vantuan5644/voxtype'
    } else {
        'https://github.com/vantuan5644/voxtype'
    }
    $voxtypeDigest = (Get-FileHash $voxtypeTarget -Algorithm SHA256).Hash.ToLowerInvariant()
    $voxtypeVersion = [string]$lock.voxtype.version
    $voxtypeRevision = [string]$lock.voxtype.sourceRevision
    if ($PSCmdlet.ParameterSetName -eq 'ExistingBinary') {
        $voxtypeVersion = 'local-binary'
        $voxtypeRevision = $voxtypeDigest
    } elseif ($PSCmdlet.ParameterSetName -eq 'SourceBuild') {
        $sourceCommit = & git -C (Resolve-Path -LiteralPath $VoxtypeSource).Path rev-parse HEAD `
            2>$null
        if ($LASTEXITCODE -eq 0 -and $sourceCommit) {
            $voxtypeRevision = ([string]$sourceCommit).Trim()
        }
        $voxtypeVersion = 'source-build'
    }
    $payloadManifest = [ordered]@{
        schemaVersion = 1
        voxtype = [ordered]@{
            version = $voxtypeVersion
            source = $voxtypeSource
            sourceRevision = $voxtypeRevision
            sha256 = $voxtypeDigest
        }
        llamaCpp = [ordered]@{
            version = [string]$lock.llamaCpp.version
            source = [string]$lock.llamaCpp.url
            sourceRevision = [string]$lock.llamaCpp.sourceRevision
            sha256 = (Get-FileHash (Join-Path $payloadStage 'llama-server.exe') `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        files = @(Get-ChildItem -LiteralPath $payloadStage -File | Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    size = $_.Length
                    sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            })
    }
    $payloadManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath `
        (Join-Path $payloadStage 'payload-manifest.json') -Encoding UTF8

    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
    Move-Item -LiteralPath $payloadStage -Destination $output
    Write-Host "Prepared: $output"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

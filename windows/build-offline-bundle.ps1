[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ModelDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$DependencyLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DependencyLock)) {
    $DependencyLock = Join-Path $PSScriptRoot 'dependencies.lock.json'
}

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -cne $Expected.ToUpperInvariant()) {
        throw "digest mismatch for $Path"
    }
}

$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$models = (Resolve-Path -LiteralPath $ModelDirectory).Path
$lock = Get-Content -LiteralPath $DependencyLock -Raw | ConvertFrom-Json
$setupName = "VoxTypeSetup-$Version-x64.exe"
$msixName = "VoxType-$Version-x64.msix"
$certificateName = "VoxType-$Version-signing.cer"
$bundleFiles = @($setupName, $msixName, 'release-manifest.json')
if (Test-Path -LiteralPath (Join-Path $release $certificateName) -PathType Leaf) {
    $bundleFiles += $certificateName
}
foreach ($name in $bundleFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $name) -PathType Leaf)) {
        throw "release file is missing: $name"
    }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) `
    ('voxtype-offline-' + [Guid]::NewGuid().ToString('N'))
$bundleRoot = Join-Path $temporary "VoxType-$Version-offline"
$bundleModels = Join-Path $bundleRoot 'models'
New-Item -ItemType Directory -Path $bundleModels -Force | Out-Null
try {
    foreach ($name in $bundleFiles) {
        Copy-Item -LiteralPath (Join-Path $release $name) -Destination $bundleRoot
    }
    Copy-Item -LiteralPath $DependencyLock -Destination $bundleRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD_PARTY_NOTICES.txt.in') `
        -Destination (Join-Path $bundleRoot 'THIRD_PARTY_NOTICES.txt')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'licenses') `
        -Destination (Join-Path $bundleRoot 'LICENSES') -Recurse
    foreach ($model in $lock.models) {
        $source = Join-Path $models ([string]$model.fileName)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "model file is missing: $source"
        }
        Assert-Hash $source ([string]$model.sha256)
        Copy-Item -LiteralPath $source -Destination $bundleModels
    }
    $checksums = Get-ChildItem -LiteralPath $bundleRoot -File -Recurse | Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($bundleRoot.Length + 1).Replace('\', '/')
            "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),
                $relative
        }
    [IO.File]::WriteAllLines((Join-Path $bundleRoot 'SHA256SUMS.txt'), $checksums,
        [Text.UTF8Encoding]::new($false))
    $archive = Join-Path $release "VoxType-$Version-windows-x64-offline.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($bundleRoot, $archive,
        [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "Built: $archive"
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}

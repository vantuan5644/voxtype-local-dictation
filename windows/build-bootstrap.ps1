[CmdletBinding(DefaultParameterSetName = 'Thumbprint')]
param(
    [Parameter(Mandatory = $true)]
    [string]$MsixPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$Publisher,

    [string]$ReleaseTag = "v$Version",
    [string]$Repository = 'vantuan5644/voxtype-local-dictation',
    [string]$OutputDirectory,
    [string]$DependencyLock,

    [Parameter(ParameterSetName = 'Thumbprint')]
    [string]$CertificateThumbprint,

    [Parameter(ParameterSetName = 'Pfx')]
    [string]$PfxPath,

    [Parameter(ParameterSetName = 'Pfx')]
    [securestring]$PfxPassword,

    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist\release'
}
if ([string]::IsNullOrWhiteSpace($DependencyLock)) {
    $DependencyLock = Join-Path $PSScriptRoot 'dependencies.lock.json'
}

function Find-SdkTool {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $found = Get-ChildItem -LiteralPath $sdk -Filter $Name -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $found) { throw "$Name was not found; install the Windows SDK" }
    return $found.FullName
}

function ConvertTo-CSharpLiteral {
    param([string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

$package = (Resolve-Path -LiteralPath $MsixPath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$packageName = "VoxType-$Version-x64.msix"
$publishedPackage = Join-Path $output $packageName
Copy-Item -LiteralPath $package -Destination $publishedPackage -Force
$baseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"
$dependencies = Get-Content -LiteralPath $DependencyLock -Raw | ConvertFrom-Json
$manifest = [ordered]@{
    schemaVersion = 1
    version = $Version
    publisher = $Publisher
    packageIdentity = 'VoxType.Windows'
    configureUri = 'voxtype-configure:'
    msix = [ordered]@{
        fileName = $packageName
        url = "$baseUrl/$packageName"
        sha256 = (Get-FileHash $publishedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    models = @($dependencies.models | ForEach-Object {
        [ordered]@{
            id = [string]$_.id
            fileName = [string]$_.fileName
            sourceRevision = [string]$_.sourceRevision
            url = [string]$_.url
            sha256 = [string]$_.sha256
        }
    })
}
$manifestPath = Join-Path $output 'release-manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'packaging\BootstrapInstaller.cs'))
$template = $template.Replace('@@VERSION@@', (ConvertTo-CSharpLiteral $Version))
$template = $template.Replace('@@PUBLISHER@@', (ConvertTo-CSharpLiteral $Publisher))
$template = $template.Replace('@@MANIFEST_URL@@',
    (ConvertTo-CSharpLiteral "$baseUrl/release-manifest.json"))
$temporarySource = Join-Path $output 'BootstrapInstaller.generated.cs'
[IO.File]::WriteAllText($temporarySource, $template, [Text.UTF8Encoding]::new($false))
$setup = Join-Path $output "VoxTypeSetup-$Version-x64.exe"
try {
    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw 'the .NET Framework C# compiler is unavailable'
    }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
        /reference:System.Web.Extensions.dll "/out:$setup" $temporarySource
    if ($LASTEXITCODE -ne 0) { throw 'bootstrap compilation failed' }

    if (-not $SkipSigning) {
        $signTool = Find-SdkTool 'signtool.exe'
        $arguments = @('sign', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256')
        if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
            if (-not $PfxPath) { throw '-PfxPath is required for PFX signing' }
            $arguments += @('/f', $PfxPath)
            if ($null -ne $PfxPassword) {
                $plain = [Net.NetworkCredential]::new('', $PfxPassword).Password
                $arguments += @('/p', $plain)
            }
        } else {
            if (-not $CertificateThumbprint) {
                throw '-CertificateThumbprint is required unless -SkipSigning is used'
            }
            $arguments += @('/sha1', $CertificateThumbprint)
        }
        & $signTool @arguments $setup
        if ($LASTEXITCODE -ne 0) { throw 'bootstrap signing failed' }
        & $signTool verify /pa /v $setup
        if ($LASTEXITCODE -ne 0) { throw 'bootstrap signature verification failed' }
    }
} finally {
    Remove-Item -LiteralPath $temporarySource -Force -ErrorAction SilentlyContinue
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD_PARTY_NOTICES.txt.in') `
    -Destination (Join-Path $output 'THIRD_PARTY_NOTICES.txt') -Force
$releaseLicenses = Join-Path $output 'LICENSES'
if (Test-Path -LiteralPath $releaseLicenses) {
    Remove-Item -LiteralPath $releaseLicenses -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'licenses') `
    -Destination $releaseLicenses -Recurse
$checksumFiles = @($setup, $publishedPackage, $manifestPath,
    (Join-Path $output 'THIRD_PARTY_NOTICES.txt')) +
    @(Get-ChildItem -LiteralPath $releaseLicenses -File)
$checksums = $checksumFiles | ForEach-Object {
    $checksumPath = if ($_ -is [IO.FileInfo]) { $_.FullName } else { [string]$_ }
    "{0}  {1}" -f (Get-FileHash -LiteralPath $checksumPath `
        -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $checksumPath)
}
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), $checksums,
    [Text.UTF8Encoding]::new($false))
Write-Host "Built: $setup"
Write-Host "Manifest: $manifestPath"

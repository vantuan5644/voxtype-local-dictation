[CmdletBinding(DefaultParameterSetName = 'Thumbprint')]
param(
    [string]$PayloadDirectory,

    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0.0',

    [string]$IdentityName = 'VoxType.Windows',

    [string]$Publisher,

    [string]$PublisherDisplayName = 'VoxType',

    [Parameter(ParameterSetName = 'Thumbprint')]
    [string]$CertificateThumbprint,

    [Parameter(ParameterSetName = 'Pfx')]
    [string]$PfxPath,

    [Parameter(ParameterSetName = 'Pfx')]
    [securestring]$PfxPassword,

    [string]$TimestampUrl = 'http://timestamp.digicert.com',

    [switch]$SkipSigning,
    [switch]$KeepStaging,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$windowsRoot = $PSScriptRoot
$voxtypeRoot = (Resolve-Path (Join-Path $windowsRoot '..')).Path
$installGuide = Join-Path $voxtypeRoot 'docs\install-windows.md'
$outputDir = Join-Path $windowsRoot 'dist'
$staging = Join-Path $windowsRoot '.msix-staging'
$package = Join-Path $outputDir "voxtype-$Version-windows-x64.msix"

function Show-Usage {
    @'
Build a signed VoxType MSIX from prebuilt Windows binaries.

Create the payload first:
  .\prepare-windows-release.ps1 -VoxtypeExe C:\build\voxtype.exe -Apply

Required payload directory contents:
  voxtype.exe                 native x64 Windows port
  llama-server.exe            native x64 Vulkan server
  payload-manifest.json       versions, HTTPS sources, and SHA-256 digests
  dependencies.lock.json      pinned model catalog used by first-run setup
  THIRD_PARTY_NOTICES.txt     notices for bundled dependencies
  *.dll / *.json              runtime files required by either executable

Signed package:
  .\build-msix.ps1 -PayloadDirectory C:\build\voxtype-windows `
    -Version 1.0.1.0 -CertificateThumbprint <CODE_SIGNING_THUMBPRINT>

Validation package:
  .\build-msix.ps1 -PayloadDirectory C:\build\voxtype-windows -SkipSigning

The publisher is derived from the signing certificate. Use -Publisher only to
override it with the certificate's exact subject.
'@ | Write-Host
    Write-Host "Payload preparation guide: $installGuide"
}

if ($Help) { Show-Usage; exit 0 }
if ([string]::IsNullOrWhiteSpace($PayloadDirectory)) {
    Show-Usage
    [Console]::Error.WriteLine('build-msix: -PayloadDirectory is required')
    exit 2
}
if (-not (Test-Path -LiteralPath $PayloadDirectory -PathType Container)) {
    throw "payload directory does not exist: $PayloadDirectory`nRun with -Help for the required layout."
}
$PayloadDirectory = (Resolve-Path -LiteralPath $PayloadDirectory).Path

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

function Copy-RequiredFile {
    param([string]$Name)
    $path = Join-Path $PayloadDirectory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "required payload is missing: $path"
    }
    Copy-Item -LiteralPath $path -Destination $staging
}

function Assert-X64Pe {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "payload is not a PE binary: $Path"
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw "payload has an invalid PE header: $Path"
    }
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x8664) { throw "payload is not an x64 executable: $Path" }
}

function Assert-PayloadMetadata {
    param(
        [string]$PropertyName,
        [string]$ArtifactPath,
        [object]$Metadata
    )
    $entry = $Metadata.$PropertyName
    if ($null -eq $entry) { throw "payload manifest has no '$PropertyName' entry" }
    foreach ($property in @('version', 'source', 'sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.$property)) {
            throw "payload manifest '$PropertyName.$property' is empty"
        }
    }
    $sourceUri = $null
    if (-not [Uri]::TryCreate([string]$entry.source, [UriKind]::Absolute, [ref]$sourceUri) -or
        $sourceUri.Scheme -cne 'https') {
        throw "payload manifest '$PropertyName.source' must be an absolute HTTPS URL"
    }
    if ([string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "payload manifest '$PropertyName.sha256' is not a SHA-256 digest"
    }
    $actual = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash
    if ($actual -cne ([string]$entry.sha256).ToUpperInvariant()) {
        throw "payload digest does not match for $PropertyName"
    }
}

function Get-SigningCertificate {
    if ($SkipSigning) { return $null }
    if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
        if (-not $PfxPath) { throw '-PfxPath is required when signing with a PFX' }
        $plainPassword = if ($null -eq $PfxPassword) { '' } else {
            [Net.NetworkCredential]::new('', $PfxPassword).Password
        }
        return [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $PfxPath, $plainPassword)
    }
    if (-not $CertificateThumbprint) {
        throw '-CertificateThumbprint is required unless -SkipSigning is used'
    }
    $certificate = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $CertificateThumbprint } |
        Select-Object -First 1
    if ($null -eq $certificate) {
        throw "signing certificate was not found: $CertificateThumbprint"
    }
    return $certificate
}

$requiredPayload = @('voxtype.exe', 'llama-server.exe', 'payload-manifest.json',
    'dependencies.lock.json', 'THIRD_PARTY_NOTICES.txt')
$missingPayload = @($requiredPayload | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $PayloadDirectory $_) -PathType Leaf)
    })
if ($missingPayload.Count -gt 0) {
    $missingList = $missingPayload | ForEach-Object { "  - $_" }
    $message = "payload directory is incomplete: $PayloadDirectory`n" +
        "$($missingList -join "`n")`n" +
        "Run with -Help or read $installGuide for preparation steps."
    throw $message
}
$voxtypePayload = Join-Path $PayloadDirectory 'voxtype.exe'
$llamaPayload = Join-Path $PayloadDirectory 'llama-server.exe'
$payloadManifest = Join-Path $PayloadDirectory 'payload-manifest.json'
$dependencyLock = Join-Path $PayloadDirectory 'dependencies.lock.json'
$thirdPartyNotices = Join-Path $PayloadDirectory 'THIRD_PARTY_NOTICES.txt'
if ((Get-Item -LiteralPath $thirdPartyNotices).Length -eq 0) {
    throw 'THIRD_PARTY_NOTICES.txt is empty'
}
Assert-X64Pe $voxtypePayload
Assert-X64Pe $llamaPayload
$runtimeDlls = Get-ChildItem -LiteralPath $PayloadDirectory -Filter '*.dll' -File
foreach ($runtimeDll in $runtimeDlls) { Assert-X64Pe $runtimeDll.FullName }
try {
    $metadata = Get-Content -LiteralPath $payloadManifest -Raw | ConvertFrom-Json
} catch {
    throw "payload manifest is invalid JSON: $($_.Exception.Message)"
}
Assert-PayloadMetadata 'voxtype' $voxtypePayload $metadata
Assert-PayloadMetadata 'llamaCpp' $llamaPayload $metadata
try {
    $dependencies = Get-Content -LiteralPath $dependencyLock -Raw | ConvertFrom-Json
} catch {
    throw "dependencies.lock.json is invalid JSON: $($_.Exception.Message)"
}
if ($dependencies.schemaVersion -ne 1 -or @($dependencies.models).Count -ne 2) {
    throw 'dependencies.lock.json must use schemaVersion 1 and contain two models'
}
foreach ($model in $dependencies.models) {
    foreach ($property in @('id', 'name', 'fileName', 'url', 'sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$model.$property)) {
            throw "dependency model '$($model.id)' has no $property"
        }
    }
    $modelUri = $null
    if (-not [Uri]::TryCreate([string]$model.url, [UriKind]::Absolute, [ref]$modelUri) -or
        $modelUri.Scheme -cne 'https') {
        throw "dependency model '$($model.id)' URL must use HTTPS"
    }
    if ([string]$model.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "dependency model '$($model.id)' has an invalid SHA-256 digest"
    }
}
$signingCertificate = Get-SigningCertificate
if ([string]::IsNullOrWhiteSpace($Publisher)) {
    $Publisher = if ($null -ne $signingCertificate) {
        $signingCertificate.Subject
    } else { 'CN=VoxType Development' }
}
if ($Publisher -notmatch '(?i)(^|,\s*)CN=') {
    throw "Publisher must be a certificate subject such as 'CN=Tuan Tran'"
}
if ($null -ne $signingCertificate -and $signingCertificate.Subject -cne $Publisher) {
    throw "manifest Publisher must exactly match certificate subject '$($signingCertificate.Subject)'"
}
if ($null -ne $signingCertificate) {
    if (-not $signingCertificate.HasPrivateKey) {
        throw 'the signing certificate has no accessible private key'
    }
    if ($signingCertificate.NotBefore -gt (Get-Date) -or
        $signingCertificate.NotAfter -le (Get-Date)) {
        throw 'the signing certificate is outside its validity period'
    }
    $codeSigningOid = '1.3.6.1.5.5.7.3.3'
    $eku = $signingCertificate.Extensions |
        Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } |
        Where-Object { $_.Value -eq $codeSigningOid }
    if ($null -eq $eku) { throw 'the certificate is not valid for code signing' }
}

if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging, $outputDir,
    (Join-Path $staging 'windows'), (Join-Path $staging 'windows\bin'),
    (Join-Path $staging 'Assets') -Force | Out-Null

try {
    Copy-RequiredFile 'voxtype.exe'
    Copy-RequiredFile 'llama-server.exe'
    Copy-RequiredFile 'payload-manifest.json'
    Copy-RequiredFile 'dependencies.lock.json'
    Copy-RequiredFile 'THIRD_PARTY_NOTICES.txt'
    $runtimeFiles = Get-ChildItem -LiteralPath $PayloadDirectory -File |
        Where-Object { $_.Extension -in @('.dll', '.json') -and
            $_.Name -notin @('payload-manifest.json', 'dependencies.lock.json') }
    $runtimeFiles | Copy-Item -Destination $staging
    $runtimeFiles | Copy-Item -Destination (Join-Path $staging 'windows\bin')
    Copy-Item -LiteralPath (Join-Path $PayloadDirectory 'llama-server.exe') `
        -Destination (Join-Path $staging 'windows\bin\llama-server.exe')
    foreach ($file in @('voxtype-local.ps1', 'voxtype-cleanup.ps1', 'voxtype-vocab.ps1',
            'voxtype-server.ps1', 'voxtype-setup.ps1')) {
        Copy-Item -LiteralPath (Join-Path $windowsRoot $file) -Destination (Join-Path $staging 'windows')
    }
    Copy-Item -LiteralPath (Join-Path $voxtypeRoot 'vocabulary.conf') `
        -Destination (Join-Path $staging 'vocabulary.conf')
    Copy-Item -LiteralPath (Join-Path $windowsRoot 'licenses') `
        -Destination (Join-Path $staging 'LICENSES') -Recurse

    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw 'C# compiler was not found; install the .NET Framework developer tools'
    }
    & $csc /nologo /target:exe /platform:x64 /optimize+ `
        "/out:$(Join-Path $staging 'voxtype-local.exe')" `
        (Join-Path $PSScriptRoot 'packaging\Launcher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'failed to compile voxtype-local.exe' }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        "/out:$(Join-Path $staging 'voxtype-cleanup-server.exe')" `
        (Join-Path $PSScriptRoot 'packaging\ServerLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'failed to compile voxtype-cleanup-server.exe' }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
        /reference:System.Web.Extensions.dll `
        "/out:$(Join-Path $staging 'voxtype-configure.exe')" `
        (Join-Path $PSScriptRoot 'packaging\ConfigureLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'failed to compile voxtype-configure.exe' }
    & $csc /nologo /target:winexe /platform:x64 /optimize+ `
        "/out:$(Join-Path $staging 'voxtype-startup.exe')" `
        (Join-Path $PSScriptRoot 'packaging\StartupLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'failed to compile voxtype-startup.exe' }

    Add-Type -AssemblyName System.Drawing
    foreach ($asset in @(@('StoreLogo.png', 50), @('Square44x44Logo.png', 44),
            @('Square150x150Logo.png', 150))) {
        $bitmap = [Drawing.Bitmap]::new($asset[1], $asset[1])
        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.Clear([Drawing.Color]::FromArgb(26, 27, 38))
                $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(122, 162, 247),
                    [Math]::Max(2, [int]($asset[1] / 12)))
                try {
                    $mid = [single]($asset[1] / 2)
                    $graphics.DrawLine($pen, [single]($asset[1] * .2), $mid,
                        [single]($asset[1] * .38), [single]($asset[1] * .28))
                    $graphics.DrawLine($pen, [single]($asset[1] * .38),
                        [single]($asset[1] * .28), [single]($asset[1] * .55),
                        [single]($asset[1] * .72))
                    $graphics.DrawLine($pen, [single]($asset[1] * .55),
                        [single]($asset[1] * .72), [single]($asset[1] * .8), $mid)
                } finally { $pen.Dispose() }
            } finally { $graphics.Dispose() }
            $bitmap.Save((Join-Path $staging "Assets\$($asset[0])"),
                [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
    }

    $escape = { param([string]$value) [Security.SecurityElement]::Escape($value) }
    $manifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'packaging\AppxManifest.xml.in'))
    $manifest = $manifest.Replace('@@IDENTITY_NAME@@', (& $escape $IdentityName))
    $manifest = $manifest.Replace('@@PUBLISHER@@', (& $escape $Publisher))
    $manifest = $manifest.Replace('@@PUBLISHER_DISPLAY_NAME@@', (& $escape $PublisherDisplayName))
    $manifest = $manifest.Replace('@@VERSION@@', $Version)
    [IO.File]::WriteAllText((Join-Path $staging 'AppxManifest.xml'), $manifest,
        [Text.UTF8Encoding]::new($false))

    $signTool = $null
    $baseSignArgs = @()
    if (-not $SkipSigning) {
        $signTool = Find-SdkTool 'signtool.exe'
        $baseSignArgs = @('sign', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256')
        if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
            $baseSignArgs += @('/f', $PfxPath)
            if ($null -ne $PfxPassword) {
                $plain = [Net.NetworkCredential]::new('', $PfxPassword).Password
                $baseSignArgs += @('/p', $plain)
            }
        } else {
            $baseSignArgs += @('/sha1', $CertificateThumbprint)
        }
        foreach ($executable in Get-ChildItem -LiteralPath $staging -Filter '*.exe' -File -Recurse) {
            & $signTool @baseSignArgs $executable.FullName
            if ($LASTEXITCODE -ne 0) { throw "SignTool failed for $($executable.Name)" }
            & $signTool verify /pa $executable.FullName
            if ($LASTEXITCODE -ne 0) {
                throw "signature verification failed for $($executable.Name)"
            }
        }
        $stagedPayloadManifest = Join-Path $staging 'payload-manifest.json'
        $stagedMetadata = Get-Content -LiteralPath $stagedPayloadManifest -Raw |
            ConvertFrom-Json
        foreach ($mapping in @(@('voxtype', 'voxtype.exe'),
                @('llamaCpp', 'llama-server.exe'))) {
            $entry = $stagedMetadata.($mapping[0])
            $entry | Add-Member -NotePropertyName sourceSha256 `
                -NotePropertyValue ([string]$entry.sha256) -Force
            $entry.sha256 = (Get-FileHash (Join-Path $staging $mapping[1]) `
                -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($null -ne $stagedMetadata.PSObject.Properties['files']) {
                foreach ($file in @($stagedMetadata.files | Where-Object {
                            $_.name -ceq $mapping[1]
                        })) {
                    $file | Add-Member -NotePropertyName sourceSha256 `
                        -NotePropertyValue ([string]$file.sha256) -Force
                    $file.sha256 = $entry.sha256
                    $file.size = (Get-Item -LiteralPath `
                        (Join-Path $staging $mapping[1])).Length
                }
            }
        }
        [IO.File]::WriteAllText($stagedPayloadManifest,
            ($stagedMetadata | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
    }

    $makeAppx = Find-SdkTool 'makeappx.exe'
    if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Force }
    & $makeAppx pack /d $staging /p $package /o
    if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed' }

    if (-not $SkipSigning) {
        & $signTool @baseSignArgs $package
        if ($LASTEXITCODE -ne 0) { throw 'SignTool failed' }
        & $signTool verify /pa /v $package
        if ($LASTEXITCODE -ne 0) { throw 'package signature verification failed' }
    }
    Write-Host "Built: $package"
} finally {
    if (-not $KeepStaging -and (Test-Path -LiteralPath $staging)) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

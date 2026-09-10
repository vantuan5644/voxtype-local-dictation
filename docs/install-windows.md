# Installing on Windows

VoxType supports 64-bit Windows 11 build 22621 or newer. The application installs
per-user and leaves WSL and developer tools out of the desktop path. Trusting the
self-signed development certificate is a one-time administrator action.

## Online installation

1. Open the latest Windows release on GitHub.
2. For a development release signed with the project certificate, download
   `VoxType-<version>-signing.cer`, confirm its thumbprint matches the release
   notes, then import it into the Local Computer **Trusted People** store from an
   administrator PowerShell session:

   ```powershell
   Import-Certificate -FilePath .\VoxType-<version>-signing.cer `
     -CertStoreLocation Cert:\LocalMachine\TrustedPeople
   ```
3. Download `VoxTypeSetup-<version>-x64.exe`.
4. Confirm that Windows shows the expected publisher, then run the installer.
5. Complete the setup window: choose a microphone, press the desired
   push-to-talk key, select online models, and choose whether VoxType starts when
   you sign in.
6. Open Notepad, hold the selected key, speak, and release it.

Importing a self-signed certificate grants it software-signing trust on the
computer. Use the certificate only for releases from this repository and remove
it from **Trusted People** when replacing the development signer.

The bootstrap verifies the HTTPS release description, MSIX SHA-256 value,
Authenticode trust, publisher, package identity, version, and architecture before
installing. It then opens the packaged setup window.

## Private offline installation

The project does not publish the multi-gigabyte model archive. A maintainer can
build `VoxType-<version>-windows-x64-offline.zip` locally from the pinned models
for private distribution. Extract the entire archive and run the included
`VoxTypeSetup-<version>-x64.exe`. The installer discovers the adjacent release
description and MSIX. In the setup window, choose **Use models from an offline
release folder** and select the extracted folder.

Each offline archive contains:

- the same signed bootstrap and MSIX published on GitHub;
- the public signing certificate used by development releases;
- the Whisper transcription model and Qwen cleanup model;
- exact source revisions, SHA-256 values, checksums, and third-party notices.

## What setup configures

The guided setup performs these operations for the current Windows account:

- enumerates Windows microphones and records the selected device;
- detects Vulkan through the packaged llama.cpp runtime and allows CPU fallback;
- captures an explicit push-to-talk key;
- downloads or imports
  `ggml-large-v3-turbo-q5_0.bin` and
  `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`;
- installs Silero voice activity detection and the guarded local cleanup command;
- records the sign-in startup preference and starts the daemon and cleanup server;
- preserves raw transcription whenever local cleanup is unavailable.

Interrupted downloads remain as `.partial` files and resume on the next attempt.
A completed model reaches its final filename only after its exact digest passes.

Configuration and vocabulary live under `%APPDATA%\VoxType`. Models, logs, and
runtime state live under `%LOCALAPPDATA%\VoxType`. These directories persist
across package upgrades and removal so an upgrade never repeats multi-gigabyte
downloads.

The installed Start menu contains **Set up VoxType** for changing the microphone,
hotkey, models, or startup choice. Advanced users also receive the `voxtype.exe`
and `voxtype-local.exe` execution aliases.

## Maintainer release preparation

`windows/dependencies.lock.json` is the release source of truth. It pins the
Windows VoxType fork artifact, official llama.cpp Vulkan archive, both models,
and their SHA-256 values. A Windows release remains blocked while the VoxType
entry has a pending revision or digest.

Preview the preparation first:

```powershell
./windows/prepare-windows-release.ps1
```

After publishing the Windows-enabled daemon artifact and filling its immutable
digest into the lock file, prepare the normal release payload:

```powershell
./windows/prepare-windows-release.ps1 -Apply
```

Local development can supply an existing executable or build a source checkout:

```powershell
./windows/prepare-windows-release.ps1 `
  -VoxtypeExe C:\build\voxtype.exe -Apply

./windows/prepare-windows-release.ps1 `
  -VoxtypeSource C:\src\voxtype -InstallTools -Apply
```

`-InstallTools` uses winget for Rustup, Visual Studio C++ Build Tools and the
Windows SDK, CMake, Ninja, and the Vulkan SDK. Those packages are maintainer
dependencies; end-user computers never receive them.

The preparer verifies the lock, downloads with partial-file resume, builds or
copies `voxtype.exe`, extracts `llama-server.exe` and its runtime DLLs, validates
x64 PE headers, assembles notices, and writes `payload-manifest.json` with file
digests. Existing nonempty output requires `-Force`.

Build the signed MSIX with a certificate from the Windows certificate store:

```powershell
./windows/build-msix.ps1 `
  -PayloadDirectory ./windows/dist/payload `
  -Version 1.0.1.0 `
  -CertificateThumbprint ABCDEF0123456789ABCDEF0123456789ABCDEF01
```

The publisher is derived from the certificate subject. Every shipped executable
and the final MSIX receives a SHA-256 signature and timestamp, followed by
signature verification.

Build the version-specific bootstrap and release description:

```powershell
./windows/build-bootstrap.ps1 `
  -MsixPath ./windows/dist/voxtype-1.0.1.0-windows-x64.msix `
  -Version 1.0.1.0 `
  -Publisher 'CN=Your Public Certificate Subject' `
  -ReleaseTag windows-v1.0.1.0 `
  -CertificateThumbprint ABCDEF0123456789ABCDEF0123456789ABCDEF01
```

Unsigned `-SkipSigning` output is suitable for source validation only. Public
distribution should use a certificate whose chain Windows already trusts. The
development workflow can use a self-signed certificate after the user explicitly
imports the published public certificate.

## Automated releases

The downstream `.github/workflows/release-windows.yml` workflow is synchronized
from the homelab source. A `windows-v<four-part-version>` tag or manual dispatch:

1. prepares the pinned payload;
2. temporarily imports the release PFX from encrypted repository secrets;
3. signs and verifies the MSIX and bootstrap;
4. exports the public signing certificate and publishes the release assets;
5. removes the temporary certificate and PFX in an always-running cleanup step.

Configure the protected `windows-release` environment with:

- `WINDOWS_SIGNING_PFX_BASE64`;
- `WINDOWS_SIGNING_PFX_PASSWORD`.

## First-release limitations

- Meeting capture, system-audio capture, media ducking, OSD, and tray UI are
  deferred.
- Windows blocks `SendInput` into processes running at a higher integrity level.
  VoxType copies the transcript to the clipboard and reports the fallback.
- Protected or exclusive-input applications can reserve a key or block text
  injection.
- The first package supports x64 Windows 11.

## Verification

Portable tests cover cleanup safety, vocabulary edits, setup configuration,
dependency locking, bootstrap compilation, and PowerShell syntax:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ./windows/tests/test-windows.ps1
pwsh -NoProfile -File ./windows/tests/test-windows.ps1
```

Release acceptance uses a clean standard-user Windows account for online and
offline installation, model interruption/resume, Vulkan and CPU processing,
Unicode dictation in Notepad/Chrome/VS Code/Windows Terminal, sleep/resume,
startup preference, package upgrade, and cleanup-service failure.

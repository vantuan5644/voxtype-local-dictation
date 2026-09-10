# Contract for the upstream Windows daemon

This directory assembles and configures a Windows package while keeping a
private copy of `peteonrails/voxtype` out of the homelab. `build-msix.ps1`
consumes the native `voxtype.exe` produced by an upstreamable fork.

The executable is ready for this package when it satisfies the following
contract.

## Build and platform boundaries

- `cargo build --release --target x86_64-pc-windows-msvc --features gpu-vulkan`
  succeeds on a clean Windows runner.
- Linux evdev/MPRIS/Wayland modules, macOS CGEvent modules, Unix signals,
  `std::os::unix` imports and socket checks are confined to their platforms.
- Windows has implementations for daemon shutdown, PID liveness, singleton
  ownership, notification, microphone privacy failures, hotkeys, clipboard,
  typing and paste.
- First-release meeting commands return a stable unsupported-platform error.
  They must never start a microphone-only meeting while claiming system audio.

## Observable behavior

- With no arguments, `voxtype.exe` runs the foreground daemon.
- `voxtype configure`, `voxtype config get`, `voxtype config set`, `voxtype
  setup vad`, and `voxtype record start|stop|toggle|cancel` retain their existing
  command shapes.
- `voxtype devices --json` prints a UTF-8 JSON array of exact CPAL input-device
  names for the Windows setup UI. An empty array is valid when microphone access
  is unavailable.
- Configuration resolves to `%APPDATA%\VoxType\config.toml`; models and runtime
  state resolve below `%LOCALAPPDATA%\VoxType`.
- `hotkey.enabled=false` is a valid initial state. The Windows build chooses no
  push-to-talk key on the user's behalf.
- The hotkey listener emits one press and one release per physical hold, ignores
  key-repeat, and hands work off immediately from its Windows message thread.
- Type mode waits for modifiers to be released and tries Unicode `SendInput`,
  clipboard plus Ctrl+V, then clipboard-only. Partial or integrity-blocked input
  reaches the clipboard and a notification explains where the text went.
- Clipboard mode uses `CF_UNICODETEXT` with bounded retry when another process
  temporarily owns the clipboard.
- The post-process command `voxtype-local.exe cleanup` receives UTF-8 text on
  stdin. Timeout, non-zero exit, invalid UTF-8, or empty output returns the raw
  transcription.
- Windows command hooks use `cmd.exe /D /S /C`. A timed-out command and all its
  descendants are terminated through a Job Object.
- A package-identity notification reports recording start, transcription and
  output fallback without requiring a console window.

## Recommended source changes

- Add a `cfg(windows)` dependency on the `windows` crate for User32, clipboard,
  process, Job Object and notification APIs.
- Add `hotkey_windows.rs`, `output/windows.rs`, `notification_windows.rs` and a
  small process-platform module behind the same traits used by Linux and macOS.
- Replace direct `tokio::signal::unix`, `libc::getuid`, Unix socket and
  `FileTypeExt` calls in shared modules with platform functions.
- Keep the existing file-trigger command protocol. Use a named mutex for one
  daemon per user and `OpenProcess` for liveness, avoiding a new IPC protocol.
- Add `windows-latest` CI for MSVC compilation, unit tests and synthetic-WAV
  transcription. Hardware-dependent Vulkan and live desktop behavior remain
  explicit manual evidence.

## Artifact handoff

Copy `windows/upstream-release.yml` to `.github/workflows/windows-release.yml`
in `vantuan5644/voxtype`. It tests the MSVC target on every change and publishes
the versioned Vulkan ZIP, checksum, and build attestation for a
`v*-windows.*` tag. The asset name is the one recorded in
`dependencies.lock.json`.

Place the resulting `voxtype.exe` beside the Vulkan `llama-server.exe`, all
required DLLs, `THIRD_PARTY_NOTICES.txt`, and `payload-manifest.json`. The JSON
file must record a version, HTTPS source, and SHA-256 digest for each executable.
Then pass that directory to `build-msix.ps1`. The package builder accepts only
those supplied binaries and performs no downloads or substitutions.

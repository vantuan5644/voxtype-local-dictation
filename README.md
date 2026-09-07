# voxtype-local-dictation

Offline push-to-talk dictation for macOS and Linux, built around
[peteonrails/voxtype](https://github.com/peteonrails/voxtype): hold a key,
speak, release — [whisper](https://github.com/ggml-org/whisper.cpp) transcribes
locally, a local [Qwen3-4B](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF)
on [llama.cpp](https://github.com/ggml-org/llama.cpp) cleans the transcript up,
and the result is typed at your cursor. **Nothing leaves the machine** — no
cloud APIs on the default path, no telemetry, no network round trip between
speaking and the text landing.

One repository, two platform implementations of the same stack:

| | macOS | Linux (Hyprland/Omarchy) |
|---|---|---|
| Push-to-talk key | `fn` (Globe) | Right Alt |
| Transcription | whisper on Metal | whisper on Vulkan/CUDA |
| Cleanup model | llama.cpp LaunchAgent, port 8088 | llama.cpp systemd user unit, port 8088 |
| Recording feedback | standalone OSD renderer (Swift) | the OSD voxtype spawns itself |
| Meeting mode | CoreAudio process tap impersonating `pactl`/`parec` | PipeWire monitor source |
| Trigger extras | Raycast script commands | Hyprland bind + Omarchy menu row |

The two halves assert the **same voxtype configuration** and share the
**same dictation vocabulary**, so a term you add for one machine works on the
other after the next install run.

## What is in here

- `macos/` — the macOS installer and payload: the signed app-bundle setup, the
  payload scripts, the OSD and meeting-shim Swift sources, LaunchAgent plists,
  and a latency benchmark harness.
- `linux/` — the Linux installer and payload: the same filter and meeting
  wrapper, a notifier shim, the templated `llama-server.service.in`, and
  optional compositor integration snippets.
- `vocabulary.conf` + `voxtype-vocab` — the shared vocabulary: **the single
  place a technical term is typed**, consumed by both whisper's
  `initial_prompt` and the cleanup model's system prompt.
- `docs/` — install, configuration, and troubleshooting for both platforms.

## Requirements

- **macOS 14.2+** (Apple Silicon; the meeting shim needs the 14.2 process-tap
  API), Xcode Command Line Tools (for the two Swift sources), Homebrew for
  `llama.cpp`, `jq`, `terminal-notifier`, `coreutils`.
- **Linux**: `voxtype` itself ([AUR `voxtype-bin`](https://aur.archlinux.org/packages/voxtype-bin)
  or built from source), `llama.cpp` **with a CPU backend compiled in** (a
  GPU backend alone is not enough — see
  [install-linux](docs/install-linux.md#the-llamacpp-trap)), `jq`, `curl`,
  membership of the `input` group for the evdev hotkey.
- Both: ~4–6 GB of disk for the models. The installers **report** the
  multi-gigabyte downloads and never perform them.

## Quick start

```sh
git clone https://github.com/vantuan5644/voxtype-local-dictation
cd voxtype-local-dictation

./macos/install.sh --dry-run     # macOS: review, then run for real
./linux/install.sh --dry-run     # Linux: review, then run for real
```

Each installer is idempotent, supports `--uninstall`, and prints the manual
steps it cannot do for you (the macOS TCC privacy grants; the model
downloads). What each phase does, and why the macOS daemon runs from Login
Items rather than a LaunchAgent, is in the install docs:

- [Installing on macOS](docs/install-macos.md)
- [Installing on Linux](docs/install-linux.md)
- [Configuration: keys, backends, environment variables](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)

## Attribution

This repository is a deployment, a port, and two original components on top of
[peteonrails/voxtype](https://github.com/peteonrails/voxtype) (MIT) — the
daemon, hotkey, whisper pipeline, and meeting engine are upstream's work. The
macOS OSD renderer ports drawing math from upstream's Rust OSD. See
[NOTICE.md](NOTICE.md) for details; license is MIT.

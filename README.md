# voxtype-local-dictation

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple&logoColor=white)](docs/install-macos.md)
[![Linux](https://img.shields.io/badge/Linux-Hyprland%20%2F%20Omarchy-f5a97f?logo=linux&logoColor=white)](docs/install-linux.md)

Hold a key, speak, and release. [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
transcribes locally, then a local
[Qwen3-4B](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF) model
running on [llama.cpp](https://github.com/ggml-org/llama.cpp) cleans up the text
and types it at your cursor. The default dictation path stays on your machine.

This project uses
[peteonrails/voxtype](https://github.com/peteonrails/voxtype). It packages the
local cleanup pipeline, installers, shared vocabulary, macOS OSD, and macOS
meeting audio support around the upstream daemon.

![The OSD while dictating](docs/img/osd-recording.png)

## Features

- Local cleanup adds punctuation, capitalization, and preferred spellings.
- If cleanup fails or changes too much, the original transcript passes through
  unchanged.
- `vocabulary.conf` supplies whisper hints and spelling corrections. Use
  `voxtype-vocab add <your-vocab>` or `voxtype-vocab edit` to maintain it.
- Meeting mode records both sides of a call. macOS uses a CoreAudio process tap;
  Linux uses a PipeWire monitor source.
- Meeting summaries try `codex,claude,local` by default. Set
  `VOXTYPE_MEETING_SUMMARY_BACKEND=local` to keep them offline.
- Both installers support `--dry-run` and `--uninstall`. They report model
  downloads instead of starting them.

## Platforms

| | macOS | Linux (Hyprland/Omarchy) |
|---|---|---|
| Push-to-talk key | `fn` (Globe) | Right Alt |
| Transcription | whisper on Metal | whisper on Vulkan/CUDA |
| Cleanup service | llama.cpp LaunchAgent on port 8088 | llama.cpp systemd user unit on port 8088 |
| Recording feedback | Swift OSD | upstream OSD |
| Meeting audio | CoreAudio process tap | PipeWire monitor source |
| Optional triggers | Raycast scripts | Hyprland bind and Omarchy menu row |

## Requirements

macOS requires Apple Silicon, macOS 14.2 or later, Xcode Command Line Tools,
and Homebrew. Linux requires `voxtype`, `jq`, `curl`, input-group membership,
and a `llama.cpp` build with a CPU backend. See the
[Linux installation note](docs/install-linux.md#the-llamacpp-trap) before
choosing a package.

Allow 4 to 6 GB of disk space for the models. The installers do not download
them.

## Quick start

```sh
git clone https://github.com/vantuan5644/voxtype-local-dictation
cd voxtype-local-dictation

./macos/install.sh --dry-run     # macOS: review, then run for real
./linux/install.sh --dry-run     # Linux: review, then run for real
```

- [Install on macOS](docs/install-macos.md)
- [Install on Linux](docs/install-linux.md)
- [Configure keys, backends, and environment variables](docs/configuration.md)
- [Troubleshoot common problems](docs/troubleshooting.md)

## Attribution

The daemon, hotkey, whisper pipeline, and meeting engine come from
[peteonrails/voxtype](https://github.com/peteonrails/voxtype), used here as an
MIT-licensed binary. The macOS OSD ports drawing logic from upstream's Rust
OSD. Both upstream and this repository use the MIT license. See
[NOTICE.md](NOTICE.md) for details.

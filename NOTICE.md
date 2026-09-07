# Notices

This repository deploys, ports, and extends software from other projects.

## peteonrails/voxtype (MIT)

The core dictation application — daemon, evdev hotkey, whisper/whisper.cpp
transcription pipeline, VAD integration, meeting engine, and OSD frontend —
is [peteonrails/voxtype](https://github.com/peteonrails/voxtype), used
unmodified as a released binary and configured by the installers here.
Its license (MIT) applies to that software; nothing in this repository
modifies it.

Derivations from upstream source, in this repository's original components:

- `macos/osd/voxtype-osd-macos.swift` — the drawing math (envelope
  aggregation, peak-hold decay, meter fraction and zone boundaries) is
  ported from upstream's `src/osd/visual.rs`, and the panel layout approach
  follows `src/bin/voxtype_osd_native/app.rs`. Ported because upstream ships
  no macOS OSD binary; the Swift implementation (frame reader over the
  daemon's socket, state watcher, NSPanel) is original to this repository.
- `macos/loopback/voxtype-loopback-macos.swift` — exists to satisfy the
  contract of upstream's `src/audio/dual_capture.rs`, which shells out to
  `pactl`/`parec` (PATH-resolved) to capture the remote side of a call. The
  shim impersonates those two CLIs on macOS with a CoreAudio process tap;
  upstream's meeting engine runs unmodified behind it.

## Models

The transcription and cleanup models this stack fetches at runtime are
[whisper.cpp's ggml models](https://huggingface.co/ggerganov/whisper.cpp)
and
[unsloth/Qwen3-4B-Instruct-2507-GGUF](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF);
they are not part of this repository and are governed by their own licenses.

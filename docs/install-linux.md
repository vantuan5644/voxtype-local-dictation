# Installing on Linux

The Linux half of the stack: hold **Right Alt**, speak, release, and whisper
transcribes on your GPU, a local Qwen3-4B on llama.cpp cleans the transcript,
and it is typed at the cursor. `linux/install.sh` installs the payload, the
config assertion, and the cleanup server as a systemd user unit. It is
platform-agnostic within Linux (developed and measured on Arch/Omarchy with
Hyprland; the compositor integration at the end is optional).

```sh
./install.sh --dry-run   # review every action
./install.sh             # install for real (idempotent)
./install.sh --uninstall # remove the payload + unit; keeps ~/.config/voxtype and models
```

`LLAMA_DEVICE` pins the llama-server device by its `--list-devices` name
(e.g. `Vulkan0`); `LLAMA_MODEL` overrides the cleanup GGUF path. Both are
baked into the generated unit at install time.

## Prerequisites

1. voxtype itself, which this script does not install:

   ```sh
   omarchy pkg aur add voxtype-bin    # Arch / Omarchy
   # or: cargo install --git https://github.com/peteonrails/voxtype
   ```

2. Membership of the `input` group, since the evdev hotkey reads
   `/dev/input/*` directly:

   ```sh
   sudo usermod -aG input "$USER"   # then log out and back in
   ```

3. llama.cpp with a CPU backend compiled in. See the trap below.

### The llama.cpp trap

Every ggml backend is an *optional* dependency of the ggml package. On Arch,
`pacman -S llama-cpp ggml-vulkan` yields a `llama-server` that lists your GPU
happily and then refuses to load any model at all, at any `-ngl`, with:

```
make_cpu_buft_list: no CPU backend found
```

Install the CPU backend too; it is not optional:

```sh
sudo pacman -S llama-cpp ggml-vulkan ggml-cpu
```

Building from source: `-DGGML_NATIVE=on` plus your GPU backend covers it.

## What the installer does

1. Preflight: reports missing voxtype / llama-server, the `input` group, and
   runs the `VOXTYPE_CONTEXT` name check (see
   [troubleshooting](troubleshooting.md#voxtype_context-is-no-longer-yours)).
2. Payload: `voxtype-cleanup`, `voxtype-meeting`, `voxtype-notify` and
   `voxtype-vocab` into `~/.local/bin`, the shared `vocabulary.conf` into
   `~/.config/voxtype/`, and Silero VAD via `voxtype setup vad` (885 KB, once).
3. The cleanup server: renders `llama-server.service.in` into
   `~/.config/systemd/user/llama-server.service` with the device, model, and
   an enumeration guard substituted, then `daemon-reload` + `enable --now`.
   While the model is missing it installs the unit *not started*, because a
   crash-looping unit helps nobody.
4. Config assertion: the 15 keys this setup owns, `get → compare → set`,
   restarting the daemon only if something moved. Which keys and why each has
   its value: [configuration](configuration.md).
5. Reports: the multi-GB model downloads (never performed) and the optional
   integration snippets.

### Device selection and the enumeration guard

`--device` names a GPU by **enumeration index**, not identity. On a box with
two Vulkan devices (a dedicated GPU plus an APU iGPU), a driver update can
flip their order. llama-server would then come up happily on the slow one, and
the only symptom would be "dictation cleanup got slow". The installer
therefore picks the device now (first Vulkan, then first CUDA, unless
`LLAMA_DEVICE` pins one) and bakes an `ExecStartPre` into the unit asserting
the index still maps to the **vendor** it saw at install time, so a flip
fails loudly instead of quietly.

### The two flags in the unit that are not optional

- `--ctx-size 4096`. llama-server defaults to 0 ("whatever the model was
  trained for"); Qwen3-2507 advertises 262144, which would size a KV cache a
  dictation can never reach. A dictation is capped at roughly 240 tokens by
  `audio.max_duration_secs`.
- `--temp 0`. This is copy-editing under a never-add-a-word rule, so sampling
  entropy is pure downside, and determinism makes the filter's guards
  testable.

## The hotkey, and why Right Alt

voxtype's own evdev hotkey is used rather than a compositor bind, because a
*modifier* cannot be reliably press/release-bound in a compositor. Right Alt
is chosen over voxtype's suggested keys because it is under the left hand's
reach and, critically, is **still a live modifier**: voxtype does not grab it,
so every ALT-bearing keybind also starts a stray push-to-talk recording. VAD
makes those harmless (nothing typed), and `audio.duck_media` turns their
side-effect into a brief dip instead of a pause. Pick a different key with
`voxtype config set hotkey.key <KEY>` if your layout disagrees.

## Meeting mode

Meeting mode records the mic **and** the remote side of a call through a
PipeWire monitor source, transcribes continuously, and splits by speaker.
Nothing is typed anywhere. `voxtype-meeting toggle` wraps it (upstream has
start/stop but no toggle), with `export` and `summarize` subcommands. Summaries
run an ordered backend chain, `codex,claude,local` by default: the hosted CLIs
lead because a whole transcript is a far heavier job than one dictation, and
the `local` link map-reduces over ~2,000-token chunks through the same
llama-server. `local` is only ever valid as the last link, so a local outage
can never escalate a transcript onto the network. The full chain rules are in
[configuration](configuration.md).

Optional triggers, as snippets rather than installs (`linux/integration/`):

- **Hyprland** (`hyprland-bind.lua`): a `SUPER + CTRL + M` bind running
  `voxtype-meeting toggle`. It is written for Omarchy's hyprlua bindings file,
  so copy the line into `~/.config/hypr/bindings.lua`.
- **Omarchy menu** (`omarchy-menu-row.jsonc`): a *Capture → Meeting
  Transcribe* row for `~/.config/omarchy/extensions/omarchy-menu.jsonc`.

## Models

The installer reports and never fetches:

```sh
# cleanup (Q8 on a big GPU; Q4_K_M at ~2.5 GB is the smaller option)
hf download unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q8_0.gguf \
   --local-dir ~/.local/share/models
systemctl --user enable --now llama-server.service

# transcription: pick engine/model/GPU in the TUI (`voxtype configure`);
# a quantised large-v3-turbo (q5_0) is the measured sweet spot
```

## Verifying

```sh
voxtype setup check                          # hotkey attached, input group, VAD
systemctl --user status llama-server         # active, model loaded
printf "um so can you check the uh tailscale status" | voxtype-cleanup
# expect: So can you check the Tailscale status?   (once llama-server is up)
voxtype-meeting start; sleep 5; voxtype-meeting stop
voxtype meeting export latest --speakers     # both a You and a Remote section
```

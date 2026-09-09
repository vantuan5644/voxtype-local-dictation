#!/usr/bin/env bash
#
# Install the voxtype dictation stack on Linux: payload scripts, the config
# assertion, and the llama.cpp cleanup server as a systemd user unit. The
# macOS twin is macos/install.sh; the reasoning behind every asserted value
# is in docs/install-linux.md and docs/configuration.md.
#
#   ./install.sh              install everything, phase by phase
#   ./install.sh --dry-run    show every action, perform none
#   ./install.sh --uninstall  stop/remove the unit and the payload
#
# Phases:
#   1. preflight -- voxtype itself, the input group, llama-server (and the
#      optional-backend trap), the VOXTYPE_CONTEXT name check
#   2. payload into ~/.local/bin + the vocabulary into ~/.config/voxtype,
#      Silero VAD
#   3. llama-server.service rendered from llama-server.service.in -- device,
#      model, and the enumeration-order guard substituted at install time --
#      then daemon-reload + enable
#   4. the config assertion: get -> compare -> set for the keys this setup
#      owns, restart only if something moved
#   5. the multi-gigabyte model downloads, reported and never performed, and
#      the optional compositor/menu integration snippets
#
# Multi-gigabyte downloads (whisper large-v3-turbo ~1.6 GB, the Qwen cleanup
# GGUF ~2.5-4.3 GB) are REPORTED, never fetched -- the same stance
# macos/install.sh takes. `voxtype setup vad` (885 KB, once) is the one
# download performed, because VAD is what makes a stray push-to-talk press
# harmless instead of a typed sentence of echoed prompt.
#
#   LLAMA_DEVICE   pin the llama-server device by its --list-devices name
#                  (e.g. Vulkan0). Default: the first Vulkan device, then
#                  the first CUDA device; none enumerated means CPU.
#   LLAMA_MODEL    path to the cleanup GGUF (default: Qwen3-4B-Instruct-2507
#                  Q4_K_M under ~/.local/share/models -- the same quantisation
#                  the macOS twin defaults to; measured FASTER here than Q8_0,
#                  124 ms against 145 ms at the median, and it edits less).
set -euo pipefail

DRY_RUN=0 UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,/^set /p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown flag: %s (try --dry-run, --uninstall)\n' "$arg" >&2; exit 1 ;;
  esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"
# The repo root: vocabulary.conf and voxtype-vocab sit beside macos/ and
# linux/, shared by both installers. cd -P rather than a lexical ".." because
# a checkout can be reached through a symlink.
ROOT="$(cd -P "$SRC/.." && pwd)"
BIN="$HOME/.local/bin"
CONF_DIR="$HOME/.config/voxtype"
UNITS="$HOME/.config/systemd/user"
MODELS="$HOME/.local/share/models"
LLAMA_MODEL="${LLAMA_MODEL:-$MODELS/Qwen3-4B-Instruct-2507-Q4_K_M.gguf}"
UNIT_NAME=llama-server.service

# voxtype-cleanup and voxtype-meeting sit beside this script in the release
# tree. In the monorepo they are developed one directory over under
# omarchy/files/ -- one source of truth, the release sync copies them in --
# so both locations are tried and the first that has them wins.
if [[ -f $SRC/voxtype-cleanup && -f $SRC/voxtype-meeting ]]; then
  PAYLOAD="$SRC"
else
  PAYLOAD="$(cd -P "$SRC/../../.." && pwd)/omarchy/files/home/local/bin"
fi

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*" >&2; }

# Every mutation goes through one of these so --dry-run is honest.
run() { # run <cmd...>
  if (( DRY_RUN )); then note "[dry] $*"; else "$@"; fi
}
runsh() { # runsh <description> <shell-snippet>
  if (( DRY_RUN )); then note "[dry] $1"; else bash -c "$2"; fi
}

# A path as it should appear INSIDE the unit file, which is not the same
# string as the path this script tests with [[ -f ]]. Two reasons it differs:
#
#   * %h, systemd's own home specifier. The hand-written unit this template
#     replaces used it, and it is worth keeping -- a literal /home/<user>
#     baked into a unit is one more thing to fix when the account moves, and
#     this repo already has hosts whose checkouts live under three different
#     usernames.
#   * %% for a literal percent. systemd reads a bare % as the start of a
#     specifier, so an unescaped one in a model filename would either expand
#     to something unintended or fail the unit at load. Rare, silent, and
#     free to prevent.
unit_path() { # unit_path <absolute-path>  ->  value safe to paste into a unit
  local p=$1 rest
  if [[ $p == "$HOME"/* ]]; then
    rest="${p#"$HOME"/}"
    printf '%%h/%s' "${rest//%/%%}"
  else
    printf '%s' "${p//%/%%}"
  fi
}

# ------------------------------------------------------------- uninstall ---
if (( UNINSTALL )); then
  say "Uninstalling the voxtype dictation payload"
  runsh "stop + disable $UNIT_NAME" "systemctl --user disable --now $UNIT_NAME 2>/dev/null || true"
  run rm -f "$UNITS/$UNIT_NAME"
  runsh "systemctl --user daemon-reload" "systemctl --user daemon-reload"
  run rm -f "$BIN/voxtype-cleanup" "$BIN/voxtype-meeting" "$BIN/voxtype-notify" \
           "$BIN/voxtype-vocab"
  note "Kept: $CONF_DIR (voxtype's own config.toml and the vocabulary),"
  note "$MODELS and any downloaded weights (multi-GB; remove by hand)."
  note "Kept: voxtype itself and its service (this script never installed them)."
  exit 0
fi

# ------------------------------------------------------------ preflight ----
say "Phase 1: preflight"
HAVE_VOXTYPE=0
if command -v voxtype >/dev/null 2>&1; then
  HAVE_VOXTYPE=1
  note "voxtype $(voxtype --version 2>/dev/null || echo '?') on PATH"
else
  # Not fatal: the payload installs regardless and the config phase skips.
  # voxtype is not on GitHub releases as a plain binary for every distro;
  # the AUR package (Arch/Omarchy) or a cargo build from source are the
  # tested routes.
  warn "voxtype is not on PATH; the config assertion will be skipped"
  warn "  Arch/Omarchy: omarchy pkg aur add voxtype-bin   (or yay -S voxtype-bin)"
  warn "  elsewhere:    cargo install --git https://github.com/peteonrails/voxtype"
fi

# The evdev hotkey reads /dev/input/* directly and cannot attach without
# this. `voxtype setup check` reports it too, alongside the modifier-release
# guard that keeps the held key out of the typed text.
if (( HAVE_VOXTYPE )) && ! id -nG | grep -qw input; then
  warn "$USER is not in the 'input' group; the hotkey cannot read the keyboard"
  warn "  sudo usermod -aG input $USER   # then log out and back in"
fi

# Does this voxtype set VOXTYPE_CONTEXT itself?
#
# Newer builds do: src/output/post_process.rs env_remove()s it and then sets
# it to the PREVIOUS dictation's text. voxtype-cleanup therefore reads
# VOXTYPE_CLEANUP_CONTEXT instead, and this warns if a drop-in or shell is
# still exporting the old name -- it would be silently swallowed, and if the
# filter ever read it again the changing value would invalidate the cached
# KV prefix on every dictation ("cleanup got slower", nothing changed).
#
# grep -o and a PREFIX match, not an anchored ^...$ or an exact -x one.
# Rust packs string literals into one blob with no separators, so a name can
# come back glued to its neighbour -- in v1.0.1 this one extracts as
# "VOXTYPE_CONTEXTS", the trailing S belonging to the next literal. An exact
# match misses it, and it was caught only by testing the guard against a
# binary known to be affected.
if (( HAVE_VOXTYPE )) &&
   strings "$(command -v voxtype)" 2>/dev/null | grep -oE 'VOXTYPE_[A-Z_]+' | grep -q '^VOXTYPE_CONTEXT'; then
  note "this voxtype sets VOXTYPE_CONTEXT itself; the filter reads VOXTYPE_CLEANUP_CONTEXT"
  [[ -n ${VOXTYPE_CONTEXT:-} ]] &&
    warn "VOXTYPE_CONTEXT is exported but no longer read; rename it to VOXTYPE_CLEANUP_CONTEXT"
fi

HAVE_LLAMA=0
if command -v llama-server >/dev/null 2>&1; then
  HAVE_LLAMA=1
  LLAMA_BIN="$(command -v llama-server)"
  # Resolved once, here, so the ExecStartPre guard and ExecStart below can
  # never disagree about which binary they mean.
  LLAMA_BIN_UNIT="$(unit_path "$LLAMA_BIN")"
  LLAMA_MODEL_UNIT="$(unit_path "$LLAMA_MODEL")"
  note "llama-server on PATH"
else
  # ggml-cpu is not optional and its absence is not obvious: every ggml
  # backend is an OPTIONAL dependency of the ggml package, so installing
  # llama-cpp + a GPU backend can yield a llama-server that lists GPU devices
  # happily and then refuses to load any model at all, at any -ngl, with
  # "make_cpu_buft_list: no CPU backend found". Install the CPU backend too.
  warn "llama-server not installed; dictation cleanup will pass text through unchanged"
  warn "  Arch: sudo pacman -S llama-cpp ggml-vulkan ggml-cpu   # all three"
  warn "  else:  build llama.cpp with -DGGML_NATIVE=on and your GPU backend"
fi

# --------------------------------------------------------------- payload ---
say "Phase 2: payload scripts + vocabulary"
run mkdir -p "$BIN" "$CONF_DIR"
run install -m 755 "$PAYLOAD/voxtype-cleanup" "$BIN/voxtype-cleanup"
run install -m 755 "$PAYLOAD/voxtype-meeting" "$BIN/voxtype-meeting"
run install -m 755 "$SRC/voxtype-notify" "$BIN/voxtype-notify"
# vocabulary.conf is the one file a technical term is ever typed into, on any
# machine. Both lists that need it are generated from it: whisper.initial_prompt
# in Phase 4, and the "Prefer these spellings" rule in voxtype-cleanup's system
# prompt, which shells out to voxtype-vocab at dictation time. Neither list is
# restated here -- add a term in vocabulary.conf and re-run.
run install -m 755 "$ROOT/voxtype-vocab" "$BIN/voxtype-vocab"
run install -m 644 "$ROOT/vocabulary.conf" "$CONF_DIR/vocabulary.conf"
# The two facts `voxtype-vocab add|edit|apply` needs and the read path never
# does: which vocabulary.conf is the SOURCE (the repo copy -- editing the copy
# installed just above is reverted by the next run), and how to apply it on this
# host. Recorded here rather than hardcoded in voxtype-vocab, which is shared
# with the macOS install and the Omarchy one, each of which applies differently.
runsh "record the vocabulary source + apply command in $CONF_DIR/vocab-source.conf" \
  "printf '%s\n' \
     \"# Written by linux/install.sh. Read (never sourced) by voxtype-vocab's\" \
     '# write path -- see that script'\"'\"'s header. Regenerated on every run.' \
     'VOXTYPE_VOCAB_SOURCE=$ROOT/vocabulary.conf' \
     'VOXTYPE_VOCAB_APPLY=$SRC/install.sh' \
     > '$CONF_DIR/vocab-source.conf' && chmod 644 '$CONF_DIR/vocab-source.conf'"

if (( HAVE_VOXTYPE )); then
  # Silero VAD, needed by vad.backend=whisper below. Without it a near-silent
  # recording still reaches the transcriber, and whisper's failure there is
  # to echo whisper.initial_prompt back as if it had been spoken. Downloads
  # once; a re-run is a no-op.
  run voxtype setup vad || warn "Silero VAD download failed; run: voxtype setup vad"
fi

# ------------------------------------------------------- llama.cpp server ---
say "Phase 3: llama.cpp cleanup server (127.0.0.1:8088)"
if (( HAVE_LLAMA )); then
  # Device selection. --device names by enumeration INDEX, not by identity:
  # a box with two Vulkan devices (dedicated + integrated) can flip their
  # order across a driver update, and llama-server would then come up happily
  # on the slow one with "cleanup got slow" as the only symptom. So the
  # device is picked here AND the unit gets an ExecStartPre guard asserting
  # the index still maps to the vendor seen at install time.
  DEVICE=""
  DEVICE_GUARD=""
  DEVICE_FLAGS=""
  listing="$(llama-server --list-devices 2>/dev/null || true)"
  if [[ -n ${LLAMA_DEVICE:-} ]]; then
    line="$(grep -E "^  ${LLAMA_DEVICE}: " <<<"$listing" | head -1 || true)"
    if [[ -n $line ]]; then
      DEVICE="$LLAMA_DEVICE"
    else
      warn "LLAMA_DEVICE='$LLAMA_DEVICE' is not enumerated by this llama-server; ignoring it"
    fi
  fi
  if [[ -z $DEVICE && -n $listing ]]; then
    line="$(grep -E '^  Vulkan[0-9]+: ' <<<"$listing" | head -1 || true)"
    [[ -n $line ]] || line="$(grep -E '^  CUDA[0-9]+: ' <<<"$listing" | head -1 || true)"
    [[ -n $line ]] && DEVICE="${line%%:*}"; DEVICE="${DEVICE# }"; DEVICE="${DEVICE# }"
  fi
  if [[ -n $DEVICE ]]; then
    # The vendor (first word after "Name: ") is the stable identity an
    # enumeration flip would break; the full description is not (it carries
    # a live temperature).
    vendor="$(grep -E "^  ${DEVICE}: " <<<"$listing" | head -1 | sed -E "s/^  ${DEVICE}: ([A-Za-z0-9]+).*/\1/" || true)"
    if [[ -n $vendor ]]; then
      DEVICE_GUARD="ExecStartPre=/bin/sh -c '$LLAMA_BIN_UNIT --list-devices | grep -q \"^  ${DEVICE}: ${vendor}\" || { echo \"${DEVICE} is no longer the ${vendor} GPU -- enumeration order changed; check llama-server --list-devices\"; exit 1; }'"
    fi
    DEVICE_FLAGS="--device $DEVICE --n-gpu-layers 999"
    note "device: $DEVICE ($vendor), with an ExecStartPre guard against enumeration flips"
  else
    warn "no GPU device enumerated; llama-server will run on the CPU (slow cleanup)"
  fi

  unit="$(cat "$SRC/llama-server.service.in")"
  unit="${unit//__LLAMA_BIN__/$LLAMA_BIN_UNIT}"
  unit="${unit//__LLAMA_MODEL__/$LLAMA_MODEL_UNIT}"
  unit="${unit//__DEVICE_GUARD__/$DEVICE_GUARD}"
  unit="${unit//__DEVICE_FLAGS__/$DEVICE_FLAGS}"
  if (( DRY_RUN )); then
    note "[dry] render $UNITS/$UNIT_NAME from llama-server.service.in"
    note "[dry]   device='$DEVICE' model='$LLAMA_MODEL_UNIT' guard=$([[ -n $DEVICE_GUARD ]] && echo yes || echo no)"
    note "[dry] systemctl --user daemon-reload + enable --now $UNIT_NAME"
  else
    mkdir -p "$UNITS"
    printf '%s\n' "$unit" >"$UNITS/$UNIT_NAME"
    if [[ -f $LLAMA_MODEL ]]; then
      systemctl --user daemon-reload
      systemctl --user enable --now "$UNIT_NAME" 2>/dev/null ||
        warn "could not start $UNIT_NAME; run: systemctl --user status $UNIT_NAME"
    else
      # Install the unit but do not start it: llama-server would exit 1 on
      # the missing model and Restart=on-failure would crash-loop it until
      # the file lands.
      systemctl --user daemon-reload
      note "unit installed but NOT started: the cleanup model is missing (see Phase 5)"
    fi
  fi
else
  note "skipped: no llama-server on PATH (Phase 5 has the install routes)"
fi

# ------------------------------------------------------ config assertion ---
say "Phase 4: voxtype config assertion"
if (( ! HAVE_VOXTYPE )); then
  note "skipped: voxtype is not on PATH"
else
  if (( DRY_RUN )); then
    note "[dry] assert 19 config keys: hotkey, language, VAD, meeting, audio,"
    note "     notifications, initial_prompt, post_process.command"
    note "[dry] meeting keys: loopback_device=auto, echo_cancel=auto,"
    note "     diarization.enabled=true, diarization.backend=simple"
    note "[dry] report-only: output.post_process.timeout_ms"
  else
    # Only the keys this setup owns, get -> compare -> set. voxtype rewrites
    # the whole config.toml on every `config set` and every `configure` save,
    # so a snapshot would revert the engine, model, GPU, and OSD choices made
    # through the TUI later. whisper.model is deliberately absent for that
    # reason.
    #
    # pause_media and the two recording notifications are off on purpose:
    # RIGHTALT is the push-to-talk key and voxtype does not grab it, so it is
    # still a live modifier and stray ALT-bearing chords start recordings VAD
    # then discards -- without this each would also MPRIS-pause the player
    # and post two notifications. osd.enabled and vad.enabled stay ON: the
    # OSD is the only feedback a real dictation is running. duck_media is
    # the replacement for the pause: it lowers other streams instead of
    # stopping them, so music does not bleed into the mic during a real
    # dictation and a stray chord costs a dip-and-recover.
    voxtype_changed=0
    # Built from [misheard] in vocabulary.conf, never restated here -- the
    # whole point of that file is that a term is typed once. Read from the
    # REPO copy, so this does not silently depend on the install above
    # having worked.
    #
    # Only the MIS-HEARD half goes in. An initial_prompt is capped by
    # whisper.cpp and, on near-silent audio, whisper echoes it back as if it
    # had been spoken, so every term here is damage the day VAD misses one.
    # Everything whisper hears correctly and merely mis-SPELLS is fixed
    # after the fact by the cleanup model, which has neither the cap nor
    # the echo risk. See docs/configuration.md.
    VOXTYPE_MISHEARD="$(VOXTYPE_VOCAB_FILE="$ROOT/vocabulary.conf" \
                        "$ROOT/voxtype-vocab" misheard 2>/dev/null || true)"
    VOXTYPE_INITIAL_PROMPT="Technical dictation about software development and AI research. Vocabulary: $VOXTYPE_MISHEARD."
    # A guard, not the cap: whisper.cpp truncates silently, so a list this
    # long is a sign the split has drifted, not that the cap is close.
    (( $(awk -F", " '{print NF}' <<<"$VOXTYPE_MISHEARD") <= 40 )) ||
      warn "[misheard] is over 40 terms; move the ones whisper only mis-SPELLS to [misspelled]"
    pairs=( hotkey.enabled=true hotkey.key=RIGHTALT hotkey.mode=push_to_talk
            whisper.language=en text.filter_filler_words=true
            vad.enabled=true vad.backend=whisper
            meeting.enabled=true
            audio.pause_media=false audio.duck_media=true
            audio.duck_media_volume_percent=10
            output.notification.on_recording_start=false
            output.notification.on_recording_stop=false
            "output.post_process.command=$BIN/voxtype-cleanup" )
    # An unreadable or empty vocabulary file must not blank the prompt whisper
    # is already using: say so and leave the key at whatever it holds.
    if [[ -n $VOXTYPE_MISHEARD ]]; then
      pairs+=( "whisper.initial_prompt=$VOXTYPE_INITIAL_PROMPT" )
    else
      warn "no [misheard] terms readable from vocabulary.conf; leaving whisper.initial_prompt as-is"
    fi
    for pair in "${pairs[@]}"; do
      key="${pair%%=*}"; want="${pair#*=}"
      have="$(voxtype config get "$key" 2>/dev/null || true)"
      if [[ $have == "$want" ]]; then
        note "unchanged  $key"
      elif voxtype config set "$key" "$want" >/dev/null 2>&1; then
        note "set        $key (was ${have:-unset})"
        voxtype_changed=1
      else
        # A newer voxtype could rename or drop the key. Say so and keep
        # going -- the hotkey values below matter more than a clean exit.
        warn "voxtype rejected '$key'; check \`voxtype config schema\` against docs/configuration.md"
      fi
    done
    # The meeting-only keys, asserted the same way and for the same reasons
    # as on the macOS twin, with one extra arm. echo_cancel=auto deliberately
    # stays: a build without the onnx-common feature degrades to
    # transcript-level dedup (the binary says so itself) and an ONNX-enabled
    # one picks GTCRN up with no config change. Keys `config set` rejects
    # fall back to the timeout_ms pattern -- report-only -- except that the
    # grep is of the RESOLVED config rather than config.toml: a settable-
    # looking key like meeting.diarization.backend is readable in the dump
    # and rejected by `config set`, and config.toml carries no
    # [meeting.diarization] section at all, so grepping the FILE would warn
    # on every run about a value that is already correct by default.
    for pair in meeting.audio.loopback_device=auto \
                meeting.audio.echo_cancel=auto \
                meeting.diarization.enabled=true \
                meeting.diarization.backend=simple; do
      key="${pair%%=*}"; want="${pair#*=}"
      have="$(voxtype config get "$key" 2>/dev/null || true)"
      if [[ $have == "$want" ]]; then
        note "unchanged  $key"
      elif voxtype config set "$key" "$want" >/dev/null 2>&1; then
        note "set        $key (was ${have:-unset})"
        voxtype_changed=1
      # A here-string rather than a pipe, and that is load-bearing: `grep -q`
      # exits at its first match and closes the pipe under it, `voxtype
      # config` then dies of SIGPIPE, and `set -o pipefail` turns that into a
      # failed pipeline -- so the arm meant to recognise an already-correct
      # default never fires and warns on every run instead. Reproduced here
      # (exit 141). It is a race on output small enough to fit the pipe
      # buffer, which is why it can look fine for a while.
      elif grep -Eq "^ *${key##*.} *= *\"?${want}\"?$" \
                <<<"$(voxtype config 2>/dev/null || true)"; then
        note "default    $key (not settable; resolved value is already $want)"
      else
        warn "voxtype rejected '$key' and its resolved value is not $want;"
        warn "  add it by hand (see docs/install-linux.md, meeting mode)"
      fi
    done
    # output.post_process.timeout_ms is a real config field but is absent
    # from `voxtype config schema`, so `config set` rejects it and this can
    # only report. It has to stay far longer than voxtype-cleanup's own
    # ceiling (5s on the local backend, 20s on a cloud one): the filter
    # falls back to the raw transcription on every failure path, and voxtype
    # killing it first would lose that guarantee.
    grep -q '^timeout_ms' "$CONF_DIR/config.toml" 2>/dev/null || {
      warn "output.post_process.timeout_ms is unset; add it under [output.post_process]:"
      warn "  timeout_ms = 60000"
    }
    # Every hotkey key is "needs restart" in `voxtype config schema`. A
    # restart reloads the whisper model and would cut off a recording in
    # progress, so only do it when something actually moved -- and only when
    # voxtype runs as the systemd user service this setup knows about.
    if (( voxtype_changed )); then
      if systemctl --user is-active --quiet voxtype.service 2>/dev/null; then
        run systemctl --user restart voxtype
      else
        warn "config changed but voxtype is not running as voxtype.service;"
        warn "  restart the daemon the way you started it"
      fi
    fi
  fi
fi

# ------------------------------------------------------- the big downloads ---
say "Phase 5: model downloads (reported, never performed)"
if [[ ! -f $LLAMA_MODEL ]]; then
  warn "cleanup model missing: $LLAMA_MODEL"
  warn "  hf download unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q4_K_M.gguf \\"
  warn "     --local-dir ~/.local/share/models"
  warn "  (~2.5 GB; Q8_0 at ~4.3 GB was the old default and measured slower)"
  warn "then: systemctl --user enable --now $UNIT_NAME"
else
  note "cleanup model present: $LLAMA_MODEL"
fi
note "whisper model: \`voxtype configure\` (TUI) picks engine/model/GPU; a"
note "  quantised large-v3-turbo (q5_0) is the measured sweet spot -- see"
note "  docs/install-linux.md"
note ""
note "Optional integration (snippets in linux/integration/):"
note "  Hyprland:  SUPER+CTRL+M -> voxtype-meeting toggle   (hyprland-bind.lua)"
note "  Omarchy:   a Capture > Meeting Transcribe menu row  (omarchy-menu-row.jsonc)"
note ""
note "Verify: voxtype setup check"
note "        systemctl --user status $UNIT_NAME"

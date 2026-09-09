#!/usr/bin/env bash
#
# Install the voxtype dictation stack on this Mac: the port of the Linux
# setup in linux/. See docs/install-macos.md for the reasoning and the file
# map, docs/troubleshooting.md for the failure modes.
#
#   ./install.sh              install everything, phase by phase
#   ./install.sh --dry-run    show every action, perform none
#   ./install.sh --with-mlx   also install the MLX benchmark server (8089)
#   ./install.sh --with-osd   also build + install the macOS OSD renderer
#   ./install.sh --with-meeting
#                              also build + install meeting mode: the
#                              pactl/parec loopback shim (voxtype-loopback-
#                              macos), the voxtype-meeting wrapper, Raycast
#                              script commands, the Info.plist patch that
#                              puts the shim on the daemon's PATH
#                              (LSEnvironment) and declares system-audio
#                              recording (NSAudioCaptureUsageDescription),
#                              and the meeting config keys
#   ./install.sh --uninstall  remove agents, scripts, and the app bundle
#
# Phases (numbered after the guide's):
#   1. voxtype v1.0.1 upstream binary, SHA256-verified; a stable self-signed
#      code-signing identity; `voxtype setup app-bundle` (Login Items, NOT a
#      LaunchAgent -- see below); the meeting-mode Info.plist patch BEFORE
#      the re-sign; Silero VAD
#   2. payload scripts into ~/.local/bin + the 14-key config assertion
#      (recording notifications conditional on the OSD) + the OSD build +
#      the meeting-mode payload (shim binary, shim dir, wrapper, Raycast)
#   3. optional macOS OSD renderer (--with-osd): swiftc-compiled
#      voxtype-osd-macos as its own LaunchAgent
#   4. llama.cpp LaunchAgent on 8088 (Metal, Qwen3-4B Q4_K_M)
#   5. optional MLX server on 8089 (--with-mlx; benchmark only)
#
# Two things upstream's own source dictates here, both counter-intuitive:
#
#   * NOT `voxtype setup launchd`. src/setup/launchd.rs prints "LaunchAgent
#     services do not receive Microphone permissions on macOS. Transcription
#     will fail" and points at `setup app-bundle` instead. TCC attributes a
#     request to the *responsible process*, which for a launchd job is
#     launchd, not the bundle. Login Items inherit correctly.
#   * The app bundle is signed with a STABLE self-signed certificate, not
#     ad-hoc. TCC validates against the code's designated requirement; an
#     ad-hoc signature has no stable one, so every upgrade rotates the cdhash
#     and breaks all three grants *while System Settings still shows them
#     ticked*. The certificate makes the requirement cert-anchored instead.
#
# Meeting mode IS supported, via a shim rather than a port: upstream's
# src/audio/dual_capture.rs captures the remote side by spawning `pactl
# list short sources` and `parec --device <src> --format=float32le
# --channels=1 --rate=16000 --raw`, PATH-resolved, with nothing else
# platform-specific in the file. install.sh --with-meeting builds one Swift
# binary (voxtype-loopback-macos) that impersonates both behind symlinks in
# a PRIVATE shim directory, so nothing but the daemon ever resolves to the
# fakes; the real capture is a CoreAudio process tap. The load-bearing half
# is the bundle patch: Login Items give the daemon launchd's minimal PATH
# (LSEnvironment fixes that), and a process tap without
# NSAudioCaptureUsageDescription on the responsible app is starved
# silently by tccd (all-zero / no-callback audio, no error). See the guide,
# "Meeting mode: the loopback shim".
#
# Multi-gigabyte downloads (whisper large-v3-turbo ~1.6 GB, the Qwen GGUF
# ~2.5 GB, the MLX weights ~2.4 GB) are REPORTED, never fetched -- the same
# stance linux/install.sh takes. TCC grants are reported too: they cannot be
# scripted, only clicked.
set -euo pipefail

DRY_RUN=0 UNINSTALL=0 WITH_MLX=0 WITH_OSD=0 WITH_MEETING=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --uninstall)    UNINSTALL=1 ;;
    --with-mlx)     WITH_MLX=1 ;;
    --with-osd)     WITH_OSD=1 ;;
    --with-meeting) WITH_MEETING=1 ;;
    # Range-matched, not a hard-coded line number: the header grows with every
    # phase, and the number was already stale once -- `2,41p` had been dropping
    # the last line of the block, so --help ended mid-sentence. Print to the
    # first `set` line, then drop it.
    -h|--help)      sed -n '2,/^set /p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown flag: %s (try --dry-run, --uninstall, --with-mlx, --with-osd, --with-meeting)\n' "$arg" >&2; exit 1 ;;
  esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
# The dictation vocabulary is shared with the Linux install, one directory
# up: the terms are a property of the person dictating, not of the OS doing the
# transcribing, so there is one copy in the repo and both installers read it.
# linux/install.sh installs these same two files. cd -P rather than a lexical
# ".." because a checkout can be reached through a symlink.
SHARED_VOXTYPE="$(cd -P "$SRC/.." && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
# `voxtype setup app-bundle` hardcodes /Applications/Voxtype.app in
# app_bundle_path(); installing anywhere else makes its own --status and
# --uninstall flags report "not installed".
APP="/Applications/Voxtype.app"
UID_N="$(id -u)"

VOXTYPE_VERSION=1.0.1
VOXTYPE_ARTIFACT="voxtype-$VOXTYPE_VERSION-macos-universal"
# Upstream release, not the Homebrew tap -- the tap is stale (cask 0.7.5,
# formula 0.6.3, and the formula's head branch is deleted) while upstream
# is at v1.0.1. Override for testing against another release.
VOXTYPE_REPO="${VOXTYPE_RELEASE_REPO:-peteonrails/voxtype}"
VOXTYPE_BASE="${VOXTYPE_RELEASE_BASE:-https://github.com/$VOXTYPE_REPO/releases/download/v$VOXTYPE_VERSION}"

# Dock-icon patch (patch_bundle_dock). The address is pinned to the
# VOXTYPE_VERSION above and MUST be re-derived when that moves -- the byte
# check makes a stale address skip the patch instead of corrupting a binary.
VOXTYPE_DOCK_VA=0x354530     # arm64 __TEXT, vmaddr base 0x100000000
VOXTYPE_DOCK_FROM=02a14039   # ldrb w2, [x8, #0x28]  (word 0x3940a102)
VOXTYPE_DOCK_TO=22008052     # mov  w2, #1           (word 0x52800022)

# The signing identity that keeps the TCC grants alive across upgrades. Reused
# if it already exists and NEVER regenerated -- a new certificate breaks every
# grant exactly as ad-hoc signing would.
CERT_CN="${VOXTYPE_SIGNING_IDENTITY:-Voxtype Local Signing}"

LLAMA_LABEL=com.tuantran.llama-server
MLX_LABEL=com.tuantran.mlx-server
OSD_LABEL=com.tuantran.voxtype-osd
OSD_BIN="$BIN/voxtype-osd-macos"
OSD_SRC="$SRC/osd/voxtype-osd-macos.swift"
# Meeting mode: the shim binary, the private directory the daemon's PATH
# sees, the wrapper, and the Raycast script commands.
LOOPBACK_BIN="$BIN/voxtype-loopback-macos"
LOOPBACK_SRC="$SRC/loopback/voxtype-loopback-macos.swift"
SHIM_DIR="$HOME/.local/libexec/voxtype-shims"
RAYCAST_DIR="$HOME/raycast-scripts"
LLAMA_MODEL="$HOME/.local/share/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
# NOT ~/Library/Application Support/voxtype/models, which is what upstream's
# MACOS_TROUBLESHOOTING.md claims. Verified on this machine: voxtype uses the
# same XDG-style path on macOS as on Linux, so the model check has to look
# here or it warns "not fetched" forever.
MODELS_DIR="$HOME/.local/share/voxtype/models"

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*" >&2; }

# run/runsh: every mutation goes through one of these so --dry-run is honest.
run() { # run <cmd...>
  if (( DRY_RUN )); then note "[dry] $*"; else "$@"; fi
}
runsh() { # runsh <description> <shell-snippet>
  if (( DRY_RUN )); then note "[dry] $1"; else bash -c "$2"; fi
}

# A self-signed code-signing certificate, created once and then left alone.
#
# TCC keys a grant to the code's designated requirement. For ad-hoc signed
# code that requirement is a bare cdhash, so rebuilding the bundle -- which
# every voxtype upgrade does -- makes macOS consider it different code. The
# grant does not fail closed and it does not prompt again: the checkbox in
# System Settings stays ticked while the API quietly returns denied. Signing
# with a real certificate makes the requirement anchor on the cert instead,
# and the grant survives.
ensure_signing_identity() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    note "signing identity present: $CERT_CN (reused, never regenerated)"
    return 0
  fi
  if (( DRY_RUN )); then
    note "[dry] create self-signed codesigning certificate '$CERT_CN' in the login keychain"
    return 0
  fi
  local t; t="$(mktemp -d)" err=
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$t/key.pem" -out "$t/cert.pem" -subj "/CN=$CERT_CN" \
    -addext 'basicConstraints=critical,CA:false' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' >/dev/null 2>&1 || {
      rm -rf "$t"; warn "could not generate the signing certificate"; return 1; }

  # -legacy is REQUIRED, and its absence is not obvious.
  #
  # OpenSSL 3 defaults PKCS#12 to AES-256-CBC with a SHA-256 MAC. macOS's
  # Security framework cannot verify that MAC, and the error it reports blames
  # the password rather than the algorithm:
  #
  #   security: SecKeychainItemImport: MAC verification failed during
  #   PKCS12 import (wrong password?)
  #
  # -legacy falls back to the 3DES/SHA-1 encoding `security` accepts. This
  # only bites where Homebrew's openssl precedes /usr/bin/openssl (LibreSSL)
  # on PATH, which is exactly the case on this machine -- so it is pinned
  # here rather than left to whichever openssl wins.
  #
  # The transit password is non-empty for the same reason: an empty one is
  # indistinguishable from the MAC failure above when something does go wrong.
  local p12pass; p12pass="voxtype-transit-$$"
  openssl pkcs12 -export -legacy -out "$t/id.p12" -inkey "$t/key.pem" \
    -in "$t/cert.pem" -passout "pass:$p12pass" >/dev/null 2>&1 || {
      rm -rf "$t"; warn "pkcs12 export failed"; return 1; }
  # -T /usr/bin/codesign pre-authorises codesign against the private key so
  # signing does not raise a keychain prompt on every build.
  err="$(security import "$t/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$p12pass" -T /usr/bin/codesign 2>&1)" || {
      rm -rf "$t"; warn "keychain import failed: $(printf '%s' "$err" | tail -1)"; return 1; }
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$t/cert.pem" >/dev/null 2>&1 ||
    warn "could not mark '$CERT_CN' trusted; macOS may prompt on first sign"
  rm -rf "$t"
  note "created signing identity: $CERT_CN"
}

# Restart the daemon.
#
# NOT `launchctl kickstart`: with the app-bundle/Login Items route there is no
# launchd job to kickstart, and asking for one fails with "Could not find
# service". The daemon is a plain process owned by the login session, so a
# restart is kill-and-relaunch. `open` re-launches through LaunchServices,
# which is what keeps TCC attributing to the bundle.
# The settle loop is not padding: `open` on an app that is still tearing down
# is a no-op that still exits 0, so without it the restart silently leaves
# nothing running -- observed on the first real run of this script.
#
# env -i is load-bearing, measured 2026-09-07: `open -a` propagates the
# caller's environment when there is one, and an inherited PATH BEATS the
# LSEnvironment this script patches into the bundle -- after a restart from
# a terminal the daemon ran without the shim dir on PATH (meetings would
# silently record mic only until the next login). With a clean environment
# Launch Services applies LSEnvironment, which puts the shim dir first;
# HOME/USER/TMPDIR still arrive from the session, only the caller's vars
# are dropped. The at-login launchd launch is the clean-env case by
# construction, so the next login lands the same way.
restart_voxtype() {
  if (( DRY_RUN )); then note "[dry] restart voxtype (pkill + env -i open -a Voxtype)"; return 0; fi
  pkill -x voxtype-bin 2>/dev/null || true
  local i=0
  while pgrep -x voxtype-bin >/dev/null 2>&1 && (( i < 40 )); do sleep 0.1; i=$((i+1)); done
  env -i /usr/bin/open -a "$APP" 2>/dev/null || { warn "could not relaunch Voxtype.app; open it by hand"; return 0; }
  i=0
  while ! pgrep -x voxtype-bin >/dev/null 2>&1 && (( i < 50 )); do sleep 0.1; i=$((i+1)); done
  pgrep -x voxtype-bin >/dev/null 2>&1 ||
    warn "Voxtype.app did not come back up; open it by hand"
}

# Sign inner binary first, then the bundle -- never --deep, which is
# deprecated since macOS 13 and which upstream's own comment admits does not
# hash inner binaries reliably.
sign_bundle() {
  local id="$1"
  run codesign --force --sign "$id" "$APP/Contents/MacOS/voxtype-bin"
  run codesign --force --sign "$id" "$APP"
}

# Patch the app bundle for meeting mode. MUST run after `voxtype setup
# app-bundle` (which rewrites the bundle, ad-hoc signed) and BEFORE
# sign_bundle (which seals Info.plist into the signature). Two keys:
#
#   LSEnvironment.PATH  Login Items launch the daemon with launchd's minimal
#                       PATH, so ~/.local/bin is invisible and `pactl`/
#                       `parec` would never resolve. The shim dir goes FIRST
#                       so it wins even when `open -a` propagated a fuller
#                       inherited PATH (whether LSEnvironment beats an
#                       inherited PATH is undocumented; first position makes
#                       the ordering argument moot when it does).
#   NSAudioCaptureUsageDescription
#                       tccd checks the RESPONSIBLE app -- for a daemon
#                       child, Voxtype.app -- for this key before allowing a
#                       CoreAudio process tap. Without it the refusal is
#                       silent: noErr everywhere, then all-zero (or no)
#                       buffers. Observed in tccd's log as a query against
#                       kTCCServiceAudioCapture.
#
# The PATH value needs the literal home directory (LSEnvironment does no ~
# expansion); that is fine here because the plist is generated, not tracked.
patch_bundle_meeting() {
  local plist="$APP/Contents/Info.plist"
  local path_value="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  if (( DRY_RUN )); then
    note "[dry] plutil -replace LSEnvironment.PATH (shim dir first) in the bundle"
    note "[dry] plutil -replace NSAudioCaptureUsageDescription in the bundle"
    return 0
  fi
  # Merge, not replace: keep any other LSEnvironment entries upstream set.
  if plutil -extract LSEnvironment json -o - "$plist" >/dev/null 2>&1; then
    plutil -replace LSEnvironment.PATH -string "$path_value" "$plist"
  else
    plutil -replace LSEnvironment -json "{\"PATH\":\"$path_value\"}" "$plist"
  fi
  plutil -replace NSAudioCaptureUsageDescription \
    -string 'Voxtype records system audio during meeting transcription.' "$plist"
  plutil -lint "$plist" >/dev/null
  note "patched $plist (LSEnvironment.PATH, NSAudioCaptureUsageDescription)"
}

# Stop the daemon taking a Dock tile. Same ordering rule as
# patch_bundle_meeting: after `voxtype setup app-bundle`, before sign_bundle.
#
# Upstream ALREADY asks for this -- the generated Info.plist carries
# LSUIElement=true -- but the ask is overridden at runtime. voxtype links
# tao 0.32.8 (with tray-icon/muda, for the menu bar item), and tao calls
# -[NSApplication setActivationPolicy:] itself at applicationDidFinishLaunching
# using its builder default, ActivationPolicy::Regular. A policy set from code
# beats LSUIElement, so the tile comes back on every launch. There is no config
# key for it (`voxtype config schema` has none) and 1.0.1 is current, so the
# only local fix is the one instruction that feeds that call:
#
#   0x354530   ldrb w2, [x8, #0x28]   ->   mov w2, #1     # 1 = Accessory
#
# Both the fast path and the lazy sel_registerName path funnel through the same
# w2, so one word covers both. arm64 slice only -- the tile is a desktop
# concern and nothing here runs the x86_64 half.
#
# Safe for the grants, and for the same reason the certificate exists: the
# designated requirement is `identifier "io.voxtype.daemon" and certificate
# leaf = H"..."`, which a changed cdhash does not affect. sign_bundle reseals
# it two blocks below.
#
# No backup is kept: `voxtype setup app-bundle` rewrites the binary from
# $BIN/voxtype, so re-running it (then this script, to restore the identity)
# is the way back to a Dock icon.
#
# RETIRE THIS, do not re-derive it. Upstream PR #554 (ivancis1,
# `macos-fix-dock-icon`) is this same fix in Rust: menubar.rs calling
# set_activation_policy(Accessory) on the event loop before run(). It still
# applies cleanly to dev, and the one red CI job blocking it was an unrelated
# clippy useless-format in src/tui/compositor_bindings.rs that dev has since
# fixed in 71db5a0, so it is a rebase from green. When VOXTYPE_VERSION next
# moves, check the new binary for the fix rather than chasing the address:
#
#   lsappinfo list | grep -A4 '"Voxtype"'   # UIElement on a stock bundle = landed
#
# If it landed, delete this function and its call site.
patch_bundle_dock() {
  local bin="$APP/Contents/MacOS/voxtype-bin" slice cur off
  [[ -f $bin ]] || return 0

  # Derive the fat-slice offset rather than pinning it; a thin arm64 build
  # prints no fat header and correctly falls through to 0.
  slice=$(otool -f -arch arm64 "$bin" 2>/dev/null |
          awk '/cputype 16777228/{f=1} f && /^ *offset /{print $2; exit}')
  off=$(( ${slice:-0} + VOXTYPE_DOCK_VA ))

  cur=$(xxd -s "$off" -l 4 -p "$bin" 2>/dev/null || true)
  case "$cur" in
    "$VOXTYPE_DOCK_TO")
      note "dock patch already applied"; return 0 ;;
    "$VOXTYPE_DOCK_FROM")
      ;;
    *)
      # Not fatal: a Dock icon is cosmetic, and refusing beats writing four
      # bytes into the middle of an unknown instruction.
      warn "dock patch SKIPPED: $bin+$off is '$cur', expected '$VOXTYPE_DOCK_FROM'."
      warn "  voxtype is probably no longer $VOXTYPE_VERSION. FIRST check whether"
      warn "  upstream PR #554 landed and this patch is now dead weight:"
      warn "    lsappinfo list | grep -A4 '\"Voxtype\"'   # UIElement = landed, drop it"
      warn "  Only if it still says Foreground, re-derive the address with:"
      warn "    otool -tvV -arch arm64 '$bin' | grep -B8 'setActivationPolicy'"
      warn "  and update VOXTYPE_DOCK_VA. Voxtype keeps its Dock icon until then."
      return 0 ;;
  esac

  if (( DRY_RUN )); then
    note "[dry] patch $bin+$off: ldrb w2,[x8,#0x28] -> mov w2,#1 (Accessory)"
    return 0
  fi
  printf '\x22\x00\x80\x52' | dd of="$bin" bs=1 seek="$off" conv=notrunc status=none
  note "patched $bin+$off (activation policy -> Accessory, no Dock tile)"
}

# Strip the meeting keys again (--uninstall). Best-effort and self-detecting:
# when neither key is present it returns without re-signing, because an
# unnecessary re-sign would rotate the cdhash for nothing. When a strip does
# happen the bundle is re-signed (a plist edit invalidates the seal), and
# only if the stable identity is still around.
unpatch_bundle_meeting() {
  local plist="$APP/Contents/Info.plist"
  [[ -f $plist ]] || return 0
  if ! plutil -extract LSEnvironment.PATH raw -o - "$plist" >/dev/null 2>&1 &&
     ! plutil -extract NSAudioCaptureUsageDescription raw -o - "$plist" >/dev/null 2>&1; then
    return 0
  fi
  if (( DRY_RUN )); then
    note "[dry] plutil -remove LSEnvironment.PATH + NSAudioCaptureUsageDescription; re-sign"
    return 0
  fi
  plutil -remove LSEnvironment.PATH "$plist" 2>/dev/null || true
  # Drop the dict too when this setup left it empty.
  if [[ $(plutil -extract LSEnvironment json -o - "$plist" 2>/dev/null) == '{}' ]]; then
    plutil -remove LSEnvironment "$plist" 2>/dev/null || true
  fi
  plutil -remove NSAudioCaptureUsageDescription "$plist" 2>/dev/null || true
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    sign_bundle "$CERT_CN"
  fi
}

# Reinstall a LaunchAgent, and PROVE it came back.
#
# bootout is asynchronous: it returns before the job has left the domain, and
# a bootstrap issued into that window fails with "Boostrap failed: 37:
# Operation already in progress". That is not theoretical -- it is what left
# this machine with no OSD after a --with-meeting run (the plist was rewritten
# at 18:29, the job was gone, and the single warn scrolled past unnoticed in a
# five-phase install). So: wait for the service to actually leave the domain,
# retry the bootstrap, and verify afterwards rather than trusting the exit
# code, because a bootstrap can succeed while the job fails to spawn.
install_agent() { # install_agent <template> <label>
  local tpl="$1" label="$2" dst="$LAUNCH_AGENTS/$2.plist"
  if (( DRY_RUN )); then note "[dry] install $dst (from $tpl, __HOME__ expanded)"; return 0; fi
  mkdir -p "$LAUNCH_AGENTS" "$HOME/Library/Logs"
  sed "s|__HOME__|$HOME|g" "$tpl" >"$dst"
  plutil -lint "$dst" >/dev/null

  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  local i=0
  while launchctl print "gui/$UID_N/$label" >/dev/null 2>&1 && (( i < 50 )); do
    sleep 0.1; i=$((i+1))
  done

  local _
  for _ in 1 2 3; do
    if launchctl bootstrap "gui/$UID_N" "$dst" 2>/dev/null; then break; fi
    sleep 0.5
  done

  if launchctl print "gui/$UID_N/$label" >/dev/null 2>&1; then
    note "loaded     $label"
  else
    warn "$label did not load; start it by hand with:"
    warn "  launchctl bootstrap gui/$UID_N $dst"
  fi
}

# ------------------------------------------------------------- uninstall ---
if (( UNINSTALL )); then
  say "Uninstalling the voxtype dictation stack"
  for label in "$LLAMA_LABEL" "$MLX_LABEL" "$OSD_LABEL"; do
    runsh "bootout $label" "launchctl bootout gui/$UID_N/$label 2>/dev/null || true"
  done
  run rm -f "$LAUNCH_AGENTS/$LLAMA_LABEL.plist" "$LAUNCH_AGENTS/$MLX_LABEL.plist" \
           "$LAUNCH_AGENTS/$OSD_LABEL.plist"
  # Removes the Login Item and /Applications/Voxtype.app together.
  # The meeting-key strip and re-sign happen FIRST: after this the bundle is
  # gone. The strip detects its own keys, so a meeting-less install is a
  # no-op here.
  [[ -d $APP ]] && unpatch_bundle_meeting
  if [[ -x "$BIN/voxtype" ]]; then
    runsh "voxtype setup app-bundle --uninstall" \
          "'$BIN/voxtype' setup app-bundle --uninstall || true"
  fi
  run rm -f "$BIN/voxtype" "$BIN/voxtype-cleanup" "$BIN/voxtype-notify" "$BIN/llama-server-run" \
           "$OSD_BIN" "$BIN/.voxtype-osd-macos.tmp" \
           "$LOOPBACK_BIN" "$BIN/.voxtype-loopback-macos.tmp" "$BIN/voxtype-meeting"
  run rm -rf "$SHIM_DIR"
  run rm -f "$RAYCAST_DIR/voxtype-meeting.sh" "$RAYCAST_DIR/voxtype-meeting-status.sh"
  # The OSD is gone, but the notification keys it silenced are not restored
  # by anything above -- say so, or the setup ends up with no feedback.
  note "If the OSD had been installed, the recording notifications are OFF"
  note "now. Restore them with:"
  note "  voxtype config set output.notification.on_recording_start true"
  note "  voxtype config set output.notification.on_recording_stop true"
  note "Kept: ~/.config/voxtype/, $MODELS_DIR, and any downloaded weights"
  note "(multi-GB; remove by hand if you are done with them)."
  note "Kept: the '$CERT_CN' keychain identity -- other things may sign with it."
  note "Drop the TCC grants for good with:"
  note "  tccutil reset Accessibility io.voxtype.daemon"
  note "  tccutil reset ListenEvent   io.voxtype.daemon"
  note "  tccutil reset Microphone    io.voxtype.daemon"
  note "  tccutil reset AudioCapture  io.voxtype.daemon   # system audio (meetings)"
  exit 0
fi

# --------------------------------------------------------------- deps -------
say "Homebrew dependencies"
# formula/binary pairs -- checked by the binary name, installed by formula.
missing=()
while read -r formula binary; do
  if command -v "$binary" >/dev/null 2>&1; then
    note "have $formula"
  else
    missing+=("$formula")
  fi
done <<'EOF'
llama.cpp llama-server
terminal-notifier terminal-notifier
coreutils gtimeout
hf hf
EOF
if (( ${#missing[@]} )); then
  run brew install "${missing[@]}"
else
  note "all formulas present"
fi

# The OSD and the meeting shim are both compiled locally (upstream ships
# neither as a macOS binary), so their only dependency is Swift itself --
# Command Line Tools, not full Xcode. Checked here rather than in Phase 2 so
# a missing toolchain warns once and the rest of the install carries on
# untouched.
#
# NOT `command -v swiftc`. /usr/bin/swiftc exists on every Mac whether or not
# a toolchain is installed -- it is the xcode-select shim
# (`codesign -dv /usr/bin/swiftc` names com.apple.dt.xcode_select.tool-shim-public),
# so `command -v` always succeeds, and INVOKING it without the Command Line
# Tools opens the GUI "install the developer tools" dialog and blocks there.
# Inside a non-interactive install that is a hang, not an error. Ask
# xcode-select and xcrun instead: both fail cleanly when nothing is installed.
HAVE_SWIFT=0
if (( WITH_OSD || WITH_MEETING )); then
  if xcode-select -p >/dev/null 2>&1 && xcrun --show-sdk-path >/dev/null 2>&1; then
    note "have swiftc ($(swiftc --version 2>/dev/null | head -1 | cut -d' ' -f4-))"
    HAVE_SWIFT=1
  else
    warn "Command Line Tools absent; the OSD and meeting phases are skipped and"
    warn "  nothing else changes. Install them, then re-run with --with-osd/--with-meeting:"
    warn "    xcode-select --install"
  fi
fi
HAVE_OSD=0
if (( WITH_OSD && HAVE_SWIFT )); then HAVE_OSD=1; fi
# A plain re-run after an --with-osd install keeps the OSD armed: without
# this check the notification assertion below would strip the OSD's config
# half while the agent still runs.
[[ -f "$LAUNCH_AGENTS/$OSD_LABEL.plist" ]] && HAVE_OSD=1
# Same re-arm for meeting mode: a plain re-run must not silently disable an
# installed feature (flag-off means "not installed", and --uninstall is the
# way to say that).
HAVE_MEETING=0
if (( WITH_MEETING && HAVE_SWIFT )); then HAVE_MEETING=1; fi
[[ -x "$LOOPBACK_BIN" && -d "$SHIM_DIR" ]] && HAVE_MEETING=1

# ------------------------------------------------- phase 1: voxtype itself --
say "Phase 1: voxtype $VOXTYPE_VERSION, signed so the TCC grants survive upgrades"
ensure_signing_identity || warn "continuing without a stable identity; grants will break on upgrade"

# `voxtype setup launchd` is one command away, upstream's own docs suggest it,
# and it leaves a SECOND daemon running beside the Login Item -- the route this
# script exists to avoid (a LaunchAgent daemon never receives Microphone
# permission; whisper then transcribes silence as "Thank you"). Both daemons
# bind /tmp/voxtype/audio.sock in turn, so whichever started last owns the path
# and the OSD renders whichever one that is: the panel would look fine while
# the wrong daemon holds the hotkey. Reported, never removed -- this script did
# not create it.
if [[ -f "$LAUNCH_AGENTS/io.voxtype.daemon.plist" ]]; then
  warn "a 'voxtype setup launchd' agent is installed alongside the Login Item."
  warn "  Two daemons then race for the socket, the state file and the hotkey,"
  warn "  and the launchd one has no Microphone grant. Remove it with:"
  warn "    launchctl bootout gui/$UID_N/io.voxtype.daemon"
  warn "    rm ~/Library/LaunchAgents/io.voxtype.daemon.plist"
fi

if [[ -x "$BIN/voxtype" ]] && "$BIN/voxtype" --version 2>/dev/null | grep -q "$VOXTYPE_VERSION"; then
  note "voxtype $VOXTYPE_VERSION already on PATH; skipping download"
else
  tmp="$(mktemp -d)"
  run curl -fL --progress-bar -o "$tmp/$VOXTYPE_ARTIFACT" "$VOXTYPE_BASE/$VOXTYPE_ARTIFACT"
  run curl -fsSL -o "$tmp/SHA256SUMS-macos.txt" "$VOXTYPE_BASE/SHA256SUMS-macos.txt"
  if (( ! DRY_RUN )); then
    # The v1.0.1 artifact is unsigned and un-notarized, which is exactly why
    # it gets verified against the release's own checksums before anything
    # else happens to it.
    grep " $VOXTYPE_ARTIFACT\$" "$tmp/SHA256SUMS-macos.txt" >"$tmp/checksum" || {
      warn "no checksum entry for $VOXTYPE_ARTIFACT; refusing to install"; exit 1; }
    (cd "$tmp" && shasum -a 256 -c checksum) >/dev/null ||
      { warn "SHA256 mismatch on $VOXTYPE_ARTIFACT; refusing to install"; exit 1; }
    note "SHA256 verified"
    mkdir -p "$BIN"
    install -m 755 "$tmp/$VOXTYPE_ARTIFACT" "$BIN/voxtype"
    xattr -dr com.apple.quarantine "$BIN/voxtype" 2>/dev/null || true
    rm -rf "$tmp"
    note "installed $BIN/voxtype"
  fi
fi

if (( DRY_RUN )); then
  note "[dry] voxtype setup app-bundle   (builds $APP, registers Login Items)"
  if (( HAVE_MEETING )); then
    note "[dry] patch the bundle: LSEnvironment.PATH + NSAudioCaptureUsageDescription"
  fi
  note "[dry] re-sign $APP with '$CERT_CN'"
  if (( HAVE_MEETING )); then
    note "[dry] lsregister -f $APP   (flush cached bundle info)"
    note "[dry] assert the designated requirement names 'certificate leaf'"
  fi
  note "[dry] voxtype setup vad"
else
  [[ -x "$BIN/voxtype" ]] || { warn "install failed: no binary at $BIN/voxtype"; exit 1; }

  # app-bundle, NOT launchd. Upstream's own setup/launchd.rs warns that a
  # LaunchAgent never receives Microphone permission, because TCC attributes
  # to the responsible process (launchd) rather than the bundle. This builds
  # /Applications/Voxtype.app, signs it, and adds it to Login Items -- which
  # do inherit the grants. It also runs `tccutil reset` itself whenever it
  # detects the binary was replaced.
  "$BIN/voxtype" setup app-bundle ||
    warn "voxtype setup app-bundle failed; run it by hand"

  # The bundle upstream just wrote is ad-hoc signed (setup app-bundle re-signs
  # with '-' EVERY run -- something re-running it is why /Applications can
  # drift off the certificate between installs). Detect that now so the
  # one-time consequence can be stated plainly: moving from ad-hoc to the
  # certificate changes the designated requirement, so the existing grants
  # stop matching even though System Settings still shows them ticked. It
  # happens ONCE; after that plist edits and upgrades are covered by the
  # certificate leaf.
  was_adhoc=0
  [[ -d $APP ]] && codesign -dvv "$APP" 2>&1 | grep -q 'Signature=adhoc' && was_adhoc=1

  # The meeting-mode patch must land while the bundle is unsealed by us (the
  # plist edit happens after upstream's ad-hoc sign and before ours), and
  # only when the stable identity exists to seal it again -- an unsealed
  # Info.plist on an ad-hoc bundle breaks its signature outright.
  if [[ -d $APP ]] && (( HAVE_MEETING )) &&
     security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    patch_bundle_meeting
  fi

  # Unconditional, unlike the meeting patch: the Dock tile is not a feature
  # anyone opted into, it is upstream's LSUIElement=true losing to tao. Gated
  # on the identity for the same reason patch_bundle_meeting is -- an edited
  # binary under upstream's ad-hoc signature is a broken bundle unless the
  # sign_bundle below actually runs.
  if [[ -d $APP ]] &&
     security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    patch_bundle_dock
  fi

  # Replace the ad-hoc signature upstream just applied with the stable one.
  # This is the whole reason the certificate exists: without it the next
  # upgrade rotates the cdhash and all three grants silently stop working.
  if [[ -d $APP ]] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    if (( was_adhoc )); then
      warn ""
      warn "  $APP was ad-hoc signed; this run moves it onto '$CERT_CN'."
      warn "  ONE-TIME consequence: re-tick Microphone, Input Monitoring and"
      warn "  Accessibility for Voxtype in System Settings after this install --"
      warn "  the old grants match the old cdhash and will not carry over, while"
      warn "  still LOOKING ticked. With --with-meeting, also expect the System"
      warn "  Audio Recording prompt on the first meeting start (it fires at"
      warn "  AudioDeviceStart, not now)."
      warn ""
    fi
    sign_bundle "$CERT_CN"
    note "re-signed $APP with $CERT_CN"
    # Launch Services caches bundle metadata; without this flush an
    # LSEnvironment added after the bundle's first registration can be
    # ignored until the next login.
    if (( HAVE_MEETING )); then
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$APP" >/dev/null 2>&1 || warn "lsregister -f failed; log out and back in once"
    fi
    # The whole point of the certificate is a stable designated requirement;
    # if the DR does not name the leaf, every grant will churn on the next
    # upgrade exactly as ad-hoc signing does. Fail the install rather than
    # leave that state silently in place.
    if ! codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf'; then
      warn "codesign -d -r- $APP does not name 'certificate leaf' --"
      warn "the identity did not take. Reset and re-grant after fixing:"
      warn "  tccutil reset Accessibility io.voxtype.daemon"
      warn "  tccutil reset ListenEvent   io.voxtype.daemon"
      warn "  tccutil reset Microphone    io.voxtype.daemon"
      exit 1
    fi
    # The running process still carries the old signature; relaunch so the
    # identity TCC sees is the one that will persist.
    restart_voxtype
  fi

  # Silero VAD: without it a near-silent recording reaches whisper, whose
  # failure there is to echo whisper.initial_prompt back as if spoken.
  "$BIN/voxtype" setup vad || warn "Silero VAD download failed; run: voxtype setup vad"
fi

# compgen -G rather than `ls | grep`: same match, no fork, and filenames with
# spaces stay whole.
if [[ -d $MODELS_DIR ]] && [[ -n $(compgen -G "$MODELS_DIR/*large-v3-turbo*" 2>/dev/null) ]]; then
  note "whisper transcription model present under ~/.local/share/voxtype/models"
else
  # whisper.model is deliberately NOT asserted -- voxtype owns config.toml and
  # rewrites it whole, so a model chosen through the TUI later must survive a
  # re-run. Same reason linux/install.sh leaves it alone. Reported
  # instead, with the measured recommendation.
  warn "no transcription model fetched (deliberately -- large downloads are reported here)"
  warn "  expected under: $MODELS_DIR"
  warn ""
  warn "  Recommended on this hardware: large-v3-turbo Q5_0. Measured indistinguishable"
  warn "  from the f16 turbo across three test clips at 40% of the memory (547 MB vs"
  warn "  1.5 GB) and ~15% less latency. It is a quantised variant, so"
  warn "  \`voxtype setup --download\` does not know the name -- fetch it directly and"
  warn "  point whisper.model at the file:"
  warn "    curl -fL -o \"$MODELS_DIR/ggml-large-v3-turbo-q5_0.bin\" \\"
  warn "      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
  warn "    voxtype config set whisper.model \"$MODELS_DIR/ggml-large-v3-turbo-q5_0.bin\""
  warn ""
  warn "  For lower latency at some accuracy risk on real speech: small.en"
  warn "    voxtype setup --download --model small.en && voxtype config set whisper.model small.en"
fi

# ------------------------------------- phase 2: payload + config assertion --
say "Phase 2: payload scripts + config assertion"
for f in voxtype-cleanup voxtype-notify llama-server-run; do
  run install -m 755 "$SRC/$f" "$BIN/$f"
done
# vocabulary.conf is the one file a technical term is ever typed into, on any
# machine. Both lists that need it are generated from it: whisper.initial_prompt
# below, and the "Prefer these spellings" rule in voxtype-cleanup's system
# prompt, which shells out to voxtype-vocab at dictation time. Neither list is
# restated here -- add a term in scripts/voxtype/vocabulary.conf and re-run.
run install -m 755 "$SHARED_VOXTYPE/voxtype-vocab" "$BIN/voxtype-vocab"
runsh "install vocabulary.conf into ~/.config/voxtype" \
  "mkdir -p '$HOME/.config/voxtype' && install -m 644 '$SHARED_VOXTYPE/vocabulary.conf' '$HOME/.config/voxtype/vocabulary.conf'"
# The two facts `voxtype-vocab add|edit|apply` needs and the read path never
# does: which vocabulary.conf is the SOURCE (the repo copy -- editing the copy
# installed just above is reverted by the next run), and how to apply it on this
# host. Recorded here rather than hardcoded in voxtype-vocab, which is shared
# with the Linux install and the Omarchy one, each of which applies differently.
# No flags recorded: Phase 1 skips the download when the version already matches
# and the builds skip when up to date, so a plain re-run is the cheap path, and
# --with-osd/--with-meeting work already installed are left alone rather than
# undone.
runsh "record the vocabulary source + apply command in ~/.config/voxtype/vocab-source.conf" \
  "printf '%s\n' \
     \"# Written by macos/install.sh. Read (never sourced) by voxtype-vocab's\" \
     '# write path -- see that script'\"'\"'s header. Regenerated on every run.' \
     'VOXTYPE_VOCAB_SOURCE=$SHARED_VOXTYPE/vocabulary.conf' \
     'VOXTYPE_VOCAB_APPLY=$SRC/install.sh' \
     > '$HOME/.config/voxtype/vocab-source.conf' && chmod 644 '$HOME/.config/voxtype/vocab-source.conf'"

# Build the OSD before the config loop, so the notification decision below
# reflects a binary that actually exists. Compiled to a temp name and moved
# over with install(1) rather than letting `swiftc -o` write the destination
# directly: macOS refuses a write to a running executable (ETXTBSY), and
# install(1) unlinks first, so a running agent keeps its old inode until
# Phase 3 bootstraps the new one. --dry-run never compiles (run() is a no-op
# there) and no artifact ever lands in the working tree.
if (( HAVE_OSD )); then
  if [[ ! -x $OSD_BIN || $OSD_SRC -nt $OSD_BIN ]]; then
    run mkdir -p "$BIN"
    run swiftc -O -whole-module-optimization -o "$BIN/.voxtype-osd-macos.tmp" "$OSD_SRC"
    run install -m 755 "$BIN/.voxtype-osd-macos.tmp" "$OSD_BIN"
    run rm -f "$BIN/.voxtype-osd-macos.tmp"
  else
    note "voxtype-osd-macos up to date ($OSD_BIN); skipping compile"
  fi
fi

# Meeting-mode payload: the shim binary, the private shim dir with the
# pactl/parec symlinks, the wrapper, and the Raycast script commands. Same
# compile contract as the OSD block above (temp name + install(1), never
# swiftc straight at a possibly-running binary), plus two flags of its own:
#   -swift-version 5   the realtime IOProc block captures mutable state,
#                      which Swift 6 mode rejects
#   -target arm64-apple-macos14.2
#                      process taps are a macOS 14.2 API; this keeps the
#                      binary runnable on anything newer (this machine's
#                      toolchain defaults to a 26 deployment target)
if (( HAVE_MEETING )); then
  if [[ ! -x $LOOPBACK_BIN || $LOOPBACK_SRC -nt $LOOPBACK_BIN ]]; then
    run mkdir -p "$BIN"
    run swiftc -O -swift-version 5 -target arm64-apple-macos14.2 \
      -o "$BIN/.voxtype-loopback-macos.tmp" "$LOOPBACK_SRC"
    run install -m 755 "$BIN/.voxtype-loopback-macos.tmp" "$LOOPBACK_BIN"
    run rm -f "$BIN/.voxtype-loopback-macos.tmp"
  else
    note "voxtype-loopback-macos up to date ($LOOPBACK_BIN); skipping compile"
  fi
  # PRIVATE directory: the fake pactl/parec resolve only on the daemon's
  # PATH (via LSEnvironment), never in an interactive shell, so a real
  # PulseAudio install can never be shadowed for anything but the daemon.
  runsh "create $SHIM_DIR with the pactl + parec symlinks" \
    "mkdir -p '$SHIM_DIR' && ln -sfn '../../bin/voxtype-loopback-macos' '$SHIM_DIR/pactl' && ln -sfn '../../bin/voxtype-loopback-macos' '$SHIM_DIR/parec'"
  run install -m 755 "$SRC/voxtype-meeting" "$BIN/voxtype-meeting"
  runsh "install the Raycast script commands into $RAYCAST_DIR" \
    "mkdir -p '$RAYCAST_DIR' && install -m 755 '$SRC/raycast/voxtype-meeting.sh' '$RAYCAST_DIR/voxtype-meeting.sh' && install -m 755 '$SRC/raycast/voxtype-meeting-status.sh' '$RAYCAST_DIR/voxtype-meeting-status.sh'"
fi

if ! command -v "$BIN/voxtype" >/dev/null 2>&1 && ! command -v voxtype >/dev/null 2>&1; then
  warn "voxtype binary not available; skipping the config assertion"
else
  # The recording notifications are the OSD's complement: with a live panel
  # drawing the waveform they are redundant, so they go OFF on the --with-osd
  # path and ON otherwise (where they are the only recording feedback left,
  # menu bar helper aside).
  notif=true
  (( HAVE_OSD )) && notif=false
  if (( DRY_RUN )); then
    note "[dry] assert 14 config keys (18 with --with-meeting): hotkey, language,"
    note "     VAD, meeting, audio, osd, initial_prompt, post_process.command"
    note "[dry] recording notifications: $notif"
    note "[dry] report-only: output.post_process.timeout_ms"
    if (( HAVE_OSD )); then note "[dry] report-only: state_file (the OSD reads it)"; fi
    if (( HAVE_MEETING )); then
      note "[dry] meeting keys: loopback_device=auto, echo_cancel=auto,"
      note "     diarization.enabled=true, diarization.backend=simple"
    fi
  else
    # Only the keys this setup owns, get -> compare -> set. voxtype rewrites
    # the whole config.toml on every `config set` and every `configure` save,
    # so a snapshot would revert the engine, model, GPU, and OSD choices made
    # through the TUI later. whisper.model is deliberately absent for the
    # same reason; output.post_process.timeout_ms is rejected by `config set`
    # and report-only below.
    voxtype_changed=0
    # Built from [misheard] in vocabulary.conf, never restated here -- the whole
    # point of that file is that a term is typed once, for every machine. Read
    # from the REPO copy, so this does not silently depend on the install above
    # having worked.
    #
    # Only the MIS-HEARD half goes in. An initial_prompt is capped by whisper.cpp
    # and, on near-silent audio, whisper echoes it back as if it had been spoken,
    # so every term here is damage the day VAD misses one. Everything whisper
    # hears correctly and merely mis-SPELLS is fixed after the fact by the
    # cleanup model, which has neither the cap nor the echo risk. See the guide.
    VOXTYPE_MISHEARD="$(VOXTYPE_VOCAB_FILE="$SHARED_VOXTYPE/vocabulary.conf" \
                        "$SHARED_VOXTYPE/voxtype-vocab" misheard 2>/dev/null || true)"
    VOXTYPE_INITIAL_PROMPT="Technical dictation about software development and AI research. Vocabulary: $VOXTYPE_MISHEARD."
    # A guard, not the cap: whisper.cpp truncates silently, so a list this long is
    # a sign the split has drifted, not that the cap is close. awk rather than
    # `grep -c` because grep exits 1 on no match and this runs under pipefail.
    (( $(awk -F", " '{print NF}' <<<"$VOXTYPE_MISHEARD") <= 40 )) ||
      warn "[misheard] is over 40 terms; move the ones whisper only mis-SPELLS to [misspelled]"
    # osd.enabled stays FALSE even on the --with-osd path. On macOS it means
    # "the daemon must not spawn a frontend", not "there is no OSD": the
    # daemon's supervisor resolves the child as a sibling of its own
    # executable (inside the sealed app bundle, where an extra file breaks
    # the code signature the TCC grants anchor on) or on its PATH (which
    # under Login Items excludes ~/.local/bin). The macOS OSD therefore
    # runs as its own LaunchAgent (Phase 3), reading the same
    # /tmp/voxtype/audio.sock feed the daemon binds unconditionally.
    #
    # The recording notifications are that renderer's complement, per the
    # $notif computation above: OFF with the panel (redundant noise), ON
    # without it. doc 20 mutes them because stray ALT-chords fired them
    # constantly; the FN hotkey has no stray chords, so that reason does not
    # transfer -- the panel-or-notifications pairing does.
    #
    # hotkey.key is FN (Globe), not the RIGHTALT default: it is free on this
    # machine (AppleFnUsageType unset, input switching on Cmd+Shift) and is
    # not a chord modifier, so no keypress while held can close or quit a
    # window. RIGHTMETA was considered and rejected for exactly that -- see
    # the guide's "Why fn, and why not both".
    #
    # Two values change *meaning* on macOS and are kept deliberately:
    # pause_media=false was about stray ALT-chords MPRIS-pausing Spotify --
    # MPRIS and the stray chords do not exist here -- but the reason to want
    # pausing (music bleeding into the mic) is unchanged, and duck_media
    # remains the better lever.
    #
    # meeting.enabled follows the flag (default false). With the shim in
    # place it is true and meeting mode works; without it, leaving it true
    # would offer a feature that silently records only your own half of the
    # call -- failing loudly beats a half-transcript nobody notices, which
    # is also why voxtype-meeting refuses to start without the shim.
    meeting_enabled=false
    (( HAVE_MEETING )) && meeting_enabled=true
    pairs=( hotkey.enabled=true hotkey.key=FN hotkey.mode=push_to_talk
            whisper.language=en text.filter_filler_words=true
            vad.enabled=true vad.backend=whisper
            "meeting.enabled=$meeting_enabled"
            audio.pause_media=false
            osd.enabled=false
            "output.notification.on_recording_start=$notif"
            "output.notification.on_recording_stop=$notif"
            "output.post_process.command=$BIN/voxtype-cleanup" )
    # An unreadable or empty vocabulary file must not blank the prompt whisper is
    # already using: say so and leave the key at whatever it holds. Without this
    # the loop would happily "set" a bare sentence with no vocabulary in it,
    # which reads as success.
    if [[ -n $VOXTYPE_MISHEARD ]]; then
      pairs+=( "whisper.initial_prompt=$VOXTYPE_INITIAL_PROMPT" )
    else
      warn "no [misheard] terms readable from vocabulary.conf; leaving whisper.initial_prompt as-is"
    fi
    for pair in "${pairs[@]}"; do
      key="${pair%%=*}"; want="${pair#*=}"
      have="$("$BIN/voxtype" config get "$key" 2>/dev/null || true)"
      if [[ $have == "$want" ]]; then
        note "unchanged  $key"
      elif "$BIN/voxtype" config set "$key" "$want" >/dev/null 2>&1; then
        note "set        $key (was ${have:-unset})"
        voxtype_changed=1
      else
        warn "voxtype rejected '$key'; check \`voxtype config schema\` against the guide"
      fi
    done
    if (( HAVE_MEETING )); then
      # The meeting-only keys. echo_cancel=auto deliberately stays: this
      # build lacks the onnx-common feature, so it degrades to transcript-
      # level dedup (the binary says so itself), and a future ONNX-enabled
      # build picks GTCRN up with no config change. Keys `config set`
      # rejects fall back to the timeout_ms pattern: report-only, with a
      # grep of the file voxtype actually reads.
      for pair in meeting.audio.loopback_device=auto \
                  meeting.audio.echo_cancel=auto \
                  meeting.diarization.enabled=true \
                  meeting.diarization.backend=simple; do
        key="${pair%%=*}"; want="${pair#*=}"
        have="$("$BIN/voxtype" config get "$key" 2>/dev/null || true)"
        if [[ $have == "$want" ]]; then
          note "unchanged  $key"
        elif "$BIN/voxtype" config set "$key" "$want" >/dev/null 2>&1; then
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
                  <<<"$("$BIN/voxtype" config 2>/dev/null || true)"; then
          # Not every schema key is settable: meeting.diarization.backend is
          # readable in the resolved dump and rejected by both `config get`
          # and `config set`. Checking the RESOLVED config rather than
          # config.toml is what makes that case quiet -- the file carries no
          # [meeting.diarization] section at all, so a grep of it warns on
          # every run about a value that is already correct by default.
          note "default    $key (not settable; resolved value is already $want)"
        else
          warn "voxtype rejected '$key' and its resolved value is not $want;"
          warn "  add it by hand (see the guide's meeting-mode config block)"
        fi
      done
    fi
    grep -q '^timeout_ms' "$HOME/.config/voxtype/config.toml" 2>/dev/null || {
      warn "output.post_process.timeout_ms is unset; add it under [output.post_process]:"
      warn "  timeout_ms = 60000"
    }
    # `voxtype config get state_file` errors with *unknown config key*, so
    # this is report-only too -- grep the config for it instead. The OSD's
    # transcribing state reads that file; without it the panel degrades to
    # upstream's plain 0.5 s teardown.
    if (( HAVE_OSD )) && ! grep -q '^state_file' "$HOME/.config/voxtype/config.toml" 2>/dev/null; then
      warn "state_file is unset; the OSD needs it for the transcribing state."
      warn "  Add at the top of ~/.config/voxtype/config.toml: state_file = \"auto\""
    fi
    # A restart reloads the whisper model and would cut off a recording in
    # progress, so only do it when something actually moved.
    if (( voxtype_changed )); then
      restart_voxtype
    fi
  fi
fi

# ------------------------------------------------- phase 3: macOS OSD ----
if (( HAVE_OSD )); then
  say "Phase 3: macOS OSD renderer (voxtype-osd-macos LaunchAgent)"
  # In --dry-run the binary "will exist" after Phase 2's build, so skip the
  # -x check there rather than warning about a file a dry run never wrote.
  if (( DRY_RUN )) || [[ -x $OSD_BIN ]]; then
    # install_agent bootouts then bootstraps, so a binary rebuilt in Phase 2
    # is picked up here without a separate kickstart.
    install_agent "$SRC/osd/com.tuantran.voxtype-osd.plist" "$OSD_LABEL"
    if (( ! DRY_RUN )) && ! launchctl print "gui/$UID_N/$OSD_LABEL" >/dev/null 2>&1; then
      # This path leaves the setup with NEITHER feedback channel: the
      # notifications were turned off in Phase 2 and no panel is running.
      warn "the OSD agent did not come up; check ~/Library/Logs/voxtype-osd.log"
      warn "and either fix it (launchctl bootstrap gui/$UID_N $LAUNCH_AGENTS/$OSD_LABEL.plist)"
      warn "or put the recording notifications back:"
      warn "  voxtype config set output.notification.on_recording_start true"
      warn "  voxtype config set output.notification.on_recording_stop true"
    fi
  else
    warn "voxtype-osd-macos missing from $BIN; agent not installed"
  fi
fi

# ------------------------------------------------- phase 4: llama.cpp/Metal --
say "Phase 4: llama.cpp on Metal (127.0.0.1:8088)"
if ! command -v llama-server >/dev/null 2>&1; then
  warn "llama-server still not on PATH (brew install llama.cpp above should have"
  warn "provided it); until it is, cleanup passes text through unchanged (~9 ms)"
fi
if [[ -f $LLAMA_MODEL ]]; then
  install_agent "$SRC/com.tuantran.llama-server.plist" "$LLAMA_LABEL"
else
  # Install the plist but do not start it: llama-server-run would exit 1 on
  # the missing model and KeepAlive would crash-loop it until the file lands.
  if (( DRY_RUN )); then
    note "[dry] install $LLAMA_LABEL plist (not started: model missing)"
  else
    mkdir -p "$LAUNCH_AGENTS" "$HOME/Library/Logs"
    sed "s|__HOME__|$HOME|g" "$SRC/com.tuantran.llama-server.plist" \
      >"$LAUNCH_AGENTS/$LLAMA_LABEL.plist"
    plutil -lint "$LAUNCH_AGENTS/$LLAMA_LABEL.plist" >/dev/null
  fi
  warn "Qwen3-4B Q4_K_M not fetched (reported, not performed -- multi-GB):"
  warn "  hf download unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q4_K_M.gguf \\"
  warn "     --local-dir ~/.local/share/models"
  warn "then start the agent:"
  warn "  launchctl bootstrap gui/$UID_N $LAUNCH_AGENTS/$LLAMA_LABEL.plist"
fi

# --------------------------------------------------- phase 5: MLX optional --
if (( WITH_MLX )); then
  say "Phase 5: MLX benchmark server (127.0.0.1:8089)"
  if command -v uv >/dev/null 2>&1; then
    runsh "uv tool install mlx-lm" "uv tool install mlx-lm"
    install_agent "$SRC/com.tuantran.mlx-server.plist" "$MLX_LABEL"
    note "first start downloads mlx-community/Qwen3-4B-Instruct-2507-4bit (~2.4 GB)"
    note "into ~/.cache/huggingface; watch $HOME/Library/Logs/voxtype-mlx-server.log"
    note "reach it through the filter's openai arm:"
    note "  VOXTYPE_CLEANUP_BACKEND=openai VOXTYPE_CLEANUP_ENDPOINT=http://127.0.0.1:8089"
    note "measure both with: $SRC/bench-cleanup.sh"
  else
    warn "uv not installed (brew install uv); MLX phase skipped"
  fi
fi

# ------------------------------------------------------------- the grants ---
say "Manual steps (cannot be scripted)"
note "1. TCC grants -- System Settings > Privacy & Security, add Voxtype to:"
note "     Microphone        (recording)"
note "     Input Monitoring  (the fn / Globe push-to-talk hotkey)"
note "     Accessibility     (typing the result at the cursor)"
note "   Grant them when first prompted, or pre-grant via the lists above."
note "   Accessibility does NOT auto-prompt for a background process; add it"
note "   with the '+' button."
note "2. If a grant looks ticked but does not work, the code identity moved."
note "   Reset per service (the Input Monitoring service is ListenEvent, not"
note "   InputMonitoring), then re-grant:"
note "     tccutil reset Accessibility io.voxtype.daemon"
note "     tccutil reset ListenEvent   io.voxtype.daemon"
note "     tccutil reset Microphone    io.voxtype.daemon"
note "   With '$CERT_CN' in place this should stop happening on upgrades."
note "3. Log out and back in once, so the Login Item starts the daemon the way"
note "   it will every day. Running it from a terminal grants TCC to the"
note "   terminal instead, which is the failure this whole setup avoids."
if (( HAVE_MEETING )); then
  note "4. Meeting mode adds one more grant, System Audio Recording. It prompts"
  note "   itself on the first meeting start (at AudioDeviceStart) -- not now."
  note "   Test it with a REAL meeting while audio plays, and check the"
  note "   export has both a You and a Remote section:"
  note "     voxtype-meeting start; voxtype-meeting stop"
  note "     voxtype meeting export latest --speakers"
  note "   Do NOT judge it by running the shim from a terminal:"
  note "     $BIN/voxtype-loopback-macos --self-test"
  note "   reports the tap's health, but a terminal is not an app declaring"
  note "   NSAudioCaptureUsageDescription (Ghostty does not), so there the"
  note "   capture is refused silently and the self-test fails no matter what"
  note "   the daemon can do. The tcc service is AudioCapture (verified):"
  note "     tccutil reset AudioCapture io.voxtype.daemon"
  note "   Raycast: the script commands land in $RAYCAST_DIR; assign the hotkey"
  note "   in Raycast's UI (suggested: ctrl-opt-cmd-M; no fn involvement)."
fi
note ""
if (( HAVE_MEETING )) && ! (( DRY_RUN )); then
  # The PATH guard: LSEnvironment only matters if the daemon actually carries
  # it. Two launch paths exist and both matter -- `open -a` from a terminal
  # propagates the caller's full environment (which is how the CURRENT"
  # daemon got Ghostty's PATH), and the at-login launch gets launchd's"
  # minimal one. Whether LSEnvironment beats an inherited PATH is"
  # undocumented, so check rather than assume, and always after a real"
  # log-out/log-in (the guide's Verification step 3) before trusting it.
  dpid="$(pgrep -x voxtype-bin | head -1 || true)"
  if [[ -n $dpid ]]; then
    if ps -wwE -o command -p "$dpid" 2>/dev/null | grep -q "PATH=$SHIM_DIR:"; then
      note "daemon PATH carries $SHIM_DIR first -- the shim will resolve"
    else
      warn "the running daemon's PATH does not start with $SHIM_DIR."
      warn "  An inherited environment beats LSEnvironment (measured): if the"
      # Single quotes, not backticks: backticks inside double quotes EXECUTE, and
      # this line used to run a stray `open -a` every time it printed.
      warn "  daemon was started by a plain 'open -a' from a terminal, its PATH"
      warn "  won. Restart it the way this script now does, or log out/in:"
      warn "    pkill -x voxtype-bin; env -i /usr/bin/open -a Voxtype"
      warn "  If the login-time launch STILL lacks it, the documented fallback:"
      warn "    sudo launchctl config user path $SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
      warn "  (needs a reboot, and widens PATH for every user-domain job --"
      warn "  which is why it is not installed by default)"
    fi
  fi
fi
note "Verify: codesign -d -r- $APP     # must name the cert, not a bare cdhash"
note "        $BIN/voxtype setup app-bundle --status"
note "        $BIN/voxtype setup check"
note "        grep -i hotkey ~/Library/Logs/voxtype/stdout.log | tail -5"

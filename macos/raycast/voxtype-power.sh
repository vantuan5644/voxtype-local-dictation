#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Voxtype Power
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 󰐥
# @raycast.packageName Voxtype
# @raycast.description Turn voxtype (daemon, llama-server, OSD) off to free its memory, or back on without changing what starts at login.

# Decides on the app alone: running means turn off, anything else means turn
# on, which also repairs a half-started stack. The toggle never passes
# --persist, so from here voxtype can only stop starting at login, never
# resume it; `voxtype-power on --persist` in a terminal does that. A refusal
# (dictation or meeting in flight) becomes the HUD line, and nothing changes.

POWER="$HOME/.local/bin/voxtype-power"

if [[ ! -x $POWER ]]; then
  echo "⚠️ voxtype-power not installed — run macos/install.sh from the voxtype-local-dictation checkout"
  exit 1
fi

if pgrep -x voxtype-bin >/dev/null 2>&1; then
  action=off
else
  action=on
fi

if err="$("$POWER" "$action" 2>&1 >/dev/null)"; then
  case "$action" in
    off) echo "󰐥 Voxtype off — stays off at login" ;;
    on)  echo "󰐥 Voxtype on" ;;
  esac
else
  echo "⚠️ $(printf '%s\n' "$err" | tail -1 | sed 's/^voxtype-power: //')"
  exit 1
fi

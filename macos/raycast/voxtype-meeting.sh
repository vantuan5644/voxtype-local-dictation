#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Meeting Transcribe
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 󰑊
# @raycast.packageName Voxtype
# @raycast.description Toggle voxtype meeting transcription: mic + system audio, speaker-split transcript. Assign a hotkey (suggested: ctrl-opt-cmd-M).

# Runs the toggle and echoes the resulting state as the HUD line. The
# notifications (start/stop/mic-only tripwire) come from voxtype-meeting
# itself via voxtype-notify; this script only needs to not lie about the
# outcome. `toggle` is correct whatever the previous state was, which is the
# whole reason the wrapper exists -- `voxtype meeting` has start/stop but no
# toggle.

MEETING="$HOME/.local/bin/voxtype-meeting"

if [[ ! -x $MEETING ]]; then
  echo "⚠️ voxtype-meeting not installed — run macos/install.sh --with-meeting from the voxtype-local-dictation checkout"
  exit 1
fi

before="$("$MEETING" status 2>/dev/null || echo idle)"
"$MEETING" toggle >/dev/null 2>&1 || true
# `meeting status` lags `meeting start` by about a second; the wrapper's
# notifications are immediate and authoritative, so a short settle here only
# makes the HUD line agree with them.
sleep 1.2
after="$("$MEETING" status 2>/dev/null || echo idle)"

case "$after" in
  recording) echo "󰑊 Recording — mic + system audio" ;;
  paused)    echo "󰏤 Paused" ;;
  *)         if [[ $before == recording || $before == paused ]]; then
               echo "󰄬 Saved — voxtype-meeting summarize latest"
             else
               echo "⚠️ Meeting did not start — check the notification"
             fi ;;
esac

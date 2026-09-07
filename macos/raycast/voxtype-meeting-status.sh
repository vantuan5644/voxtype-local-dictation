#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Meeting Status
# @raycast.mode inline
# @raycast.refreshTime 10s

# Optional parameters:
# @raycast.icon 󰑊
# @raycast.packageName Voxtype
# @raycast.description Show whether voxtype meeting transcription is running

# Fails toward "idle": an unrecognised output, a stopped daemon or a missing
# wrapper leaves the row plain, and the toggle script then tries to start a
# meeting -- the harmless direction (a permanently ticked row that can do
# nothing is the harmful one).

MEETING="$HOME/.local/bin/voxtype-meeting"

if [[ ! -x $MEETING ]]; then
  echo "voxtype-meeting not installed"
  exit 0
fi

case "$("$MEETING" status 2>/dev/null || echo idle)" in
  recording) echo "󰑊 Meeting: recording" ;;
  paused)    echo "󰏤 Meeting: paused" ;;
  *)         echo "Meeting: idle" ;;
esac

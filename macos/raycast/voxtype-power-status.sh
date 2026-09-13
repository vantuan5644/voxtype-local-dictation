#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Voxtype Status
# @raycast.mode inline
# @raycast.refreshTime 30s

# Optional parameters:
# @raycast.icon 󰐥
# @raycast.packageName Voxtype
# @raycast.description Show whether the voxtype stack is running

# `status --short` skips footprint and System Events, so a 30 s refresh costs
# a pgrep and a few launchctl calls. "partial" usually means a crashed agent or
# a half-finished toggle; the Voxtype Power command repairs it by turning on.

POWER="$HOME/.local/bin/voxtype-power"

if [[ ! -x $POWER ]]; then
  echo "voxtype-power not installed"
  exit 0
fi

case "$("$POWER" status --short 2>/dev/null || echo unknown)" in
  on)      echo "󰐥 Voxtype: on" ;;
  partial) echo "󰐥 Voxtype: partly on" ;;
  off)     echo "Voxtype: off" ;;
  *)       echo "Voxtype: unknown" ;;
esac

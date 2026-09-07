#!/usr/bin/env bash
#
# render-docs-images.sh — regenerate the OSD pictures used in the docs.
#
# The images under docs/img/ are not screenshots. They are the OSD's own
# drawing code (voxtype-osd-macos --render, see the Render section of the
# Swift source) painting one frame of deterministic synthetic audio straight
# into a PNG. Two consequences worth knowing:
#
#   * They cannot drift. Change the palette, the meter zones, or the
#     waveform layout and re-running this script shows the change; a
#     screenshot taken once would have silently gone stale.
#   * They contain nothing personal. A real capture of a dictation panel
#     carries whatever the microphone heard and whatever was on screen
#     behind it; this carries a seeded pseudo-random waveform.
#
# Deterministic means byte-identical output for the same source and seed, so
# a run that changes nothing produces no git diff. Requires the Command Line
# Tools' swiftc; macOS only.
#
# Usage: ./render-docs-images.sh [--check]
#   --check   render to a temporary directory and diff against the committed
#             images instead of overwriting them (what CI runs)
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/../.." && pwd)"     # the repo root: docs/ is its sibling
OUT="$ROOT/docs/img"
SRC="$HERE/voxtype-osd-macos.swift"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
[ $# -gt 1 ] && { echo "usage: $0 [--check]" >&2; exit 2; }

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found — install the Xcode Command Line Tools" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# -O to match how install.sh builds it: the renderer is the same binary, and
# an unoptimised build has no reason to draw differently, but keeping the
# flags identical removes the question.
swiftc -O -whole-module-optimization -o "$tmp/voxtype-osd-macos" "$SRC"

# --check renders somewhere disposable and compares; a normal run writes the
# committed images in place.
if [ "$CHECK" -eq 1 ]; then
  dest="$tmp/img"
else
  dest="$OUT"
fi
mkdir -p "$dest"

# 2x is the scale a Retina display samples the 400x48 pt panel at, so these
# are the pixels the panel really occupies on the machines it runs on.
#
# Under --check each frame is also compared against its committed copy, by the
# renderer itself rather than by cmp(1). The reason is the transcribing frame:
# it draws a label with the system monospaced font, whose rasterisation is NOT
# stable across macOS versions, so a byte comparison fails on CI while drawing
# the identical picture (observed: macos-15 against a newer local release).
# --render-ignore-label masks out the label's region and compares everything
# else EXACTLY, at zero tolerance.
#
# A percentage tolerance was tried first and rejected: it has to be set so
# loose to absorb the font that a completely different waveform slips under it
# (measured, a fresh seed moves only 6.8% of that frame). Excluding a rect and
# demanding exactness outside it discriminates properly -- a 10 -> 9.5 change
# in waveform gain still fails.
status=0
for state in recording transcribing; do
  ignore=""
  [ "$state" = transcribing ] && ignore="--render-ignore-label"
  if [ "$CHECK" -eq 1 ]; then
    # shellcheck disable=SC2086  # $ignore is one optional flag, deliberately split
    "$tmp/voxtype-osd-macos" --render "$dest/osd-$state.png" \
      --render-state "$state" --render-scale 2 \
      --render-compare "$OUT/osd-$state.png" $ignore || status=1
  else
    "$tmp/voxtype-osd-macos" --render "$dest/osd-$state.png" \
      --render-state "$state" --render-scale 2
  fi
done

if [ "$CHECK" -eq 1 ]; then
  if [ "$status" -eq 0 ]; then
    echo "docs images match the renderer"
  else
    echo "docs images are stale: re-run $0 and commit the result" >&2
  fi
  exit "$status"
fi

echo
echo "Wrote:"
for state in recording transcribing; do
  echo "  docs/img/osd-$state.png"
done

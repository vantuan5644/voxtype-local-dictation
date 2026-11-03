#!/usr/bin/env bash
# Offline checks for voxtype-ime-hold: a stand-in fcitx5-remote keeps its state
# in a file, so the real input method is never touched.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/fcitx5-remote" <<'STUB'
#!/usr/bin/env bash
state="$(dirname "$0")/state"
case "${1:-}" in
  -c) echo 1 > "$state" ;;
  -o) echo 2 > "$state" ;;
  "") cat "$state" ;;
esac
echo "${1:-query}" >> "$(dirname "$0")/calls"
STUB
chmod +x "$work/fcitx5-remote"
export VOXTYPE_IME_REMOTE="$work/fcitx5-remote" XDG_RUNTIME_DIR="$work"
hold="$here/voxtype-ime-hold"
fail=0
check() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

echo 2 > "$work/state"; : > "$work/calls"
"$hold" begin
check "an active input method is off while typing" "$(cat "$work/state")" 1
"$hold" end
check "and back on after" "$(cat "$work/state")" 2

echo 1 > "$work/state"; : > "$work/calls"
"$hold" begin; "$hold" end
check "a plain keyboard is left alone" "$(cat "$work/state")" 1
check "  and never switched" "$(grep -c -- '-o\|-c' "$work/calls" || true)" 0

echo 2 > "$work/state"
"$hold" end
check "end without begin switches nothing" "$(cat "$work/state")" 2

VOXTYPE_IME_REMOTE="$work/missing" "$hold" begin
check "without fcitx5 it exits 0" "$?" 0
"$hold" bogus 2>/dev/null
check "a wrong argument still exits 0" "$?" 0
exit $fail

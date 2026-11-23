#!/usr/bin/env bash
# Boxes in the daemon (see test/over_check.py): run with over and its
# errors, over and under in status, shown and held set by attaches, the
# limit of 16, unseen_ms, the stop rule, and seen.ended on an ended box.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
# Session data and the socket go to the test directory, never the user's.
export XDG_RUNTIME_DIR="$dir" XDG_STATE_HOME="$dir/state"
cleanup() {
    "$BIN" shutdown >/dev/null 2>&1 || true
    for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir" && kill "$pid" 2>/dev/null
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT

"$BIN" list >/dev/null
python3 "$(dirname "$0")/over_check.py" "$dir/tuppet-$(id -u).sock" "$BIN"
echo "PASS: run over, its errors, over and under, shown and held, the limit of 16, unseen_ms, the stop rule, seen.ended"

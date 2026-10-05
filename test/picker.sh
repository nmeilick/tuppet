#!/usr/bin/env bash
# The picker that `tuppet attach` opens without an id, driven by tuppet itself:
# an outer daemon runs the picker, an inner one holds the sessions it
# shows.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
inner=(env XDG_RUNTIME_DIR="$dir/in" XDG_STATE_HOME="$dir/in/state")
outer=(env XDG_RUNTIME_DIR="$dir/out" XDG_STATE_HOME="$dir/out/state")
mkdir -p "$dir/in" "$dir/out"
cleanup() {
    "${outer[@]}" "$BIN" stop "${picker:-0}" >/dev/null 2>&1 || true
    for side in in out; do
        for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
            tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/$side" && kill "$pid" 2>/dev/null
        done
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
screen_has() { "${outer[@]}" "$BIN" wait "$picker" --match "$1" --timeout 3000 >/dev/null || fail "$2"; }

first=$("${inner[@]}" "$BIN" run --name first sh -c 'echo FIRST-SCREEN; exec cat')
second=$("${inner[@]}" "$BIN" run --name second sh -c 'echo SECOND-SCREEN; exec cat')

# Outside a terminal there is nothing to pick with: the sessions are listed.
if "${inner[@]}" "$BIN" attach </dev/null >/dev/null 2>"$dir/err"; then fail "attach without an id succeeded"; fi
grep -q "first" "$dir/err" || fail "attach without an id did not list the sessions"

picker=$("${outer[@]}" "$BIN" run --size 100x30 "${inner[@]}" "$BIN" attach)
screen_has "2 sessions, 2 running" "the list did not show both sessions"
screen_has "SECOND-SCREEN" "the preview did not show the newest session"

# The viewer: the session full screen, an overlay naming it, and the
# neighbors a key away.
"${outer[@]}" "$BIN" key "$picker" '<Enter>'
screen_has "#$second second" "the viewer's overlay did not name the session"
"${outer[@]}" "$BIN" key "$picker" '<Right>'
screen_has "#$first first" "the viewer did not switch to the next session"
screen_has "FIRST-SCREEN" "the viewer did not show the next session's screen"
"${outer[@]}" "$BIN" key "$picker" '<Esc>'
screen_has "Enter view" "Esc did not return to the list"

# Attach controls the session; Ctrl-] comes back to the picker.
"${outer[@]}" "$BIN" key "$picker" a
"${outer[@]}" "$BIN" wait "$picker" --idle 200 --timeout 3000 >/dev/null
"${outer[@]}" "$BIN" send "$picker" "typed-through-picker"
"${inner[@]}" "$BIN" wait "$first" --match typed-through-picker --timeout 3000 >/dev/null \
    || fail "keys did not reach the attached session"
"${outer[@]}" "$BIN" key "$picker" '<C-]>'
screen_has "detached from #$first" "Ctrl-] did not return to the picker"

"${outer[@]}" "$BIN" key "$picker" q
"${outer[@]}" "$BIN" wait "$picker" --exit --timeout 3000 >/dev/null || fail "q did not quit the picker"
"${outer[@]}" "$BIN" list | grep -q "^$picker	.*	exited	.*	0$" || fail "the picker did not exit 0"

echo "PASS: picker list, preview, viewer, switching, attach and back, quit"

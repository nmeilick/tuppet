#!/usr/bin/env bash
# `tuppet play` inside a tuppet session: the screen, recorded queries that
# get no answer, recorded input left out, q in the kitty keyboard
# protocol, the modes reset at the end, a recording larger than the window
# with a resize event, the notice outside a session, and the failure
# outside a terminal.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
cleanup() {
    for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir" && kill "$pid" 2>/dev/null
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT
export XDG_RUNTIME_DIR="$dir" XDG_STATE_HOME="$dir/state" TUPPET_CONFIG=
fail() { echo "FAIL: $1" >&2; "$BIN" view "${id:-0}" >&2 || true; exit 1; }
size_is() { "$BIN" view "$id" -j | grep -q "\"cols\":$1,\"rows\":$2,"; }
screen_has() { "$BIN" wait "$id" -m "$1" -t 3s >/dev/null || fail "$2"; }

# Mouse reports, kitty flags 1|8 (every key as an escape sequence),
# modifyOtherKeys, and bracketed paste, then a cursor report and a device
# attributes query last, so an answer would end the last frame.
cat >"$dir/modes.cast" <<'EOF'
{"version":2,"width":30,"height":6}
[0.0,"o","hello\r\n"]
[0.01,"i","LEAKED"]
[0.02,"o","\u001b[?1003h\u001b[?1006h\u001b[>9u\u001b[>4;2m\u001b[?2004h"]
[0.03,"o","done\u001b[6n\u001b[c"]
EOF
id=$("$BIN" run -s 40x10 sh -c '"$0" play "$1"; echo "play=$?"; IFS= read -r line; echo "got:$line"' "$BIN" "$dir/modes.cast")
screen_has done "the recording did not play"
size_is 30 6 || fail "the session does not have the recording's size"
"$BIN" view "$id" | grep -q LEAKED && fail "recorded input was played"
if "$BIN" wait "$id" -m 'play=' -t 500ms >/dev/null 2>&1; then fail "an answer to a recorded query ended the last frame"; fi
"$BIN" key "$id" q >/dev/null
screen_has 'play=0' "q did not quit in the kitty keyboard protocol"
size_is 40 10 || fail "the session did not get its size back"
"$BIN" key "$id" 'hi<Enter>' >/dev/null
screen_has 'got:hi' "the recording's keyboard modes stayed on"

# 80x24 in a 40x10 session, then a resize event to 100x30.
cat >"$dir/big.cast" <<'EOF'
{"version":2,"width":80,"height":24}
[0.0,"o","\u001b[24;70Hbottom"]
[0.01,"r","100x30"]
[0.02,"o","\u001b[30;90Hlarger"]
EOF
id=$("$BIN" run -s 40x10 sh -c '"$0" play "$1"; echo "one=$?"; env -u TUPPET_SESSION "$0" play "$1"; echo "two=$?"' "$BIN" "$dir/big.cast")
screen_has larger "the recording larger than the window did not play"
size_is 100 30 || fail "the session did not follow the resize event"
"$BIN" view "$id" | grep -q 'bottom$' || fail "the bottom row of the recording is missing"
"$BIN" key "$id" ' ' >/dev/null
screen_has 'larger than this terminal (40x10)' "outside a session, play did not say the window is smaller"
size_is 40 10 || fail "play resized a session it does not run in"
"$BIN" key "$id" q >/dev/null
screen_has 'two=0' "q did not quit"

if "$BIN" play "$dir/big.cast" </dev/null >"$dir/out" 2>&1; then code=0; else code=$?; fi
[ "$code" = 2 ] && grep -q 'needs a terminal' "$dir/out" || fail "outside a terminal play exited $code: $(cat "$dir/out")"
echo "PASS: play: screen, queries unanswered, input left out, q in kitty mode, modes reset, larger recording, notice, no terminal"

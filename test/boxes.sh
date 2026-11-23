#!/usr/bin/env bash
# Boxes in a drawn attach, driven by tuppet itself: an outer daemon runs
# `tuppet attach --drawn --no-detach` in a session, an inner one holds the
# session underneath and the boxes over it. The outer session answers the
# cursor report as a terminal would.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
inner=(env XDG_RUNTIME_DIR="$dir/in" XDG_STATE_HOME="$dir/in/state" TUPPET_CONFIG=)
outer=(env XDG_RUNTIME_DIR="$dir/out" XDG_STATE_HOME="$dir/out/state" TUPPET_CONFIG=)
mkdir -p "$dir/in" "$dir/out"
cleanup() {
    local pids=()
    for side in in out; do
        for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
            tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/$side" && kill "$pid" 2>/dev/null && pids+=("$pid")
        done
    done
    for _ in $(seq 100); do
        local alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" = 0 ] && break
        sleep 0.05
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; "${outer[@]}" "$BIN" view "${att:-0}" >&2 || true; exit 1; }
key() { "${outer[@]}" "$BIN" key "$att" "$@" >/dev/null; }
outer_has() { "${outer[@]}" "$BIN" wait "$att" --match "$1" --timeout 3s >/dev/null || fail "$2"; }
inner_has() { "${inner[@]}" "$BIN" wait "$1" --match "$2" --timeout 3s >/dev/null || fail "$3"; }
# box GRAB TITLE CMD...: a box over the session underneath; prints its id.
box() {
    python3 -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
s.connect(sys.argv[1])
over = {"session": "agent", "title": sys.argv[3], "grab": sys.argv[2]}
s.sendall(json.dumps({"cmd": "run", "argv": sys.argv[4:], "cols": 30, "rows": 4, "over": over}).encode() + b"\n")
reply = json.loads(s.makefile("rb").readline())
if not reply["ok"]:
    sys.exit("FAIL: run over: %r" % reply)
print(reply["status"]["id"])
' "$dir/in/tuppet-$(id -u).sock" "$@"
}

# A program that shows what it reads.
cat >"$dir/show.py" <<'EOF'
import os, sys, tty
tty.setraw(0)
name = sys.argv[1].encode()
def w(b):
    sys.stdout.buffer.write(b)
    sys.stdout.buffer.flush()
# A second argument asks for focus reports.
w(b"\x1b[2J\x1b[H" + (b"\x1b[?1004h" if len(sys.argv) > 2 else b"") + name + b" READY\r\n")
got = b""
while True:
    data = os.read(0, 4096)
    if data == b"q":
        sys.exit(0)
    got += data
    w(b"\x1b[3;1H\x1b[2K" + name + b" got " + repr(got).encode())
EOF
printf '[attach]\nbox_pause = "100ms"\n' >"$dir/config.toml"
under=$("${inner[@]}" "$BIN" run -n agent python3 "$dir/show.py" UNDER)
inner_has "$under" "UNDER READY" "the session underneath did not start"
att=$("${outer[@]}" "$BIN" run --size 70x20 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 \
    "$BIN" attach --drawn --no-detach "$under")
outer_has "UNDER READY" "the drawn attach did not paint the session"
key a
inner_has "$under" "UNDER got b'a'" "typing did not reach the session underneath"

# A box arrives as a line, opens after the pause, and takes keys only once
# the cursor report came and keys paused for 500 ms: what is typed
# meanwhile reaches no session.
id=$(box pause "confirm deploy" python3 "$dir/show.py" BOX)
outer_has "confirm deploy waits" "the box did not arrive as a line"
"${outer[@]}" "$BIN" list -j "$att" | grep -q '"bell_count":1,' || fail "the box's arrival did not ring the bell once"
outer_has "wait…" "the box did not open after the pause"
for _ in $(seq 6); do
    key x
    sleep 0.1
done
outer_has "keys here" "the box did not take the keyboard after keys paused"
"${outer[@]}" "$BIN" view "$att" | grep -q "BOX READY" || fail "the box's session is not painted in it"
key hello
inner_has "$id" "BOX got b'hello'" "typing did not reach the box"
"${inner[@]}" "$BIN" view "$id" | grep -q x && fail "keys typed before the hand-over reached the box"
"${inner[@]}" "$BIN" view "$under" | grep -q x && fail "keys typed while the box was open reached the session underneath"

# A box made smaller to fit the window grows back once the window is
# larger, and takes keys again after the hand-over.
box_cols() {
    for _ in $(seq 60); do
        "${inner[@]}" "$BIN" list -j "$id" | grep -q "\"cols\":$1," && return 0
        sleep 0.05
    done
    fail "$2"
}
"${outer[@]}" "$BIN" resize "$att" 24x10 >/dev/null
box_cols 22 "the box was not made smaller to fit the window"
"${outer[@]}" "$BIN" resize "$att" 70x20 >/dev/null
box_cols 30 "the box did not grow back once the window was larger"
outer_has "keys here" "the box did not take keys again after it grew back"

# The box closes: the receipt shows, and keys go nowhere until they pause.
key q
outer_has "confirm deploy closed · keys go to agent" "no receipt after the box closed"
key z
sleep 0.6
key k
inner_has "$under" "UNDER got b'ak'" "a key after the pause did not reach the session underneath"
"${inner[@]}" "$BIN" view "$under" | grep -q z && fail "a key right after the box closed reached the session underneath"

# A --grab never box is painted while the session underneath keeps the
# keyboard.
note=$(box never "progress" python3 "$dir/show.py" NOTE)
outer_has "NOTE READY" "the --grab never box was not painted"
key m
inner_has "$under" "UNDER got b'akm'" "the session underneath lost the keyboard to a --grab never box"
"${inner[@]}" "$BIN" view "$note" | grep -q "got" && fail "the --grab never box took a key"
"${inner[@]}" "$BIN" stop "$note" >/dev/null

# A box's program that asked for focus reports is told when its box takes
# the keys.
focus=$(box pause "focus" python3 "$dir/show.py" FOCUS focus)
outer_has "keys here" "the box with focus reports did not take the keys"
inner_has "$focus" "FOCUS got b'\\x1b[I'" "the box's program was not told it has the keys"
key q
outer_has "focus closed" "the box with focus reports did not close"
sleep 0.6

# The main use, through the CLI: a caller asks through a box and gets
# the answer as run --over's exit code. Once the box takes keys, what the
# person types reaches its program.
# over_ends FILE CODE WANT LINE: run --over printed the box's id, then
# LINE with BOX for the id, exited with WANT, and removed the box.
over_ends() {
    local box
    box=$(head -1 "$1")
    [ "$2" = "$3" ] || fail "run --over exited $2, not $3: $(cat "$1")"
    [ "$(sed -n 2p "$1")" = "${4//BOX/$box}" ] || fail "run --over did not print '$4': $(cat "$1")"
    "${inner[@]}" "$BIN" list -j "$box" | grep -q '"sessions":\[\]' || fail "run --over did not remove box $box"
}
"${inner[@]}" "$BIN" run --over agent --title "ship it?" -- \
    sh -c 'printf "type go: "; read -r a; [ "$a" = go ] && exit 6; exit 9' >"$dir/ask" &
runner=$!
outer_has "ship it? waits" "run --over's box did not arrive as a line"
outer_has "keys here" "run --over's box did not take the keyboard"
outer_has "type go:" "run --over's program is not painted in its box"
key 'go<Enter>'
if wait "$runner"; then code=0; else code=$?; fi
over_ends "$dir/ask" "$code" 6 "ended BOX exit=6 held=yes shown=yes"

"${inner[@]}" "$BIN" run --over agent --grab never -- sh -c 'echo NOTICE; read -r _; exit 5' >"$dir/notice" &
runner=$!
outer_has "NOTICE" "run --over's --grab never box was not painted"
"${inner[@]}" "$BIN" key "$(head -1 "$dir/notice")" '<Enter>' >/dev/null
if wait "$runner"; then code=0; else code=$?; fi
over_ends "$dir/notice" "$code" 5 "ended BOX exit=5 held=no shown=yes"

# The picture behind an open box is the session's after a resize, not
# the old one cut to the new size.
wrap=$("${inner[@]}" "$BIN" run -n wrap -s 60x15 sh -c 'for i in $(seq 14); do printf "row%02d %050d\n" "$i" 0; done; exec cat')
inner_has "$wrap" "row14" "the session to wrap did not print"
att=$("${outer[@]}" "$BIN" run --size 60x15 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 \
    "$BIN" attach --drawn "$wrap")
outer_has "row14" "the drawn attach did not paint the session to wrap"
"${inner[@]}" "$BIN" run --over wrap -s 20x3 -- sh -c 'read -r _' >/dev/null 2>&1 &
outer_has "Esc later" "the box over the session to wrap did not open"
"${outer[@]}" "$BIN" resize "$att" 40x12 >/dev/null
for _ in $(seq 60); do
    [ "$("${outer[@]}" "$BIN" view "$att" | head -1)" = "$("${inner[@]}" "$BIN" view "$wrap" | head -1)" ] && break
    sleep 0.05
done
[ "$("${outer[@]}" "$BIN" view "$att" | head -1)" = "$("${inner[@]}" "$BIN" view "$wrap" | head -1)" ] ||
    fail "the picture behind the box is not the session's after a resize"
# The session shows beside the box, on the rows it sits on.
"${outer[@]}" "$BIN" view "$att" | grep -qE '^row[0-9]+ 0+ +┃' || fail "the session is not shown left of the box"
"${outer[@]}" "$BIN" view "$att" | grep -qE '┃ +0+$' || fail "the session is not shown right of the box"
# Esc sets the box aside, and the detach key pressed over and over opens
# it again and does not detach. The resize ran the hand-over again: Esc
# acts once the box takes keys.
outer_has "Esc later" "the box did not take keys again after the resize"
"${outer[@]}" "$BIN" key "$att" '<Esc>' >/dev/null
outer_has "opens it" "Esc did not set the box aside"
sleep 1.1
for _ in $(seq 6); do "${outer[@]}" "$BIN" key "$att" '<C-]>' >/dev/null; done
outer_has "Esc later" "the detach key did not open the box again"
sleep 0.3
"${outer[@]}" "$BIN" list -j "$att" | grep -q '"state":"running"' || fail "pressing the detach key over and over detached"

# Without setting aside, the detach key detaches from an open box, and a
# box's program that asked for focus reports hears that it lost the keys.
printf '[attach]\nbox_pause = "100ms"\nset_aside = false\n' >"$dir/no-aside.toml"
att=$("${outer[@]}" "$BIN" run --size 70x20 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/no-aside.toml" LC_ALL=C.UTF-8 \
    "$BIN" attach --drawn -f "$under")
outer_has "UNDER" "the attach without setting aside did not paint the session"
focus=$(box pause "focus" python3 "$dir/show.py" FOCUS focus)
outer_has "] detach" "the box without setting aside did not take the keys"
inner_has "$focus" "FOCUS got b'\\x1b[I'" "the box's program was not told it has the keys"
key '<C-]>'
"${outer[@]}" "$BIN" wait "$att" --ended --timeout 3s >/dev/null || fail "the detach key did not detach from the open box"
inner_has "$focus" "FOCUS got b'\\x1b[I\\x1b[O'" "the box's program was not told it lost the keys at the detach"
"${inner[@]}" "$BIN" stop "$focus" >/dev/null

# A session that run -a --drawn starts reports the person's terminal's
# colors to its program, a box over it does too, and the session behind
# the box is painted in a color between the two.
cat >"$dir/ask.py" <<'EOF'
import os, select, tty
tty.setraw(0)
os.write(1, b"\x1b]11;?\x1b\\")
got = b""
while select.select([0], [], [], 1)[0]:
    got += os.read(0, 100)
    if got.endswith(b"\x1b\\") or got.endswith(b"\x07"):
        break
os.write(1, b"BG " + got.replace(b"\x1b", b"").replace(b"\\", b"").replace(b"\x07", b"") + b"\r\n")
os.read(0, 1)
EOF
att=$("${outer[@]}" "$BIN" run --size 60x12 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 \
    sh -c "printf '\033]10;rgb:00/00/00\033\\\\\033]11;rgb:ff/ff/ff\033\\\\'; exec $BIN run -a --drawn -n light python3 $dir/ask.py")
outer_has "BG ]11;rgb:ffff/ffff/ffff" "the session did not report the terminal's background"
"${inner[@]}" "$BIN" run --over light -s 30x3 -- python3 "$dir/ask.py" >/dev/null 2>&1 &
outer_has "┃BG ]11;rgb:ffff/ffff/ffff" "the box did not report the background of the session it is over"
# Row 1 is painted in that color: as the base, or as a run of its own.
styles=$("${outer[@]}" "$BIN" view "$att" --styles)
grep -q '^1:1-60 fg=#7f7f7f "BG' <<<"$styles" || { grep -qx 'base: fg=#7f7f7f' <<<"$styles" && ! grep -q '^1:' <<<"$styles"; } || fail "the session behind the box is not painted in a color between the terminal's two"

# A --grab now box opens at once over the box that is open.
"${inner[@]}" "$BIN" run --over light --grab now -s 30x3 -- sh -c 'echo PICKER; read -r _' >/dev/null 2>&1 &
outer_has "┃PICKER" "a --grab now box did not open over the open box"

echo "PASS: a box arrives as a line, opens after the pause, takes keys only after the cursor report and a pause, closes with a receipt and dropped keys; a --grab never box leaves the keyboard alone; a box's program hears focus; the picture behind a box after a resize, the session beside it, Esc sets it aside, the detach key pressed over and over does not detach, and without setting aside it detaches and the box hears it lost the keys; the terminal's colors for the session, its box, and the backdrop; a --grab now box opens over an open one; run --over's boxes in a drawn attach report the program's code"

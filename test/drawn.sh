#!/usr/bin/env bash
# The drawn attach, driven by tuppet itself: an outer daemon runs
# `tuppet attach --drawn` in a session, an inner one holds the session it
# paints. What the outer session shows must equal the inner session.
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
    # The daemons write their state as they stop.
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
# A drawn attach of SESSION in a new outer session of 60x15.
drawn() { "${outer[@]}" "$BIN" run --size 60x15 env -u TUPPET_SESSION "${inner[@]:1}" "$@"; }
key() { "${outer[@]}" "$BIN" key "$att" "$@" >/dev/null; }
screen_has() { "${outer[@]}" "$BIN" wait "$att" --match "$1" --timeout 3s >/dev/null || fail "$2"; }
# The screen with its styles, without the blank rows at the bottom, and
# the cursor.
shown() {
    "$@" --styles | awk 'p{print;next} /^base:/{p=1;print;next} /^$/{e++;next} {for(;e>0;e--)print "";print}'
    "$@" -j | grep -o '"cursor":{[^}]*}'
}
# same WHY: the outer session shows what the inner one does.
same() {
    for _ in $(seq 60); do
        [ "$(shown "${outer[@]}" "$BIN" view "$att")" = "$(shown "${inner[@]}" "$BIN" view "$id")" ] && return
        sleep 0.05
    done
    diff <(shown "${outer[@]}" "$BIN" view "$att") <(shown "${inner[@]}" "$BIN" view "$id") >&2 || true
    fail "$1"
}
# step KEY...: type into the outer session, wait for the inner session to
# change, and compare.
step() {
    local seq
    seq=$("${inner[@]}" "$BIN" view "$id" -j | grep -o '"seq":[0-9]*' | head -1 | cut -d: -f2)
    key "$@"
    "${inner[@]}" "$BIN" wait "$id" --since "$seq" --timeout 3s >/dev/null || fail "$* did not reach the program"
    same "the screens differ after $*"
}

# Option errors are usage errors (exit 2), and come before any daemon is
# asked.
usage_error() {
    local want=$1 code=0
    shift
    "${inner[@]}" "$BIN" "$@" </dev/null >/dev/null 2>"$dir/err" || code=$?
    [ "$code" = 2 ] && grep -qF -- "$want" "$dir/err" || { cat "$dir/err" >&2; fail "$* exited $code without saying: $want"; }
}
usage_error "cannot be combined with --read-only" attach 1 --drawn -r
usage_error "needs a drawn attach" attach 1 --no-detach
usage_error "attach --drawn needs a terminal" attach 1 --drawn
usage_error "goes with -a" run --drawn true
usage_error "--alt-screen needs a drawn attach" attach 1 --alt-screen
usage_error "invalid --pass 'bel'" attach 1 --drawn --pass bel
usage_error "--pass needs a drawn attach" attach 1 --pass none
usage_error "goes with -a" run -k ^A true
usage_error "--no-keys goes with --read-only" attach 1 --no-keys
usage_error "--label names the writer" attach 1 -r --label x
usage_error "it has control characters" attach 1 --label $'a\eb'
# drawn = true never applies to -r, which writes the output outside a
# terminal as before.
printf '[attach]\ndrawn = true\n' >"$dir/config.toml"
done_id=$("${inner[@]}" "$BIN" run sh -c 'echo DONE-OUTPUT')
"${inner[@]}" "$BIN" wait "$done_id" --ended --timeout 3s >/dev/null
"${inner[@]}" TUPPET_CONFIG="$dir/config.toml" "$BIN" attach "$done_id" -r </dev/null 2>/dev/null | grep -q DONE-OUTPUT \
    || fail "drawn = true changed attach -r"

# A program that draws with styles, colours, wide and combined
# characters, a link, and a cursor of its own shape, asks for cursor-key
# mode and bracketed paste, and shows what it reads.
cat >"$dir/prog.py" <<'EOF'
import os, sys, tty
tty.setraw(0)
def w(b):
    sys.stdout.buffer.write(b)
    sys.stdout.buffer.flush()
w(b"\x1b[?1049h\x1b[H\x1b[2J")
w("\x1b[1;31mbold red\x1b[0m \x1b[4:3;38;2;10;20;30mcurly\x1b[0m 一二 é \x1b[3;9;53mit\x1b[0m\r\n".encode())
w(b"\x1b[44m\x1b[K\x1b[0m\r\n\x1b[7;32minverse\x1b[0m \x1b]8;;http://x.test/\x1b\\link\x1b]8;;\x1b\\\r\n")
w(b"\x1b[?1h\x1b[?2004h\x1b[6 q\x1b[5;1HREADY\x1b[6;3H")
n = 0
while True:
    data = os.read(0, 4096)
    if data == b"q":
        sys.exit(7)
    if data == b"n":
        w(b"\x1b[?2004l")
    n += 1
    w(b"\x1b7\x1b[8;1H\x1b[2K" + ("got %d %r" % (n, data)).encode() + b"\x1b8")
EOF
id=$("${inner[@]}" "$BIN" run python3 "$dir/prog.py")
"${inner[@]}" "$BIN" wait "$id" --match READY --timeout 3s >/dev/null
att=$(drawn sh -c "$BIN attach --drawn $id; echo AFTER-DETACH \$?; exec cat")
same "the drawn attach did not paint the session as it is"
step abc
screen_has "got 1 b'abc'" "typing did not reach the program"
step '<Up>'
screen_has '\x1bOA' "the arrow key did not arrive in cursor-key mode"
"${outer[@]}" "$BIN" do "$att" -p pasted >/dev/null
screen_has '\x1b[200~pasted\x1b[201~' "a paste lost its brackets"
step n
"${outer[@]}" "$BIN" do "$att" -p plain >/dev/null
screen_has "got 5 b'plain'" "a paste kept its brackets for a program that did not ask for them"
# Another party resizes the session: the outer screen follows.
"${inner[@]}" "$BIN" resize "$id" 50x12 >/dev/null
same "the screens differ after another party resized the session"
# The detach key leaves the session running and gives the terminal back
# with its modes: normal cursor keys, no bracketed paste.
key '<C-]>'
screen_has "AFTER-DETACH 0" "the detach key did not detach"
"${inner[@]}" "$BIN" list -j "$id" | grep -q '"state":"running"' || fail "the session ended at the detach"
key '<Up>'
"${outer[@]}" "$BIN" do "$att" -p zz >/dev/null
screen_has '^[[Azz' "the drawn attach left its input modes behind"

# With --no-detach the key is dropped, and the attach ends with the
# program's exit code.
att=$(drawn "$BIN" attach --drawn --no-detach "$id")
same "the drawn attach did not paint the session again"
key '<C-]>' x
screen_has "got 6 b'x'" "--no-detach passed the detach key or lost the next key"
key q
"${outer[@]}" "$BIN" wait "$att" --ended --timeout 3s >/dev/null || fail "the attach did not end with the program"
"${outer[@]}" "$BIN" list -j "$att" | grep -q '"exit":{"code":7' || fail "the attach did not exit with the program's code"

# What the program writes for its own terminal stays there: the outer
# session keeps its title and never sees a clipboard read, and nothing
# the outer terminal answers reaches the program. A clipboard write, a
# bell, and a notification are passed on.
cat >"$dir/trust.py" <<'EOF'
import os, sys, tty, select
tty.setraw(0)
def w(b):
    sys.stdout.buffer.write(b)
    sys.stdout.buffer.flush()
w(b"WAITING\r\n")
os.read(0, 1)
w(b"\x1b]2;from-program\x07\x1b]52;c;aGk=\x07\x1b]52;c;?\x07\x1b[c\x1b[6n\x07\x1b]9;note\x1b\\\x1bPzunknown\x1b\\")
got = b""
while select.select([0], [], [], 0.3)[0]:
    got += os.read(0, 4096)
w(b"answers %r\r\n" % got)
EOF
id=$("${inner[@]}" "$BIN" run python3 "$dir/trust.py")
"${inner[@]}" "$BIN" wait "$id" --match WAITING --timeout 3s >/dev/null
att=$(drawn "$BIN" attach --drawn --label drawn-label "$id")
screen_has WAITING "the drawn attach did not paint the program"
"${inner[@]}" "$BIN" list -j "$id" | grep -q '"writer":{"label":"drawn-label"}' || fail "the drawn attach did not send its --label"
"${outer[@]}" "$BIN" record "$att" --start "$dir/out.cast" >/dev/null
key g
screen_has answers "the program did not finish its queries"
"${outer[@]}" "$BIN" record "$att" --stop >/dev/null
"${inner[@]}" "$BIN" view "$id" | grep -qE "^answers b'\\\\x1b\[\?[0-9;]*c\\\\x1b\[[0-9]+;[0-9]+R'$" \
    || fail "the program got answers other than its own daemon's"
status=$("${outer[@]}" "$BIN" list -j "$att")
grep -q '"title":null' <<<"$status" || fail "the program set the outer session's title"
grep -q '"bell_count":1' <<<"$status" || fail "the bell was not passed on"
grep -q '"text":"note"' <<<"$status" || fail "the notification was not passed on"
grep -qF ']52;c;aGk=' "$dir/out.cast" || fail "the clipboard write was not passed on"
grep -qF ']52;c;?' "$dir/out.cast" && fail "the clipboard read was passed on"
# The DCS that the client's copy does not know is logged by the emulator;
# no log line reaches the terminal it paints.
grep -qF 'DCS' "$dir/out.cast" && fail "a log line reached the attach's terminal"

# A raw attach sends its --label and takes -k, and so does run -a.
raw=$("${inner[@]}" "$BIN" run cat)
att=$(drawn sh -c "$BIN attach --no-drawn --label raw-label -k ^A $raw; echo RAW-DETACHED \$?; exec cat")
for _ in $(seq 60); do "${inner[@]}" "$BIN" list -j "$raw" | grep -q '"writer":{"label":"raw-label"}' && break; sleep 0.05; done
"${inner[@]}" "$BIN" list -j "$raw" | grep -q '"writer":{"label":"raw-label"}' || fail "the raw attach did not send its --label"
key '<C-a>'
screen_has "RAW-DETACHED 0" "-k did not set the raw attach's detach key"
att=$(drawn sh -c "$BIN run -a -k ^A -n runk cat; echo RUN-DETACHED \$?; exec cat")
for _ in $(seq 60); do "${inner[@]}" "$BIN" list -j runk 2>/dev/null | grep -q '"writer":{' && break; sleep 0.05; done
key '<C-a>'
screen_has "RUN-DETACHED 0" "run -a -k did not set the detach key"

# A real full-screen program, step by step.
for i in $(seq 120); do printf '\033[3%dmline %d\033[0m \xe4\xb8\x80 wide \033[1mbold\033[0m e\xcc\x81\n' $((i % 8)) "$i"; done >"$dir/text"
id=$("${inner[@]}" "$BIN" run sh -c "TERM=xterm-256color exec less -R $dir/text")
"${inner[@]}" "$BIN" wait "$id" --match 'line 1 ' --timeout 3s >/dev/null
att=$(drawn "$BIN" attach --drawn "$id")
same "less was not painted as it is"
for k in '<Space>' '/line 15<Enter>' G '<Up>' g; do step "$k"; done
# The attaching terminal is resized: the session follows it.
"${outer[@]}" "$BIN" resize "$att" 70x20 >/dev/null
for _ in $(seq 60); do
    "${inner[@]}" "$BIN" list -j "$id" | grep -q '"cols":70,"rows":20' && break
    sleep 0.05
done
same "the session did not follow the attaching terminal's size"

# A recorded vim session (test/vim.cast: syntax colours, insert, visual
# mode, a search, a split, undo), replayed one input's output per key.
cat >"$dir/replay.py" <<'EOF'
import json, os, sys, tty
tty.setraw(0)
steps = [b""]
with open(sys.argv[1]) as f:
    f.readline()
    for t, kind, data in map(json.loads, f):
        if kind == "i":
            steps.append(b"")
        elif kind == "o":
            steps[-1] += data.encode()
for s in steps:
    sys.stdout.buffer.write(s)
    sys.stdout.buffer.flush()
    os.read(0, 1)
while True:
    os.read(0, 4096)
EOF
cast="$(realpath "$(dirname "$0")")/vim.cast"
id=$("${inner[@]}" "$BIN" run --size 60x15 python3 "$dir/replay.py" "$cast")
att=$(drawn "$BIN" attach --drawn "$id")
same "the replay's start was not painted as it is"
for _ in $(seq "$(grep -c '^\[[0-9.]*,"i",' "$cast")"); do step n; done

# --pass: what the session and a box write of the bell, notifications,
# the clipboard and links reaches the terminal only when it is listed.
# The attach's own output is recorded by script(1), as the terminal gets it.
printf '\a\033]9;NOTE\a\033]52;c;SGVsbG8=\a\033]8;;http://x.test/\033\\LINK\033]8;;\033\\\nDONE\n' >"$dir/payload"
printf '[attach]\nbox_pause = "100ms"\nset_aside = false\n' >"$dir/config.toml"
passed() { # PASS-ARGS...: what arrived, as "bell note clip link" with - for each missing
    local sh
    sh=$("${inner[@]}" "$BIN" run -s 60x15 bash --norc --noprofile)
    "${inner[@]}" "$BIN" key "$sh" 'PS1="$ "<Enter>' >/dev/null
    rm -f "$dir/raw"
    att=$(drawn TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 script -qfc "$BIN attach --drawn $* $sh" "$dir/raw")
    screen_has 'PS1' "--pass $*: the attach did not paint"
    "${inner[@]}" "$BIN" key "$sh" "clear; cat $dir/payload<Enter>" >/dev/null
    screen_has 'LINK' "--pass $*: the session's output did not arrive"
    "${inner[@]}" "$BIN" run --over "$sh" -s 30x4 -- sh -c "cat $dir/payload; read -r _" >/dev/null 2>&1 &
    screen_has 'keys here' "--pass $*: the box did not open"
    # Without setting aside, the detach key detaches from an open box.
    screen_has '] detach' "--pass $*: the box does not name the detach key"
    key '<C-]>'
    "${outer[@]}" "$BIN" wait "$att" --ended --timeout 3s >/dev/null || fail "--pass $*: the attach did not detach"
    python3 - "$dir/raw" <<'EOF'
import re, sys
b = open(sys.argv[1], "rb").read()
bare = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", b)
print(" ".join([
    "bell" if b"\x07" in bare else "-",
    "note" if re.search(rb"\x1b\][^\x07\x1b]*NOTE", b) else "-",
    "clip" if b"\x1b]52;c;SGVsbG8" in b else "-",
    "link" if b"\x1b]8;;http://x.test" in b else "-",
]))
EOF
}
[ "$(passed)" = "bell note clip link" ] || fail "the default --pass is not all four: $(passed)"
# tuppet's own bell for the box that arrives stays.
[ "$(passed --pass none)" = "bell - - -" ] || fail "--pass none let through: $(passed --pass none)"
[ "$(passed --pass clipboard,links)" = "bell - clip link" ] || fail "--pass clipboard,links let through: $(passed --pass clipboard,links)"
# The cursor style the terminal answered is the one left at the end, not
# the default (0), which xterm makes blink.
[ "$(grep -ao $'\e\\[[0-9] q' "$dir/raw" | tail -1)" != $'\e[0 q' ] || fail "the drawn attach left the default cursor style"

# The wheel scrolls a full-screen program that did not ask for the mouse:
# alternate scroll (1007) is on while it runs and off once it left.
sh=$("${inner[@]}" "$BIN" run -s 60x15 bash --norc --noprofile)
rm -f "$dir/raw"
att=$(drawn LC_ALL=C.UTF-8 script -qfc "$BIN attach --drawn $sh" "$dir/raw")
screen_has 'bash' "the attach for the wheel did not paint"
"${inner[@]}" "$BIN" key "$sh" "printf '\\033[?1049hFULL'; read -r _; printf '\\033[?1049l'<Enter>" >/dev/null
screen_has 'FULL' "the full-screen program did not start"
for _ in $(seq 40); do grep -aq $'\e\\[?1007h' "$dir/raw" && break; sleep 0.05; done
grep -aq $'\e\\[?1007h' "$dir/raw" || fail "the wheel was not turned into arrow keys for a full-screen program"
"${inner[@]}" "$BIN" key "$sh" '<Enter>' >/dev/null
for _ in $(seq 40); do [ "$(grep -ao $'\e\\[?1007[hl]' "$dir/raw" | tail -1)" = $'\e[?1007l' ] && break; sleep 0.05; done
[ "$(grep -ao $'\e\\[?1007[hl]' "$dir/raw" | tail -1)" = $'\e[?1007l' ] || fail "alternate scroll stayed on after the program left the alternate screen"

echo "PASS: drawn attach option errors, painting, typing, cursor keys, paste with and without brackets, resize by another party, detach and modes, --no-detach, exit code, what stays with the program, --label, no log line on the terminal, -k for attach and run -a, less and its terminal's resize, a recorded vim session, --pass, the cursor style left, the wheel in a full-screen program"

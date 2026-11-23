#!/usr/bin/env bash
# A drawn attach with tmux as the person's terminal: what tmux holds in
# its pane must equal what tuppet holds in the session, and, with a box
# open over it, what tuppet's own terminal makes of the same output.
# Needs tmux, so it is not in the Makefile's E2E list; run it by hand.
# tmux runs on a private socket that is removed at the end.
set -euo pipefail
unset TUPPET_SOCKET TMUX
command -v tmux >/dev/null || { echo "SKIP: no tmux"; exit 0; }

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
inner=(env XDG_RUNTIME_DIR="$dir/in" XDG_STATE_HOME="$dir/in/state" TUPPET_CONFIG=)
cmp=(env XDG_RUNTIME_DIR="$dir/cmp" XDG_STATE_HOME="$dir/cmp/state" TUPPET_CONFIG=)
mkdir -p "$dir/in" "$dir/cmp"
tm() { tmux -L "tuppet-test-$$" -f "$dir/tmux.conf" "$@"; }
cleanup() {
    tm kill-server 2>/dev/null || true
    local pids=()
    for side in in cmp; do
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
fail() { echo "FAIL: $1" >&2; tm capture-pane -p -t cmp >&2 || true; exit 1; }
pane_has() {
    for _ in $(seq 60); do tm capture-pane -p -t cmp | grep -qF -- "$1" && return; sleep 0.05; done
    fail "$2"
}
# replay FILE: a new session of the pane's size that shows FILE's bytes;
# prints its id.
replay() { "${cmp[@]}" "$BIN" run --size 60x15 sh -c 'stty -echo; cat "$1"; exec sleep 600' sh "$1"; }
# styles SESSION: the session's text and styles once its output settled.
styles() {
    "${cmp[@]}" "$BIN" wait "$1" --idle 200ms --timeout 3s >/dev/null
    "${cmp[@]}" "$BIN" view "$1" --styles
}
# pane FILE: what tmux holds in the pane, its styles and links, without
# the last newline, so that replaying it does not scroll.
pane() { tm capture-pane -e -p -N -t cmp | head -c -1 >"$1"; }

# A screen with styles, colours, wide characters and emoji, combining
# marks, a link, a background-only line, and a cursor of its own shape.
cat >"$dir/prog.py" <<'EOF'
import os, sys, tty
tty.setraw(0)
def w(s):
    sys.stdout.buffer.write(s.encode())
    sys.stdout.buffer.flush()
w("\x1b[?1049h\x1b[H\x1b[2J")
w("\x1b[1;31mbold red\x1b[0m \x1b[4:3;38;2;10;20;30mcurly\x1b[0m 一二 é é \x1b[3;9mit\x1b[0m \x1b[2;5mfaint\x1b[0m\r\n")
w("\x1b[44m\x1b[K\x1b[0m\r\n\x1b[7;32minverse\x1b[0m \x1b]8;;http://x.test/\x1b\\link\x1b]8;;\x1b\\ "
  "\x1b[38;5;208;48;5;17mp256\x1b[0m \x1b[4:2;58;5;1mdbl\x1b[0m\r\n")
for i in range(4, 14):
    w("\x1b[3%dmline %d 中文 ä 🙂 \x1b[0mtail\r\n" % (i % 8, i))
w("\x1b[6 q\x1b[15;1HREADY\x1b[6;3H")
while True:
    os.read(0, 4096)
EOF
cat >"$dir/box.py" <<'EOF'
import os, sys, tty
tty.setraw(0)
sys.stdout.buffer.write("\x1b[1;32mbox\x1b[0m 中文 é \x1b]8;;http://b.test/\x1b\\yes\x1b]8;;\x1b\\?".encode())
sys.stdout.buffer.flush()
os.read(0, 1)
EOF
printf 'set -g status off\n' >"$dir/tmux.conf"
printf '[attach]\nbox_pause = "100ms"\n' >"$dir/config.toml"
under=$("${inner[@]}" "$BIN" run --size 60x15 -n agent python3 "$dir/prog.py")
"${inner[@]}" "$BIN" wait "$under" --match READY --timeout 3s >/dev/null
# The attach waits for Enter, so that tmux keeps all it writes.
tm new-session -d -x 60 -y 15 -s cmp env LC_ALL=C.UTF-8 sh -c 'read -r _; exec "$@"' sh \
    env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 \
    "$BIN" attach --drawn --no-detach "$under"
tm pipe-pane -o -t cmp "cat >$dir/drawn.out"
tm send-keys -t cmp Enter
pane_has READY "the drawn attach did not paint in tmux"

# The session alone: tmux's pane equals the session, cursor included.
want=$("${inner[@]}" "$BIN" view "$under" --styles)
for _ in $(seq 20); do
    pane "$dir/pane"
    got=$(styles "$(replay "$dir/pane")")
    [ "$got" = "$want" ] && break
    sleep 0.05
done
[ "$got" = "$want" ] || { diff <(echo "$want") <(echo "$got") >&2 || true; fail "tmux's pane differs from the session"; }
cursor=$("${inner[@]}" "$BIN" view "$under" -j | grep -o '"cursor":{[^}]*}')
want=$(sed 's/.*"row":\([0-9]*\),"col":\([0-9]*\).*/\2,\1/' <<<"$cursor")
got=$(tm display -p -t cmp '#{e|+:#{cursor_x},1},#{e|+:#{cursor_y},1} #{cursor_shape}')
[ "$got" = "$want bar" ] || fail "tmux's cursor is at $got, not $want bar"

# A box open over it: tmux answers the cursor report, and its pane
# equals what tuppet's own terminal makes of the same output.
"${inner[@]}" "$BIN" run --over agent --title "confirm deploy" -s 30x4 -- python3 "$dir/box.py" >"$dir/run" &
runner=$!
pane_has "keys here" "the box did not take the keyboard in tmux"
pane_has "box 中文" "the box's program was not painted in tmux"
pane "$dir/pane"
own=$(styles "$(replay "$dir/drawn.out")")
got=$(styles "$(replay "$dir/pane")")
[ "$got" = "$own" ] || { diff <(echo "$own") <(echo "$got") >&2 || true; fail "tmux's pane with a box differs from tuppet's"; }
tm send-keys -t cmp y
wait "$runner" || fail "run --over did not end with the program's code: $(cat "$dir/run")"
echo "PASS: tmux holds what the session holds, cursor included, and paints an open box as tuppet does"

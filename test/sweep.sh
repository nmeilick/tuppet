#!/usr/bin/env bash
# tuppet sweep against programs with planted layout bugs: breakpoints, a cut
# text, a right-aligned text, a program that ignores SIGWINCH, the refusal
# while a writer is attached, the size coming back after the sweep is
# killed, the -- CMD form, --save, -j, and do --resize.
set -euo pipefail

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
# Session data goes to the test directory, never to the user's store.
export XDG_STATE_HOME="$dir/state"
export TUPPET_SOCKET="$dir/s.sock"
daemon_pid=
holder=
cleanup() {
    [ -n "$holder" ] && kill "$holder" 2>/dev/null
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

"$BIN" daemon --socket "$TUPPET_SOCKET" 2>"$dir/log" &
daemon_pid=$!
for _ in $(seq 100); do "$BIN" list >/dev/null 2>&1 && break; sleep 0.02; done

# A board that redraws on SIGWINCH, with its bugs: the title is left out
# below 44 columns, the task is cut at the right edge below 60, and the
# status is right-aligned.
cat >"$dir/board.py" <<'PY'
import os, signal, tty
tty.setraw(0)
def draw(*_):
    cols, rows = os.get_terminal_size(1)
    status = "[3 open | 12 done]"
    task = "Review PR #42 (picker preview)"
    out = "\x1b[H\x1b[2J"
    if cols >= 44:
        out += "\x1b[1;2H TaskBoard v0.3 "
    out += "\x1b[1;%dH%s" % (cols - len(status), status)
    out += "\x1b[3;30H" + task[:max(0, cols - 30)]
    out += "\x1b[%d;1Hsize %dx%d" % (rows, cols, rows)
    os.write(1, out.encode())
signal.signal(signal.SIGWINCH, draw)
draw()
while True:
    signal.pause()
PY
# One that never redraws.
cat >"$dir/static.py" <<'PY'
import os, signal, tty
tty.setraw(0)
signal.signal(signal.SIGWINCH, signal.SIG_IGN)
os.write(1, b"\x1b[H\x1b[2J\x1b[2;5HSTATIC")
while True:
    signal.pause()
PY
# Holds an attach stream open: mode, seconds.
cat >"$dir/hold.py" <<'PY'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall((json.dumps({"cmd": "attach", "session": sys.argv[2], "mode": sys.argv[3], "label": "holder"}) + "\n").encode())
print(json.loads(s.makefile("rb").readline())["ok"], flush=True)
time.sleep(float(sys.argv[4]))
PY
cols_of() { "$BIN" list "$1" -j | python3 -c 'import json, sys; print(json.load(sys.stdin)["sessions"][0]["cols"])'; }
hold() {
    : >"$dir/held"
    python3 "$dir/hold.py" "$TUPPET_SOCKET" "$1" "$2" 10 >"$dir/held" &
    holder=$!
    for _ in $(seq 100); do [ -s "$dir/held" ] && break; sleep 0.02; done
}
unhold() { kill "$holder"; wait "$holder" 2>/dev/null || true; holder=; }

id=$("$BIN" run -s 80x20 python3 "$dir/board.py")
"$BIN" wait "$id" -m 'size 80x20' -t 5s >/dev/null

# Breakpoints: the title appears at 45, the task is a prefix where it was
# until it fits at 60, the right-aligned status collapses by its right
# edge, and a find that is never there says so.
finds=(--find 'title=TaskBoard v0.3' --find 'status=[3 open | 12 done]' --find 'task=Review PR #42 (picker preview)' --find nope=NOPE)
"$BIN" sweep "$id" -s 40..75x20 --step 5 --settled 50ms "${finds[@]}" >"$dir/out" 2>"$dir/err" || fail "sweep exited $?: $(cat "$dir/err")"
grep -q "find nope: 'NOPE' is not on the screen at 80x20" "$dir/err" || fail "no warning for an absent find: $(cat "$dir/err")"
grep -Eq '^40 +20 +changed 4/20 rows, [0-9]+ bytes +absent +1:22 +absent +absent$' "$dir/out" || fail "40 columns: $(cat "$dir/out")"
grep -Eq '^45 .* 1:3 +1:27 +prefix "Review PR #42 \(" at 3:30 +absent$' "$dir/out" || fail "the cut task at 45: $(cat "$dir/out")"
grep -Eq '^65\.\.75 +20 +changed 2/20 rows, 108 bytes +1:3 +1:47\.\.57 right=2 +3:30 stale +absent$' "$dir/out" \
    || fail "the right-aligned status did not collapse: $(cat "$dir/out")"
grep -qx 'back at 80x20: same' "$dir/out" || fail "the way back: $(cat "$dir/out")"
grep -qx 'nope absent at every size' "$dir/out" || fail "no footer for the absent find"
grep -q '^not checked: only finds and the return screen were compared; settle 50ms, deadline 2s, sizes sampled every 5;' "$dir/out" \
    || fail "no footer: $(cat "$dir/out")"
[ "$(cols_of "$id")" = 80 ] || fail "the sweep did not restore the size"

# -j and --save: the fixed keys of every line, and a file pair per size.
"$BIN" sweep "$id" -s 50..60x20 --step 10 --settled 50ms --find 'task=Review PR #42 (picker preview)' -j --save "$dir/saved" >"$dir/json" 2>/dev/null \
    || fail "sweep -j exited $?"
python3 - "$dir/json" <<'PY' || fail "sweep -j: $(cat "$dir/json")"
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
size_keys = ["type", "cols", "rows", "screen", "rows_changed", "bytes", "exit", "late", "blank", "resize_seq", "seq", "finds"]
spot_keys = ["state", "row", "col", "right", "prefix", "count", "stale"]
assert [l["type"] for l in lines] == ["size", "size", "end"], lines
for l in lines[:2]:
    assert list(l) == size_keys, list(l)
    assert list(l["finds"]["task"]) == spot_keys, l["finds"]
cut, full = lines[0]["finds"]["task"], lines[1]["finds"]["task"]
assert cut == {"state": "prefix", "row": 3, "col": 30, "right": 2, "prefix": "Review PR #42 (picke", "count": 1, "stale": False}, cut
assert full["state"] == "at" and full["prefix"] is None and lines[1]["screen"] == "changed", lines[1]
end = lines[2]
assert end["back"] == "same" and end["stopped"] is None and end["start"] == {"cols": 80, "rows": 20}, end
PY
for f in 50x20.txt 50x20.styles 60x20.txt 60x20.styles baseline.txt baseline.styles; do
    [ -f "$dir/saved/$f" ] || fail "--save wrote no $f"
done
grep -q 'size 50x20' "$dir/saved/50x20.txt" || fail "50x20.txt does not hold its screen"
set +e
"$BIN" sweep "$id" -s 50x20 --save "$dir/saved" >/dev/null 2>"$dir/err"
code=$?
set -e
[ "$code" = 2 ] && grep -q 'not empty' "$dir/err" || fail "--save into a full directory exited $code: $(cat "$dir/err")"

# A program that ignores SIGWINCH writes nothing, and its text is the
# terminal's leftover: stale.
static=$("$BIN" run -s 60x10 python3 "$dir/static.py")
"$BIN" wait "$static" -m STATIC -t 5s >/dev/null
"$BIN" sweep "$static" -s 50..70x10 --step 10 --settled 50ms -t 200ms --find s=STATIC >"$dir/out" 2>/dev/null || fail "static sweep exited $?"
grep -Eq '^50\.\.70 +10 +wrote nothing +2:5 stale$' "$dir/out" || fail "stale finds: $(cat "$dir/out")"
grep -q 'had stale finds' "$dir/out" || fail "no hint for stale finds: $(cat "$dir/out")"
"$BIN" stop "$static" >/dev/null

# Another writer refuses the sweep, -f or not, and do --resize
# --unless-attached too.
hold "$id" write
set +e
"$BIN" sweep "$id" -s 50x20 -f >/dev/null 2>"$dir/err"
code=$?
"$BIN" do "$id" --resize 60x20 --unless-attached >"$dir/out" 2>/dev/null
guard=$?
set -e
[ "$code" = 5 ] && grep -q 'has a writer (holder)' "$dir/err" || fail "a sweep with a writer attached exited $code: $(cat "$dir/err")"
[ "$guard" = 5 ] && grep -q '^guard unattended' "$dir/out" || fail "do --resize --unless-attached exited $guard: $(cat "$dir/out")"
unhold

# Killed mid-sweep, the session gets its size back from the daemon.
"$BIN" sweep "$id" -s 30..90x20 --settled 300ms >/dev/null 2>&1 &
sweeper=$!
for _ in $(seq 250); do [ "$(cols_of "$id")" != 80 ] && break; sleep 0.02; done
[ "$(cols_of "$id")" != 80 ] || fail "the sweep never resized"
kill -9 "$sweeper"
wait "$sweeper" 2>/dev/null || true
for _ in $(seq 100); do [ "$(cols_of "$id")" = 80 ] && break; sleep 0.02; done
[ "$(cols_of "$id")" = 80 ] || fail "the size did not come back after SIGKILL: $(cols_of "$id")"

# -- CMD sweeps a session of its own and removes it.
TUPPET_SIZE=70x12 "$BIN" sweep -s 50x12 --settled 50ms --find 'task=Review PR #42 (picker preview)' -- python3 "$dir/board.py" >"$dir/out" 2>/dev/null \
    || fail "sweep -- CMD exited $?"
grep -Eq '^50 +12 +changed .* +prefix "Review PR #42 \(picke" at 3:30$' "$dir/out" || fail "sweep -- CMD: $(cat "$dir/out")"
grep -qx 'back at 70x12: same' "$dir/out" || fail "sweep -- CMD did not start at TUPPET_SIZE: $(cat "$dir/out")"
[ "$("$BIN" list -j | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["sessions"]))')" = 2 ] || fail "the scratch session was not removed"

# do --resize: conditions count from the reflow; the same size is met at
# once and says so.
"$BIN" do "$id" --resize 60x20 -m 'size 60x20' -w 2s | grep -q '^met match#0' || fail "do --resize -m"
out=$("$BIN" do "$id" --resize 60x20 --settled 50ms -w 1s) || fail "do --resize to the same size exited $?"
case $out in "same size $id seq="*) ;; *) fail "do --resize to the same size: $out" ;; esac
"$BIN" do "$id" --resize 80x20 --settled 50ms -w 2s | grep -q '^met settled#0' || fail "do --resize --settled"

echo "PASS: sweep breakpoints, prefixes, right edges, stale finds, refusal, kill, -- CMD, --save, -j, do --resize"

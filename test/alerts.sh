#!/usr/bin/env bash
# Alerts: defaults from the config file and --no-default-alerts, do --hit
# after an input, an answered dialog that stays visible not meeting --hit,
# --reply-to refused after a newer input, a hit marking the recording, hit
# events, the ! mark and the alert's name in list until an ack, alert
# add/list/remove, a hit of an unknown alert failing at once, resizes not
# firing again while new output does, and restart copying the alerts.
set -euo pipefail

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
export XDG_STATE_HOME="$dir/state"
export TUPPET_SOCKET="$dir/s.sock"
export TUPPET_CONFIG="$dir/config.toml"
daemon_pid=
cleanup() {
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
# exits N MESSAGE COMMAND...: COMMAND exits N, its output in $dir/out and $dir/err.
exits() {
    local want=$1 msg=$2
    shift 2
    set +e
    "$@" >"$dir/out" 2>"$dir/err"
    local got=$?
    set -e
    [ "$got" -eq "$want" ] || fail "$msg (exit $got: $(cat "$dir/err"))"
}
# field SESSION EXPR: a Python expression over the session's status `s`.
field() { "$BIN" list -j "$1" | python3 -c "import json,sys; s=json.load(sys.stdin)['sessions'][0]; print($2)"; }

"$BIN" daemon --socket "$TUPPET_SOCKET" 2>"$dir/log" &
daemon_pid=$!
for _ in $(seq 100); do "$BIN" list >/dev/null 2>&1 && break; sleep 0.02; done

# --- defaults come from the config file -----------------------------------
printf '[alerts]\nbad = 1\n' >"$TUPPET_CONFIG"
exits 1 "a broken config file did not fail run" "$BIN" run sleep 30
grep -q "config.toml:2: " "$dir/err" || fail "the config error lacks its line: $(cat "$dir/err")"
cat >"$TUPPET_CONFIG" <<'EOF'
# every session watches for the prompt
[alerts]
approve = "Proceed? "
EOF
id=$("$BIN" run -n ask bash --norc --noprofile -i)
[ "$(field "$id" "s['alerts']")" = "['approve']" ] || fail "the default alert is missing: $(field "$id" "s['alerts']")"
other=$("$BIN" run --no-default-alerts --alert 'x=XX' sleep 30)
[ "$(field "$other" "s['alerts']")" = "['x']" ] || fail "--no-default-alerts kept the defaults"
"$BIN" wait "$id" -m '$ ' -t 3s >/dev/null

# --- do waits for the hit after its input; it marks the recording ---------
"$BIN" record "$id" --start "$dir/ask.trace"
# The typed command does not show the text; the prompt it prints does.
ask="read -p \$'Proc\\x65ed? ' x"
"$BIN" do "$id" -s "$ask" -k '<Enter>' --hit approve -w 3s >"$dir/out" || fail "do --hit was not met"
grep -q "^met hit#0 $id seq=[0-9]* input_seq=[0-9]* hit_seq=1$" "$dir/out" || fail "the outcome line: $(cat "$dir/out")"
grep -q "^hit 1 approve Proceed? $" "$dir/out" || fail "the hit line: $(cat "$dir/out")"
"$BIN" record "$id" --stop >/dev/null
grep -q '"ev":"mark".*"label":"hit 1 approve"' "$dir/ask.trace" || fail "the hit did not mark the recording"

# --- the hit marks the session until an ack --------------------------------
"$BIN" list "$id" | grep -q '^! .* approve ' || fail "list does not name the hit: $("$BIN" list "$id")"
"$BIN" ack "$id"
"$BIN" list "$id" | grep -q '^ .* running ' || fail "ack did not clear the hit: $("$BIN" list "$id")"

# --- an answered dialog that is still visible does not meet --hit --------
"$BIN" do "$id" -s y -k '<Enter>' -m '$ ' -w 3s >/dev/null
"$BIN" view "$id" | grep -q '^Proceed? y$' || fail "the answered dialog is not visible"
exits 3 "an answered dialog met --hit" "$BIN" wait "$id" --hit approve -t 300ms
# The hit numbered before still counts with --after-hit.
"$BIN" wait "$id" --hit '*' --after-hit 0 -t 1s >"$dir/out" || fail "--after-hit 0 was not met"
grep -q '^hit 1 approve ' "$dir/out" || fail "the --after-hit line: $(cat "$dir/out")"

# --- reply_to refuses once a newer input came ------------------------------
exits 5 "--reply-to after a newer input was not refused" "$BIN" do "$id" --reply-to 1 -s 'echo NOPE'
grep -q "^guard reply_to $id " "$dir/out" || fail "the guard line: $(cat "$dir/out")"

# --- hits are events -------------------------------------------------------
"$BIN" events "$id" --count 1 -t 10s >"$dir/lines" &
text_pid=$!
python3 - "$TUPPET_SOCKET" "$id" "$BIN" "$ask" <<'PY' || fail "no hit frame"
import json, socket, subprocess, sys, time
path, sid, tuppet, ask = sys.argv[1:]
s = socket.socket(socket.AF_UNIX)
s.connect(path)
s.sendall(json.dumps({"cmd": "events", "sessions": [sid]}).encode() + b"\n")
s.settimeout(10)
f = s.makefile()
assert json.loads(f.readline())["ok"]
while json.loads(f.readline())["type"] != "synced":
    pass
subprocess.run([tuppet, "do", sid, "-s", ask, "-k", "<Enter>", "--hit", "approve", "-w", "3s"], check=True, stdout=subprocess.DEVNULL)
subprocess.run([tuppet, "do", sid, "-s", "y", "-k", "<Enter>", "-m", "$ ", "-w", "3s"], check=True, stdout=subprocess.DEVNULL)
while True:
    frame = json.loads(f.readline())
    if frame["type"] == "hit":
        break
assert frame["hit"]["alerts"] == ["approve"] and frame["hit"]["region"] == "visible", frame
assert frame["status"]["hit_seq"] == frame["hit"]["n"], frame
PY
# The command-line reader may have subscribed after that hit.
for _ in $(seq 50); do
    kill -0 "$text_pid" 2>/dev/null || break
    "$BIN" do "$id" -s "$ask" -k '<Enter>' --hit approve -w 3s >/dev/null
    "$BIN" do "$id" -s y -k '<Enter>' -m '$ ' -w 3s >/dev/null
done
wait "$text_pid" || fail "events did not print a hit"
grep -q " ask  hit [0-9]* approve: Proceed? $" "$dir/lines" || fail "the hit's event line: $(cat "$dir/lines")"

# --- alert add, list, remove -----------------------------------------------
"$BIN" alert add "$id" 'err=error:' --icase
"$BIN" alert list "$id" | grep -q "^ *$id  err  *error:  (icase)$" || fail "alert list: $("$BIN" alert list "$id")"
exits 1 "adding a name twice did not fail" "$BIN" alert add "$id" 'err=x'
grep -q "already" "$dir/err" || fail "the exists message: $(cat "$dir/err")"
"$BIN" alert remove "$id" err
exits 1 "removing a missing alert did not fail" "$BIN" alert remove "$id" err
[ "$(field "$id" "s['alerts']")" = "['approve']" ] || fail "alert remove left: $(field "$id" "s['alerts']")"

# --- a hit of an alert the session lacks fails at once ----------------------
for cmd in "wait $id --hit nosuch -t 30s" "do $id -s x --hit nosuch -t 30s" "record $id --start $dir/r.cast --hit nosuch" \
    "run --no-default-alerts --hit nosuch -t 30s -- true"; do
    # shellcheck disable=SC2086
    exits 1 "$cmd did not fail" timeout 10 "$BIN" $cmd
    grep -q "alert" "$dir/err" || fail "$cmd: $(cat "$dir/err")"
done
"$BIN" view "$id" | grep -q "^x" && fail "do typed despite an unknown alert"
[ "$("$BIN" list | grep -c true)" = 0 ] || fail "run started a session despite an unknown alert"

# --- a resize does not fire again; new output does ---------------------------
# A window drag over a status line whose text changes with the width.
cat >"$dir/status.py" <<'PY'
import os, signal, sys, time
def draw(*_):
    c, r = os.get_terminal_size()
    sys.stdout.write("\x1b[H\x1b[2Jmain view" + ("\x1b[%d;1Hstatus F10 Quit cols=%d" % (r, c) if c >= 40 else ""))
    sys.stdout.flush()
signal.signal(signal.SIGWINCH, draw)
sys.stdout.write("\x1b[?1049h"); draw()
while True: time.sleep(1)
PY
tui=$("$BIN" run -s 80x10 --no-default-alerts --alert 'quit=F10 Quit' -m 'cols=80' -t 3s -- python3 "$dir/status.py" | sed -n 1p)
for size in 30x10 81x10 30x10 82x10; do
    seq=$("$BIN" resize "$tui" "$size")
    "$BIN" wait "$tui" --since "$seq" --settled 100ms -t 3s >/dev/null || fail "no redraw after a resize to $size"
done
[ "$(field "$tui" "s['hit_seq']")" = 1 ] || fail "a window drag fired the alert again: hit_seq $(field "$tui" "s['hit_seq']")"
# After a resize the line scrolls away, and the program prints the text
# anew without an input.
out=$("$BIN" run --no-default-alerts --alert 'err=ERROR' -m 'ERROR one' -t 3s -- \
    sh -c "echo ERROR one; while [ ! -e '$dir/go' ]; do sleep 0.05; done; seq 60; echo ERROR two; exec sleep 30")
scroll=$(head -1 <<<"$out")
"$BIN" resize "$scroll" 100x30 >/dev/null
touch "$dir/go"
"$BIN" wait "$scroll" --hit err --after-hit 1 -t 3s >"$dir/out" || fail "new output after a resize did not fire"
grep -q '^hit 2 err ERROR two$' "$dir/out" || fail "the new hit: $(cat "$dir/out")"
"$BIN" stop "$tui" "$scroll" >/dev/null

# --- the end of a burst past the rate limit is logged a second later -------
burst=$("$BIN" run --no-default-alerts --alert 'tick=tick' sh -c 'for i in $(seq 20); do echo tick $i; done; exec sleep 30')
"$BIN" wait "$burst" --hit tick --after-hit 10 -t 3s >"$dir/out" || fail "the end of a burst was not logged"
grep -q '^hit 11 tick tick 20$' "$dir/out" || fail "the burst's last hit: $(cat "$dir/out")"
"$BIN" stop "$burst" >/dev/null

# --- restart copies the alerts, not the hits --------------------------------
"$BIN" stop "$id" >/dev/null
new=$("$BIN" restart ask)
[ "$(field "$new" "(s['alerts'], s['hit_seq'])")" = "(['approve'], None)" ] || fail "restart: $(field "$new" "(s['alerts'], s['hit_seq'])")"

"$BIN" remove -f '*' >/dev/null
echo "PASS: alerts, hits, guards, events, config defaults"

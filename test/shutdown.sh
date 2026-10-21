#!/usr/bin/env bash
# tuppet shutdown: stopping the daemon with its sessions, --reset that
# starts ids over, --all across endpoints, supervised daemons, and
# requests that race a shutdown.
set -euo pipefail
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
export XDG_RUNTIME_DIR="$dir"
# Session data goes to the test directory, never to the user's store.
export XDG_STATE_HOME="$dir/state"
export TUPPET_IDLE_EXIT=10s
sock="$dir/tuppet-$(id -u).sock"
pids=()
cleanup() {
    "$BIN" shutdown >/dev/null 2>&1 || true
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
# json EXPRESSION: a Python expression over the JSON r on stdin.
json() { python3 -c "import json, sys; r = json.load(sys.stdin); print($1)"; }
# A program that ignores the hangup and SIGTERM, so stopping it takes the
# 0.5 s grace before SIGKILL.
stubborn=(sh -c 'trap "" HUP TERM; exec sleep 300')
start_supervised() {
    "$BIN" daemon --socket "$1" --log "$1.log" &
    pids+=($!)
    for _ in $(seq 100); do "$BIN" --socket "$1" list >/dev/null 2>&1 && return 0; sleep 0.02; done
    fail "the daemon did not listen on $1"
}

# No daemon: nothing to do, and none is started.
out=$("$BIN" shutdown) || fail "shutdown without a daemon failed"
[ "$out" = "no daemon on $sock" ] || fail "unexpected output without a daemon: $out"
[ ! -e "$sock" ] || fail "shutdown started a daemon"

# Running sessions are stopped and saved; streams end, waits get their
# answer, and ended sessions survive into the next daemon.
a=$("$BIN" run -n build sleep 300)
b=$("$BIN" run sh -c 'exit 3')
"$BIN" wait "$b" -e >/dev/null
"$BIN" wait "$a" -e -t 30s >"$dir/wait.out" &
waiter=$!
python3 - "$sock" "$dir/events" <<'PY' &
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(15)
s.connect(sys.argv[1])
s.sendall(b'{"cmd":"events"}\n')
f = s.makefile()
kinds = []
for line in f:
    frame = json.loads(line)
    kinds.append(frame.get("type") or "reply")
    if frame.get("type") == "synced":
        open(sys.argv[2] + ".ready", "w").close()
    if frame.get("type") == "end":
        kinds.append(frame["reason"])
open(sys.argv[2], "w").write(" ".join(kinds))
PY
events=$!
for _ in $(seq 100); do [ -e "$dir/events.ready" ] && break; sleep 0.02; done
[ -e "$dir/events.ready" ] || fail "the event stream did not sync"
"$BIN" events --count 100 -j >"$dir/cli-events" 2>"$dir/cli-events.err" &
cli_events=$!
for _ in $(seq 100); do grep -q '"synced"' "$dir/cli-events" && break; sleep 0.02; done
out=$("$BIN" shutdown) || fail "shutdown failed"
[ "$out" = "stopped 1 running session ($a build) and the daemon on $sock; kept 2 ended sessions" ] || fail "unexpected shutdown output: $out"
[ ! -S "$sock" ] || fail "shutdown returned before the daemon was gone"
wait "$waiter" || fail "a wait for the end did not get its answer"
grep -q "^met ended#0 $a .* exit=stopped" "$dir/wait.out" || fail "the wait's answer: $(cat "$dir/wait.out")"
wait "$events"
status=0
wait "$cli_events" || status=$?
[ "$status" = 4 ] && grep -qx "tuppet: the daemon shut down after [0-9]* of 100 events" "$dir/cli-events.err" \
    || fail "tuppet events --count exited $status on a shutdown: $(cat "$dir/cli-events.err")"
case "$(cat "$dir/events")" in *" ended "*"end shutdown") ;; *) fail "the event stream did not report the end and the shutdown: $(cat "$dir/events")" ;; esac
"$BIN" list -j | json '" ".join("%s:%s:%s" % (s["id"], s["state"], s["exit"]["stopped"]) for s in r["sessions"])' >"$dir/list"
[ "$(cat "$dir/list")" = "$a:exited:True $b:exited:False" ] || fail "ended sessions did not survive: $(cat "$dir/list")"

# A program that ended on its own just before the shutdown is still
# saving its large history; the daemon waits for that.
big=$("$BIN" run --scrollback 64M sh -c 'seq 1 1000000; exit 3')
"$BIN" wait "$big" -e -t 30s >/dev/null
"$BIN" shutdown >/dev/null || fail "shutdown right after a session ended failed"
"$BIN" list -j "$big" | json 'r["sessions"][0]["state"], r["sessions"][0]["exit"]["code"]' >"$dir/big"
[ "$(cat "$dir/big")" = "exited 3" ] || fail "a session that was saving at the shutdown was not saved: $(cat "$dir/big")"
"$BIN" remove "$big"

# --reset brings ids back to 1 while seqs keep rising, keeps recordings
# written to files the user named, and shows the reset in the boot.
k=$("$BIN" run --record-file "$dir/keep.cast" sh -c 'echo KEPT')
r=$("$BIN" run -r sh -c 'echo STORED')
before=$("$BIN" run -j true)
for id in "$k" "$r" "$(echo "$before" | json 'r["status"]["id"]')"; do "$BIN" wait "$id" -e >/dev/null; done
boot=$(echo "$before" | json 'r["boot"]')
seq=$(echo "$before" | json 'r["status"]["start_seq"]')
store_rec=$("$BIN" list -j "$r" | json 'r["sessions"][0]["recording"]["path"]')
[ -f "$store_rec" ] || fail "the store recording is missing before the reset"
out=$("$BIN" shutdown --reset) || fail "shutdown --reset failed"
[ "$out" = "stopped the daemon on $sock; deleted 5 sessions and the recordings kept with them; ids start at 1 again" ] || fail "unexpected reset output: $out"
[ -f "$dir/keep.cast" ] || fail "the reset deleted a recording at a path the user named"
[ ! -e "$store_rec" ] || fail "the reset kept a recording in the store"
after=$("$BIN" run -j true)
[ "$(echo "$after" | json 'r["status"]["id"]')" = 1 ] || fail "ids did not start at 1 after the reset: $after"
[ "$(echo "$after" | json 'r["status"]["start_seq"]')" -gt "$seq" ] || fail "seqs started over after the reset"
[ "$(echo "$after" | json 'r["boot"]')" = "$boot.1" ] || fail "the boot does not show the reset: $after"

# --reset with no daemon resets the store in the command.
"$BIN" shutdown >/dev/null
out=$("$BIN" shutdown --reset) || fail "shutdown --reset without a daemon failed"
[ "$out" = "no daemon on $sock; deleted 1 session and the recordings kept with them; ids start at 1 again" ] || fail "unexpected output of a reset without a daemon: $out"
[ ! -e "$sock" ] || fail "a reset without a daemon left an endpoint behind"
[ "$("$BIN" run true)" = 1 ] || fail "ids did not start at 1 after a reset without a daemon"
"$BIN" wait 1 -e >/dev/null

# --all shuts down the other daemons the store names, then the target; a
# supervised daemon exits 0.
other="$dir/other.sock"
start_supervised "$other"
supervised=${pids[-1]}
"$BIN" --socket "$other" run sleep 300 >/dev/null
"$BIN" shutdown --all >"$dir/all.out" || fail "shutdown --all failed"
grep -q "^stopped 1 running session (2) and the daemon on $other; kept 1 ended session$" "$dir/all.out" || fail "--all did not shut down the other daemon: $(cat "$dir/all.out")"
grep -q "^stopped the daemon on $sock; kept 1 ended session$" "$dir/all.out" || fail "--all did not shut down the target: $(cat "$dir/all.out")"
status=0
wait "$supervised" || status=$?
[ "$status" = 0 ] || fail "a supervised daemon exited $status on shutdown"

# A run racing a shutdown never loses its session: it runs in the old
# daemon and is stopped, or it waits and runs in the next one.
"$BIN" run "${stubborn[@]}" >/dev/null
"$BIN" shutdown >/dev/null &
shutdown_pid=$!
for i in 1 2 3 4 5 6; do
    "$BIN" run sleep 300 >"$dir/race.$i" &
    pids+=($!)
    sleep 0.1
done
wait "$shutdown_pid" || fail "the racing shutdown failed"
for i in 1 2 3 4 5 6; do wait "${pids[-$i]}" || fail "a run racing the shutdown failed"; done
"$BIN" list -j | json '" ".join(str(s["id"]) for s in r["sessions"] if s["state"] != "lost")' >"$dir/kept"
for i in 1 2 3 4 5 6; do
    id=$(cat "$dir/race.$i")
    [[ " $(cat "$dir/kept") " == *" $id "* ]] || fail "session $id of a racing run was lost"
done

# An explicit endpoint that is shutting down is refused, not retried.
start_supervised "$other"
supervised=${pids[-1]}
"$BIN" --socket "$other" run "${stubborn[@]}" >/dev/null
"$BIN" --socket "$other" shutdown >/dev/null &
shutdown_pid=$!
refused=
for _ in $(seq 100); do
    if ! "$BIN" --socket "$other" list >/dev/null 2>"$dir/refused"; then refused=$(cat "$dir/refused"); break; fi
    sleep 0.02
done
[ "$refused" = "tuppet: the daemon on $other is shutting down" ] || fail "a stopping explicit endpoint was not refused as such: $refused"
wait "$shutdown_pid" || fail "the shutdown of the explicit endpoint failed"
wait "$supervised" || fail "the supervised daemon did not exit 0"

# SIGTERM shuts down an auto-started daemon as a shutdown does.
term=$("$BIN" run sleep 300)
daemon=$(python3 -c 'import socket, struct, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
print(struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0])' "$sock")
kill -TERM "$daemon"
for _ in $(seq 250); do [ -S "$sock" ] || break; sleep 0.02; done
[ ! -S "$sock" ] || fail "SIGTERM did not stop the auto-started daemon"
[ "$("$BIN" list -j "$term" | json 'r["sessions"][0]["exit"]["stopped"]')" = True ] || fail "SIGTERM did not stop and save the session"

echo "PASS: shutdown, --reset, --all, supervised daemons, requests racing a shutdown, SIGTERM"

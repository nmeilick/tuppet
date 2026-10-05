#!/usr/bin/env bash
# Supervised daemon mode: explicit --socket endpoint, clients that never
# auto-start, hello, the daemon's environment for env-less runs, and
# session children that never outlive the daemon.
set -euo pipefail
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
# Session data goes to the test directory, never to the user's store.
export XDG_STATE_HOME="$dir/state"
sock="$dir/s.sock"
daemon_pid=
cleanup() {
    [ -n "$daemon_pid" ] && kill -KILL "$daemon_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$dir"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
start_daemon() {
    TUPPET_PROBE=from-daemon "$BIN" daemon --socket "$sock" --log "$dir/log" &
    daemon_pid=$!
    for _ in $(seq 100); do "$BIN" --socket "$sock" list >/dev/null 2>&1 && return 0; sleep 0.02; done
    fail "daemon did not listen on $sock"
}
# Wait until none of the given pids exist (up to 2 s).
gone() {
    for _ in $(seq 100); do
        local alive=0
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" -eq 0 ] && return 0
        sleep 0.02
    done
    return 1
}
request() { python3 - "$sock" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
print(s.makefile().readline().strip())
PY
}

# No daemon listening: an explicit endpoint fails instead of starting one.
if "$BIN" --socket "$sock" list 2>/dev/null; then fail "client without a daemon succeeded"; fi
[ ! -e "$sock" ] || fail "client started a daemon on the explicit socket"

start_daemon
[ "$(stat -c %a "$sock")" = 600 ] || fail "socket mode is not 0600"
if timeout 2 "$BIN" daemon --socket "$sock" 2>/dev/null; then fail "second daemon on a live socket succeeded"; fi

request '{"cmd":"hello"}' | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["version"] and isinstance(r["protocol"], int) and isinstance(r["features"], list), r'

# --socket and TUPPET_SOCKET reach the daemon; a run without env gets the
# daemon's environment.
id=$("$BIN" --socket "$sock" run sleep 300)
TUPPET_SOCKET="$sock" "$BIN" list | grep -q "^$id	" || fail "TUPPET_SOCKET client does not see the session"
probe=$(request '{"cmd":"run","argv":["sh","-c","echo $TUPPET_PROBE; sleep 300"]}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
TUPPET_SOCKET="$sock" "$BIN" wait "$probe" --match from-daemon --timeout 2000 >/dev/null || fail "env-less run lacks the daemon's environment"

# SIGTERM stops every session and exits.
pids=$(TUPPET_SOCKET="$sock" "$BIN" list | awk -F'\t' '$4 == "running" { print $2 }')
kill -TERM "$daemon_pid"
gone "$daemon_pid" || fail "daemon did not exit on SIGTERM"
# shellcheck disable=SC2086
gone $pids || fail "SIGTERM left session children running"

# SIGKILL: children die with the daemon; the stale socket is replaced.
start_daemon
TUPPET_SOCKET="$sock" "$BIN" run sleep 300 >/dev/null
# Ignoring SIGHUP survives the pty hangup; only the parent-death signal
# can end this one.
TUPPET_SOCKET="$sock" "$BIN" run sh -c 'trap "" HUP; exec sleep 300' >/dev/null
pids=$(TUPPET_SOCKET="$sock" "$BIN" list | awk -F'\t' '$4 == "running" { print $2 }')
kill -KILL "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
# shellcheck disable=SC2086
gone $pids || fail "SIGKILL left session children running"
start_daemon
TUPPET_SOCKET="$sock" "$BIN" list >/dev/null || fail "stale socket was not replaced"

echo "PASS: supervised mode, hello, explicit sockets, daemon environment, child cleanup"

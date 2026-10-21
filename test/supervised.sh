#!/usr/bin/env bash
# Supervised daemon mode: explicit --socket endpoint, clients that never
# auto-start, hello and the protocol check, the daemon's environment for
# env-less runs, and session children that never outlive the daemon.
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

# Running sessions' pids.
running_pids() {
    TUPPET_SOCKET="$sock" "$BIN" list -j | python3 -c '
import json, sys
print(" ".join(str(s["pid"]) for s in json.load(sys.stdin)["sessions"] if s["state"] == "running"))'
}

# No daemon listening: an explicit endpoint fails instead of starting one.
if "$BIN" --socket "$sock" list 2>/dev/null; then fail "client without a daemon succeeded"; fi
[ ! -e "$sock" ] || fail "client started a daemon on the explicit socket"

# A daemon of an older protocol revision is refused with a way out.
python3 - "$sock" <<'PY' &
import os, socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(4)
conn, _ = s.accept()
conn.makefile().readline()
conn.sendall(b'{"ok":true,"version":"0.0.0","protocol":1,"features":[],"boot":"x"}\n')
conn.close()
os.unlink(sys.argv[1])
PY
old_pid=$!
for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.02; done
if "$BIN" --socket "$sock" list 2>"$dir/old.err"; then fail "a protocol 1 daemon was used"; fi
wait "$old_pid"
grep -q "speaks protocol 1, but this tuppet needs 2; restart that daemon" "$dir/old.err" || fail "the protocol mismatch was not explained"

start_daemon
[ "$(stat -c %a "$sock")" = 600 ] || fail "socket mode is not 0600"
if timeout 2 "$BIN" daemon --socket "$sock" 2>/dev/null; then fail "second daemon on a live socket succeeded"; fi

request '{"cmd":"hello"}' | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["version"] and r["protocol"] == 2 and isinstance(r["features"], list) and r["boot"], r'

# --socket and TUPPET_SOCKET reach the daemon; a run without env gets the
# daemon's environment.
id=$("$BIN" --socket "$sock" run sleep 300)
TUPPET_SOCKET="$sock" "$BIN" list "$id" | grep -q "^ *$id " || fail "TUPPET_SOCKET client does not see the session"
probe=$(request '{"cmd":"run","argv":["sh","-c","echo $TUPPET_PROBE $TUPPET_SESSION; sleep 300"]}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])')
TUPPET_SOCKET="$sock" "$BIN" wait "$probe" --match "from-daemon $probe" --timeout 2s >/dev/null || fail "env-less run lacks the daemon's environment or TUPPET_SESSION"

# SIGTERM ends attach streams with reason shutdown, stops every session,
# and exits.
python3 - "$sock" "$id" "$dir/viewer" <<'PY' &
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(json.dumps({"cmd": "attach", "session": sys.argv[2]}).encode() + b"\n")
f = s.makefile("rb")
f.readline()
open(sys.argv[3] + ".ready", "w").close()
reason = None
for line in f:
    reason = json.loads(line).get("end", {}).get("reason", reason)
open(sys.argv[3], "w").write(str(reason))
PY
viewer_pid=$!
for _ in $(seq 100); do [ -e "$dir/viewer.ready" ] && break; sleep 0.02; done
pids=$(running_pids)
kill -TERM "$daemon_pid"
gone "$daemon_pid" || fail "daemon did not exit on SIGTERM"
# shellcheck disable=SC2086
gone $pids || fail "SIGTERM left session children running"
wait "$viewer_pid"
[ "$(cat "$dir/viewer")" = shutdown ] || fail "an attach stream did not end with reason shutdown"

# SIGKILL: children die with the daemon; the stale socket is replaced.
start_daemon
TUPPET_SOCKET="$sock" "$BIN" run sleep 300 >/dev/null
# Ignoring SIGHUP survives the pty hangup; only the parent-death signal
# can end this one.
TUPPET_SOCKET="$sock" "$BIN" run sh -c 'trap "" HUP; exec sleep 300' >/dev/null
pids=$(running_pids)
kill -KILL "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
# shellcheck disable=SC2086
gone $pids || fail "SIGKILL left session children running"
start_daemon
TUPPET_SOCKET="$sock" "$BIN" list >/dev/null || fail "stale socket was not replaced"

echo "PASS: supervised mode, hello, explicit sockets, daemon environment, shutdown, child cleanup"

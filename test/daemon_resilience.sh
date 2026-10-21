#!/bin/sh
# Daemon robustness: endpoint ownership, malformed and stalled clients,
# stalled children, session lifecycle, and running without statx.
# Every check is bounded to a few seconds.
set -eu
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN=$(realpath "${BIN:-./zig-out/bin/tuppet}")
test_dir=$(mktemp -d)
daemon_pid=
blocker_pid=
old_kernel_pid=
cleanup() {
    for pid in $blocker_pid $daemon_pid $old_kernel_pid; do
        kill "$pid" 2>/dev/null || true
    done
    # strace exits once its traced daemon does.
    [ -n "$old_kernel_pid" ] && pkill -P "$old_kernel_pid" 2>/dev/null
    wait 2>/dev/null || true
    rm -rf -- "$test_dir"
}
trap cleanup EXIT INT TERM

export XDG_RUNTIME_DIR="$test_dir"
# Session data goes to the test directory too, never to the user's store.
export XDG_STATE_HOME="$test_dir/state"
socket="$test_dir/tuppet-$(id -u).sock"
# wait_for_socket PATH [LOG...]: the logs are shown if the socket never
# appears.
wait_for_socket() {
    path=$1
    shift
    for _ in $(seq 250); do
        [ -S "$path" ] && return 0
        sleep 0.02
    done
    echo "daemon did not create $path" >&2
    for log in "$@"; do
        echo "--- $log ---" >&2
        cat "$log" >&2 || true
    done
    exit 1
}

"$BIN" daemon >"$test_dir/daemon.log" 2>&1 &
daemon_pid=$!
wait_for_socket "$socket"

# A second daemon must exit with an error at once, without replacing the
# live daemon's endpoint (timeout's 124 means it kept running).
set +e
timeout 2 "$BIN" daemon >/dev/null 2>&1
status=$?
set -e
if [ "$status" -eq 0 ] || [ "$status" -eq 124 ]; then
    echo "second daemon did not fail on the live endpoint (status $status)" >&2
    exit 1
fi

# Malformed envelopes get JSON errors; a peer that never finishes its
# line does not block other clients.
python3 - "$socket" <<'PY'
import json
import socket
import sys

path = sys.argv[1]
for request in (b"[]\n", b"{}\n", b'{"cmd":1}\n', b'{"cmd":"run","argv":[]}\n'):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.connect(path)
        peer.sendall(request)
        response = b""
        while not response.endswith(b"\n"):
            response += peer.recv(4096)
        reply = json.loads(response)
        assert reply["ok"] is False and reply["code"] == "bad_request", response
PY
python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"{\"cmd\":\"list\""); print("sent", flush=True); time.sleep(30)' "$socket" >"$test_dir/blocker" &
blocker_pid=$!
for _ in $(seq 250); do grep -q sent "$test_dir/blocker" && break; sleep 0.02; done
grep -q sent "$test_dir/blocker"
timeout 1 "$BIN" list >/dev/null

# A large, compressible screen is checked after encoding, not rejected
# from its uncompressed size.
big=$("$BIN" run --size 256x96 sh -c 'printf "\342\226\200"; sleep 5')
"$BIN" png "$big" "$test_dir/screen.png"
test -s "$test_dir/screen.png"
"$BIN" stop "$big"
huge=$("$BIN" run --size 1000x1000 sleep 5)
if "$BIN" png "$huge" "$test_dir/huge.png" 2>"$test_dir/huge.err"; then exit 1; fi
grep -q '128 MiB render limit' "$test_dir/huge.err"
"$BIN" stop "$huge"

# Input to a child that stops reading must not block other requests,
# and stopping the child ends the input at once.
stuck=$("$BIN" run sh -c 'stty raw -echo; exec sleep 300')
for _ in $(seq 250); do "$BIN" list -j "$stuck" | grep -q '"canonical":false' && break; sleep 0.02; done
"$BIN" list -j "$stuck" | grep -q '"canonical":false'
# Three arguments: one would exceed the 128 KiB per-argument limit.
chunk=$(head -c 100000 /dev/zero | tr '\0' x)
"$BIN" do "$stuck" -s "$chunk" -s "$chunk" -s "$chunk" >/dev/null 2>&1 &
send_pid=$!
# input_seq is taken as the batch starts writing.
for _ in $(seq 250); do "$BIN" list -j "$stuck" | grep -q '"input_seq":[0-9]' && break; sleep 0.02; done
"$BIN" list -j "$stuck" | grep -q '"input_seq":[0-9]'
timeout 1 "$BIN" list >/dev/null
timeout 1 "$BIN" stop "$stuck"
if wait "$send_pid"; then
    echo "input to a child that never reads succeeded" >&2
    exit 1
fi
timeout 1 "$BIN" remove "$stuck"

# A background job holding the pty must not keep the session running or
# hang stop; the shell passes stop's hangup on to the job.
shell=$("$BIN" run bash --norc --noprofile -i)
"$BIN" wait "$shell" --idle 100ms --timeout 2s >/dev/null
"$BIN" key "$shell" 'sleep 301 &' '<Enter>'
"$BIN" wait "$shell" --match '[1] ' --after-input --timeout 2s >/dev/null
timeout 2 "$BIN" stop "$shell"
"$BIN" list -j "$shell" | grep -q '"state":"exited"'

# Sessions run in the caller's directory, not the daemon's.
mkdir "$test_dir/here"
here=$(cd "$test_dir/here" && "$BIN" run pwd)
"$BIN" wait "$here" --match /here --timeout 2s >/dev/null

# Kernels before 4.11 have no statx (tuppet supports Linux 3.10): with it
# failing as ENOSYS, the daemon still starts and runs a session.
if ! command -v strace >/dev/null 2>&1; then
    echo "skipping the check without statx: strace is not installed" >&2
elif ! strace -f -qq -o /dev/null -e trace=statx -e inject=statx:error=ENOSYS true 2>"$test_dir/strace-probe.log"; then
    echo "skipping the check without statx: strace cannot inject errors here:" >&2
    cat "$test_dir/strace-probe.log" >&2
else
    old_dir="$test_dir/old"
    mkdir "$old_dir"
    XDG_RUNTIME_DIR=$old_dir strace -f -qq -o "$test_dir/strace.log" -e trace=statx -e inject=statx:error=ENOSYS \
        "$BIN" daemon >"$test_dir/old-daemon.log" 2>&1 &
    old_kernel_pid=$!
    wait_for_socket "$old_dir/tuppet-$(id -u).sock" "$test_dir/old-daemon.log" "$test_dir/strace.log"
    old_id=$(XDG_RUNTIME_DIR=$old_dir "$BIN" run echo no-statx)
    XDG_RUNTIME_DIR=$old_dir "$BIN" wait "$old_id" --match no-statx --timeout 2s >/dev/null
fi

# An auto-started daemon exits once it has had no sessions or clients for
# TUPPET_IDLE_EXIT, removing its socket; the next command starts a new one.
idle_dir="$test_dir/idle"
mkdir "$idle_dir"
XDG_RUNTIME_DIR=$idle_dir TUPPET_IDLE_EXIT=1s "$BIN" list >/dev/null
wait_for_socket "$idle_dir/tuppet-$(id -u).sock"
for _ in $(seq 150); do
    [ -S "$idle_dir/tuppet-$(id -u).sock" ] || break
    sleep 0.02
done
if [ -S "$idle_dir/tuppet-$(id -u).sock" ]; then echo "the idle daemon did not exit" >&2; exit 1; fi
XDG_RUNTIME_DIR=$idle_dir TUPPET_IDLE_EXIT=1s "$BIN" list >/dev/null

# A daemon that cannot start says why as soon as it exits, with only what
# this start logged, and without a timeout on top.
fail_dir="$test_dir/fail"
mkdir "$fail_dir"
: >"$test_dir/statefile"
echo "a line of an earlier start" >"$fail_dir/tuppet-$(id -u).log"
if XDG_RUNTIME_DIR=$fail_dir XDG_STATE_HOME=$test_dir/statefile "$BIN" list 2>"$test_dir/fail.err"; then exit 1; fi
grep -q "cannot use the session store in $test_dir/statefile/tuppet: a part of its path is not a directory" "$test_dir/fail.err"
if grep -q "earlier start\|in time" "$test_dir/fail.err"; then cat "$test_dir/fail.err" >&2; exit 1; fi

# A request still queued when a daemon exits was never read, so the
# client retries it against a new daemon. The fake daemon closes its
# listener as soon as a client is queued, as an exiting daemon does.
reset_dir="$test_dir/reset"
mkdir "$reset_dir"
python3 - "$reset_dir/tuppet-$(id -u).sock" <<'PY' &
import os, select, socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(4)
select.select([s], [], [], 5)
os.unlink(sys.argv[1])
s.close()
PY
fake_pid=$!
wait_for_socket "$reset_dir/tuppet-$(id -u).sock"
XDG_RUNTIME_DIR=$reset_dir TUPPET_IDLE_EXIT=1s "$BIN" list >/dev/null
wait "$fake_pid"

echo "daemon resilience checks passed"

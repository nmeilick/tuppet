#!/usr/bin/env bash
# The daemon's write_pty effect must answer the child's
# DSR query (CSI 6 n) with the cursor position report (ESC [ 1 ; 1 R).
set -euo pipefail
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN="${BIN:-./zig-out/bin/tuppet}"
NAME="dsr"

# Run against an isolated daemon in a temp runtime dir so the test never
# touches (or leaks sessions into) the user's real daemon.
test_dir="$(mktemp -d)"
daemon_pid=
cleanup() {
    if [ -n "$daemon_pid" ]; then
        kill "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export XDG_RUNTIME_DIR="$test_dir"
# Session data goes to the test directory too, never to the user's store.
export XDG_STATE_HOME="$test_dir/state"
"$BIN" daemon >"$test_dir/daemon.log" 2>&1 &
daemon_pid=$!

for _ in $(seq 1 100); do
    [ -S "$test_dir/tuppet-$(id -u).sock" ] && break
    sleep 0.02
done
[ -S "$test_dir/tuppet-$(id -u).sock" ] || { echo "FAIL: daemon did not start"; exit 1; }

# Child: switch the PTY to raw mode, query the cursor position, read the
# 6-byte response, print it as hex, restore sane mode.
ID="$("$BIN" run --name "$NAME" bash -c \
  'stty raw -echo; printf "\033[6n"; dd bs=1 count=6 2>/dev/null | od -An -tx1; stty sane')"

"$BIN" wait "$ID" --exit --timeout 5000

out="$("$BIN" view "$ID")"
echo "--- screen ---"
echo "$out"
echo "---------------"

if echo "$out" | grep -q "1b 5b 31 3b 31 52"; then
    echo "PASS: write_pty answered DSR with ESC[1;1R"
else
    echo "FAIL: DSR response missing from screen"
    "$BIN" remove "$ID" || true
    exit 1
fi

"$BIN" remove "$ID"

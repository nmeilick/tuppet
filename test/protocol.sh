#!/usr/bin/env bash
# Socket-protocol features for programmatic clients: paste and attach.
set -euo pipefail

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
# Session data goes to the test directory, never to the user's store.
export XDG_STATE_HOME="$dir/state"
export TUPPET_SOCKET="$dir/s.sock"
daemon_pid=
cleanup() {
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

"$BIN" daemon --socket "$TUPPET_SOCKET" 2>"$dir/log" &
daemon_pid=$!
for _ in $(seq 100); do "$BIN" list >/dev/null 2>&1 && break; sleep 0.02; done

# One request, one JSON reply line.
request() { python3 - "$TUPPET_SOCKET" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
print(s.makefile().readline().strip())
PY
}

# --- paste ---------------------------------------------------------------
request '{"cmd":"hello"}' | grep -q '"features":\[[^]]*"paste"' || fail "hello does not list paste"
# cat -v shows exactly what arrives: ^[ for ESC, ^M for CR.
on=$("$BIN" run sh -c 'stty raw -echo; printf "\033[?2004hREADY"; exec cat -v')
off=$("$BIN" run sh -c 'stty raw -echo; printf READY; exec cat -v')
"$BIN" wait "$on" --match READY --timeout 2000 >/dev/null
"$BIN" wait "$off" --match READY --timeout 2000 >/dev/null
request "{\"cmd\":\"send\",\"id\":\"$on\",\"data\":\"a\\nb\",\"paste\":true}" | grep -q '"bracketed":true' \
    || fail "paste to a mode-2004 app did not report bracketed:true"
request "{\"cmd\":\"send\",\"id\":\"$off\",\"data\":\"a\\nb\",\"paste\":true}" | grep -q '"bracketed":false' \
    || fail "paste without mode 2004 did not report bracketed:false"
"$BIN" wait "$on" --match '^[[200~a^Mb^[[201~' --timeout 2000 >/dev/null || fail "paste was not wrapped"
"$BIN" wait "$off" --match 'a^Mb' --timeout 2000 >/dev/null || fail "unbracketed paste was changed"
"$BIN" view "$off" | grep -q '200~' && fail "unbracketed paste was wrapped"
"$BIN" send "$off" --paste x >/dev/null || fail "tuppet send --paste failed"

# --- attach --------------------------------------------------------------
att() { python3 "$(dirname "$0")/attach_check.py" "$TUPPET_SOCKET" "$@"; }

sh_id=$("$BIN" run bash --norc --noprofile -i)
"$BIN" wait "$sh_id" --idle 100 --timeout 2000 >/dev/null
"$BIN" key "$sh_id" 'echo one' '<Enter>'
"$BIN" wait "$sh_id" --match one --timeout 2000 >/dev/null
att replay "$sh_id" "$BIN"
att writers "$sh_id"
att pipelined "$sh_id"

# tuppet attach shows the current screen at once, even when it is idle.
idle=$("$BIN" run sh -c 'echo HELLO-MARKER; sleep 30')
"$BIN" wait "$idle" --match HELLO-MARKER --timeout 2000 >/dev/null
timeout 1 "$BIN" attach "$idle" --read-only </dev/null >"$dir/attach.out" 2>/dev/null || true
grep -q HELLO-MARKER "$dir/attach.out" || fail "tuppet attach did not show the current screen"

# tuppet attach keeps the program's queries and reporting modes away from the
# user's terminal: the daemon already answers them.
asks=$("$BIN" run sh -c 'echo READY; read x; printf "\033[c\033[6n\033]11;?\007\033[?1049;2048hQUERIES-SENT"; read x')
"$BIN" wait "$asks" --match READY --timeout 2000 >/dev/null
"$BIN" attach "$asks" --read-only </dev/null >"$dir/asks.out" 2>/dev/null &
attach_pid=$!
for _ in $(seq 100); do grep -q READY "$dir/asks.out" && break; sleep 0.02; done
"$BIN" send "$asks" "go
"
for _ in $(seq 100); do grep -q QUERIES-SENT "$dir/asks.out" && break; sleep 0.02; done
kill "$attach_pid"; wait "$attach_pid" 2>/dev/null || true
grep -q QUERIES-SENT "$dir/asks.out" || fail "attach did not show the output after the queries"
if grep -qE $'\e\[c|\e\[6n|\e\]11;\\?|2048' "$dir/asks.out"; then fail "attach passed a query to the terminal"; fi
grep -q $'\e\[?1049h' "$dir/asks.out" || fail "attach dropped a mode that is not a reporting mode"
"$BIN" stop "$asks" >/dev/null

# A client that stopped reading cannot hold an exited session.
held=$("$BIN" run sh -c "read x; head -c 1500000 /dev/zero | tr '\\0' y; exit 7")
# exec, so that killing the background job kills the client itself.
(exec python3 "$(dirname "$0")/attach_check.py" "$TUPPET_SOCKET" stalled "$held") &
stalled_pid=$!
sleep 0.2
"$BIN" send "$held" "go
"
"$BIN" wait "$held" --exit --timeout 3000 >/dev/null
timeout 3 "$BIN" remove "$held" || fail "a stalled attach client blocked remove"
kill "$stalled_pid" 2>/dev/null || true

flood=$("$BIN" run sh -c 'read x; yes | head -c 8000000; sleep 30')
att slow "$flood" "$BIN"
"$BIN" list | grep -q "^$flood	.*	running	" || fail "slow viewer stopped the session"

done_id=$("$BIN" run sh -c 'sleep 0.5; exit 4')
att exits "$done_id"
code_id=$("$BIN" run sh -c 'sleep 0.5; exit 5')
set +e
"$BIN" attach "$code_id" </dev/null >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 5 ] || fail "tuppet attach exited $status, not the child's 5"

# tuppet run -a starts a session and attaches to it, ending with the
# program's exit code.
set +e
"$BIN" run -a sh -c 'echo RUN-ATTACHED; exit 3' </dev/null >"$dir/run-a.out" 2>/dev/null
status=$?
set -e
[ "$status" -eq 3 ] || fail "tuppet run -a exited $status, not the program's 3"
grep -q RUN-ATTACHED "$dir/run-a.out" || fail "tuppet run -a did not show the program"

echo "PASS: paste, attach"

#!/usr/bin/env bash
# The session store: ids that continue across daemons, ended sessions
# served from disk, lost sessions, expiry, other boots' directories, and
# recordings made with run --record.
set -euo pipefail
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
export XDG_RUNTIME_DIR="$dir"
export XDG_STATE_HOME="$dir/state"
export TUPPET_IDLE_EXIT=1
sock="$dir/tuppet-$(id -u).sock"
# This test's daemon: the tuppet daemon whose runtime directory is $dir.
our_daemon() {
    for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
        if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir"; then
            echo "$pid"
        fi
    done
}
cleanup() {
    local pid
    for pid in $(our_daemon); do kill "$pid" 2>/dev/null || true; done
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
boot=$(tr -d '\n' </proc/sys/kernel/random/boot_id)
store="$dir/state/tuppet/$(tr -d '\n' </etc/machine-id)"
daemon_gone() {
    for _ in $(seq 150); do [ -S "$sock" ] || return 0; sleep 0.02; done
    return 1
}

# Other boots' directories go when a daemon starts; anything else stays.
mkdir -p "$store/00000000-0000-0000-0000-000000000001/1" "$store/notes" "$dir/state/tuppet/other-machine/00000000-0000-0000-0000-000000000002"
first=$("$BIN" run sh -c 'echo FIRST-OUTPUT; exit 7')
"$BIN" wait "$first" --exit >/dev/null
[ ! -e "$store/00000000-0000-0000-0000-000000000001" ] || fail "another boot's directory was kept"
[ -d "$store/notes" ] || fail "an unrelated directory was deleted"
[ -d "$dir/state/tuppet/other-machine/00000000-0000-0000-0000-000000000002" ] || fail "another machine's boot was deleted"
[ "$(stat -c %a "$store/$boot/$first/session.json")" = 600 ] || fail "session data is not private"

# run --record writes into the session's directory from the first byte,
# and a trace ends with the exit code.
rec=$("$BIN" run --record --record-format trace sh -c 'echo RECORDED; exit 5')
"$BIN" wait "$rec" --exit >/dev/null
for _ in $(seq 100); do grep -q '"ev":"stop"' "$store/$boot/$rec/output.trace" 2>/dev/null && break; sleep 0.02; done
grep -q RECORDED "$store/$boot/$rec/output.trace" || fail "the recording missed the first output"
grep -q '"reason":"exit","exit_code":5' "$store/$boot/$rec/output.trace" || fail "the trace lacks the exit code"
"$BIN" view "$rec" --format json | grep -q "\"recording\":\"$store/$boot/$rec/output.trace\"" \
    || fail "view does not name the recording"

# A program whose output scrolled, with a blank last row and a scroll
# region set. Removing a session right after it exited works.
scrolled=$("$BIN" run sh -c 'seq 1 100; printf "\033[3;8r\033[5;2Hcur"')
"$BIN" wait "$scrolled" --exit >/dev/null
scrolled_before=$("$BIN" view "$scrolled" --format json | sed 's/"idle_ms":[0-9]*//')
quick=$("$BIN" run true)
"$BIN" wait "$quick" --exit >/dev/null
"$BIN" remove "$quick" || fail "remove right after the program exited failed"

# An ended session holds no descriptors, and keeps its last size.
fds() { ls "/proc/$(our_daemon)/fd" | wc -l; }
before=$(fds)
for _ in 1 2 3; do "$BIN" wait "$("$BIN" run true)" --exit >/dev/null; done
[ "$(fds)" -le "$before" ] || fail "ended sessions keep descriptors open"
resized=$("$BIN" run --size 40x10 sh -c 'read x')
"$BIN" resize "$resized" 100x10
"$BIN" send "$resized" "
"
"$BIN" wait "$resized" --exit >/dev/null

# With no programs running the daemon exits; the next one continues the
# ids and serves ended sessions from disk.
daemon_gone || fail "the idle daemon did not exit"
# A restored screen keeps its blank bottom row and its cursor.
scrolled_view=$("$BIN" view "$scrolled" --format json | sed 's/"idle_ms":[0-9]*//')
[ "$scrolled_view" = "$scrolled_before" ] || fail "a restored screen differs from the original"
next=$("$BIN" run --scrollback 0 sh -c 'seq 1 100')
[ "$next" -gt "$rec" ] || fail "id $next reuses an earlier one"
"$BIN" view "$first" | grep -q FIRST-OUTPUT || fail "an ended session's screen was not kept"
"$BIN" list | grep -q "^$first	.*	exited	120x40	7$" || fail "list lacks the exit status"
"$BIN" list | grep -q "^$resized	.*	exited	100x10	0$" || fail "a restored session lost its last size"
"$BIN" wait "$next" --exit >/dev/null
[ "$("$BIN" view "$next" --scrollback | wc -l)" -le 40 ] || fail "--scrollback 0 kept history"

# A daemon killed while its program runs leaves the session lost.
lost=$("$BIN" run sleep 300)
kill -KILL "$(our_daemon)"
"$BIN" list | grep -q "^$lost	.*	lost	" || fail "a session of a killed daemon is not lost"
if "$BIN" view "$lost" 2>"$dir/lost.err"; then fail "a lost session has a screen"; fi
grep -q 'was lost' "$dir/lost.err" || fail "the error does not say the session was lost"

# Ended sessions expire; removing one never frees its id.
"$BIN" remove "$lost"
daemon_gone || fail "the daemon did not exit"
sleep 1.1
TUPPET_KEEP=1s "$BIN" list >/dev/null
for _ in $(seq 100); do [ -d "$store/$boot/$first" ] || break; sleep 0.02; done
[ ! -d "$store/$boot/$first" ] || fail "an expired session was kept"
last=$("$BIN" run true)
[ "$last" -gt "$lost" ] || fail "id $last reuses a removed one"

echo "PASS: store ids, ended and lost sessions, expiry, other boots, run --record"

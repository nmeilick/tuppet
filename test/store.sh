#!/usr/bin/env bash
# The session store: ids that continue across daemons, ended sessions
# served from disk, lost and damaged sessions, expiry, other boots'
# directories, recordings made with run --record, and the memory budget.
set -euo pipefail
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
export XDG_RUNTIME_DIR="$dir"
export XDG_STATE_HOME="$dir/state"
export TUPPET_IDLE_EXIT=1s
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
# status ID EXPRESSION: a Python expression over the session's status s.
status() { "$BIN" list -j "$1" | python3 -c "import json, sys; s = json.load(sys.stdin)['sessions'][0]; print($2)"; }
# The screen as view -j shows it: text, cursor, and size.
screen_of() {
    "$BIN" view "$1" -j | python3 -c 'import json, sys; r = json.load(sys.stdin); print(json.dumps([r["text"], r["cursor"], r["status"]["cols"], r["status"]["rows"]]))'
}
boot=$(tr -d '\n' </proc/sys/kernel/random/boot_id)
store="$dir/state/tuppet/$(tr -d '\n' </etc/machine-id)"
daemon_gone() {
    for _ in $(seq 150); do [ -S "$sock" ] || return 0; sleep 0.02; done
    return 1
}

# Other boots' directories go when a daemon starts; anything else stays.
mkdir -p "$store/00000000-0000-0000-0000-000000000001/1" "$store/notes" "$dir/state/tuppet/other-machine/00000000-0000-0000-0000-000000000002"
first=$("$BIN" run sh -c 'echo FIRST-OUTPUT; exit 7')
"$BIN" wait "$first" --ended >/dev/null
[ ! -e "$store/00000000-0000-0000-0000-000000000001" ] || fail "another boot's directory was kept"
[ -d "$store/notes" ] || fail "an unrelated directory was deleted"
[ -d "$dir/state/tuppet/other-machine/00000000-0000-0000-0000-000000000002" ] || fail "another machine's boot was deleted"
[ "$(stat -c %a "$store/$boot/$first/session.json")" = 600 ] || fail "session data is not private"

# run --record writes into the session's directory from the first byte,
# and a trace ends with the exit code.
rec=$("$BIN" run --record --record-format trace sh -c 'echo RECORDED; exit 5')
"$BIN" wait "$rec" --ended >/dev/null
for _ in $(seq 100); do grep -q '"ev":"stop"' "$store/$boot/$rec/output.trace" 2>/dev/null && break; sleep 0.02; done
grep -q RECORDED "$store/$boot/$rec/output.trace" || fail "the recording missed the first output"
grep -q '"reason":"ended","exit_code":5' "$store/$boot/$rec/output.trace" || fail "the trace lacks the exit code"
"$BIN" list "$rec" -j | python3 -c '
import json, sys
r = json.load(sys.stdin)["sessions"][0]["recording"]
sys.exit(0 if r["path"] == sys.argv[1] and r["format"] == "trace" else 1)' "$store/$boot/$rec/output.trace" \
    || fail "an ended session's status does not give its recording"

# A program whose output scrolled, with a blank last row below one erased
# in color, a scroll region, and origin mode set. Removing a session right
# after it exited works.
scrolled=$("$BIN" run sh -c 'seq 1 100; printf "\033[39H\033[44m\033[K\033[m\033[3;8r\033[?6h\033[5;2Hcur"')
"$BIN" wait "$scrolled" --ended >/dev/null
scrolled_before=$(screen_of "$scrolled")
quick=$("$BIN" run true)
"$BIN" wait "$quick" --ended >/dev/null
"$BIN" remove "$quick" || fail "remove right after the program exited failed"

# An ended session holds no descriptors, and keeps its last size.
fds() { ls "/proc/$(our_daemon)/fd" | wc -l; }
before=$(fds)
for _ in 1 2 3; do "$BIN" wait "$("$BIN" run true)" --ended >/dev/null; done
[ "$(fds)" -le "$before" ] || fail "ended sessions keep descriptors open"
resized=$("$BIN" run --size 40x10 sh -c 'read x')
"$BIN" resize "$resized" 100x10
"$BIN" key "$resized" '<Enter>'
"$BIN" wait "$resized" --ended >/dev/null

# With no programs running the daemon exits; the next one continues the
# ids and serves ended sessions from disk.
daemon_gone || fail "the idle daemon did not exit"
# A restored screen keeps its blank bottom row and its cursor.
scrolled_view=$(screen_of "$scrolled")
[ "$scrolled_view" = "$scrolled_before" ] || fail "a restored screen differs from the original"
next=$("$BIN" run --scrollback 0 sh -c 'seq 1 100')
[ "$next" -gt "$rec" ] || fail "id $next reuses an earlier one"
"$BIN" view "$first" | grep -q FIRST-OUTPUT || fail "an ended session's screen was not kept"
"$BIN" list "$first" | grep -q " failed 7 " || fail "list lacks the exit status"
[ "$(status "$first" "s['exit']['code'], s['cols'], s['end_seq'] > s['start_seq']")" = "7 120 True" ] \
    || fail "a stored session's status lacks how and when it ended"
[ "$(status "$resized" "s['state'], s['cols'], s['rows']")" = "exited 100 10" ] || fail "a restored session lost its last size"
"$BIN" wait "$next" --ended >/dev/null
[ "$("$BIN" view "$next" --scrollback | wc -l)" -le 40 ] || fail "--scrollback 0 kept history"

# A daemon killed while its program runs leaves the session lost.
lost=$("$BIN" run sleep 300)
kill -KILL "$(our_daemon)"
[ "$(status "$lost" "s['state']")" = lost ] || fail "a session of a killed daemon is not lost"
if "$BIN" view "$lost" 2>"$dir/lost.err"; then fail "a lost session has a screen"; fi
grep -q 'was lost' "$dir/lost.err" || fail "the error does not say the session was lost"

# Ended sessions expire; removing one never frees its id.
"$BIN" remove "$lost"
daemon_gone || fail "the daemon did not exit"
# A stored session with a size outside the limits is damaged: listed with
# the reason, never loaded, and removable. Neither it nor a seq mark near
# the top of the range keeps a daemon from starting.
sed -i 's/"cols":[0-9]*/"cols":65535/' "$store/$boot/$resized/session.json"
echo 18446744073709551615 >"$store/$boot/seq"
[ "$(status "$resized" "s['damaged']")" = "its stored size 65535x10 is outside 1..1000" ] || fail "a damaged session is not listed as damaged"
if "$BIN" view "$resized" 2>"$dir/damaged.err"; then fail "a damaged session was shown"; fi
grep -q "is damaged" "$dir/damaged.err" || fail "the error does not say the session is damaged"
"$BIN" remove "$resized" || fail "a damaged session cannot be removed"
# So is one whose screen is missing, or whose session.json names another.
rm "$store/$boot/$rec/screen.vt"
if "$BIN" view "$rec" 2>"$dir/noscreen.err"; then fail "a session without its screen was shown"; fi
grep -q "is damaged: its saved screen is missing" "$dir/noscreen.err" || fail "a missing screen: $(cat "$dir/noscreen.err")"
sed -i "s/\"id\":$next,/\"id\":$first,/" "$store/$boot/$next/session.json"
echo garbage >"$store/$boot/$scrolled/session.json"
daemon_gone || fail "the daemon did not exit"
[ "$(status "$next" "s['id'], s['damaged']")" = "$next its session.json names session $first" ] || fail "a session.json of another session is not damaged"
[ "$(status "$scrolled" "s['damaged']")" = "its session.json does not parse" ] || fail "an unreadable session is not listed as damaged"
"$BIN" remove "$scrolled" || fail "an unreadable session cannot be removed"
daemon_gone || fail "the daemon did not exit"
sleep 1.1
TUPPET_KEEP=1s "$BIN" list >/dev/null
for _ in $(seq 100); do [ -d "$store/$boot/$first" ] || break; sleep 0.02; done
[ ! -d "$store/$boot/$first" ] || fail "an expired session was kept"
last=$("$BIN" run true)
[ "$last" -gt "$lost" ] || fail "id $last reuses a removed one"

# A store deleted under the daemon is made again, and a new session never
# takes the id of one the daemon still holds.
holder=$("$BIN" run sleep 300)
rm -rf "$dir/state/tuppet"
"$BIN" run true >/dev/null 2>"$dir/remade.err" || fail "a run after the store was deleted failed: $(cat "$dir/remade.err")"
echo $((holder - 1)) >"$store/$boot/last-id"
again=$("$BIN" run true)
[ "$again" != "$holder" ] || fail "a new session took the id of one the daemon holds"
"$BIN" stop "$holder" >/dev/null

# The memory budget trims history instead of refusing a session, refuses
# one whose screens do not fit and says why; an ended session leaves
# memory to make room.
daemon_gone || fail "the daemon did not exit"
export TUPPET_MEMORY=4M
held=$("$BIN" run sleep 300)
hist=$("$BIN" run -- sh -c 'seq 1 100000; echo DONE; sleep 300')
"$BIN" wait "$hist" -m DONE -t 30s >/dev/null || fail "a session with more history than the budget did not run"
"$BIN" run sleep 300 >/dev/null || fail "a session was refused although its screens fit the memory budget"
"$BIN" list -j "$hist" | grep -q '"history_trimmed":true' || fail "the session over the budget does not report its trimmed history"
if "$BIN" run sleep 300 2>"$dir/budget.err"; then fail "a session whose screens do not fit the memory budget started"; fi
grep -q "memory budget" "$dir/budget.err" || fail "the refusal does not name the memory budget"
"$BIN" stop "$held" >/dev/null
# Each fits once the session before it has saved its results.
fits() {
    for _ in $(seq 100); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.02
    done
    return 1
}
fits "$BIN" run true || fail "an ended session kept its share of the memory budget"
fits "$BIN" view "$held" || fail "an ended session that left memory cannot be shown"
"$BIN" stop '*' >/dev/null
unset TUPPET_MEMORY

echo "PASS: store ids, ended, lost and damaged sessions, expiry, other boots, run --record, memory budget"

#!/usr/bin/env bash
# Flow-tracing acceptance: `tuppet trace` records a whole interaction in one
# call (input events, screen diffs, expect outcomes, stop reason), and
# `tuppet record --until-*` stops daemon-side without losing the final chunk.
set -euo pipefail
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

BIN="${BIN:-./zig-out/bin/tuppet}"

# Isolated daemon in a temp runtime dir: never touches the user's daemon.
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

# Poll for a pattern in a file instead of sleeping a fixed time.
await() {
    for _ in $(seq 100); do
        grep -q "$1" "$2" 2>/dev/null && return 0
        sleep 0.02
    done
    return 1
}

fail() {
    echo "FAIL: $1"
    exit 1
}

ID="$("$BIN" run --name trace --size 40x10 sh)"

# --- 1. happy path: keys + send + expect + mark, JSONL artifact --------

"$BIN" trace "$ID" "$test_dir/flow.trace" \
    --send 'echo hello' --key '<CR>' --expect hello --within 3000 --mark done \
    >"$test_dir/summary.json" || fail "trace exited nonzero"

grep -q '"ok":true' "$test_dir/summary.json" || fail "summary is not ok:true"

trace_file="$test_dir/flow.trace"
[ -s "$trace_file" ] || fail "trace artifact missing or empty"

# Event order: start, snap, in(send), diff..., stop.
[ "$(sed -n 1p "$trace_file" | grep -c '"ev":"start"')" -eq 1 ] || fail "first event is not start"
[ "$(sed -n 2p "$trace_file" | grep -c '"ev":"snap"')" -eq 1 ] || fail "second event is not the initial snap"
grep -q '"ev":"in","kind":"send","text":"echo hello"' "$trace_file" || fail "send input event missing"
grep -q '"ev":"in","kind":"key","keys":\["<CR>"\]' "$trace_file" || fail "key input event missing"
grep -q '"ev":"mark","label":"done"' "$trace_file" || fail "mark event missing"
grep -q '"ev":"stop","reason":"request"' "$trace_file" || fail "stop event missing"

# The input event precedes the diff that shows its effect (causality).
in_line="$(grep -n '"ev":"in","kind":"send"' "$trace_file" | cut -d: -f1)"
diff_line="$(grep -n '"text":"\$ echo hello"' "$trace_file" | cut -d: -f1)"
[ -n "$in_line" ] && [ -n "$diff_line" ] && [ "$in_line" -lt "$diff_line" ] \
    || fail "send event does not precede its screen diff"

# The stop event is last and preceded by a final full snap.
last_two="$(tail -n 2 "$trace_file")"
echo "$last_two" | sed -n 1p | grep -q '"ev":"snap"' || fail "no final snap before stop"
echo "$last_two" | sed -n 2p | grep -q '"ev":"stop"' || fail "stop is not the last event"

# --- 2. expect failure: exit 3, screen on stderr, closed artifact -------

if "$BIN" trace "$ID" "$test_dir/bad.trace" --expect NEVERAPPEARS --within 200 \
    >"$test_dir/bad.json" 2>"$test_dir/bad.err"; then
    fail "trace with impossible expect succeeded"
else
    [ "$?" -eq 3 ] || fail "expect failure did not exit 3"
fi
grep -q '"ok":false' "$test_dir/bad.json" || fail "failure summary is not ok:false"
grep -q '"failed_step":1' "$test_dir/bad.json" || fail "failure summary lacks failed_step"
grep -q 'current screen:' "$test_dir/bad.err" || fail "stderr lacks the screen dump"
grep -q '\$ echo hello' "$test_dir/bad.err" || fail "stderr screen has no session content"
grep -q '"ev":"stop","reason":"request"' "$test_dir/bad.trace" || fail "failed trace was not closed"
grep -q 'expect failed: NEVERAPPEARS' "$test_dir/bad.trace" || fail "failure mark missing from trace"

# --- 3. daemon-side until-match: no tail race, reason recorded ---------

"$BIN" record "$ID" "$test_dir/match.trace" --format trace --until-match DONEMARKER --until-timeout 10000
"$BIN" send "$ID" 'printf "DONEMARKER\n"'
"$BIN" key "$ID" '<CR>'

# The recording stops itself once DONEMARKER renders; then a plain stop
# must be a successful no-op, and a new recording must be able to start
# (AlreadyRecording would prove the auto-stop never happened).
await '"ev":"stop"' "$test_dir/match.trace" || fail "until-match never stopped the recording"
"$BIN" record "$ID" || fail "stop after auto-stop was not idempotent"
"$BIN" record "$ID" "$test_dir/probe.cast" || fail "recording still active after until-match"
"$BIN" record "$ID" || fail "could not stop probe recording"

grep -q '"ev":"in","kind":"send","text":"printf' "$test_dir/match.trace" \
    || fail "input event missing from trace"
grep -q 'DONEMARKER' "$test_dir/match.trace" \
    || fail "triggering output missing from trace (tail race?)"
grep -q '"ev":"stop","reason":"match","match":"DONEMARKER"' "$test_dir/match.trace" \
    || fail "stop reason is not match"

# --- 4. until-timeout fires without any output --------------------------

"$BIN" record "$ID" "$test_dir/timeout.trace" --format trace --until-timeout 100
await '"ev":"stop"' "$test_dir/timeout.trace" || fail "until-timeout never stopped the recording"
"$BIN" record "$ID" || fail "stop after until-timeout was not idempotent"
"$BIN" record "$ID" "$test_dir/probe2.cast" || fail "recording still active after until-timeout"
"$BIN" record "$ID" || fail "could not stop probe recording"
grep -q '"ev":"stop","reason":"timeout"' "$test_dir/timeout.trace" \
    || fail "stop reason is not timeout"

# --- 5. mark without an active recording fails --------------------------

if "$BIN" record "$ID" --mark oops 2>/dev/null; then
    fail "mark without recording succeeded"
fi

# --- 6. up-front validation fails without touching the session ----------

if "$BIN" trace "$ID" "$test_dir/never.trace" --bogus 2>/dev/null; then
    fail "trace with unknown flag succeeded"
else
    [ "$?" -eq 2 ] || fail "unknown flag did not exit 2"
fi
[ ! -e "$test_dir/never.trace" ] || fail "failed trace still created its file"

# --- 7. tuppet wait prints the screen on timeout ----------------------------

if "$BIN" wait "$ID" --match NOMATCH --timeout 100 2>"$test_dir/wait.err"; then
    fail "wait with impossible match succeeded"
fi
grep -q 'current screen:' "$test_dir/wait.err" || fail "wait timeout lacks the screen dump"
grep -q 'DONEMARKER' "$test_dir/wait.err" || fail "wait screen has no session content"

# Rows are trimmed, so a needle's trailing spaces must not prevent a match.
"$BIN" wait "$ID" --match '$ ' --timeout 2000 2>/dev/null || fail "a needle with a trailing space did not match"

# A session that exited fails a --match wait at once, not at the timeout.
DEAD=$("$BIN" run true)
"$BIN" wait "$DEAD" --exit --timeout 3000
if "$BIN" wait "$DEAD" --match NOMATCH --timeout 30000 2>"$test_dir/dead.err"; then
    fail "wait on an exited session succeeded"
fi
grep -q 'exited before' "$test_dir/dead.err" || fail "wait on an exited session did not say it exited"
"$BIN" remove "$DEAD"

# A needle that scrolls off before the screen is checked still matches.
"$BIN" record "$ID" "$test_dir/scrolled.trace" --format trace --until-match SCROLLED
"$BIN" send "$ID" 'echo SCROLLED; seq 200
'
await '"ev":"stop","reason":"match"' "$test_dir/scrolled.trace" || fail "scrolled-off needle did not stop the recording"

# --- 8. tuppet trace --format cast carries input events ---------------------

"$BIN" trace "$ID" "$test_dir/flow.cast" --format cast \
    --send 'echo castok' --key '<CR>' --expect castok --within 3000 >/dev/null \
    || fail "trace --format cast exited nonzero"
grep -q '"version":2' "$test_dir/flow.cast" || fail "cast header missing"
grep -q '"i","echo castok"' "$test_dir/flow.cast" || fail "cast input event missing"
grep -q '"o".*castok' "$test_dir/flow.cast" || fail "cast output event missing"

"$BIN" stop "$ID"
"$BIN" remove "$ID"

echo "PASS: trace artifact, expect failure, until-match, until-timeout, mark, validation, wait screen, cast format"

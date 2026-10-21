#!/usr/bin/env bash
# Recording acceptance: `tuppet do --record-file` records a whole interaction
# in one call (input events, screen diffs, the stop), and `tuppet record
# --start` stops daemon-side on its conditions, its time, or the session's end.
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

# --- 1. happy path: text + keys + a wait, JSONL artifact --------------

"$BIN" do "$ID" -s 'echo hello' -k '<CR>' -m hello -w 3s --record-file "$test_dir/flow.trace" \
    >"$test_dir/do.out" || fail "do exited nonzero"
grep -q "^met match#0 $ID " "$test_dir/do.out" || fail "do did not print the met line"

trace_file="$test_dir/flow.trace"
[ -s "$trace_file" ] || fail "trace artifact missing or empty"

# Event order: start, snap, in(send), diff..., stop.
[ "$(sed -n 1p "$trace_file" | grep -c '"ev":"start"')" -eq 1 ] || fail "first event is not start"
[ "$(sed -n 2p "$trace_file" | grep -c '"ev":"snap"')" -eq 1 ] || fail "second event is not the initial snap"
grep -q '"ev":"in","kind":"send","text":"echo hello"' "$trace_file" || fail "send input event missing"
grep -q '"ev":"in","kind":"key","keys":\["<CR>"\]' "$trace_file" || fail "key input event missing"
grep -q '"ev":"stop","reason":"request"' "$trace_file" || fail "stop event missing"

# The input event precedes the diff that shows its effect (causality).
# The first frame showing the command may be a diff or a snap.
in_line="$(grep -n '"ev":"in","kind":"send"' "$trace_file" | head -n 1 | cut -d: -f1 || true)"
frame_line="$(grep -n '"ev":"\(diff\|snap\)".*"\$ echo hello"' "$trace_file" | head -n 1 | cut -d: -f1 || true)"
[ -n "$in_line" ] && [ -n "$frame_line" ] && [ "$in_line" -lt "$frame_line" ] \
    || fail "send event does not precede the frame that shows it"

# The stop event is last and preceded by a final full snap.
last_two="$(tail -n 2 "$trace_file")"
echo "$last_two" | sed -n 1p | grep -q '"ev":"snap"' || fail "no final snap before stop"
echo "$last_two" | sed -n 2p | grep -q '"ev":"stop"' || fail "stop is not the last event"

# --- 2. a wait that fails: exit 3, the step on stdout, closed artifact ---

if "$BIN" do "$ID" -m NEVERAPPEARS -w 200ms --record-file "$test_dir/bad.trace" \
    >"$test_dir/bad.out" 2>"$test_dir/bad.err"; then
    fail "do with an impossible wait succeeded"
else
    [ "$?" -eq 3 ] || fail "a failed wait did not exit 3"
fi
grep -q "^timeout - $ID .* step=1 done=0$" "$test_dir/bad.out" || fail "the timeout line lacks the step"
grep -q 'no condition was met' "$test_dir/bad.err" || fail "stderr does not say the wait timed out"
grep -q '"ev":"stop","reason":"request"' "$test_dir/bad.trace" || fail "a failed do left its recording open"

# --- 3. a condition stops the recording: reason met ------------------------

"$BIN" record "$ID" --start "$test_dir/match.trace" -m DONEMARKER -t 10s
"$BIN" key "$ID" 'printf "DONE""MARKER\n"' '<CR>'

# The recording stops itself once DONEMARKER shows; the stop then reports
# how, and a new recording can start (busy would prove it never stopped).
await '"ev":"stop"' "$test_dir/match.trace" || fail "the condition never stopped the recording"
[ "$("$BIN" record "$ID" --stop)" = "met $test_dir/match.trace" ] || fail "the stop does not report reason met"
grep -q '"ev":"in","kind":"key","keys":\["printf' "$test_dir/match.trace" || fail "input event missing from trace"
grep -q '"ev":"stop","reason":"met"' "$test_dir/match.trace" || fail "stop reason is not met"

# --- 4. -t stops it without any output: reason max_ms ----------------------

"$BIN" record "$ID" --start "$test_dir/timeout.trace" -t 100ms
await '"ev":"stop"' "$test_dir/timeout.trace" || fail "-t never stopped the recording"
grep -q '"ev":"stop","reason":"max_ms"' "$test_dir/timeout.trace" || fail "stop reason is not max_ms"
[ "$("$BIN" record "$ID" --stop)" = "max_ms $test_dir/timeout.trace" ] || fail "the stop does not report reason max_ms"

# --- 5. marks, a second start, and a stop without a recording ---------------

"$BIN" record "$ID" --start "$test_dir/mark.cast"
"$BIN" record "$ID" --mark checkpoint
if "$BIN" record "$ID" --start "$test_dir/second.cast" 2>"$test_dir/busy.err"; then
    fail "a second start succeeded"
fi
grep -q 'already active' "$test_dir/busy.err" || fail "a second start does not say a recording is active"
[ ! -e "$test_dir/second.cast" ] || fail "a refused start created its file"
"$BIN" record "$ID" --stop >/dev/null
grep -q '"m","checkpoint"' "$test_dir/mark.cast" || fail "the mark is missing"
if "$BIN" record "$ID" --mark oops 2>/dev/null; then
    fail "mark without recording succeeded"
fi
if "$BIN" record "$ID" --stop 2>/dev/null; then
    fail "stop without recording succeeded"
fi

# A seq older than the session is stale, as for wait.
start_seq=$("$BIN" view "$ID" -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["start_seq"])')
if "$BIN" record "$ID" --start "$test_dir/stale.trace" --since $((start_seq - 1)) 2>"$test_dir/stale.err"; then
    fail "a stale --since started a recording"
fi
grep -q 'older than session' "$test_dir/stale.err" || fail "a stale --since is not refused as stale"

# --- 6. up-front validation fails without touching the session ----------

if "$BIN" do "$ID" -s x --bogus --record-file "$test_dir/never.trace" 2>/dev/null; then
    fail "do with an unknown flag succeeded"
else
    [ "$?" -eq 2 ] || fail "unknown flag did not exit 2"
fi
[ ! -e "$test_dir/never.trace" ] || fail "a do with bad arguments still created its file"

# --- 7. tuppet wait shows what changed on timeout and exits 3 ----------------

if "$BIN" wait "$ID" --match NOMATCH --timeout 100ms >/dev/null 2>"$test_dir/wait.err"; then
    fail "wait with impossible match succeeded"
else
    [ "$?" -eq 3 ] || fail "a wait timeout did not exit 3"
fi
grep -q 'no condition was met' "$test_dir/wait.err" || fail "wait timeout does not say so"
grep -q 'DONEMARKER' "$test_dir/wait.err" || fail "wait timeout does not show the rows that changed"

# The prompt wrote its trailing space, so a needle's trailing space matches.
"$BIN" wait "$ID" --match '$ ' --timeout 2s >/dev/null || fail "a needle with a trailing space did not match"

# A session that ended fails a --match wait at once with exit 4, not at the
# timeout.
DEAD=$("$BIN" run true)
"$BIN" wait "$DEAD" --ended --timeout 3s >/dev/null
if "$BIN" wait "$DEAD" --match NOMATCH --timeout 30s >/dev/null 2>"$test_dir/dead.err"; then
    fail "wait on an exited session succeeded"
else
    [ "$?" -eq 4 ] || fail "wait on an ended session did not exit 4"
fi
grep -q 'ended before' "$test_dir/dead.err" || fail "wait on an exited session did not say it ended"
"$BIN" remove "$DEAD"

# A needle that scrolls off before the screen is checked still matches.
"$BIN" record "$ID" --start "$test_dir/scrolled.trace" -m SCROLLED
"$BIN" key "$ID" 'echo SCROLL""ED; seq 200' '<CR>'
await '"ev":"stop","reason":"met"' "$test_dir/scrolled.trace" || fail "scrolled-off needle did not stop the recording"

# --- 8. a .cast recording carries input events -----------------------------

"$BIN" do "$ID" -s 'echo castok' -k '<CR>' -m castok -w 3s --record-file "$test_dir/flow.cast" >/dev/null \
    || fail "do --record-file x.cast exited nonzero"
grep -q '"version":2' "$test_dir/flow.cast" || fail "cast header missing"
grep -q '"i","echo castok"' "$test_dir/flow.cast" || fail "cast input event missing"
grep -q '"o".*castok' "$test_dir/flow.cast" || fail "cast output event missing"

# --- 9. a secret reaches a cast only as a marker ----------------------------

PW_ID=$("$BIN" run --size 40x10 sh -c 'stty -echo; read pw; stty echo; echo got ${#pw}')
"$BIN" wait "$PW_ID" --hidden-input -t 5s >/dev/null || fail "the password prompt never hid its input"
PW=hunter2secret "$BIN" do "$PW_ID" --secret PW -k '<CR>' -m 'got 13' --record-file "$test_dir/pw.cast" >/dev/null \
    || fail "do --secret with a cast recording failed"
grep -q '"m","secret input"' "$test_dir/pw.cast" || fail "the cast lacks the secret's marker"
grep -q hunter2secret "$test_dir/pw.cast" && fail "the secret reached the cast"
# Typed as plain text while the program hides its input, it stays out too.
PLAIN_ID=$("$BIN" run --size 40x10 sh -c 'stty -echo; read pw; stty echo; echo got ${#pw}')
"$BIN" wait "$PLAIN_ID" --hidden-input -t 5s >/dev/null || fail "the second password prompt never hid its input"
"$BIN" do "$PLAIN_ID" -s typedplain -k '<CR>' -m 'got 10' --record-file "$test_dir/plain.trace" >/dev/null \
    || fail "do with a trace recording at a hidden prompt failed"
grep -q '"kind":"secret"' "$test_dir/plain.trace" || fail "the trace lacks the hidden input's marker"
grep -q typedplain "$test_dir/plain.trace" && fail "text typed at a hidden prompt reached the trace"

# --- 10. the session's end stops the recording: reason ended ---------------

# The evaluator checks this recording's condition, so its end stops it.
END_ID=$("$BIN" run --size 40x10 sh -c 'read x; echo bye')
"$BIN" record "$END_ID" --start "$test_dir/end.trace" -m NEVERSHOWN
"$BIN" key "$END_ID" '<CR>'
"$BIN" wait "$END_ID" -e -t 5s >/dev/null || fail "the session did not end"
await '"ev":"stop","reason":"ended","exit_code":0' "$test_dir/end.trace" || fail "the end did not stop the recording with reason ended"
[ "$("$BIN" record "$END_ID" --stop)" = "ended $test_dir/end.trace" ] || fail "the stop does not report reason ended"
# A program killed by a signal ends the trace with the signal.
KILLED_ID=$("$BIN" run --size 40x10 sh -c 'read x; kill -KILL $$')
"$BIN" record "$KILLED_ID" --start "$test_dir/killed.trace" -m NEVERSHOWN
"$BIN" key "$KILLED_ID" '<CR>'
await '"ev":"stop","reason":"ended","signal":"SIGKILL"' "$test_dir/killed.trace" || fail "a killed program's trace: $(tail -1 "$test_dir/killed.trace")"

"$BIN" stop "$ID"
"$BIN" remove "$ID" "$PW_ID" "$PLAIN_ID" "$END_ID" "$KILLED_ID"

echo "PASS: do recording, failed wait, met, max_ms, mark, busy, stale, validation, wait screen, cast format, secret, hidden input, ended"

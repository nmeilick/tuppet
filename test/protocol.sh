#!/usr/bin/env bash
# The socket protocol for programmatic clients: the revision 2 envelope and
# error codes, references resolved by the daemon, view --since, paste, and
# input batches, and attach streams.
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
# reply_has REQUEST PYTHON-EXPRESSION: the expression holds for the reply r.
reply_has() {
    request "$1" | python3 -c "import json, sys; r = json.load(sys.stdin); sys.exit(0 if ($2) else 1)"
}

# --- envelope and codes ----------------------------------------------------
reply_has '{"cmd":"hello"}' 'r["protocol"] == 2 and r["features"] == ["alerts", "shutdown", "limits", "fonts"]' || fail "hello does not report protocol 2"
reply_has '{"cmd":"run","argv":["true"],"record":{"pathx":"/x"}}' \
    'r["code"] == "bad_request" and "record.pathx" in r["err"] and r["status"] is None' \
    || fail "an unknown nested field was not rejected by name"
reply_has '{"cmd":"view","session":"999"}' 'r["code"] == "no_session"' || fail "an unknown id is not no_session"
# A client that closes its side after the request may leave out the newline.
python3 - "$TUPPET_SOCKET" <<'PY' || fail "a request without a newline before a half-close got no reply"
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b'{"cmd":"hello"}')
s.shutdown(socket.SHUT_WR)
sys.exit(0 if json.loads(s.makefile().readline())["ok"] else 1)
PY

# A name or pattern is resolved by the daemon; one that picks several is
# ambiguous and lists them.
a=$("$BIN" run -n pick-a sh -c 'echo ONE; exec cat')
b=$("$BIN" run -n pick-b cat)
reply_has '{"cmd":"view","session":"pick-*"}' "r['code'] == 'ambiguous' and [m['id'] for m in r['matches']] == [$a, $b]" \
    || fail "an ambiguous pattern did not list its matches"
"$BIN" wait pick-a --match ONE --timeout 2s >/dev/null

# A NUL byte would cut an argument or a path short where the system reads it.
for req in '{"cmd":"run","argv":["echo","a\u0000b"]}' '{"cmd":"run","argv":["true"],"cwd":"/tmp\u0000x"}' \
    "{\"cmd\":\"run\",\"argv\":[\"true\"],\"record\":{\"path\":\"$dir/run\\u0000.cast\"}}" \
    "{\"cmd\":\"record\",\"session\":\"$a\",\"start\":{\"path\":\"$dir/rec\\u0000.cast\",\"format\":\"cast\"}}"; do
    reply_has "$req" 'r["code"] == "bad_request"' || fail "a NUL byte was accepted: $req"
done
[ -z "$(ls "$dir" | grep -E '^(run|rec)')" ] || fail "a path cut at its NUL byte was written"

# view --since: only the lines changed after a seq; a seq from before the
# session is stale.
seq=$("$BIN" view pick-a -j | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"]["seq"])')
"$BIN" key pick-a TWO '<Enter>'
"$BIN" wait pick-a --match TWO --timeout 2s >/dev/null
[ "$("$BIN" view pick-a --since "$seq")" = "$(printf 'TWO\nTWO')" ] || fail "view --since did not show just the changed lines"
reply_has "{\"cmd\":\"view\",\"session\":\"pick-a\",\"since\":$seq}" 'r["rows"] == [2, 3]' || fail "view --since did not report the rows"
reply_has "{\"cmd\":\"view\",\"session\":\"$a\",\"since\":0}" 'r["code"] == "stale" and r["status"]["id"] > 0' \
    || fail "a seq older than the session was not stale"
seq=$("$BIN" view pick-a -j | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"]["seq"])')
[ "$("$BIN" view pick-a --since "$seq" | wc -c)" -eq 0 ] || fail "view --since printed something without a change"

# An HTML line of view --since stands alone: its colors are resolved.
col=$("$BIN" run -s 10x5 sh -c 'printf "\033[31mRED\033[0m 0123456789abc"; exec cat')
"$BIN" wait "$col" --match abc --timeout 2s >/dev/null
start=$("$BIN" view "$col" -j | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"]["start_seq"])')
html=$("$BIN" view "$col" -f html --since "$start")
case $html in *RED*) ;; *) fail "view --since -f html lost the text" ;; esac
case $html in *var\(--vt-palette*) fail "view --since -f html left palette colors unresolved" ;; esac
# --unwrap joins the rows the terminal wrapped.
[ "$("$BIN" view "$col" --unwrap)" = "RED 0123456789abc" ] || fail "view --unwrap did not join the wrapped rows"
"$BIN" stop "$col" >/dev/null

# view --styles: the style of most cells, then the runs of the others,
# blanks included, with the keys that differ; plain text only.
sty=$("$BIN" run -s 12x3 sh -c 'printf "\033[44m\033[2J\033[H\033[1;31mab\033[22;39m c\033[7m \033[0m\nz"; exec cat')
"$BIN" wait "$sty" --match z --timeout 2s >/dev/null
[ "$("$BIN" view "$sty" --styles)" = "$(printf 'ab c\nz\nbase: bg=4\n1:1-2 fg=1 bold "ab"\n1:5-5 inverse " "\n2:1-1 bg=default "z"')" ] \
    || fail "view --styles: $("$BIN" view "$sty" --styles)"
reply_has "{\"cmd\":\"view\",\"session\":\"$sty\",\"styles\":true,\"since\":$("$BIN" view "$sty" -j | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"]["start_seq"])')}" \
    'r["styles"]["base"]["bg"] == 4 and [x["row"] for x in r["styles"]["runs"]] == [1, 1, 2] and not r["styles"]["truncated"]' \
    || fail "view styles with since"
reply_has "{\"cmd\":\"view\",\"session\":\"$sty\",\"styles\":true,\"format\":\"vt\"}" 'r["code"] == "bad_request"' || fail "styles with vt were accepted"
set +e
"$BIN" view "$sty" --styles -f html >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "view --styles -f html exited $status, not 2"
"$BIN" stop "$sty" >/dev/null

# Input to an ended session fails with code ended, and the CLI exits 4.
"$BIN" stop pick-a pick-b >/dev/null
reply_has '{"cmd":"input","session":"pick-a","steps":[{"keys":["x"]}]}' 'r["code"] == "ended" and r["done"] == 0 and r["status"]["state"] == "exited"' \
    || fail "input to an ended session is not code ended"
set +e
"$BIN" key pick-a x 2>/dev/null
status=$?
"$BIN" stop pick-a 2>/dev/null
stop_status=$?
set -e
[ "$status" -eq 4 ] || fail "key to an ended session exited $status, not 4"
[ "$stop_status" -eq 4 ] || fail "stop of an ended session exited $stop_status, not 4"
reply_has '{"cmd":"stop","sessions":["pick-a"]}' 'r["results"][0]["code"] == "ended"' || fail "stop of an ended session is not code ended"
"$BIN" remove 'pick-*'

# A sessions list past 1024 references fails before anything is stopped;
# a reference given twice gets one result.
keep=$("$BIN" run cat)
many=$(python3 -c 'import json, sys; print(json.dumps([sys.argv[1]] + ["nope"] * 1024))' "$keep")
reply_has "{\"cmd\":\"stop\",\"sessions\":$many}" 'r["code"] == "limit"' || fail "1025 references were not refused"
"$BIN" list "$keep" | grep -q ' running ' || fail "a refused stop stopped a session"
reply_has "{\"cmd\":\"stop\",\"sessions\":[\"nope\",\"$keep\",\"nope\",\"$keep\"]}" \
    "[(x['ref'], x['ok']) for x in r['results']] == [('nope', False), ('$keep', True)]" || fail "a repeated reference got more than one result"

# --- paste ---------------------------------------------------------------
# cat -v shows exactly what arrives: ^[ for ESC, ^M for CR.
on=$("$BIN" run sh -c 'stty raw -echo; printf "\033[?2004hREADY"; exec cat -v')
off=$("$BIN" run sh -c 'stty raw -echo; printf READY; exec cat -v')
"$BIN" wait "$on" --match READY --timeout 2s >/dev/null
"$BIN" wait "$off" --match READY --timeout 2s >/dev/null
reply_has "{\"cmd\":\"input\",\"session\":\"$on\",\"steps\":[{\"paste\":\"a\\nb\"}]}" 'r["done"] == 1' \
    || fail "a paste did not report its step done"
"$BIN" do "$off" -p 'a
b' >/dev/null || fail "tuppet do -p failed"
"$BIN" wait "$on" --match '^[[200~a^Mb^[[201~' --timeout 2s >/dev/null || fail "paste was not wrapped"
"$BIN" wait "$off" --match 'a^Mb' --timeout 2s >/dev/null || fail "unbracketed paste was changed"
"$BIN" view "$off" | grep -q '200~' && fail "unbracketed paste was wrapped"

# --- attach --------------------------------------------------------------
att() { python3 "$(dirname "$0")/attach_check.py" "$TUPPET_SOCKET" "$@"; }

sh_id=$("$BIN" run bash --norc --noprofile -i)
"$BIN" wait "$sh_id" --idle 100ms --timeout 2s >/dev/null
"$BIN" key "$sh_id" 'echo one' '<Enter>'
"$BIN" wait "$sh_id" --match one --timeout 2s >/dev/null
att replay "$sh_id" "$BIN"
att writers "$sh_id"
att pipelined "$sh_id"
att detach "$sh_id"
att sized "$sh_id"
att preview "$sh_id" "$BIN"
reply_has "{\"cmd\":\"attach\",\"session\":\"$sh_id\",\"cols\":80,\"rows\":24}" 'r["code"] == "bad_request"' \
    || fail "a viewer's attach took a size"
if "$BIN" png "$sh_id" "$dir/missing/shot.png" 2>"$dir/png.err"; then fail "png into a missing directory succeeded"; fi
grep -q "its directory does not exist" "$dir/png.err" || fail "png did not say why it cannot create the file: $(cat "$dir/png.err")"

# tuppet attach shows the current screen at once, even when it is idle.
idle=$("$BIN" run sh -c 'echo HELLO-MARKER; sleep 30')
"$BIN" wait "$idle" --match HELLO-MARKER --timeout 2s >/dev/null
timeout 1 "$BIN" attach "$idle" --read-only </dev/null >"$dir/attach.out" 2>/dev/null || true
grep -q HELLO-MARKER "$dir/attach.out" || fail "tuppet attach did not show the current screen"

# tuppet attach keeps the program's queries and reporting modes away from the
# user's terminal: the daemon already answers them.
asks=$("$BIN" run sh -c 'echo READY; read x; printf "\033[c\033[6n\033]11;?\007\033[?1049;2048hQUERIES-SENT"; read x')
"$BIN" wait "$asks" --match READY --timeout 2s >/dev/null
"$BIN" attach "$asks" --read-only </dev/null >"$dir/asks.out" 2>/dev/null &
attach_pid=$!
for _ in $(seq 100); do grep -q READY "$dir/asks.out" && break; sleep 0.02; done
"$BIN" key "$asks" go '<Enter>'
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
for _ in $(seq 250); do "$BIN" list -j "$held" | grep -q '"viewers":1' && break; sleep 0.02; done
"$BIN" list -j "$held" | grep -q '"viewers":1' || fail "the stalled attach client did not attach"
"$BIN" key "$held" go '<Enter>'
"$BIN" wait "$held" --ended --timeout 3s >/dev/null
timeout 3 "$BIN" remove "$held" || fail "a stalled attach client blocked remove"
kill "$stalled_pid" 2>/dev/null || true

flood=$("$BIN" run sh -c 'read x; yes | head -c 8000000; sleep 30')
att slow "$flood" "$BIN"
"$BIN" list "$flood" | grep -q ' running ' || fail "slow viewer stopped the session"

done_id=$("$BIN" run sh -c 'sleep 0.5; exit 4')
att exits "$done_id"
code_id=$("$BIN" run sh -c 'sleep 0.5; exit 5')
# Outside a terminal a writer attach is refused, before it takes the
# writer role; a read-only one streams the output, ends with the
# session, and marks nothing seen.
set +e
"$BIN" attach "$code_id" </dev/null >/dev/null 2>"$dir/attach.err"
status=$?
set -e
[ "$status" -eq 2 ] || fail "a writer attach outside a terminal exited $status, not 2"
grep -q "tuppet view" "$dir/attach.err" || fail "a writer attach outside a terminal did not point to view"
"$BIN" list -j "$code_id" | grep -q '"writer":null' || fail "a refused attach took the writer role"
set +e
"$BIN" attach "$code_id" -r </dev/null >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 5 ] || fail "tuppet attach -r exited $status, not the child's 5"
"$BIN" list "$code_id" | grep -q '^!' || fail "tuppet attach -r outside a terminal marked the session seen"
set +e
"$BIN" run -a true </dev/null >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "run -a outside a terminal exited $status, not 2"

# tuppet run -a starts a session and attaches to it, ending with the
# program's exit code: here in a session's terminal.
outer_a=$("$BIN" run "$BIN" run -a sh -c 'echo RUN-ATTACHED; exit 3')
"$BIN" wait "$outer_a" --ended --timeout 5s | grep -q ' exit=3$' || fail "tuppet run -a did not exit with the program's 3"
"$BIN" view "$outer_a" | grep -q RUN-ATTACHED || fail "tuppet run -a did not show the program"

echo "PASS: envelope, codes, daemon-side references, view --since, paste, attach"

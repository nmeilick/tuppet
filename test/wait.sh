#!/usr/bin/env bash
# Daemon-side waits: outcomes and exit codes, --after-input against a typed
# echo and a full-screen redraw, --since alone, run with until, wait --any,
# and how waits live: outside the request slots, cancelled by a hang-up but
# not by a half-close, ended by a remove, and stale seqs refused.
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

# Raw protocol clients; see the modes below.
cat >"$dir/client.py" <<'PY'
import json, socket, sys, time
path, mode = sys.argv[1], sys.argv[2]

def connect():
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    return s

def send(s, req):
    s.sendall(json.dumps(req).encode() + b"\n")

def lines(s, n):
    f = s.makefile()
    return [json.loads(f.readline()) for _ in range(n)]

def ask(req):
    s = connect()
    send(s, req)
    return lines(s, 1)[0]

def wait_req(sid, text, ms):
    return {"cmd": "wait", "session": sid, "until": [{"match": text}], "timeout_ms": ms}

if mode == "run":
    s = connect()
    send(s, {"cmd": "run", "argv": ["sh", "-c", "echo UNTIL-READY; exec sleep 30"],
             "until": [{"ended": True}, {"match": "UNTIL-READY"}], "timeout_ms": 5000})
    first, second = lines(s, 2)
    ok = (first["ok"] and second["outcome"] == "met" and second["met"] == 1
          and second["status"]["id"] == first["status"]["id"] and second["hits"] == [])
    print(first["status"]["id"] if ok else "bad: %r %r" % (first, second))
elif mode == "flood":
    # More waits than request slots, up to the 256 they may hold.
    sid = sys.argv[3]
    held = []
    for _ in range(256):
        s = connect()
        send(s, wait_req(sid, "NEVER", 60000))
        held.append(s)
    deadline = time.time() + 10
    while True:
        r = ask(wait_req(sid, "NEVER", 0))
        if r.get("code") == "limit":
            break
        if time.time() > deadline:
            sys.exit("the 257th wait was never refused: %r" % r)
    if not ask({"cmd": "list"})["ok"]:
        sys.exit("a request failed while 256 waits were open")
    # Hanging up frees every slot.
    for s in held:
        s.close()
    while True:
        r = ask(wait_req(sid, "NEVER", 0))
        if r.get("outcome") == "timeout":
            break
        if time.time() > deadline:
            sys.exit("hung-up waits kept their slots: %r" % r)
    print("ok")
elif mode == "halfclose":
    s = connect()
    send(s, wait_req(sys.argv[3], "HALF-CLOSED", 5000))
    s.shutdown(socket.SHUT_WR)
    print("sent", flush=True)
    print(lines(s, 1)[0]["outcome"], flush=True)
elif mode == "remove":
    s = connect()
    send(s, wait_req(sys.argv[3], "NEVER", 10000))
    removed = ask({"cmd": "remove", "sessions": [sys.argv[3]], "force": True})
    outcome = lines(s, 1)[0]["outcome"]
    print("ok" if removed["results"][0]["ok"] and outcome in ("ended", "removed") else "bad: %r %s" % (removed, outcome))
elif mode == "ask":
    print(json.dumps(ask(json.loads(sys.argv[3]))))
PY
client() { python3 "$dir/client.py" "$TUPPET_SOCKET" "$@"; }
# exits N MESSAGE COMMAND...: COMMAND exits N, its output in $dir/out and $dir/err.
exits() {
    local want=$1 msg=$2
    shift 2
    set +e
    "$@" >"$dir/out" 2>"$dir/err"
    local got=$?
    set -e
    [ "$got" -eq "$want" ] || fail "$msg (exit $got)"
}

# --- outcomes and exit codes ---------------------------------------------
sh_id=$("$BIN" run bash --norc --noprofile -i)
line=$("$BIN" wait "$sh_id" -m '$ ' -t 3s)
[[ $line =~ ^met\ match#0\ $sh_id\ seq=[0-9]+\ input_seq=-\ hit_seq=-$ ]] || fail "unexpected met line: $line"
exits 3 "a timeout did not exit 3" "$BIN" wait "$sh_id" -m NEVER -t 100ms
grep -q "^timeout - $sh_id seq=" "$dir/out" || fail "a timeout did not print its line"
grep -q 'no condition was met' "$dir/err" || fail "a timeout did not say so on stderr"

# --after-input: the typed echo stays on the prompt's row, the next prompt
# is a new one.
"$BIN" key "$sh_id" 'echo typed'
exits 3 "the echo on the prompt row met --after-input" "$BIN" wait "$sh_id" -m '$ ' --after-input -t 300ms
"$BIN" key "$sh_id" '<Enter>'
"$BIN" wait "$sh_id" -m '$ ' --after-input -t 3s >/dev/null || fail "the next prompt did not meet --after-input"
"$BIN" view "$sh_id" | grep -q '^typed$' || fail "the command did not run"

# --since alone: any text change after the seq, and nothing before it.
seq=$("$BIN" wait "$sh_id" -i 100ms -t 3s | sed 's/.* seq=\([0-9]*\) .*/\1/')
exits 3 "an unchanged screen met --since alone" "$BIN" wait "$sh_id" --since "$seq" -t 200ms
"$BIN" key "$sh_id" z
line=$("$BIN" wait "$sh_id" --since "$seq" -t 3s)
[[ $line =~ ^met\ changed#0\ $sh_id\  ]] || fail "a text change did not meet --since alone: $line"
"$BIN" key "$sh_id" '<BS>'

# The seq a resize prints comes before the program's redraw, also one
# drawn at once on SIGWINCH, and after the reflow.
redraw=$("$BIN" run -s 80x24 python3 -c '
import os, signal, sys
def draw(*_):
    c, r = os.get_terminal_size()
    sys.stdout.write("\x1b[2J\x1b[HREDRAWN %dx%d\n" % (c, r)); sys.stdout.flush()
signal.signal(signal.SIGWINCH, draw)
draw()
while True: signal.pause()')
"$BIN" wait "$redraw" -m 'REDRAWN 80x24' -t 3s >/dev/null
for size in 100x30 80x24 120x40 80x24 100x30 80x24; do
    seq=$("$BIN" resize "$redraw" "$size")
    "$BIN" wait "$redraw" --since "$seq" -t 3s >/dev/null || fail "the redraw after a resize to $size did not change the screen after its seq"
    shown=$("$BIN" view "$redraw" | head -1)
    [ "$shown" = "REDRAWN $size" ] || fail "the view after a resize to $size shows '$shown', not the redraw"
done
# The same size again takes no seq; the status keeps the last resize's.
[ "$("$BIN" resize "$redraw" 80x24)" = - ] || fail "a resize to the same size printed a seq"
same=$(client ask "{\"cmd\":\"resize\",\"session\":\"$redraw\",\"cols\":80,\"rows\":24}")
[[ $same == *'"resize_seq": null'* && $same == *"\"resize_seq\": $seq,"* ]] \
    || fail "a resize to the same size did not reply resize_seq null with the last one in the status: $same"

# resize -j prints the reply.
[ "$("$BIN" resize "$redraw" 81x24 -j | python3 -c 'import json, sys; r = json.load(sys.stdin); print(r["resize_seq"] == r["status"]["resize_seq"])')" = True ] \
    || fail "resize -j did not print the reply with resize_seq"

# --- settled, gone, and the counters ----------------------------------------
# A program that clears at once and draws 300 ms later: a --settled longer
# than the pause sees the draw.
cat >"$dir/stage.py" <<'PY'
import os, signal, sys, time
pending = [0]
signal.signal(signal.SIGWINCH, lambda *_: pending.__setitem__(0, 1))
def full():
    sys.stdout.write("\x1b[H\x1b[2J[ Settings ]  width %d\r\nF10 Quit\r\n" % os.get_terminal_size()[0]); sys.stdout.flush()
sys.stdout.write("\x1b[?1049h"); full()
while True:
    if pending[0]:
        pending[0] = 0
        sys.stdout.write("\x1b[H\x1b[2J"); sys.stdout.flush()
        time.sleep(0.3); full()
    time.sleep(0.005)
PY
stage=$("$BIN" run -s 80x10 python3 "$dir/stage.py")
"$BIN" wait "$stage" -m 'F10 Quit' -t 3s >/dev/null
seq=$("$BIN" resize "$stage" 70x10)
line=$("$BIN" wait "$stage" --since "$seq" --settled 600ms -t 5s) || fail "--settled after a resize was not met: $line"
[[ $line =~ ^met\ settled#0\  ]] || fail "the settled line: $line"
"$BIN" view "$stage" | grep -q 'width 70' || fail "--settled 600ms did not wait for the draw after the pause"
# An identical redraw changes nothing: --settled waits for a change, and
# the counters see the bytes and the full clear but no draw.
cat >"$dir/same.py" <<'PY'
import signal, sys
def draw(*_):
    sys.stdout.write("\x1b[H\x1b[2Jhello world\r\nstatic layout\r\n"); sys.stdout.flush()
signal.signal(signal.SIGWINCH, draw)
sys.stdout.write("\x1b[?1049h"); draw()
while True: signal.pause()
PY
same=$("$BIN" run -s 80x10 python3 "$dir/same.py")
"$BIN" wait "$same" -m 'static layout' -t 3s >/dev/null
counters() { "$BIN" list -j "$same" | python3 -c 'import json, sys; s = json.load(sys.stdin)["sessions"][0]; print(s["out_bytes"], s["draws"], s["full_clears"])'; }
read -r bytes0 draws0 clears0 <<<"$(counters)"
seq=$("$BIN" resize "$same" 80x12)
exits 3 "an identical redraw met --settled" "$BIN" wait "$same" --since "$seq" --settled 100ms -t 500ms
read -r bytes1 draws1 clears1 <<<"$(counters)"
[ "$bytes1" -gt "$bytes0" ] && [ "$draws1" -eq "$draws0" ] && [ "$clears1" -eq $((clears0 + 1)) ] \
    || fail "the counters of an identical redraw: $bytes0 $draws0 $clears0 -> $bytes1 $draws1 $clears1"
"$BIN" stop "$stage" "$same" >/dev/null
# --settled in do counts from the input; --stats adds the counts.
# ED 3 erases the history and is no full clear.
line=$("$BIN" do "$sh_id" -s 'printf "\033[H\033[2J\033[3JSETTLED\n"' -k '<Enter>' --settled 200ms -w 5s --stats) || fail "do --settled: $line"
[[ $line =~ ^met\ settled#0\ $sh_id\ .*\ out_bytes=[1-9][0-9]*\ draws=[1-9][0-9]*\ full_clears=1\ rows_changed=[1-9][0-9]*/[0-9]+\ first_change_ms=[0-9]+$ ]] \
    || fail "do --settled --stats: $line"
# --gone: text that came and went, in any case; never text that never came.
line=$("$BIN" do "$sh_id" -s 'printf "WOR%s\n" KING; sleep 0.3; printf "\\033[H\\033[2J"' -k '<Enter>' --gone working --icase -w 5s) || fail "do --gone: $line"
[[ $line =~ ^met\ gone#0\  ]] || fail "the gone line: $line"
exits 3 "text that never came met --gone" "$BIN" wait "$sh_id" --gone NEVER-SHOWN -t 300ms
# Scrolling into the history counts as gone.
"$BIN" do "$sh_id" -s 'printf "SCROLL%s\n" ED; seq 60' -k '<Enter>' --gone SCROLLED -w 5s >/dev/null || fail "text that scrolled away did not meet --gone"

# A program that failed: -e is met and prints the exit code; a text it
# never printed ends the wait with exit 4.
failed=$("$BIN" run sh -c 'exit 3')
line=$("$BIN" wait "$failed" -e -t 3s)
[[ $line =~ ^met\ ended#0\ $failed\ .*\ exit=3$ ]] || fail "unexpected ended line: $line"
exits 4 "an ended session did not exit 4" "$BIN" wait "$failed" -m NEVER -t 3s
grep -q "^ended - $failed " "$dir/out" || fail "an ended wait did not print its line"
grep -q 'ended before' "$dir/err" || fail "an ended wait did not say so"

# A needle visible before the input on a full-screen program: only the
# redraw after it blanked the screen meets --after-input.
repl=$("$BIN" run sh -c 'printf "\033[?1049h\033[HREADY>"; while read -r l; do sleep 1; printf "\033[2J"; sleep 0.3; printf "\033[Hgot %s\r\nREADY>" "$l"; done')
"$BIN" wait "$repl" -m 'READY>' -t 3s >/dev/null
"$BIN" key "$repl" x '<Enter>'
exits 3 "a needle on screen before the input met --after-input" "$BIN" wait "$repl" -m 'READY>' --after-input -t 300ms
"$BIN" wait "$repl" -m 'READY>' --after-input -t 5s >/dev/null || fail "the redrawn needle did not meet --after-input"
"$BIN" view "$repl" | grep -q '^got x$' || fail "the full-screen program did not redraw"
"$BIN" stop "$repl" >/dev/null
"$BIN" wait "$repl" -e -t 3s | grep -q ' exit=stopped$' || fail "a stopped session's outcome line did not say exit=stopped"

# --- run with until ------------------------------------------------------
ran=$(client run)
[[ $ran =~ ^[0-9]+$ ]] || fail "run with until: $ran"
out=$("$BIN" run -m RUN-READY -t 3s -- sh -c 'echo RUN-READY; exec sleep 30')
id=$(head -1 <<<"$out")
[ "$(sed -n 2p <<<"$out" | cut -d' ' -f1-3)" = "met match#0 $id" ] || fail "run -m did not print the id and then the outcome: $out"
exits 3 "run -m did not time out" "$BIN" run -m NEVER -t 100ms -- sleep 30
grep -q "keeps running; 'tuppet stop" "$dir/err" || fail "a failed run wait did not say how to stop the session"
exits 2 "run -a with a condition was not a usage error" "$BIN" run -a -m x -- true

# --- wait --any ----------------------------------------------------------
quiet=$("$BIN" run sleep 30)
loud=$("$BIN" run sh -c 'sleep 0.2; echo ANY-LOUD; exec sleep 30')
# The session that ended first is not reported on stdout.
line=$("$BIN" wait "$failed" "$loud" -m ANY-LOUD --any -t 3s 2>/dev/null)
[[ $line =~ ^met\ match#0\ $loud\  && $line != *$'\n'* ]] || fail "wait --any did not report only the session that met: $line"
exits 2 "several sessions without --any was not a usage error" "$BIN" wait "$quiet" "$loud" -m x
# With --any a pattern stands for every session it matches.
"$BIN" run -n anyp-a sleep 30 >/dev/null
anyp=$("$BIN" run -n anyp-b sh -c 'sleep 0.2; echo ANY-PATTERN; exec sleep 30')
line=$("$BIN" wait 'anyp-*' -m ANY-PATTERN --any -t 3s 2>/dev/null) || fail "wait --any with a pattern failed: $line"
[[ $line =~ ^met\ match#0\ $anyp\  ]] || fail "wait --any with a pattern: $line"
exits 1 "wait --any with a pattern that matches nothing did not fail" "$BIN" wait 'nomatch-*' -m x --any -t 1s
grep -q "no session matches 'nomatch-\*'" "$dir/err" || fail "a pattern that matches nothing: $(cat "$dir/err")"

# --- how waits live ------------------------------------------------------
[ "$(client flood "$quiet")" = ok ] || fail "waits outside the request slots"
client halfclose "$quiet" >"$dir/half" &
half_pid=$!
for _ in $(seq 100); do grep -q sent "$dir/half" && break; sleep 0.02; done
# The tty echoes what is typed, though sleep never reads it.
"$BIN" key "$quiet" HALF-CLOSED
wait "$half_pid" || true
grep -q '^met$' "$dir/half" || fail "a half-closed client lost its wait: $(cat "$dir/half")"
[ "$(client remove "$quiet")" = ok ] || fail "remove during a wait"

stale=$(client ask "{\"cmd\":\"wait\",\"session\":\"$loud\",\"until\":[{\"match\":\"x\",\"since\":0}],\"timeout_ms\":0}")
[[ $stale == *'"code": "stale"'* ]] || fail "a seq from before the session was not stale: $stale"
"$BIN" key "$sh_id" x
earlier=$("$BIN" wait "$sh_id" -m '$ x' --after-input -t 3s | sed 's/.* input_seq=\([0-9]*\) .*/\1/')
"$BIN" key "$sh_id" y
"$BIN" wait "$sh_id" -m '$ xy' --after-input -t 3s >/dev/null
stale=$(client ask "{\"cmd\":\"wait\",\"session\":\"$sh_id\",\"until\":[{\"idle_ms\":0,\"after_input\":$earlier}],\"timeout_ms\":0}")
[[ $stale == *'"code": "stale"'* ]] || fail "an input that is no longer the latest was not stale: $stale"

"$BIN" remove -f '*' >/dev/null
echo "PASS: outcomes, --after-input, run until, --any, slots, hang-up, half-close, remove, stale"

#!/usr/bin/env bash
# Session events and attention: the snapshot and synced, started and changed
# frames, idle and active edges, a bell marking the session in list until an
# ack, acks with stale values never moving seen back, a rename leaving a
# filter, a slow subscriber's resync, "stopped" and unmarked after tuppet stop,
# and events --count.
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

def ask(req):
    s = connect()
    s.sendall(json.dumps(req).encode() + b"\n")
    return json.loads(s.makefile().readline())

class Stream:
    def __init__(self, req):
        self.s = connect()
        self.s.sendall(json.dumps(req).encode() + b"\n")
        self.f = self.s.makefile()
        self.reply = self.next()

    def next(self, timeout=5):
        self.s.settimeout(timeout)
        return json.loads(self.f.readline())

    def until(self, what, pred, timeout=5):
        deadline = time.time() + timeout
        seen = []
        while time.time() < deadline:
            frame = self.next(max(0.01, deadline - time.time()))
            seen.append(frame["type"])
            if pred(frame):
                return frame
        sys.exit("no %s frame within %ss; got %s" % (what, timeout, seen))

def typed(sid, text):
    r = ask({"cmd": "input", "session": sid, "steps": [{"text": text}]})
    assert r["ok"], r

def bash():
    r = ask({"cmd": "run", "argv": ["bash", "--norc", "--noprofile", "-i"], "env": ["PS1=$ ", "PATH=/usr/bin:/bin"]})
    sid = str(r["status"]["id"])
    w = ask({"cmd": "wait", "session": sid, "until": [{"match": "$ "}], "timeout_ms": 5000})
    assert w["outcome"] == "met", w
    return sid

if mode == "frames":
    old = bash()
    st = Stream({"cmd": "events"})
    assert st.reply["ok"] and st.reply["boot"], st.reply
    snap = st.until("snapshot", lambda f: f["type"] in ("snapshot", "synced"))
    assert snap["type"] == "snapshot" and str(snap["status"]["id"]) == old, snap
    st.until("synced", lambda f: f["type"] == "synced")
    new = bash()
    started = st.until("started", lambda f: f["type"] == "started" and str(f["id"]) == new)
    assert started["status"]["state"] == "running", started
    typed(new, "printf '\\033]2;T2\\007'\r")
    st.until("title", lambda f: f["type"] == "changed" and str(f["id"]) == new and "title" in f["fields"]
             and f["status"]["title"] == "T2")
    print(new)
elif mode == "idle":
    sid = sys.argv[3]
    st = Stream({"cmd": "events", "sessions": [sid], "idle_ms": 300})
    st.until("synced", lambda f: f["type"] == "synced")
    typed(sid, "echo one\r")
    st.until("idle", lambda f: f["type"] == "idle")
    typed(sid, "echo two\r")
    st.until("active", lambda f: f["type"] == "active")
elif mode == "quiet-tty":
    # A subscriber wakes the sampling of a session that is quiet already.
    sid = str(ask({"cmd": "run", "argv": ["sh", "-c", "sleep 1; stty -echo; exec sleep 30"]})["status"]["id"])
    time.sleep(0.5)
    st = Stream({"cmd": "events", "sessions": [sid]})
    st.until("tty", lambda f: f["type"] == "changed" and "tty" in f["fields"] and f["status"]["tty"]["echo"] is False)
    r = ask({"cmd": "events", "idle_ms": 10 ** 12})
    assert r["code"] == "bad_request" and "idle_ms" in r["err"], r
    ask({"cmd": "remove", "sessions": [sid], "force": True})
elif mode == "stale-acks":
    sid = sys.argv[3]
    before = ask({"cmd": "list", "sessions": [sid]})["sessions"][0]
    count = before["bell_count"]
    assert before["seen"]["bell_count"] < count, before
    first = ask({"cmd": "ack", "sessions": [sid], "shown": {"bell_count": count, "seq": before["seq"]}})
    second = ask({"cmd": "ack", "sessions": [sid], "shown": {"bell_count": count - 1, "seq": 1}})
    a, b = (r["results"][0]["status"]["seen"] for r in (first, second))
    assert a["bell_count"] == count and a["seq"] == before["seq"], first
    assert (b["bell_count"], b["seq"]) == (a["bell_count"], a["seq"]), second
elif mode == "leave":
    st = Stream({"cmd": "events", "sessions": ["web*"]})
    st.until("snapshot", lambda f: f["type"] == "snapshot" and f["status"]["name"] == "web1")
    st.until("synced", lambda f: f["type"] == "synced")
    r = ask({"cmd": "rename", "session": "web1", "name": "api"})
    assert r["ok"], r
    left = st.until("left", lambda f: f["type"] in ("left", "renamed"))
    assert left["type"] == "left" and left["status"]["name"] == "api", left
elif mode == "slow":
    # Snapshot frames large enough to fill the socket, which this client
    # does not read; then more events than the daemon keeps.
    big = [ask({"cmd": "run", "argv": ["sh", "-c", "sleep 30", "a" * 100000, "b" * 100000, "c" * 100000]})
           for _ in range(4)]
    small = str(ask({"cmd": "run", "argv": ["sleep", "30"]})["status"]["id"])
    st = Stream({"cmd": "events"})
    time.sleep(0.3)
    for i in range(1100):
        assert ask({"cmd": "rename", "session": small, "name": "r%d" % (i % 2)})["ok"]
    st.until("resync", lambda f: f["type"] == "resync", timeout=10)
    st.until("synced", lambda f: f["type"] == "synced", timeout=10)
    for r in big:
        ask({"cmd": "remove", "sessions": [str(r["status"]["id"])], "force": True})
    ask({"cmd": "remove", "sessions": [small], "force": True})
PY
client() { python3 "$dir/client.py" "$TUPPET_SOCKET" "$@"; }

sh_id=$(client frames) || fail "events frames: $sh_id"
client idle "$sh_id" || fail "idle and active edges"
client quiet-tty || fail "a quiet session's tty change"

# A bell marks the session in list until an ack.
"$BIN" key "$sh_id" "printf '\\a'" '<Enter>'
for _ in $(seq 100); do "$BIN" list "$sh_id" | grep -q '^! .* bell ' && break; sleep 0.02; done
"$BIN" list "$sh_id" | grep -q '^! .* bell ' || fail "a bell did not mark the session: $("$BIN" list "$sh_id")"
"$BIN" ack "$sh_id"
"$BIN" list "$sh_id" | grep -q '^ .* running ' || fail "ack did not clear the mark: $("$BIN" list "$sh_id")"
"$BIN" key "$sh_id" "printf '\\a'; sleep 0.1; printf '\\a'" '<Enter>'
for _ in $(seq 100); do [ "$("$BIN" list -j "$sh_id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions"][0]["bell_count"])')" = 3 ] && break; sleep 0.02; done
client stale-acks "$sh_id" || fail "stale acks"

"$BIN" run -n web1 sleep 30 >/dev/null
client leave || fail "a renamed session did not leave the filter"

client slow || fail "a slow subscriber did not resync"

# tuppet stop ends a session as stopped, not as failed by its signal, and
# it needs nobody: whoever stopped it knows.
"$BIN" stop api >/dev/null
"$BIN" list api | grep -q '^  .* stopped ' || fail "stop did not show stopped, unmarked: $("$BIN" list api)"

# --count: the command exits 0 after that many events.
"$BIN" events --count 1 -t 10s "$sh_id" >"$dir/events.out" &
events_pid=$!
for i in $(seq 50); do
    kill -0 "$events_pid" 2>/dev/null || break
    "$BIN" rename "$sh_id" "n$i"
    sleep 0.1
done
wait "$events_pid" || fail "events --count exited $?"
grep -q " $sh_id n[0-9]*  renamed to n[0-9]*$" "$dir/events.out" || fail "events printed: $(cat "$dir/events.out")"
# -t running out before --count events came: exit 3 and a line saying so.
set +e
"$BIN" events --count 1 -t 200ms "$sh_id" >/dev/null 2>"$dir/events.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "events --count with -t running out exited $status, not 3"
grep -q "0 of 1 events came within 200ms" "$dir/events.err" || fail "events timeout: $(cat "$dir/events.err")"

"$BIN" remove -f '*' >/dev/null
echo "PASS: events, attention marks, acks, stopped"

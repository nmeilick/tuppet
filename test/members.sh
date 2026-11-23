#!/usr/bin/env bash
# Groups and side sessions in the daemon: numbers in a group, update,
# flag, side views and side-requested, actions in events, leases, respawn,
# --idle-exit, and the hello features.
set -euo pipefail

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
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
field() { "$BIN" list "$1" -j | python3 -c "import json,sys; v=json.load(sys.stdin)['sessions'][0]['$2']; print(v if not isinstance(v,(list,dict)) else json.dumps(v))"; }

python3 - "$TUPPET_SOCKET" <<'PY' || fail "hello lacks a feature"
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b'{"cmd":"hello"}\n')
f = json.loads(s.makefile().readline())["features"]
assert all(x in f for x in ["groups", "side", "lease", "marks", "respawn"]), f
PY

# Numbers: the lowest free one in the group, also after a member left.
"$BIN" events -j >"$dir/events" &
events_pid=$!
sleep 0.2
"$BIN" run -n a --group w --label 'db07 prod' --accent --action 's:share:Once|Live|Stop' -- sleep 60 >/dev/null
"$BIN" run -n b --group w -- sleep 60 >/dev/null
[ "$(field a number)" = 0 ] && [ "$(field b number)" = 1 ] || fail "numbers $(field a number) $(field b number)"
"$BIN" update a --group v --mark '◉' --meta route=dmz >/dev/null
[ "$(field a group)" = v ] && [ "$(field a number)" = 0 ] || fail "moved: $(field a group) $(field a number)"
"$BIN" run -n c --group w -- sleep 60 >/dev/null
[ "$(field c number)" = 0 ] || fail "the free number is $(field c number)"
[ "$(field a mark)" = '◉' ] && [ "$(field a label)" = 'db07 prod' ] || fail "update lost the label or mark"
"$BIN" flag b --attention 'login?' >/dev/null
[ "$(field b attention)" = 'login?' ] || fail "flag"
"$BIN" flag b --clear >/dev/null
[ "$(field b attention)" = None ] || fail "flag --clear"

# Side sessions: tied, one at a time, views, a request on one without.
"$BIN" run -n p --side-of a --side-view half -- sleep 60 >/dev/null
[ "$(field a side)" = "$(field p id)" ] && [ "$(field p side_view)" = half ] || fail "side tie"
"$BIN" run -n q --side-of a -- sleep 60 >/dev/null 2>&1 && fail "a second side session was tied"
"$BIN" side a --view full >/dev/null
[ "$(field p side_view)" = full ] || fail "side --view on the session it is tied to"
"$BIN" side b --request >/dev/null
python3 - "$TUPPET_SOCKET" "$(field a id)" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(json.dumps({"cmd": "action", "session": sys.argv[2], "key": "s", "value": "Live"}).encode() + b"\n")
assert json.loads(s.makefile().readline())["ok"]
PY
sleep 0.5
kill "$events_pid"
wait "$events_pid" 2>/dev/null || true
python3 - "$dir/events" <<'PY' || fail "events: $(cat "$dir/events")"
import json, sys
frames = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
kinds = [f["type"] for f in frames]
assert "side-view" in kinds and "side-requested" in kinds, kinds
act = [f for f in frames if f["type"] == "action"]
assert act and act[0]["key"] == "s" and act[0]["value"] == "Live", act
PY
"$BIN" stop p >/dev/null
[ "$(field a side)" = None ] || fail "an ended side session stays tied"

# Respawn: the old screen, the number, and the side session go along.
"$BIN" run -n r --group w -- sh -c 'echo before-respawn' >/dev/null
"$BIN" wait r -e -t 3s >/dev/null
"$BIN" run -n rs --side-of r -- sleep 60 >/dev/null 2>&1 && fail "a side session was tied to an ended session"
number=$(field r number)
new=$("$BIN" respawn r --env PATH=/usr/bin:/bin)
"$BIN" wait r -e -t 3s >/dev/null
[ "$(field r id)" = "$new" ] && [ "$(field r number)" = "$number" ] || fail "respawn kept $(field r id) $(field r number)"
[ "$("$BIN" view r | grep -c before-respawn)" = 2 ] || fail "respawn lost the screen: $("$BIN" view r)"

# Leases: closing one stops the session; one ends with its session.
"$BIN" run -n l -- sleep 60 >/dev/null
"$BIN" lease l >/dev/null &
lease_pid=$!
sleep 0.3
kill "$lease_pid"
wait "$lease_pid" 2>/dev/null || true
"$BIN" wait l -e -t 3s >/dev/null || fail "a closed lease did not stop its session"
[ "$(field l exit | python3 -c 'import json,sys; print(json.load(sys.stdin)["stopped"])')" = True ] || fail "not stopped"
timeout 5 "$BIN" run -n m --lease -- sleep 0.3 >/dev/null || fail "run --lease did not end with its session"

# --idle-exit: a minute without sessions, so only that it starts.
"$BIN" stop '*' >/dev/null 2>&1 || true
"$BIN" daemon --socket "$dir/idle.sock" --idle-exit --keep-fresh 2>"$dir/idle.log" &
idle_pid=$!
for _ in $(seq 100); do "$BIN" --socket "$dir/idle.sock" list >/dev/null 2>&1 && break; sleep 0.02; done
kill "$idle_pid"
wait "$idle_pid" 2>/dev/null || true

echo "members: ok"

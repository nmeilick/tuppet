#!/usr/bin/env bash
# Session names: unique among running sessions, taken over from ended
# ones (also from ones only the store still has), kept or replaced on
# request, and usable with patterns wherever an id is; the list table and
# its JSON.
set -euo pipefail

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
# Session data goes to the test directory, never to the user's store.
export XDG_STATE_HOME="$dir/state"
export TUPPET_SOCKET="$dir/s.sock"
daemon_pid=
start_daemon() {
    "$BIN" daemon --socket "$TUPPET_SOCKET" 2>>"$dir/log" &
    daemon_pid=$!
    for _ in $(seq 100); do "$BIN" list >/dev/null 2>&1 && return; sleep 0.02; done
    return 1
}
cleanup() {
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
named() { "$BIN" list | awk -v n="$1" 'NR > 1 { sub(/^!/, ""); if ($2 == n) print $1 }'; }

start_daemon

# A running session keeps its name; the name works like the id.
web=$("$BIN" run -n web sh -c 'echo FIRST; exec cat')
if "$BIN" run -n web true 2>"$dir/err"; then fail "a running session's name was given out twice"; fi
grep -q "running session 'web'" "$dir/err" || fail "the error does not name the running session"
"$BIN" wait web -m FIRST -t 2s >/dev/null || fail "wait by name failed"
[ "$("$BIN" run -n web --if-exists keep true)" = "$web" ] || fail "--if-exists keep did not return the running session"

# A replaced session is stopped and gives its name up to the new one, as
# an ended session does.
web2=$("$BIN" run --name web --if-exists replace sh -c 'echo SECOND; exec cat')
[ "$(named web)" = "$web2" ] || fail "the new session did not take the name over"
if "$BIN" view "$web" 2>/dev/null; then fail "the replaced session was kept"; fi

# A pattern for one session must pick exactly one; stop and remove take
# several, each once, and their patterns pick only what they apply to.
a=$("$BIN" run -n ci-a cat)
b=$("$BIN" run -n ci-b cat)
unnamed=$("$BIN" run true)
"$BIN" wait "$unnamed" -e >/dev/null
if "$BIN" view 'ci-*' 2>"$dir/err"; then fail "a pattern picked one of several sessions"; fi
grep -q "matches 2 sessions" "$dir/err" || fail "the error does not say how many sessions matched"
"$BIN" stop 'ci-*' "$a" || fail "stopping by pattern failed"
"$BIN" stop 'ci-?' || fail "a pattern matching only ended sessions made stop fail"
"$BIN" remove '*' || fail "removing every ended session failed"
[ "$("$BIN" list | awk 'NR > 1 { print $1 }')" = "$web2" ] || fail "remove '*' did not remove exactly the ended sessions"
if "$BIN" remove 'ci-*' web 2>"$dir/err"; then fail "remove reported success for nothing to remove"; fi
grep -q "no session matches 'ci-\*'" "$dir/err" || fail "a pattern matching nothing was not reported"
grep -q "session $web2 is still running" "$dir/err" || fail "a running session named explicitly was not reported"
"$BIN" remove -f 'ci-*' || fail "remove -f failed for a pattern that matches nothing"

# The list: a table with a header in a pipe too, and its JSON.
"$BIN" list | head -1 | grep -q '^!  *ID  *NAME  *STATE  *AGE  *CMD$' || fail "the list table lacks its header"
"$BIN" list web | grep -q "^ *$web2  *web  *running  .*  sh -c 'echo SECOND; exec cat'$" || fail "the list table row is wrong"
"$BIN" list -j web 'nothing-*' | python3 -c "
import json, sys
s = json.load(sys.stdin)['sessions']
assert [x['id'] for x in s] == [$web2] and s[0]['name'] == 'web' and s[0]['state'] == 'running', s" \
    || fail "list -j did not give the picked sessions' status"

# A later daemon on the same endpoint still enforces the names of the
# ended sessions it only has in the store.
kill "$daemon_pid"; wait "$daemon_pid" || true
start_daemon
web3=$("$BIN" run -n web true)
[ "$(named web)" = "$web3" ] || fail "a stored session's name was not taken over"
if "$BIN" view "$web2" 2>/dev/null; then fail "the replaced stored session was kept"; fi

echo "PASS: session names, patterns, and several sessions per stop and remove"

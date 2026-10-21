#!/usr/bin/env bash
# Sampled facts in the status: hidden input at bash's `read -s` and a wait
# for it, the foreground program's name, and the title and working
# directory a program reports.
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

# field ID EXPR: EXPR in Python over the session's status `s`.
field() {
    "$BIN" list -j "$1" | python3 -c 'import json, sys; s = json.load(sys.stdin)["sessions"][0]; print(json.dumps(eval(sys.argv[1])))' "$2"
}
# poll ID EXPR WANT: until EXPR gives WANT, for at most 5 seconds.
poll() {
    local got
    for _ in $(seq 250); do
        got=$(field "$1" "$2")
        [ "$got" = "$3" ] && return 0
        sleep 0.02
    done
    fail "$2 stayed $got, wanted $3"
}

sh_id=$("$BIN" run bash --norc --noprofile -i)
"$BIN" wait "$sh_id" -m '$ ' -t 3s >/dev/null
[ "$(field "$sh_id" 's["hidden_input"]')" = false ] || fail "a shell prompt counted as hidden input"

# read -s reads a line without echo: hidden input, until the line is read.
# The second prompt follows the answer to the first at once, and is new.
"$BIN" key "$sh_id" 'read -s -p "pw: " pw; read -s -p "again: " again; echo "got ${#pw} ${#again}"' '<Enter>'
line=$("$BIN" wait "$sh_id" --hidden-input --after-input -t 5s)
[[ $line =~ ^met\ hidden_input#0\ $sh_id\  ]] || fail "read -s did not meet --hidden-input: $line"
[ "$(field "$sh_id" '[s["hidden_input"], s["tty"]]')" = '[true, {"canonical": true, "echo": false}]' ] ||
    fail "read -s is not hidden input in the status"
"$BIN" list "$sh_id" | grep -q ' password? ' || fail "list did not show password?"
"$BIN" key "$sh_id" hunter2 '<Enter>'
"$BIN" wait "$sh_id" --hidden-input --after-input -t 5s >/dev/null || fail "the second prompt did not meet --hidden-input"
"$BIN" key "$sh_id" hunter2 '<Enter>'
"$BIN" wait "$sh_id" -m 'got 7 7' -t 3s >/dev/null
[ "$(field "$sh_id" 's["hidden_input"]')" = false ] || fail "hidden input stayed after the read"

# A foreground job is its own process group.
"$BIN" key "$sh_id" 'sleep 5' '<Enter>'
poll "$sh_id" 's["foreground"]["name"]' '"sleep"'
"$BIN" key "$sh_id" '<C-c>'
poll "$sh_id" 's["foreground"]["name"]' '"bash"'

# The title (OSC 2) loses its controls, the working directory (OSC 7) its
# percent-encoding.
"$BIN" key "$sh_id" "printf '\\033]2;build\\001 log\\007\\033]7;file://box/tmp/a%%20b\\007'" '<Enter>'
poll "$sh_id" '[s["title"], s["cwd"]]' '["build log", {"path": "/tmp/a b", "host": "box"}]'

"$BIN" remove -f '*' >/dev/null
echo "PASS: hidden input, foreground name, title, cwd"

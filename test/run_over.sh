#!/usr/bin/env bash
# `tuppet run --over`: its usage errors, the outcome line and exit code of a
# box that a raw attach held, of one never held, and of one whose -t ran out,
# the box removed after its result, an interrupt stopping the box, and the
# `box waits` mark in `tuppet list`. An outer daemon gives the attach its
# terminal; the inner one holds the boxes.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
inner=(env XDG_RUNTIME_DIR="$dir/in" XDG_STATE_HOME="$dir/in/state" TUPPET_CONFIG=)
outer=(env XDG_RUNTIME_DIR="$dir/out" XDG_STATE_HOME="$dir/out/state" TUPPET_CONFIG=)
mkdir -p "$dir/in" "$dir/out"
cleanup() {
    for side in in out; do
        for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
            tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/$side" && kill "$pid" 2>/dev/null
        done
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
tuppet() { "${inner[@]}" "$BIN" "$@"; }
# poll CMD...: CMD succeeds within 5 s.
poll() { for _ in $(seq 100); do "$@" && return 0; sleep 0.05; done; return 1; }
# outcome FILE CODE WANT LINE: run --over printed the box's id, then LINE
# with BOX for the id, exited with CODE as WANT, and removed the box.
outcome() {
    local box
    box=$(head -1 "$1")
    [ "$2" = "$3" ] || fail "run --over exited $2, not $3: $(cat "$1")"
    [ "$(sed -n 2p "$1")" = "${4//BOX/$box}" ] || fail "the outcome is not '$4': $(cat "$1")"
    tuppet list -j "$box" | grep -q '"sessions":\[\]' || fail "box $box was not removed"
}
held() { tuppet list -j "$box" | grep -q '"held":true'; }

tuppet run -n under cat >/dev/null
for opts in "-a" "-m x" "--grab never --backdrop live"; do
    # shellcheck disable=SC2086
    if tuppet run --over under $opts -- cat >/dev/null 2>&1; then code=0; else code=$?; fi
    [ "$code" = 2 ] || fail "run --over $opts exited $code, not 2"
done

if tuppet run --over under -- true >"$dir/never"; then code=0; else code=$?; fi
outcome "$dir/never" "$code" 4 "ended BOX exit=0 held=no shown=no"
if tuppet run --over under -t 200ms -- cat >"$dir/unseen"; then code=0; else code=$?; fi
outcome "$dir/unseen" "$code" 3 "stopped BOX reason=unseen held=no shown=no"

# A box that no writer holds waits over its session, which then needs
# someone; once a raw attach holds it, the program's own code comes back.
tuppet run --over under -- sh -c 'read -r _; exit 7' >"$dir/held" &
runner=$!
poll test -s "$dir/held" || fail "run --over printed no id"
box=$(head -1 "$dir/held")
tuppet list under | grep -Eq '^! +[0-9]+ +under +box waits ' || fail "no box waits: $(tuppet list under)"
"${outer[@]}" "$BIN" run "${inner[@]}" "$BIN" attach "$box" >/dev/null
poll held || fail "the attach did not hold the box"
tuppet list under | grep -q 'box waits' && fail "a held box still waits"
tuppet key "$box" 'x<Enter>'
if wait "$runner"; then code=0; else code=$?; fi
outcome "$dir/held" "$code" 7 "ended BOX exit=7 held=yes shown=yes"

# Not through the function: the signal must reach tuppet, not a subshell.
"${inner[@]}" "$BIN" run --over under -- cat >"$dir/interrupted" &
runner=$!
poll test -s "$dir/interrupted" || fail "run --over printed no id"
kill -INT "$runner"
if wait "$runner"; then code=0; else code=$?; fi
outcome "$dir/interrupted" "$code" 130 "stopped BOX reason=stopped held=no shown=no"

# A box lost with its daemon is reported as lost, with exit 4. Last: the
# inner daemon is gone after it.
"${inner[@]}" "$BIN" run --over under -- cat >"$dir/lost" 2>/dev/null &
runner=$!
poll test -s "$dir/lost" || fail "run --over printed no id"
for pid in $(pgrep -f "^$BIN daemon"); do
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/in" && kill -KILL "$pid"
done
if wait "$runner"; then code=0; else code=$?; fi
[ "$code" = 4 ] || fail "run --over whose daemon died exited $code, not 4: $(cat "$dir/lost")"
[ "$(sed -n 2p "$dir/lost")" = "lost $(head -1 "$dir/lost")" ] || fail "no lost line: $(cat "$dir/lost")"
echo "PASS: run --over: usage errors, held, never held, -t, removal, interrupt, box waits, lost"

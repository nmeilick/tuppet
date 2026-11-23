#!/usr/bin/env bash
# A drawn attach of a group: an outer daemon's session plays the person's
# terminal and runs `tuppet attach --drawn --group w` against an inner
# daemon. Members are sized to the window minus the bar, a switch sends no
# resize, the outer scrollback holds each line once with a mark at a
# switch and none of the bar, the side pane steps through its views, an
# ended member stays dimmed until Enter closes it, d detaches, and
# --end-with ends the attach with that session's code.
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
    sleep 0.3
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; "${outer[@]}" "$BIN" view "${att:-0}" -s >&2 || true; exit 1; }
I() { "${inner[@]}" "$BIN" "$@"; }
O() { "${outer[@]}" "$BIN" "$@"; }
ok() { O key "$att" "$@" >/dev/null; }
outer_has() { O wait "$att" --match "$1" --timeout 5s >/dev/null || fail "$2"; }
field() { I list "$1" -j | python3 -c "import json,sys; print(json.load(sys.stdin)['sessions'][0]['$2'])"; }
size_is() {
    for _ in $(seq 60); do [ "$(field "$1" cols)x$(field "$1" rows)" = "$2" ] && return; sleep 0.05; done
    fail "$1 is $(field "$1" cols)x$(field "$1" rows), not $2"
}
view_is() {
    for _ in $(seq 60); do [ "$(field "$1" side_view)" = "$2" ] && return; sleep 0.05; done
    fail "$1's view is $(field "$1" side_view), not $2"
}

I run -n a --group w -s 50x10 -- bash --norc --noprofile >/dev/null
I run -n b --group w -s 50x10 --label 'db07 prod' -- bash --norc --noprofile >/dev/null
I key a 'PS1="a> "<Enter>' >/dev/null
I key b 'PS1="b> "<Enter>' >/dev/null
att=$(O run --size 100x40 env -u TUPPET_SESSION "${inner[@]:1}" LC_ALL=C.UTF-8 "$BIN" attach --drawn --group w a)
outer_has 'a>' "the group attach did not show a"
size_is a 100x39
size_is b 100x39
resize_b=$(field b resize_seq)

ok 'echo one<Enter>'
outer_has 'one' "keys did not reach a"
# The switcher, and 1 goes to b.
ok '<F12>'
outer_has 'Enter go' "the switcher did not open"
ok 1
outer_has 'b>' "b did not come to the front"
outer_has 'db07 prod' "the bar does not name b's label"
sleep 0.3
[ "$(field b resize_seq)" = "$resize_b" ] || fail "the switch resized b"
ok 'seq 1 60 | sed s/^/n/<Enter>'
outer_has 'n60' "b's output did not show"
O view "$att" -s >"$dir/hist"
grep -q '^── b' "$dir/hist" || fail "no mark at the switch in the scrollback"
[ "$(grep -c '^n37$' "$dir/hist")" = 1 ] || fail "a line of b is not in the scrollback once"
if head -n -40 "$dir/hist" | grep -q 'F12'; then fail "the bar went into the scrollback"; fi

# F12 twice goes back to a.
ok '<F12>' '<F12>'
outer_has 'a> echo one' "F12 twice did not go back"

# The side pane: below the front, half, and compact again with Esc.
I run -n p --side-of a -- bash --norc --noprofile >/dev/null
I key p 'PS1="p> "<Enter>' >/dev/null
size_is a 100x31
size_is p 100x8
outer_has 'p>' "the side pane did not show"
ok '<F11>'
view_is p half
size_is p 100x19
ok 'echo side<Enter>'
I wait p --match 'side' -t 3s >/dev/null || fail "keys did not reach the side session in half"
ok '<Esc>'
view_is p compact
size_is a 100x31

# An ended member stays dimmed until Enter closes it; the caller's action
# on x comes before x's closing.
ok '<F12>' 1
outer_has 'b>' "b did not come back"
I update b --action 'x:done' >/dev/null
I events b -j >"$dir/b-events" &
b_events=$!
ok 'exit<Enter>'
outer_has 'Enter close' "the ended member does not say so"
sleep 0.6
ok x
for _ in $(seq 60); do grep -q '"type":"action"' "$dir/b-events" && break; sleep 0.05; done
kill "$b_events"
wait "$b_events" 2>/dev/null || true
grep -q '"type":"action".*"key":"x"' "$dir/b-events" || fail "x on the ended member was no action: $(cat "$dir/b-events")"
ok '<Enter>'
outer_has 'a>' "Enter did not close b and go back"
count_b() { I list b -j | python3 -c "import json,sys; print(len(json.load(sys.stdin)['sessions']))"; }
for _ in $(seq 60); do [ "$(count_b)" = 0 ] && break; sleep 0.05; done
[ "$(count_b)" = 0 ] || fail "the closed member was not removed"

# A caller's action, after the letters' half second, and with a choice.
I update a --action 'z:zap' --action 's:share:Once|Live' >/dev/null
I events a -j >"$dir/events" &
events_pid=$!
sleep 0.2
ok '<F12>'
outer_has 'z zap' "the switcher does not offer the caller's action"
sleep 0.7
ok z
ok '<F12>'
sleep 0.7
ok s '<Right>' '<Enter>'
sleep 0.5
kill "$events_pid"
wait "$events_pid" 2>/dev/null || true
python3 - "$dir/events" <<'PY' || fail "actions: $(grep action "$dir/events")"
import json, sys
acts = [(f["key"], f["value"]) for f in map(json.loads, open(sys.argv[1])) if f["type"] == "action"]
assert acts == [("z", None), ("s", "Live")], acts
PY

# d detaches; the members keep running.
ok '<C-]>'
sleep 0.7
ok d
O wait "$att" -e -t 5s >/dev/null || fail "d did not detach"
[ "$(field a state)" = running ] || fail "a stopped"
# --end-with ends the attach with that session's code.
I run -n e --group v -- sh -c 'sleep 1; exit 7' >/dev/null
att=$(O run --size 80x24 env -u TUPPET_SESSION "${inner[@]:1}" LC_ALL=C.UTF-8 "$BIN" attach --drawn --group v --end-with e)
O wait "$att" -e -t 5s >/dev/null || fail "--end-with did not end the attach"
[ "$(O list "$att" -j | python3 -c "import json,sys; print(json.load(sys.stdin)['sessions'][0]['exit']['code'])")" = 7 ] || fail "--end-with did not give the code"

# A group of one draws no bar, yet shows tuppet's line for a waiting box
# and the ended member's line, as a plain drawn attach does.
printf '[attach]\nbox_pause = "60s"\n' >"$dir/config.toml"
I run -n solo --group s -- bash --norc --noprofile >/dev/null
I key solo 'PS1="solo> "<Enter>' >/dev/null
att=$(O run --size 80x24 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 "$BIN" attach --drawn --group s)
outer_has 'solo>' "the group of one did not show solo"
size_is solo 80x24
I run --over solo --title 'check it' -- sleep 1 >/dev/null 2>&1 &
box_pid=$!
outer_has 'check it waits' "a group of one does not show a waiting box's line"
wait "$box_pid" || true
ok 'exit<Enter>'
outer_has 'ended 0' "a group of one does not say that its member ended"
outer_has 'Enter close' "a group of one does not offer to close its member"
sleep 0.6
ok '<Enter>'
O wait "$att" -e -t 5s >/dev/null || fail "Enter did not close the only member"

# Seven actions leave tuppet's own keys in the switcher's footer, at 120
# columns and at 80; --title names its frame, and --quiet-detach says
# nothing on detach.
I update a --action 'z:zap' --action 's:share:Once|Live' --action 'k:keep' --action 'l:lock' \
    --action 'm:move' --action 'n:note' --action 'o:open:?host' >/dev/null
att=$(O run --size 120x30 env -u TUPPET_SESSION "${inner[@]:1}" LC_ALL=C.UTF-8 "$BIN" attach --drawn --group w --title 'My hosts' --quiet-detach)
outer_has 'a>' "the attach did not show a"
ok '<F12>'
outer_has 'My hosts' "the switcher's frame does not show --title"
for want in 'digits' 'z zap' 'o open' 'd detach' 'f side' 'h history' 'F12 back'; do
    outer_has "$want" "the footer at 120 columns lacks '$want'"
done
O resize "$att" 80x30 >/dev/null
sleep 0.5
for want in 'digits' 'z zap' 'o open' 'd detach' 'f side' 'h history' 'F12 back'; do
    outer_has "$want" "the footer at 80 columns lacks '$want'"
done
sleep 0.5
ok d
O wait "$att" -e -t 5s >/dev/null || fail "d did not detach"
if O view "$att" -s | grep -q 'detached from group'; then fail "--quiet-detach still said how to return"; fi
echo "group: ok"

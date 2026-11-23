#!/usr/bin/env bash
# A drawn attach keeps the terminal's scrollback: an outer daemon's
# session plays the person's terminal and runs `tuppet attach --drawn` to
# a shell in an inner daemon. What leaves the shell's screen must reach
# the outer session's history once, in order, and with no text of
# tuppet's: through a flood, an erase of history, a full reset, a
# full-screen program, a box, and resizes.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
inner=(env XDG_RUNTIME_DIR="$dir/in" XDG_STATE_HOME="$dir/in/state" TUPPET_CONFIG=)
outer=(env XDG_RUNTIME_DIR="$dir/out" XDG_STATE_HOME="$dir/out/state" TUPPET_CONFIG=)
mkdir -p "$dir/in" "$dir/out"
cleanup() {
    local pids=()
    for side in in out; do
        for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
            tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/$side" && kill "$pid" 2>/dev/null && pids+=("$pid")
        done
    done
    for _ in $(seq 100); do
        local alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" = 0 ] && break
        sleep 0.05
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; "${outer[@]}" "$BIN" view "${att:-0}" -s >&2 || true; exit 1; }
ik() { "${inner[@]}" "$BIN" key "$in" "$@" >/dev/null; }
ok() { "${outer[@]}" "$BIN" key "$att" "$@" >/dev/null; }
outer_has() { "${outer[@]}" "$BIN" wait "$att" --match "$1" --timeout 5s >/dev/null || fail "$2"; }
# Poll until the outer session's history agrees with the inner's.
agree_soon() {
    for _ in $(seq 60); do
        [ "$("${inner[@]}" "$BIN" view "$in" -s --unwrap | sed '/./,$!d')" = "$("${outer[@]}" "$BIN" view "$att" -s --unwrap | sed '/./,$!d')" ] && return
        sleep 0.05
    done
    both_agree "$1"
}
# The outer and inner sessions' history and screen, joined at wraps, from
# the first line that is not blank.
both_agree() {
    "${inner[@]}" "$BIN" view "$in" -s --unwrap | sed '/./,$!d' >"$dir/want"
    "${outer[@]}" "$BIN" view "$att" -s --unwrap | sed '/./,$!d' >"$dir/got"
    diff "$dir/want" "$dir/got" >"$dir/diff" || fail "$1: $(head -20 "$dir/diff")"
}
# in_order PREFIX N: PREFIX1..PREFIXN each in the outer history, in order;
# a line may repeat where a resize cut.
in_order() {
    "${outer[@]}" "$BIN" view "$att" -s --unwrap | python3 -c '
import re, sys
p, n = sys.argv[1], int(sys.argv[2])
nums = [int(m.group(1)) for m in (re.fullmatch(re.escape(p) + r"(\d+)", l) for l in sys.stdin.read().split("\n")) if m]
missing = sorted(set(range(1, n + 1)) - set(nums))
if missing:
    sys.exit("missing %r" % missing[:10])
last = 0
for x in nums:
    if x < last - 12:
        sys.exit("out of order: %d after %d" % (x, last))
    last = max(last, x)
' "$1" "$2" || fail "$3"
}

printf '[attach]\nbox_pause = "100ms"\n' >"$dir/config.toml"
in=$("${inner[@]}" "$BIN" run -n agent -s 60x10 bash --norc --noprofile)
ik 'PS1="$ "<Enter>'
att=$("${outer[@]}" "$BIN" run --size 60x10 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" LC_ALL=C.UTF-8 \
    "$BIN" attach --drawn "$in")
outer_has 'PS1' "the drawn attach did not paint the session"

# A flood, and a line that wraps: every line once, in order.
ik 'seq 1 3000; printf "%075d\n" 7<Enter>'
outer_has '000000000000007' "the flood did not end"
both_agree "after a flood"

# Rows in the history before an erase of history or a reset stay in the
# terminal's; a full-screen program leaves none of its own.
ik 'seq -f a%g 15; clear; echo K$((0+1))<Enter>'
outer_has 'K1' "clear did not end"
in_order a 5 "the rows that left before clear were not kept"
ik 'seq -f b%g 15; printf "\033c"; echo K$((0+2))<Enter>'
outer_has 'K2' "the reset did not end"
in_order b 6 "the rows that left before a reset were not kept"
seq -f "vline%g" 100 >"$dir/f"
ik "vim -u NONE $dir/f<Enter>"
outer_has 'vline8' "vim did not start"
# vim may still be asking its terminal questions when the first keys come.
for _ in $(seq 30); do
    "${inner[@]}" "$BIN" view "$in" | grep -q vline8 || break
    ik '<Esc>:q!<Enter>'
    sleep 0.1
done
"${inner[@]}" "$BIN" view "$in" | grep -q vline8 && fail "vim did not end"
ik 'seq -f c%g 15<Enter>'
outer_has 'c15' "the shell did not go on after vim"
"${outer[@]}" "$BIN" view "$att" -s | grep -q '^vline1$' && fail "vim's screen reached the scrollback"

# Lines that scroll while a box has the keyboard come after it closes.
"${inner[@]}" "$BIN" run --over agent --title confirm -s 30x4 -- sh -c 'echo BOXED; read -r _' >/dev/null &
outer_has 'keys here' "the box did not open"
ik 'seq -f d%g 20<Enter>'
"${inner[@]}" "$BIN" wait "$in" --match 'd20' --timeout 3s >/dev/null || fail "the session did not print under the box"
ok 'ok<Enter>'
outer_has 'confirm closed' "the box did not close"
ik 'seq -f e%g 12<Enter>'
outer_has 'e12' "the shell did not go on after the box"
in_order d 20 "the rows that left under the box were not kept"

# Resizes with the cursor at the bottom, above it, and hidden.
ik 'seq -f f%g 30<Enter>'
outer_has 'f30' "no lines before the resizes"
"${outer[@]}" "$BIN" resize "$att" 60x6 >/dev/null
ik 'seq -f g%g 10<Enter>'
outer_has 'g10' "no lines after a shrink"
"${outer[@]}" "$BIN" resize "$att" 60x10 >/dev/null
ik 'seq -f h%g 12<Enter>'
outer_has 'h12' "no lines after a growth"
ik 'clear; seq -f i%g 3<Enter>'
outer_has 'i3' "no lines with the cursor high"
"${outer[@]}" "$BIN" resize "$att" 60x5 >/dev/null
ik 'seq -f j%g 12<Enter>'
outer_has 'j12' "no lines after a shrink with the cursor high"
ik 'printf "\033[?25l"; seq -f k%g 12<Enter>'
outer_has 'k12' "no lines with the cursor hidden"
"${outer[@]}" "$BIN" resize "$att" 50x8 >/dev/null
ik 'seq -f l%g 12<Enter>'
outer_has 'l12' "no lines after a resize with the cursor hidden"
"${outer[@]}" "$BIN" resize "$att" 60x10 >/dev/null
ik 'printf "\033[?25h"; seq -f m%g 12<Enter>'
outer_has 'm12' "no lines after the last resize"
in_order f 30 "rows lost around a shrink"
in_order g 10 "rows lost around a growth"
for p in j k l; do in_order "$p" 12 "rows lost around a resize ($p)"; done

# Growths while lines print: the outer terminal takes rows back from its
# scrollback, and none of them may be painted over.
ik 'for i in $(seq 300); do echo n$i; sleep 0.01; done<Enter>'
for step in 'n40 60x16' 'n120 60x22'; do
    outer_has "${step% *}" "the lines did not print before a growth"
    "${outer[@]}" "$BIN" resize "$att" "${step#* }" >/dev/null
done
outer_has 'n300' "the lines did not go on after the growths"
in_order n 300 "rows lost around a growth while lines print"

# Nothing of tuppet's own reached the history.
"${outer[@]}" "$BIN" view "$att" -s | head -n -10 | grep -E 'tuppet|confirm|keys here|━' && fail "tuppet's own text reached the scrollback"

# Rows on the screen when an attach starts: a long line stays one line in
# the scrollback, and a wrapped row whose next row was erased does not
# move the rows below it.
in=$("${inner[@]}" "$BIN" run -s 20x8 sh -c 'printf "abcdefghijklmnopqrstuvwxyz\033[2;1H\033[K\033[3;1Hrow2\033[4;1Hrow3\033[5;1H%025d\n" 9; exec cat')
"${inner[@]}" "$BIN" wait "$in" --match row3 --timeout 3s >/dev/null || fail "the screen to attach to was not printed"
att=$("${outer[@]}" "$BIN" run --size 20x8 env -u TUPPET_SESSION "${inner[@]:1}" LC_ALL=C.UTF-8 "$BIN" attach --drawn "$in")
outer_has 'row3' "the drawn attach did not paint the screen it found"
[ "$("${outer[@]}" "$BIN" view "$att")" = "$("${inner[@]}" "$BIN" view "$in")" ] || fail "the screen the attach found is painted out of place"
for i in $(seq 8); do ik "l$i<Enter>"; done
agree_soon "rows on the screen when the attach started"

# --history: the older lines come first, and a long line that the
# session's screen cut in two, half in its history, stays one line.
in=$("${inner[@]}" "$BIN" run -s 60x10 sh -c 'seq -f p%g 5; printf "%075d\n" 7; seq -f q%g 8; exec cat')
"${inner[@]}" "$BIN" wait "$in" --match q8 --timeout 3s >/dev/null || fail "the lines for --history were not printed"
att=$("${outer[@]}" "$BIN" run --size 60x10 env -u TUPPET_SESSION "${inner[@]:1}" LC_ALL=C.UTF-8 "$BIN" attach --drawn --history 20 "$in")
outer_has 'q8' "the drawn attach with --history did not paint"
for i in $(seq 12); do ik "r$i<Enter>"; done
agree_soon "--history and a line cut by the screen's top"

echo "PASS: drawn attach on the normal screen: a flood and a wrapped line, erase of history and reset, a full-screen program, lines under a box, resizes with the cursor at the bottom, above, and hidden, growths while lines print, nothing of tuppet's in the scrollback, the rows the attach found, --history"

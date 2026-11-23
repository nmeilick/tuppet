#!/usr/bin/env bash
# `tuppet attach --history`: the session's older lines come first, to a
# pipe as they are, and in a terminal (an outer session) into its
# scrollback in order, right above the session's screen.
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
fail() { echo "FAIL: $1" >&2; exit 1; }

# To a pipe: the last 5 lines of the history, then the stream.
done_id=$("${inner[@]}" "$BIN" run --size 20x5 sh -c 'for i in $(seq 1 40); do echo "line $i"; done')
"${inner[@]}" "$BIN" wait "$done_id" -e --timeout 5s >/dev/null || fail "the printing session did not end"
"${inner[@]}" "$BIN" attach -r "$done_id" --history 5 >"$dir/pipe" || true
python3 - "$dir/pipe" <<'EOF' || fail "attach -r --history 5 to a pipe did not print the last 5 history lines first"
import sys
data = open(sys.argv[1], "rb").read()
want = b"".join(b"line %d\r\n" % i for i in range(32, 37))
sys.exit(0 if data.startswith(want + b"\x1b") else "got %r" % data[:200])
EOF
# The config's alt_screen is the drawn attach's: it leaves -r its history.
printf '[attach]\nalt_screen = true\n' >"$dir/alt.toml"
"${inner[@]}" TUPPET_CONFIG="$dir/alt.toml" "$BIN" attach -r "$done_id" --history 5 >"$dir/alt-pipe" 2>"$dir/alt-err" || true
cmp -s "$dir/pipe" "$dir/alt-pipe" || fail "alt_screen in the config refused --history to attach -r: $(cat "$dir/alt-err")"

# In a terminal: the older lines land in its scrollback, in order, and
# the session's screen follows right below them.
old=$("${inner[@]}" "$BIN" run --size 40x10 sh -c 'for i in $(seq 1 60); do echo "old $i"; done; exec cat')
"${inner[@]}" "$BIN" wait "$old" --match "old 60" --timeout 5s >/dev/null || fail "the inner session did not print its lines"
att=$("${outer[@]}" "$BIN" run --size 40x10 env -u TUPPET_SESSION "${inner[@]:1}" "$BIN" attach "$old" --history 30)
"${outer[@]}" "$BIN" wait "$att" --match "old 60" --timeout 5s >/dev/null || fail "the raw attach did not show the session"
"${outer[@]}" "$BIN" view -s "$att" | python3 -c '
import sys
text = sys.stdin.read().split("\n")
lines = [l for l in text if l.startswith("old ")]
want = ["old %d" % i for i in range(22, 61)]
if lines != want:
    sys.exit("got %r" % lines)
first = text.index("old 22")
sys.exit("blank rows above the older lines: %d" % first if first > 1 else 0)
' || fail "the older lines did not land in the terminal's scrollback in order, right above the screen, after no blank rows"
"${outer[@]}" "$BIN" key "$att" "<C-]>" >/dev/null
"${outer[@]}" "$BIN" wait "$att" -e --timeout 5s >/dev/null || fail "the raw attach did not detach"
echo "history: ok"

#!/usr/bin/env bash
# The picker that a bare `tuppet` opens in a terminal, driven by tuppet itself:
# an outer daemon runs the picker, an inner one holds the sessions it
# shows.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
inner=(env XDG_RUNTIME_DIR="$dir/in" XDG_STATE_HOME="$dir/in/state")
outer=(env XDG_RUNTIME_DIR="$dir/out" XDG_STATE_HOME="$dir/out/state")
mkdir -p "$dir/in" "$dir/out"
cleanup() {
    "${outer[@]}" "$BIN" stop "${picker:-0}" "${att:-0}" "${sized:-0}" "${guard:-0}" "${other:-0}" >/dev/null 2>&1 || true
    for side in in out; do
        for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
            tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/$side" && kill "$pid" 2>/dev/null
        done
    done
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; "${outer[@]}" "$BIN" view "${picker:-0}" >&2 || true; exit 1; }
# screen_has TEXT WHY [SESSION]: the outer session shows TEXT within 3 s.
screen_has() { "${outer[@]}" "$BIN" wait "${3:-$picker}" --match "$1" --timeout 3s >/dev/null || fail "$2"; }
screen_lacks() { if "${outer[@]}" "$BIN" view "$picker" | grep -qF -- "$1"; then fail "$2"; fi; }
key() { "${outer[@]}" "$BIN" key "$picker" "$@"; }
# attached SESSION: an attach took the writer role of the inner session.
attached() {
    for _ in $(seq 60); do "${inner[@]}" "$BIN" list -j "$1" | grep -q '"writer":{' && return; sleep 0.05; done
    fail "the attach to #$1 did not start"
}

first=$("${inner[@]}" "$BIN" run --name first sh -c 'echo FIRST-SCREEN; exec cat')
second=$("${inner[@]}" "$BIN" run --name second sh -c 'echo SECOND-SCREEN; exec cat')

# Outside a terminal there is nothing to pick with: the sessions are listed.
if "${inner[@]}" "$BIN" attach </dev/null >/dev/null 2>"$dir/err"; then fail "attach without an id succeeded"; fi
grep -q "first" "$dir/err" || fail "attach without an id did not list the sessions"

# The config's [attach] section sets the picker's detach key; run reads
# such a file too.
printf '[attach]\ndetach_key = "^A"\nbell = false\n' >"$dir/config.toml"
done_id=$("${inner[@]}" TUPPET_CONFIG="$dir/config.toml" "$BIN" run true) || fail "run failed on a config with [attach]"
"${inner[@]}" "$BIN" remove -f "$done_id" >/dev/null

picker=$("${outer[@]}" "$BIN" run --size 100x30 env -u TUPPET_SESSION "${inner[@]:1}" TUPPET_CONFIG="$dir/config.toml" \
    PAGER="cat >$dir/history" "$BIN")
screen_has "2 sessions, 2 running · 0 need you" "the header did not count the sessions"
screen_has "SECOND-SCREEN" "the preview did not show the newest session"
"${inner[@]}" "$BIN" list -j "$second" | grep -q '"viewers":0' || fail "the preview counted as a viewer"

# The viewer: the session full screen, an overlay naming it, and the
# neighbors a key away. Right after the mode changed, x does nothing.
key '<Enter>' x
screen_has "#$second second" "the viewer's overlay did not name the session"
screen_lacks "y/N" "x asked to stop right after the mode changed"
"${outer[@]}" "$BIN" wait "$picker" --idle 600ms --timeout 3s >/dev/null
key x
screen_has "stop #$second second? y/N" "x did not ask before stopping"
key n
screen_has "left as it is" "n did not keep the session"
key '<Right>'
screen_has "#$first first" "the viewer did not switch to the next session"
screen_has "FIRST-SCREEN" "the viewer did not show the next session's screen"
key '<Esc>'
screen_has "ID  NAME" "Esc did not return to the list"

# Attach controls the session; the detach key from the config comes back
# to the picker, with the cursor on the session just left.
key a
attached "$first"
key "typed-through-picker"
"${inner[@]}" "$BIN" wait "$first" --match typed-through-picker --timeout 3s >/dev/null \
    || fail "keys did not reach the attached session"
key '<C-a>'
screen_has "detached from #$first" "the detach key from the config did not return to the picker"
screen_has " #$first first ·" "the cursor did not stay on the session just left"

# - goes back to the session attached before.
key k
screen_has " #$second second ·" "k did not move up"
key -
screen_has " #$first first ·" "- did not go to the session attached before"

# `tuppet attach -` returns to the session detached from last.
# At the session's own size, so no resize moves its text.
att=$("${outer[@]}" "$BIN" run --size 120x40 "${inner[@]}" "$BIN" attach -)
attached "$first"
screen_has "typed-through-picker" "attach - did not show the session detached from" "$att"
"${outer[@]}" "$BIN" key "$att" '<C-]>'
"${outer[@]}" "$BIN" wait "$att" --ended --timeout 3s >/dev/null || fail "attach - did not detach"

# A direct attach draws the session at this terminal's size from the
# start, and again after this terminal is resized; after the detach, its
# message starts below the session's text.
lines=$("${inner[@]}" "$BIN" run --size 80x24 sh -c 'for i in $(seq 40); do echo L$i; done; exec cat')
"${inner[@]}" "$BIN" wait "$lines" --match L40 --timeout 3s >/dev/null
sized=$("${outer[@]}" "$BIN" run --size 100x30 sh -c "${inner[*]} $BIN attach $lines; echo AFTER-DETACH; exec cat")
attached "$lines"
# same_screen WHY: the attached terminal shows what the session does.
same_screen() {
    for _ in $(seq 60); do
        [ "$("${outer[@]}" "$BIN" view "$sized")" = "$("${inner[@]}" "$BIN" view "$lines")" ] && return
        sleep 0.05
    done
    fail "$1"
}
same_screen "the attach did not draw the session at the terminal's size"
"${outer[@]}" "$BIN" resize "$sized" 90x28
same_screen "the attach did not draw the session again after a resize"
"${outer[@]}" "$BIN" key "$sized" '<C-]>'
screen_has AFTER-DETACH "the attach did not detach" "$sized"
shown=$("${outer[@]}" "$BIN" view "$sized")
last_line=$(grep -n '^L40$' <<<"$shown" | cut -d: -f1)
message=$(grep -n 'tuppet: detached' <<<"$shown" | cut -d: -f1)
[ -n "$last_line" ] && [ -n "$message" ] && [ "$message" -gt "$last_line" ] \
    || fail "the detach message did not start below the session's text"
"${inner[@]}" "$BIN" remove -f "$lines" >/dev/null

# A bell marks a session; Tab goes to it and Space acks it.
bell=$("${inner[@]}" "$BIN" run --name bell sh -c 'printf "\a"; exec cat')
screen_has "3 running · 1 needs you" "the header did not count the marked session"
key '<Tab>'
screen_has " #$bell bell ·" "Tab did not go to the marked session"
key '<Space>'
screen_has "0 need you" "Space did not ack the session"
"${inner[@]}" "$BIN" list bell | grep -q "^  *$bell " || fail "the ack did not reach the daemon"

# / filters by name, command, directory, and title, also with patterns.
key / 'sec*'
screen_has " #$second second ·" "the filter did not select the matching session"
screen_lacks " first " "the filter kept a session that does not match"
# A Down arrow cut in two after ESC [ is still Down (which ends the
# filter's input and keeps it), not Esc (which clears it) and keys.
"${outer[@]}" "$BIN" do "$picker" -s $'\e[' --sleep 100ms -s B >/dev/null
screen_has "/sec* " "a split arrow key did not act as one key"
# ESC with a key right behind it reads as Alt and that key: the next keys
# wait until the Esc has shown.
key '<Esc>'
screen_has " first " "Esc did not clear the filter"

# x asks, y stops; a stopped session needs nobody.
victim=$("${inner[@]}" "$BIN" run --name victim sleep 600)
key / victim '<Enter>'
screen_has " #$victim victim ·" "the filter did not find the session to stop"
key x
screen_has "stop #$victim victim? y/N" "x did not ask before stopping"
key y
"${inner[@]}" "$BIN" wait "$victim" --ended --timeout 5s >/dev/null || fail "y did not stop the session"
"${inner[@]}" "$BIN" list victim | grep -q "^  *$victim .*stopped" || fail "a stopped session was marked as needing attention"
# d asks too, and y removes the ended session.
key d
screen_has "remove #$victim victim? y/N" "d did not ask before removing"
key y
for _ in $(seq 60); do "${inner[@]}" "$BIN" list victim 2>/dev/null | grep -q victim || break; sleep 0.05; done
"${inner[@]}" "$BIN" list victim 2>/dev/null | grep -q victim && fail "y did not remove the session"

# A session that exits while attached lands in the viewer with its end.
quitter=$("${inner[@]}" "$BIN" run --name quitter sh -c 'echo READY; read x; exit 3')
key '<Esc>'
screen_has " first " "Esc did not clear the filter"
key / quitter '<Enter>'
screen_has " #$quitter quitter ·" "the filter did not find the session to attach to"
key a
attached "$quitter"
key 'go<Enter>'
screen_has "exited 3 · Esc back" "an exit while attached did not land in the viewer"

# Esc in the list clears the filter and never quits. Once keys work
# again after the attach, o shows the history in $PAGER, after its count
# of lines.
key '<Esc>' '<Esc>' '<Esc>'
screen_has " second " "Esc did not clear the filter"
"${outer[@]}" "$BIN" wait "$picker" --idle 600ms --timeout 3s >/dev/null
key o
for _ in $(seq 60); do [ -s "$dir/history" ] && break; sleep 0.05; done
head -1 "$dir/history" | grep -q "^history: [0-9]* lines\? kept" || fail "o did not open the history in the pager"
# A pager other than less may print and quit: a key returns.
screen_has "press a key to return to tuppet" "the picker did not wait after the pager"
key x
screen_has "ID  NAME" "a key did not return to the list"

key q
"${outer[@]}" "$BIN" wait "$picker" --ended --timeout 3s >/dev/null || fail "q did not quit the picker"
"${outer[@]}" "$BIN" list "$picker" | grep -q " done " || fail "the picker did not exit 0"

# In a session's terminal the picker labels that session, refuses to show
# it, and warns once that an attach around it takes Ctrl-] first.
guard=$("${outer[@]}" "$BIN" run --size 100x30 env "${inner[@]:1}" TUPPET_SESSION="$second" TUPPET_SESSION_SOCKET="$dir/in/tuppet-$(id -u).sock" "$BIN")
screen_has "this terminal is tuppet session #$second" "a nested picker did not warn" "$guard"
screen_has "(this terminal)" "the picker did not label its own session" "$guard"
"${outer[@]}" "$BIN" key "$guard" / second '<Enter>' '<Enter>'
screen_has "#$second is this terminal" "the picker viewed its own session" "$guard"
"${outer[@]}" "$BIN" key "$guard" q
# A session of another daemon with the same id is not this terminal.
other=$("${outer[@]}" "$BIN" run --size 100x30 env "${inner[@]:1}" TUPPET_SESSION="$second" TUPPET_SESSION_SOCKET=/elsewhere.sock "$BIN")
screen_has "this terminal is tuppet session #$second" "a nested picker did not warn" "$other"
screen_has " second " "the picker did not list the sessions" "$other"
"${outer[@]}" "$BIN" view "$other" | grep -qF "(this terminal)" && fail "the picker labelled another daemon's session as its own"
"${outer[@]}" "$BIN" key "$other" q

echo "PASS: picker list, header, viewer, key guard, attach and back, -, attach -, attach size and detach line, Tab and Space, filter, split keys, stop, exit to viewer, history, self guard"

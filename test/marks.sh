#!/usr/bin/env bash
# Shell marks (OSC 133) and the prompt guard: a bash that prints the marks
# is at its prompt, a line goes onto it without Enter, and the guard refuses
# with text typed, while a command runs, at a continuation prompt, on the
# alternate screen, with bracketed paste off, and for a stale prompt_seq;
# commands keeps the command line, its output, and its exit code.
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

# The marks: A and B around the primary prompt, C when a command starts,
# D with its exit code before the next prompt.
cat >"$dir/rc" <<'RC'
PS1='\[\e]133;A\a\]$ \[\e]133;B\a\]'
PS0='\e]133;C\a'
PROMPT_COMMAND='printf "\e]133;D;%s\a" "$?"'
bind 'set enable-bracketed-paste on'
RC
field() { "$BIN" list "$1" -j | python3 -c "import json,sys; print(json.load(sys.stdin)['sessions'][0]['$2'])"; }
at_prompt() {
    for _ in $(seq 100); do [ "$(field sh shell)" = prompt ] && return 0; sleep 0.05; done
    fail "the shell never waited at its prompt"
}
guard() { "$BIN" do sh --at-prompt "$(field sh prompt_seq)" -p "$1" 2>&1 && echo ok || true; }

"$BIN" run -n sh -s 80x20 -- bash --rcfile "$dir/rc" -i >/dev/null
at_prompt
[ "$(field sh paste_mode)" = True ] || fail "bracketed paste is not on"

# At a prompt: the line is put there, without Enter.
[ "$(guard 'echo put-there')" = ok ] || fail "the guard refused a waiting prompt"
"$BIN" wait sh -m 'echo put-there' -t 2s >/dev/null || fail "the line did not appear"
sleep 0.2
[ "$(field sh shell)" = prompt ] || fail "the pasted line ran"

# Something typed since the prompt appeared: refused.
out=$(guard 'echo again')
case "$out" in *"typed since"*) ;; *) fail "typed text: $out" ;; esac
"$BIN" key sh '<C-u>' '<Enter>' >/dev/null
at_prompt

# A stale prompt_seq: refused.
seq=$(field sh prompt_seq)
"$BIN" key sh '<Enter>' >/dev/null
for _ in $(seq 50); do [ "$(field sh prompt_seq)" != "$seq" ] && break; sleep 0.05; done
out=$("$BIN" do sh --at-prompt "$seq" -p 'echo stale' 2>&1 || true)
case "$out" in *"prompt_seq"*) ;; *) fail "stale prompt: $out" ;; esac

# A command that fails: its line, output, and code are kept.
"$BIN" do sh -s 'ls /no-such-dir; echo done-ls' -k '<Enter>' -m '$ ' -t 3s >/dev/null
at_prompt
"$BIN" commands sh 1 | grep -q 'exit=0 ls /no-such-dir; echo done-ls' || fail "commands: $("$BIN" commands sh)"
"$BIN" commands sh 1 | grep -q '  done-ls' || fail "commands lost the output"
"$BIN" do sh -s '(exit 3)' -k '<Enter>' -m '$ ' -t 3s >/dev/null
at_prompt
[ "$(field sh last_exit)" = 3 ] || fail "last_exit is $(field sh last_exit)"

# While a command runs: refused.
"$BIN" do sh -s 'sleep 2' -k '<Enter>' >/dev/null
for _ in $(seq 50); do [ "$(field sh shell)" = running ] && break; sleep 0.05; done
out=$(guard 'echo during')
case "$out" in *"does not wait"*) ;; *) fail "running command: $out" ;; esac
at_prompt

# At a continuation prompt, which has no marks: the Enter that led there
# was typed after the prompt.
"$BIN" do sh -s 'echo "open' -k '<Enter>' -m '> ' -t 3s >/dev/null
out=$(guard 'quote')
case "$out" in *"typed since"*) ;; *) fail "continuation prompt: $out" ;; esac
"$BIN" key sh '<C-c>' >/dev/null
at_prompt

# On the alternate screen, at a prompt all the same: refused.
"$BIN" do sh -s "printf '\\e[?1049h'" -k '<Enter>' -t 3s --settled 300ms >/dev/null
at_prompt
out=$(guard 'echo alt')
case "$out" in *"normal screen"*) ;; *) fail "alternate screen: $out" ;; esac
"$BIN" do sh -s "printf '\\e[?1049l'" -k '<Enter>' -t 3s --settled 300ms >/dev/null
at_prompt

# Bracketed paste off: refused.
"$BIN" do sh -s "bind 'set enable-bracketed-paste off'" -k '<Enter>' -t 3s --settled 300ms >/dev/null
at_prompt
out=$(guard 'echo plain')
case "$out" in *"bracketed paste off"*) ;; *) fail "paste mode off: $out" ;; esac

# The text must be one line of printable characters.
out=$("$BIN" do sh --at-prompt 1 -p "$(printf 'a\nb')" 2>&1 || true)
case "$out" in *"one line"*) ;; *) fail "two lines: $out" ;; esac

echo "marks: ok"

#!/usr/bin/env bash
# `tuppet start`: a block of the start file logs a new session in through
# fake hosts (an ssh that opens a shell with another prompt, a sudo that
# asks for a password), checks each step, fails fast and says where, and
# keeps the password out of the session's environment.
set -euo pipefail
unset TUPPET_SOCKET

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
dir="$(mktemp -d)"
mkdir -p "$dir/run" "$dir/outer" "$dir/bin" "$dir/home" "$dir/conf/tuppet"
chmod 700 "$dir/run" "$dir/outer"
cleanup() {
    for pid in $(pgrep -f "^$BIN daemon" 2>/dev/null); do
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/\(run\|outer\)" && kill "$pid" 2>/dev/null
    done
    sleep 0.2
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; [ -f "$dir/err" ] && sed 's/^/  | /' "$dir/err" >&2; exit 1; }

cat >"$dir/bin/ssh" <<'EOF'
#!/bin/bash
host="${1%%.*}"
case "$host" in
    bad*) echo "ssh: Could not resolve hostname $1: Name or service not known"; exit 255 ;;
    quiet*) sleep 600 ;;
    keyok*) echo "Reset your password: see the wiki" ;;
    drop*) sleep 0.2; exit 255 ;;
    ask*) if [ ! -e "$HOME/known_$host" ]; then
            printf 'Are you sure you want to continue connecting (yes/no/[fingerprint])? '
            read -r answer
            [ "$answer" = yes ] || exit 255
            touch "$HOME/known_$host"
        fi ;;
esac
export HOST_NAME="$host"
PS1="me@$host:\\w\$ " exec bash --norc --noprofile -i
EOF
cat >"$dir/bin/sudo" <<'EOF'
#!/bin/bash
user="$2"
if [ ! -e "$HOME/cached" ]; then
    [ -e "$HOME/lecture" ] && echo "Remember: root@ sees all you type."
    printf '[sudo] password for me: '
    IFS= read -rs pw
    echo
    [ "$pw" = hunter2 ] || { echo "Sorry, try again."; exit 1; }
fi
PS1="$user@$HOST_NAME:\\w\$ " exec bash --norc --noprofile -i
EOF
cat >"$dir/bin/pwfirst" <<'EOF'
#!/bin/bash
printf 'Password: '
IFS= read -rs pw
echo
[ "$pw" = hunter2 ] && echo welcome
exec sleep 600
EOF
cat >"$dir/bin/yesno" <<'EOF'
#!/bin/bash
printf 'ready\nGo on (yes/no)? '
read -r answer
sleep 0.5
echo ready
exec sleep 600
EOF
cat >"$dir/bin/late" <<'EOF'
#!/bin/sh
echo banner
sleep 0.5
PS1='me@laptop:~$ ' exec bash --norc --noprofile -i
EOF
cat >"$dir/bin/ctrl-c-editor" <<'EOF'
#!/bin/sh
kill -INT 0
EOF
chmod +x "$dir/bin"/*

start="$dir/conf/tuppet/start"
cat >"$start" <<'EOF'
command bash --norc --noprofile -i

steps jump
    send     ssh jump.example.com
    expect   me@jump:~$

steps become user pw=$SUDO_PW
    send     sudo -iu %{user}
    when     [sudo] password for me:
        secret %{pw}
    expect   %{user}@

start db1 db* bad* drop* quiet*
    command  bash --norc --noprofile -i
    use      "jump"
    send     ssh %i.internal
    expect(2s) me@%i:~$
    fail     me@jump:~$
    use      become app $APP_PW
    send     cd /tmp
    expect   app@%i:/tmp$

start keyok1
    command  bash --norc --noprofile -i
    send     ssh %i.internal
    expect   password:
    secret   $APP_PW
    expect   me@%i:~$

start lect1
    command  bash --norc --noprofile -i
    send     sudo -iu root
    expect   [sudo] password for me:
    secret   $APP_PW
    expect   root@

start job0 job3
    command  bash --norc --noprofile -i
    send     exit 3
    ended    3

start ask1
    command  bash --norc --noprofile -i
    size     40x10
    expect   me@laptop:~$
    send     ssh %i.internal
    when     (yes/no/[fingerprint])?
        send yes
    expect   me@%i:~$
    fail     me@laptop:~$

start inst1
    command  bash --norc --noprofile -i
    send     echo Overwr""ite? no; sleep 0.1; exit 0
    when     Overwrite?
        send y
    ended    0

steps hop host
    expect   me@laptop:~$
    send     ssh %{host}.internal
    expect   me@%{host}:~$

group pair db2 db3
group mix db6 bad3

start pw1
    command  pwfirst
    expect(re) ^Password: $
    secret   $APP_PW
    expect   welcome

start pw2
    command  pwfirst
    expect   Password:
    secret   $APP_PW
    expect   welcome

start yn1
    command  yesno
    when     Go on (yes/no)?
        send yes
    expect   ready

start nodir
    dir      ~/does-not-exist
    send     true
    expect   me@laptop

start echo1
    command  bash --norc --noprofile -i
    send     sleep 1; echo ok-done
    expect   ok-done
    send     echo one
    send     echo two
    expect(re) ^t[w]o$
    send     echo last%i

start late1
    command  late
    send     PS1='me@db1:~$ '
    expect   me@db1:~$
    fail     me@laptop:~$
EOF
chmod 600 "$start"
export XDG_RUNTIME_DIR="$dir/run" XDG_STATE_HOME="$dir/state" XDG_CONFIG_HOME="$dir/conf" TUPPET_CONFIG=
export PATH="$dir/bin:$PATH" HOME="$dir/home" PS1='me@laptop:\w$ '
T() { "$BIN" "$@"; }
cd "$HOME"

# --check: a stray line outside a block is a problem; the steps of an id
# as they will run, with where they come from.
if T start --check >"$dir/out" 2>"$dir/err"; then fail "--check passed a file with a stray line"; fi
grep -q "start:1: an indented line\|start:1: expected 'start', 'steps', or 'group'" "$dir/err" || fail "--check did not name the stray line"
sed -i 1d "$start"
T start --check >"$dir/out" 2>"$dir/err" || fail "--check refused a good file"
! grep -q "no block uses the steps 'jump'" "$dir/err" || fail "--check took a quoted use for no use"
T start --check db7 >"$dir/out" 2>"$dir/err" || fail "--check db7 failed"
grep -q "send     ssh db7.internal" "$dir/out" || fail "--check db7 did not show the expanded command"
[ "$(grep -c "when     \[sudo\] password for me:   answered: secret %{pw}" "$dir/out")" = 1 ] || fail "--check db7 did not show the password's when once"

# A refused file: others may write it.
chmod 622 "$start"
if T start -d db1 2>"$dir/err"; then fail "a file others may write was used"; fi
grep -q "group or others may write" "$dir/err" || fail "the refusal did not say why"
chmod 600 "$start"

# Detached: logs in through jump, ssh, and sudo with the password from the
# environment, which the session's environment does not have.
id=$(APP_PW=hunter2 T start -d db1 2>"$dir/err") || fail "start -d db1 failed"
T view "$id" | grep -q 'app@db1:/tmp\$' || fail "the session did not end at app@db1:/tmp"
T do "$id" -s 'echo "[${APP_PW-unset}]"' -k '<Enter>' -m '[unset]' >/dev/null || fail "the password variable reached the session"
for pid in $(pgrep -f "^$BIN daemon"); do
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/run"; then
        tr '\0' '\n' <"/proc/$pid/environ" | grep -q '^APP_PW=' && fail "the daemon that start launched has the password variable"
    fi
done
# Nor does a daemon that `do --secret` starts.
DO_PW=hunter2 XDG_RUNTIME_DIR="$dir/outer" XDG_STATE_HOME="$dir/ostate" T do 1 --secret DO_PW >/dev/null 2>&1 || true
found=
for pid in $(pgrep -f "^$BIN daemon"); do
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$dir/outer"; then
        found=1
        tr '\0' '\n' <"/proc/$pid/environ" | grep -q '^DO_PW=' && fail "the daemon that do --secret launched has the secret variable"
    fi
done
[ -n "$found" ] || fail "do --secret did not start a daemon"

# The name is taken: the next session is db1-2. With a cached sudo the
# password prompt and the password are skipped.
touch "$HOME/cached"
id2=$(APP_PW= T start -d db1 2>"$dir/err" </dev/null) && fail "an unset secret variable outside a terminal was accepted"
grep -q 'APP_PW is not set' "$dir/err" || fail "the unset variable was not named"
id2=$(APP_PW=x T start -d db1 2>"$dir/err") || fail "start -d db1 with a cached sudo failed"
T list "$id2" | grep -q "db1-2" || fail "the second session is not named db1-2"
rm "$HOME/cached"

# Failing fast: a failure text, a hop that drops back to the earlier
# prompt, silence until the timeout, and a wrong password.
expect_fail() {
    local id=$1 code=$2 text=$3 limit=$4
    local t0 t1 got=0
    t0=$(date +%s%N)
    APP_PW=${PW:-hunter2} T start -d "$id" >/dev/null 2>"$dir/err" || got=$?
    t1=$(date +%s%N)
    [ "$got" = "$code" ] || fail "start $id exited $got, not $code"
    grep -q -- "$text" "$dir/err" || fail "start $id did not say '$text'"
    [ $(((t1 - t0) / 1000000)) -lt "$limit" ] || fail "start $id took $(((t1 - t0) / 1000000)) ms"
}
expect_fail bad1 1 "'Could not resolve hostname' appeared" 1500
grep -q "start:15  send ssh %i.internal" "$dir/err" || fail "the failure did not show the step's line"
expect_fail drop1 1 "'me@jump:~\$' appeared" 1500
expect_fail quiet1 3 "the session went quiet" 3500
PW=wrong expect_fail db9 1 "'Sorry, try again' appeared" 1500
grep -q "in become, used at line 18" "$dir/err" || fail "the failure did not show the use chain"

# A password goes only where a program waits for it: not into the shell
# of a key login whose banner says "password:", and not skipped when
# sudo's lecture holds the text expected after it.
expect_fail keyok1 5 "its prompt is not on the cursor's line" 5000
T view keyok1 | grep -q hunter2 && fail "the password was typed into the shell"
touch "$HOME/lecture"
id=$(APP_PW=hunter2 T start -d lect1 2>"$dir/err") || fail "start -d lect1 failed"
T view "$id" | grep -q 'root@:~\$' || fail "the lecture skipped the password"
rm "$HOME/lecture"

# ended: the program ends with the status it should, or the run fails.
T start -d job3 >/dev/null 2>"$dir/err" || fail "start -d job3 failed"
sed -i 's/^    ended    3$/    ended    0/' "$start"
expect_fail job0 1 "ended with exit status 3, not exit status 0" 3000
grep -q "keeps running" "$dir/err" && fail "an ended session was said to keep running"

# when: ssh's question about a new host is answered the first time, and
# the run says so; the next time it is not asked.
T start -d ask1 >/dev/null 2>"$dir/err" || fail "start -d ask1 failed"
grep -q "'(yes/no/\[fingerprint\])?' came (line [0-9]*); answered: send yes" "$dir/err" || fail "the run did not say it answered the question"
T start -d --new ask1 >/dev/null 2>"$dir/err" || fail "start -d ask1 failed when no question came"
grep -q "came (line" "$dir/err" && fail "a question that did not come was answered"
T start -d inst1 >/dev/null 2>"$dir/err" || fail "a question's text in the output of a program that ends failed ended"
sed -i '/^start inst1$/,/^$/s/^    ended    0$/    ended    4/' "$start"
expect_fail inst1 1 "ended with exit status 0, not exit status 4" 3000

# A when before any input: what was on the screen before its answer does
# not meet the check.
id=$(T start -d yn1 2>"$dir/err") || fail "start -d yn1 failed"
[ "$(T view "$id" | grep -c '^ready *$')" = 2 ] || fail "the check after a when's answer was met by what came before the answer"

# Checks are optional, and an input's echo never meets its check: the
# run waits for the output of a command whose text the check is part of,
# an input without a check pauses for its output, and the last one is
# typed too. A regex matches whole lines.
t0=$(date +%s%N)
id=$(T start -d echo1 2>"$dir/err") || fail "start -d echo1 failed"
t1=$(date +%s%N)
[ $(((t1 - t0) / 1000000)) -ge 1000 ] || fail "the echo of 'sleep 1; echo ok-done' met its check"
T wait "$id" --regex -m '^lastecho1 *$' -t 3s >/dev/null || fail "the last input without a check was not typed"
# The first input waits for the shell's line editor, which a banner and
# a pause come before: typed early, it comes back after the prompt.
T start -d late1 >/dev/null 2>"$dir/err" || fail "the first input was typed before the shell took input"
APP_PW=hunter2 T start -d pw1 >/dev/null 2>"$dir/err" || fail "a password prompt whose regex ends in a blank got no password"

# do --use: the steps of a block in a session a script opened, only from
# the prompt it starts at, not into a line someone began to type.
s=$(T run -C "$HOME" bash --norc --noprofile -i)
T do "$s" -m 'me@laptop:~$' -s 'echo Permission denied' -k '<Enter>' -m 'me@laptop:~$' -t 5s >/dev/null || fail "the shell for do --use did not start"
T do "$s" --use hop db4 2>"$dir/err" || fail "do --use hop db4 failed"
T view "$s" | grep -q 'me@db4:~\$' || fail "do --use did not reach me@db4"
s=$(T run -C "$HOME" bash --norc --noprofile -i)
T do "$s" -m 'me@laptop:~$' -s 'echo half' -t 5s >/dev/null || fail "typing a half line failed"
got=0
T do "$s" --use hop db4 2>"$dir/err" || got=$?
[ "$got" = 5 ] || fail "do --use at a half-typed line exited $got, not 5"
grep -q "does not end with the prompt" "$dir/err" || fail "do --use did not say why it typed nothing"
T view "$s" | grep -q 'ssh db4' && fail "do --use typed into a half-typed line"

# Several ids: one after another, none attached; a session that runs
# already is kept, and one whose start failed is replaced. --atomic
# stops what the run opened when one fails.
out=$(APP_PW=hunter2 T start -d pair 2>"$dir/err") || fail "start -d pair failed"
[ "$(echo "$out" | wc -l)" = 2 ] || fail "start -d pair did not print two ids"
T view db3 | grep -q 'app@db3:/tmp\$' || fail "the group did not start db3"
APP_PW=hunter2 T start -d pair db2 >/dev/null 2>"$dir/err" || fail "starting a running group again failed"
grep -q "db2: runs already" "$dir/err" || fail "a running session of the group was not kept"
T list | grep -q "db2-2" && fail "starting the group again made db2-2"
got=0
APP_PW=hunter2 T start -d mix >"$dir/out" 2>"$dir/err" || got=$?
[ "$got" = 1 ] || fail "a group with a failing id exited $got, not 1"
grep -q "1 of 2 ready; did not finish: bad3" "$dir/err" || fail "the group's summary did not name bad3"
first=$(T list bad3 | awk 'NR==2 {print $1}')
APP_PW=hunter2 T start -d bad3 >/dev/null 2>"$dir/err" || true
grep -q "bad3: replacing session $first, whose start did not finish" "$dir/err" || fail "starting bad3 again did not replace the failed session"
w=$(T run -n watcher -- "$BIN" attach -r bad3)
for _ in $(seq 50); do T list -j bad3 | grep -q '"viewers":1' && break; sleep 0.1; done
APP_PW=hunter2 T start -d bad3 >/dev/null 2>"$dir/err" || true
grep -q "replacing" "$dir/err" && fail "a failed session someone watches was replaced"
T stop "$w" >/dev/null
got=0
APP_PW=hunter2 T start -d -A db7 nodir >"$dir/out" 2>"$dir/err" || got=$?
[ "$got" = 1 ] || fail "start -A exited $got, not 1"
[ -s "$dir/out" ] && fail "start -A printed ids after a failure"
grep -q "atomic stopped what this run opened: db7$" "$dir/err" || fail "start -A did not say what it stopped"
T list db7 | grep -q running && fail "start -A left db7 running"

# In a terminal (an outer session): the password is asked for there and
# typed, then the terminal is attached; a failure offers to stop the
# session.
outer=(env XDG_RUNTIME_DIR="$dir/outer" XDG_STATE_HOME="$dir/ostate")
inner=(env XDG_RUNTIME_DIR="$dir/run" XDG_STATE_HOME="$dir/state")
outer_has() {
    "${outer[@]}" "$BIN" wait "$1" -m "$2" -t 10s >/dev/null || { "${outer[@]}" "$BIN" view "$1" >"$dir/err"; fail "$3"; }
}
o=$("${outer[@]}" "$BIN" run -s 100x24 -C "$HOME" env -u APP_PW XDG_RUNTIME_DIR="$dir/run" XDG_STATE_HOME="$dir/state" "$BIN" start db5)
outer_has "$o" "password (not shown):" "the password was not asked for on the terminal"
"${outer[@]}" "$BIN" do "$o" -s hunter2 -k '<Enter>' -m 'app@db5:/tmp$' -t 10s >/dev/null || fail "the session was not attached after the steps"
if "${outer[@]}" "$BIN" view "$o" | grep -q hunter2; then fail "the password showed on the terminal"; fi
"${outer[@]}" "$BIN" key "$o" '<C-]>'
o=$("${outer[@]}" "$BIN" run -s 100x24 -C "$HOME" "${inner[@]}" VISUAL="$dir/bin/ctrl-c-editor" "$BIN" start bad2)
outer_has "$o" "[q] stop the session" "a failure in a terminal did not offer the choices"
# Ctrl-C in the editor is the editor's: the choices come again.
"${outer[@]}" "$BIN" do "$o" -k 'e<Enter>' >/dev/null
menus() { "${outer[@]}" "$BIN" view "$o" | grep -c 'stop the session'; }
for _ in $(seq 50); do [ "$(menus)" -ge 2 ] && break; sleep 0.1; done
[ "$(menus)" -ge 2 ] || fail "the choices did not come again after the editor"
"${outer[@]}" "$BIN" do "$o" -k 'q<Enter>' -e -t 5s >/dev/null || fail "Ctrl-C in the editor ended tuppet start, or q did not"
T list bad2 | grep -q stopped || fail "q did not stop the session"
# A password whose prompt is the first thing is not typed after someone
# else typed since the prompt came.
o=$("${outer[@]}" "$BIN" run -s 100x24 -C "$HOME" env -u APP_PW XDG_RUNTIME_DIR="$dir/run" XDG_STATE_HOME="$dir/state" "$BIN" start pw2)
outer_has "$o" "password (not shown):" "pw2's password was not asked for on the terminal"
T key pw2 x
"${outer[@]}" "$BIN" do "$o" -s hunter2 -k '<Enter>' -m 'something else was typed' -t 10s >/dev/null || fail "a password went in after someone else typed"
"${outer[@]}" "$BIN" do "$o" -k 'q<Enter>' -e -t 5s >/dev/null || fail "q did not end tuppet start pw2"

# Recording: a login by hand becomes a block that uses the jump steps,
# has secret where the password was typed, and is appended on 'a'.
o=$("${outer[@]}" "$BIN" run -s 100x24 -C "$HOME" "${inner[@]}" "$BIN" start --record rec1 -- bash --norc --noprofile -i)
outer_has "$o" 'me@laptop:~$' "the recording did not attach the session"
for step in 'ssh jump.example.com|me@jump:~$' 'ssh db3.internal|me@db3:~$' 'sudo -iu app|password for me:' 'hunter2|app@db3:~$' 'cd /tmp|app@db3:/tmp$'; do
    "${outer[@]}" "$BIN" do "$o" -s "${step%%|*}" -k '<Enter>' -m "${step#*|}" -t 10s >/dev/null || fail "typing '${step%%|*}' while recording got no '${step#*|}'"
done
"${outer[@]}" "$BIN" key "$o" '<C-]>'
outer_has "$o" "[a]ppend it to" "the recorded block was not offered for appending"
"${outer[@]}" "$BIN" view "$o" >"$dir/err"
grep -q "use      jump" "$dir/err" || fail "the recorded block does not use the jump steps"
"${outer[@]}" "$BIN" do "$o" -k 'a<Enter>' -m 'appended' -t 5s >/dev/null || fail "'a' did not append the block"
"${outer[@]}" "$BIN" key "$o" '<C-]>'
"${outer[@]}" "$BIN" wait "$o" -e -t 5s >/dev/null || fail "start --record did not end after the second detach"
grep -q hunter2 "$start" && fail "the password was written to the start file"
sed -n '/^start rec1/,$p' "$start" >"$dir/err"
for want in 'command  bash --norc --noprofile -i' 'expect   me@laptop:~$' 'use      jump' 'send     ssh db3.internal' 'fail     me@jump:~$' 'when     [sudo] password for me:' '        secret' 'send     cd /tmp' 'expect   app@db3:/tmp$'; do
    grep -qF -- "$want" "$dir/err" || fail "the recorded block lacks '$want'"
done
T start --check rec1 >/dev/null 2>"$dir/err" || fail "the recorded block does not pass --check"

echo "PASS: start --check reports stray lines and shows expanded steps; a file others may write is refused; start -d logs in through use, ssh, and sudo with a password kept out of the session's environment; a taken name gives db1-2; a when answers sudo's password prompt only when it comes; a failure text, a fail line for the prompt a hop came from, silence, and a wrong password fail fast with the step's line and use chain; a password goes only to a program that waits for it, not into a shell whose banner says "password:", and a sudo lecture does not skip it; ended checks the exit status; checks are optional, an input's echo never meets its check, and a regex matches; when answers ssh's question about a new host only when it comes, also when it wraps; do --use runs a block's steps in a running session from its prompt, and not into a half-typed line; a group starts its ids one after another, keeps those that run, replaces one whose start failed unless someone watches it, and --atomic stops what it opened when one fails, also when a session cannot open; in a terminal the password is asked for and the session attached, and a failure offers to stop it; --record turns a login by hand into a block with use, fail lines, and a when for sudo's password, without the password"

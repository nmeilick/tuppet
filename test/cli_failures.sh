#!/bin/sh
set -eu
# Never talk to a daemon named by the caller's environment.
unset TUPPET_SOCKET

bin=${BIN:-./zig-out/bin/tuppet}
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM
# A runtime directory that does not exist: a usage check that wrongly
# reached the daemon fails instead of touching a real one.
export XDG_RUNTIME_DIR="$tmp/no-daemon"
export XDG_STATE_HOME="$tmp/state"

check_usage_error() {
    set +e
    "$bin" "$@" </dev/null >"$tmp/stdout" 2>"$tmp/stderr"
    status=$?
    set -e

    test "$status" -eq 2
    test ! -s "$tmp/stdout"
    test -s "$tmp/stderr"
    if grep -Eq 'stack trace|src/main\.zig|error:' "$tmp/stderr"; then
        return 1
    fi
}

check_usage_error bogus
check_usage_error help extra
check_usage_error --version extra
check_usage_error daemon extra
check_usage_error
check_usage_error wait 1 --ended --timeout 9223372036854775808s
check_usage_error wait 1 --ended --timeout 500
check_usage_error view 1 --format json
check_usage_error run --if-exists keep true
check_usage_error do 1 --mouse 10 0 0
check_usage_error do 1 --mouse left:press:x 0 0
check_usage_error do 1 --mouse left 1_0 0
check_usage_error do 1 typed
check_usage_error do 1 -s x -w 1s
check_usage_error do 1 -s x -m y --icase -w 1s -w 2s
check_usage_error key 1 'x<Ener>'
check_usage_error key 1
check_usage_error view 'no such'
check_usage_error run -n 42 true
check_usage_error stop 1 --all
check_usage_error wait 1 --match ''
check_usage_error run --since 5 -m x -- true
check_usage_error run ''
check_usage_error record 1 --start a.cast --stop
grep -q -- "--start and --stop conflict" "$tmp/stderr"
check_usage_error sweep 1 -s 80x24 --find 'title=ok '
check_usage_error view "$(printf '\377')"
grep -q "is not valid UTF-8" "$tmp/stderr"

"$bin" help >"$tmp/help"
grep -q '1\.\.9' "$tmp/help"
if grep -q '1\.\.11' "$tmp/help"; then
    exit 1
fi
grep -q 'tuppet resize <session> WxH' "$tmp/help"

# Per-command help: `tuppet <cmd> --help` and `tuppet help <cmd>` print the same
# text on stdout and exit 0, without touching the daemon.
for cmd in run list stop remove restart rename key do resize view png record wait daemon llm-skill attach help; do
    "$bin" "$cmd" --help >"$tmp/stdout" 2>"$tmp/stderr"
    test ! -s "$tmp/stderr"
    head -1 "$tmp/stdout" | grep -q "^tuppet $cmd "
    grep -q 'usage: tuppet ' "$tmp/stdout"
    "$bin" help "$cmd" >"$tmp/help_cmd"
    cmp -s "$tmp/stdout" "$tmp/help_cmd"
done

# Help also comes where the command takes an option.
"$bin" alert add --help >"$tmp/stdout"
"$bin" help alert >"$tmp/help_cmd"
cmp -s "$tmp/stdout" "$tmp/help_cmd"
"$bin" view 1 -j --help | grep -q '^tuppet view '

check_usage_error help bogus
check_usage_error help key extra
check_usage_error key -x 1 a
check_usage_error view -s
# A writer attach needs a terminal; stdin and stdout are none here.
check_usage_error attach 1
grep -q "'tuppet view'" "$tmp/stderr"

# A usage error points to the help of the command at hand.
check_usage_error view 1 --format json
grep -q "see 'tuppet help view'" "$tmp/stderr"
check_usage_error alert add 1 '=x'
grep -q "the alert name is empty" "$tmp/stderr"

# Options may come before the session: these parse, and fail only for
# want of a daemon (exit 1, not 2).
for args in "view -j 1" "wait -m x 1" "do -t 1s 1 -s x" "record --stop 1" "attach -r 1" "key -- 1 -v"; do
    set +e
    # shellcheck disable=SC2086
    "$bin" $args </dev/null >/dev/null 2>"$tmp/stderr"
    status=$?
    set -e
    test "$status" -eq 1
done

set +e
XDG_RUNTIME_DIR="$tmp/missing/runtime" "$bin" list >"$tmp/stdout" 2>"$tmp/stderr"
status=$?
set -e

test "$status" -eq 1
test ! -s "$tmp/stdout"
test -s "$tmp/stderr"

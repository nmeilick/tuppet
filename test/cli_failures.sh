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
    "$bin" "$@" >"$tmp/stdout" 2>"$tmp/stderr"
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
check_usage_error wait 1 --exit --timeout 9223372036854775808
check_usage_error watch 1 --interval 9223372036854775808
check_usage_error mouse 1 10 0 0
check_usage_error mouse 1 left 0 0 --mods x
check_usage_error mouse 1 left 1_0 0
check_usage_error view abc
check_usage_error wait 1 --match ''

"$bin" help >"$tmp/help"
grep -q '1\.\.9' "$tmp/help"
if grep -q '1\.\.11' "$tmp/help"; then
    exit 1
fi
grep -q 'tuppet resize <id> WxH' "$tmp/help"

# Per-command help: `tuppet <cmd> --help` and `tuppet help <cmd>` print the same
# text on stdout and exit 0, without touching the daemon.
for cmd in run list stop remove send key mouse focus resize view png record trace wait watch daemon llm-skill attach help; do
    "$bin" "$cmd" --help >"$tmp/stdout" 2>"$tmp/stderr"
    test ! -s "$tmp/stderr"
    head -1 "$tmp/stdout" | grep -q "^tuppet $cmd "
    grep -q 'usage: tuppet ' "$tmp/stdout"
    "$bin" help "$cmd" >"$tmp/help_cmd"
    cmp -s "$tmp/stdout" "$tmp/help_cmd"
done

check_usage_error help bogus
check_usage_error help key extra

set +e
XDG_RUNTIME_DIR="$tmp/missing/runtime" "$bin" list >"$tmp/stdout" 2>"$tmp/stderr"
status=$?
set -e

test "$status" -eq 1
test ! -s "$tmp/stdout"
test -s "$tmp/stderr"

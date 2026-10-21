#!/usr/bin/env bash
# Input batches: do types and waits for what follows, guards refuse before
# the first byte, one batch runs at a time, secrets stay out of
# recordings, a held writer keeps its order, and a writer's size goes
# with it. Also rename and restart.
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
# exits N MESSAGE COMMAND...: COMMAND exits N, its output in $dir/out and $dir/err.
exits() {
    local want=$1 msg=$2
    shift 2
    set +e
    "$@" >"$dir/out" 2>"$dir/err"
    local got=$?
    set -e
    [ "$got" -eq "$want" ] || fail "$msg (exit $got: $(cat "$dir/err"))"
}
att() { python3 "$(dirname "$0")/attach_check.py" "$TUPPET_SOCKET" "$@"; }

"$BIN" daemon --socket "$TUPPET_SOCKET" 2>"$dir/log" &
daemon_pid=$!
for _ in $(seq 100); do "$BIN" list >/dev/null 2>&1 && break; sleep 0.02; done

# --- do: type a command and wait for the next prompt -----------------------
sh_id=$("$BIN" run bash --norc --noprofile -i)
"$BIN" wait "$sh_id" -m '$ ' -t 3s >/dev/null
line=$("$BIN" do "$sh_id" -s 'echo DONE-$((40+2))' -k '<Enter>' -m '$ ' -w 3s)
[[ $line =~ ^met\ match#0\ $sh_id\ seq=[0-9]+\ input_seq=[0-9]+\ hit_seq=-$ ]] || fail "unexpected do line: $line"
"$BIN" view "$sh_id" | grep -q '^DONE-42$' || fail "the typed command did not run before the prompt came back"

# --- guards refuse the whole batch before its first byte -------------------
exits 5 "a stale --if-input-seq did not exit 5" "$BIN" do "$sh_id" --if-input-seq 1 -s 'echo NOPE' -k '<Enter>'
grep -q "^guard input_seq $sh_id .* step=1 done=0$" "$dir/out" || fail "the guard line: $(cat "$dir/out")"
export PW=hunter2
exits 5 "a secret at a shell prompt was not refused" "$BIN" do "$sh_id" --secret PW
grep -q "^guard hidden_input " "$dir/out" || fail "the hidden-input guard line: $(cat "$dir/out")"
# Input before the secret is typed; the message does not deny it.
exits 5 "a secret after typed text was not refused" "$BIN" do "$sh_id" -s 'echo TYPED' --secret PW
grep -q "^guard hidden_input .* step=2 done=1$" "$dir/out" || fail "the hidden-input guard line after text: $(cat "$dir/out")"
grep -q "nothing was typed" "$dir/err" && fail "the guard denies the typed text: $(cat "$dir/err")"
"$BIN" do "$sh_id" -k '<C-u>' >/dev/null
"$BIN" view "$sh_id" | grep -q 'NOPE\|hunter2' && fail "a refused batch typed something"

# --- do -j: each condition step's reply, and a failure with step and done --
# json_has EXPRESSION: it holds for r, the JSON object in $dir/out.
json_has() { python3 -c "import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$dir/out"; }
exits 0 "do -j failed" "$BIN" do -j "$sh_id" -s 'echo JSON' -k '<Enter>' -m '$ ' -w 3s
json_has 'r["outcome"] == "met" and "ok" not in r and r["status"]["id"] == '"$sh_id" || fail "do -j: $(cat "$dir/out")"
exits 5 "do -j with a stale guard did not exit 5" "$BIN" do "$sh_id" --if-input-seq 1 -s x -j
json_has 'r["code"] == "guard" and r["guard"] == "input_seq" and r["step"] == 1 and r["done"] == 0' \
    || fail "do -j's failure: $(cat "$dir/out")"
exits 1 "--secret with an unset variable did not exit 1" "$BIN" do "$sh_id" --secret TUPPET_UNSET_VAR
grep -q "environment variable TUPPET_UNSET_VAR is not set" "$dir/err" || fail "--secret UNSET: $(cat "$dir/err")"

# --- one batch at a time --------------------------------------------------
"$BIN" do "$sh_id" -s 'echo slow' --sleep 1s --sleep 1s >/dev/null &
batch_pid=$!
"$BIN" wait "$sh_id" -m '$ echo slow' -t 3s >/dev/null
exits 1 "a second batch was not refused" "$BIN" key "$sh_id" x
grep -q 'another input batch' "$dir/err" || fail "a busy batch did not say so: $(cat "$dir/err")"
wait "$batch_pid" || fail "the first batch failed"
"$BIN" view "$sh_id" | grep -q 'slowx' && fail "the refused key was typed"
"$BIN" key "$sh_id" '<C-u>'

# --- a key only the kitty protocol expresses fails and names the key -------
exits 1 "<C-S-c> was typed without the kitty protocol" "$BIN" key "$sh_id" x '<C-S-c>'
grep -q "the key '<C-S-c>' needs the kitty keyboard protocol" "$dir/err" || fail "the key failure: $(cat "$dir/err")"

# --- a non-UTF-8 environment variable is left out, with a warning ---------
env $'TUPPET_BAD=\xff' "$BIN" run true >/dev/null 2>"$dir/err" || fail "run failed with a non-UTF-8 variable: $(cat "$dir/err")"
grep -q "leaving out the environment variable TUPPET_BAD" "$dir/err" || fail "no warning for the variable: $(cat "$dir/err")"

# --- secrets never reach a recording --------------------------------------
pw_id=$("$BIN" run bash --norc --noprofile -c 'read -rs -p "pw: " pw; echo; echo "got ${#pw}"; exec sleep 30')
"$BIN" do "$pw_id" --hidden-input --secret PW -k '<Enter>' -m 'got 7' --record-file "$dir/pw.trace" >/dev/null \
    || fail "the secret was not typed at the password prompt"
grep -q '"kind":"secret"' "$dir/pw.trace" || fail "the recording lacks the secret's marker"
grep -q hunter2 "$dir/pw.trace" && fail "the secret reached the recording"

# --- a writer typing during a batch is held and keeps its order -----------
cat_id=$("$BIN" run sh -c 'stty raw -echo; exec cat')
att hold "$cat_id" "$BIN"

# --- the size from before a writer comes back when it detaches ------------
sized=$("$BIN" run --size 50x10 sleep 30)
att restore "$sized" "$BIN"

# --- rename ---------------------------------------------------------------
"$BIN" run -n alpha sleep 30 >/dev/null
"$BIN" run -n beta sleep 30 >/dev/null
"$BIN" rename alpha gamma
"$BIN" list gamma | grep -q ' gamma ' || fail "rename did not rename"
exits 1 "renaming to a running session's name succeeded" "$BIN" rename gamma beta
grep -q "has that name" "$dir/err" || fail "rename to a taken name did not say so"
"$BIN" rename -j gamma delta | grep -q '"name":"delta"' || fail "rename -j did not print the status"

# --- restart: an ended session's command, with this environment -----------
old=$(X=one "$BIN" run -n job sh -c 'echo "RUN-$X"')
"$BIN" wait job -e -t 3s >/dev/null
exits 1 "restarting a running session succeeded" "$BIN" restart "$sized"
new=$(X=two "$BIN" restart job)
[ "$new" != "$old" ] || fail "restart reused the id"
"$BIN" wait "$new" -m RUN-two -t 3s >/dev/null || fail "restart did not run the command with this environment"
"$BIN" list job | grep -q "^!\? *$new  job " || fail "the restarted session did not take the name"
[ "$("$BIN" list "$old" | wc -l)" -eq 1 ] || fail "the ended namesake was not replaced"

echo "PASS: do, guards, busy, secrets, attach hold, size restore, rename, restart"

---
name: tuppet
description: Drive interactive terminal programs (vim, htop, REPLs, installers, curses or Bubble Tea TUIs) headlessly with the `tuppet` CLI. Use when a program needs a real TTY, draws a full-screen UI, or needs keys like arrows, Esc, or Ctrl-C. Not needed for commands that work with plain pipes.
---

# tuppet (TUI puppet)

`tuppet` runs programs in emulated terminals owned by a background daemon
(started automatically). You start a session, send input, wait for the
screen to change, and read the screen back as text.

## Core loop

```sh
id=$(tuppet run vim notes.txt)                 # prints the session id
tuppet wait $id --match 'notes.txt'            # wait for the UI; never guess with sleep
tuppet key $id i 'hello world' '<Esc>'
tuppet wait $id --match 'hello world'
tuppet view $id                                # the screen as text
tuppet key $id ':wq' '<Enter>'
tuppet wait $id --exit --timeout 5000
tuppet remove $id                              # delete the ended session
```

- `tuppet run [--name n] [--size WxH] [--cwd dir] <cmd...>`: runs in your
  current directory with your environment; TERM is xterm-256color. The
  terminal is 120x40 unless `--size` (or TUPPET_SIZE) says otherwise.
- `tuppet view <id>`: the visible screen. `--format json` adds the cursor
  (1-based, while mouse cells are zero-based), `exited`, `exit_code`,
  and `idle_ms`; `--scrollback` adds history.
- `tuppet wait <id> [--match s] [--exit] [--idle ms] [--timeout ms]`: the
  first condition that holds ends the wait. Exits 1 on timeout (default
  30 s) and prints the screen to stderr. `--match` fails at once if the
  program exits first; trailing spaces in `s` are ignored.
- `tuppet stop <id>` ends a running session; `tuppet remove <id>` deletes an
  ended one. Sessions outlive your command: always clean up.
- `tuppet list` shows every session (id, pid, name, state, size, and the
  exit code once the program has ended).
- An ended session keeps its final screen and exit status, so
  `tuppet view` works after the program exits, even after the daemon has
  restarted. History is limited (about 700 lines); to keep all output of
  a program, start it with `tuppet run --record <cmd...>`, and
  `tuppet view <id> --format json` gives the recording's path.
- Exit codes: 0 ok, 1 runtime failure (message on stderr), 2 bad
  arguments, 3 failed trace expect. `tuppet help <command>` has details.

## Input

- `tuppet key <id> <tokens...>`: `<Enter>` `<Esc>` `<Tab>` `<BS>` `<Up>`
  `<PgDown>` `<F5>`, modifiers inside brackets: `<C-c>` `<M-x>`
  `<S-Tab>` `<C-S-p>`. Any other token is typed as text, so `Enter`
  types five letters. Quote tokens for the shell: `'<Enter>'`.
- `tuppet send <id> <text>` writes raw bytes, no newline added.
- `tuppet send <id> --paste "$(cat msg.txt)"` pastes multi-line text as one
  message (bracketed paste when the app supports it) instead of
  submitting each line.
- `tuppet mouse <id> left <x> <y>` (zero-based cells; add
  `--action release` for the release), `tuppet resize <id> WxH`,
  `tuppet focus <id> on|off`.

## Evidence

- `tuppet png <id> shot.png` renders the screen.
- `tuppet trace <id> save.trace --key i --send hello --key '<Esc>' --send ':w' --key '<Enter>' --expect written`
  records a whole flow (here, in vim) and prints a JSON summary; exit 3
  means an `--expect` failed (the screen is on stderr).
- `tuppet record <id> file.cast` starts an asciicast recording;
  `tuppet record <id>` stops it.

## Watching live and other daemons

- The user can watch: `tuppet attach` without an id, in their terminal,
  lists your sessions with live previews and lets them view or take
  over any of them (Ctrl-] hands it back). Agents use `view` and `wait`.
- `tuppet --socket PATH <command>` (or `TUPPET_SOCKET=PATH`) uses a daemon
  that another program started with `tuppet daemon --socket PATH`; it never
  starts one, and fails if nothing listens there.
- Programs can speak the daemon's JSON-lines protocol directly; send
  `{"cmd":"hello"}` first to check the protocol and features.

## Pitfalls

- Wait for output before sending keys to a program that is still
  starting (`tuppet wait --match`, or `tuppet key --delay ms`).
- `wait --match` and `png` see only the visible screen, like `view`.
  Matching is per screen row, so pick a needle that fits on one row.
- A program that stopped reading input makes `send`/`key` fail after
  5 s; check the screen.

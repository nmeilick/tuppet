---
name: tuppet
description: Drive interactive terminal programs (vim, htop, REPLs, installers, curses or Bubble Tea TUIs) headlessly with the `tuppet` CLI. Use when a program needs a real TTY, draws a full-screen UI, or needs keys like arrows, Esc, or Ctrl-C. Not needed for commands that work with plain pipes.
---

# tuppet (TUI puppet)

`tuppet` runs programs in emulated terminals owned by a background daemon
(started automatically). You start a session, type into it, wait for
the screen to change, and read the screen back as text.

## Core loop

```sh
id=$(tuppet run vim notes.txt)                 # prints the session id
tuppet wait $id --match 'notes.txt'            # wait for the UI; never guess with sleep
tuppet do $id -k 'ihello world<Esc>' -m 'hello world'   # type, then wait
tuppet view $id                                # the screen as text
tuppet do $id -k ':wq<Enter>' -e -w 5s         # type, then wait for the end
tuppet remove $id                              # delete the ended session
```

- `tuppet run [-n name] [-s WxH] [-C dir] <cmd...>`: runs in your
  current directory with your environment; TERM is xterm-256color. The
  terminal is 120x40 unless `-s` (or TUPPET_SIZE) says otherwise.
- Every command that takes a session accepts its id or its name
  (`tuppet run -n web npm start`, then `tuppet wait web -m Listening`).
  Names are unique: `run -n` fails while a running session has the
  name and replaces an ended one, so rerunning a named job needs no
  cleanup. Patterns with `*` and `?` work too (quote them).
- Durations always take a unit: `500ms`, `5s`, `2m` (or plain `0`).
- `tuppet view <id>`: the visible screen. `-j` prints JSON with the
  text, the cursor (1-based, while mouse cells are zero-based), and the
  session's `status` (`state`, `exit`, `idle_ms`, `seq`, ...);
  `--scrollback` adds history. `--since SEQ` prints only the lines that
  changed after a seq taken from an earlier `view -j`. `--styles` adds
  colors and emphasis after the text: `base: …` (the style of most
  cells), then `ROW:C1-C2 key=value… "text"` per run of cells styled
  otherwise, such as the selected item of a menu.
- `tuppet wait <id> [-m TEXT] [-e] [-i DUR] [-t DUR]`: the first
  condition that holds ends the wait (`-m` text on screen, `-e` the
  program ended, `-i` the screen's text unchanged that long). It prints
  one line: `met match#0 3 seq=N input_seq=N hit_seq=-` (`#0`: the
  first condition given). Exits 3 on timeout (default 30s) with the
  last changed lines on stderr, and 4 at once if the program ends
  before a condition is met; `-e` is met (exit 0) however the program
  ended, and the line ends with `exit=CODE`. `--view` also prints the
  screen.
- Type a command and wait for what is new since that input in one call:
  `tuppet do $id -s make -k '<Enter>' -m '$ ' -t 10m` ignores the prompt
  `make` was typed on and is met by the next prompt; it prints the same
  line as `wait`. Text inside the typed command itself still counts as
  new, so pick a needle the command does not contain. `tuppet help
  conditions` has the details and limits.
- After a key or a resize, wait with `--settled DUR`, not `-i`: `tuppet
  do $id -k j --settled 200ms` is met once the screen changed after the
  key and then stayed quiet for 200ms, while `-i` can be met before the
  program reacted. A program that redraws nothing new never meets it
  (exit 3). `--gone TEXT` waits until text leaves the screen: `tuppet do
  $id -k '<Enter>' --gone 'Loading' -w 30s`; it is never met by text
  that never appeared.
- `--hidden-input` waits for a password prompt (input read without
  echo), and `--secret VAR` types `$VAR` only while one is open, kept
  out of recordings: `tuppet do $id -k 'sudo make install<Enter>'
  --hidden-input --secret PW -k '<Enter>' -m '$ ' -t 10m`. A refused
  secret types nothing and exits 5. The status shows `hidden_input`,
  the foreground program (`foreground.name`), the window `title`, and
  the `cwd` shells report; `tuppet list` shows `password?`. Not on
  Windows.
- Alerts watch for a dialog: `tuppet run -n agent --alert 'approve=Do
  you want to proceed?' -- ./agent` (or `tuppet alert add $id
  NAME=TEXT`) makes a line that comes to show the text a hit.
  `tuppet wait $id --hit approve -t 10m` waits for a hit after the latest input, so an answered dialog
  still on screen does not count, and prints `hit N approve <line>`
  after the outcome line. Answer with `tuppet do $id --reply-to N -k
  'y<Enter>' --hit approve -w 10m`: it types nothing (exit 5) if anyone
  typed since hit N. A line fires once (a spinner or the typed answer
  on it does not fire again), so put the alert on a line that changes
  when the dialog is reused, such as the one naming the file or command.
  `--hit NAME` needs an alert of that name on the session (or `'*'`);
  an unknown name fails at once with `no_alert` instead of waiting.
  `[alerts]` in the config file (`$XDG_CONFIG_HOME/tuppet/config.toml`,
  by default `~/.config/tuppet/config.toml`) gives every `run` default
  alerts (`--no-default-alerts` leaves them out).
- `tuppet run -m 'Listening on' -t 1m -- npm start` starts and waits in
  one step: it prints the id, then the outcome line; the session keeps
  running if the wait fails. `tuppet wait a b -m DONE --any` waits on
  several sessions.
- `tuppet stop <session>...` ends running sessions; `tuppet remove
  <session>...` deletes ended ones; `tuppet restart <session>` runs an
  ended one's command again (with your current environment), and
  `tuppet rename <session> <name>` renames. Sessions outlive your command:
  always clean up, e.g. `tuppet remove -f 'job-*'` (stops, then deletes;
  a pattern skips sessions the command does not apply to).
- `tuppet run -n NAME --if-exists keep <cmd...>` reuses a running
  session of that name instead of failing; `--if-exists replace` starts
  it anew.
- `tuppet list` shows every session as a table (ID, NAME, STATE such as
  running, password?, quiet 3m, bell, done, stopped, failed 2, lost; AGE;
  CMD); `tuppet list -j` gives each session's full status as JSON. `!`
  marks a session that rang the bell, sent a notification, had an alert
  hit (STATE names the alert), or ended since it was last seen; `tuppet
  ack <session>` clears it.
- `tuppet events [<session>...] --count 1 -t 10m` blocks until something
  happens to those sessions (started, ended, bell, notification,
  password?, alert hit, renamed) and prints a line for it, or exits 3
  when nothing did (4 when the daemon shut down first); `-j` prints JSON
  frames with the status, `-i 30s` adds idle/active. Not on Windows.
- An ended session keeps its final screen and exit status, so
  `tuppet view` works after the program exits, even after the daemon has
  restarted. History is limited (about 7500 lines of 120 columns, and
  fewer while the daemon trims history to stay within its memory
  budget, which the status shows as `history_trimmed`); to keep all
  output of a program, start it with `tuppet run --record <cmd...>`;
  the recording is kept with the session and deleted with it, and
  `tuppet view <id> -j` shows its path (`status.recording.path`), also after the program ended.
- Exit codes: 0 ok, 1 runtime failure (message on stderr), 2 bad
  arguments, 3 timeout (wait, a condition step of do), 4 the session
  ended first (input to an ended session, a wait it never met), 5 a
  guard of do refused the input, or sweep refused to start. `tuppet
  help <command>` has details.

## Input

- `tuppet key <id> <keys...>`: `<Enter>` `<Esc>` `<Tab>` `<BS>` `<Up>`
  `<PgDown>` `<F5>`, modifiers inside brackets: `<C-c>` `<M-x>`
  `<S-Tab>` (`<C-S-p>` only where the program enabled the kitty
  keyboard protocol; a key the program's keyboard mode cannot express
  fails and types nothing); one argument may hold several
  (`':wq<Enter>'`).
  Everything else is typed as text, so `Enter` types five letters.
  Quote keys for the shell: `'<Enter>'`. key has no options.
- `tuppet do <id> STEP...` runs steps in order: `-k KEYS`, `-s TEXT`
  (raw, no newline added), `-p TEXT` or `--stdin` (pasted as one
  message, bracketed when the app supports it), `--mouse left X Y`
  (a click at zero-based cells; `left:release` for one event),
  `--focus on|off`, `--sleep DUR`, and conditions `-m`, `--gone`, `-e`,
  `--settled`, `-i`, `--hidden-input` with `-w DUR` per condition step.
  Input steps in a row are typed as one batch nothing interrupts.
  `--stats` adds to each outcome line what the program did meanwhile
  (`out_bytes= draws= full_clears= rows_changed=k/N first_change_ms=`,
  approximate).
- `--unless-attached` types nothing while the user is attached as
  writer; `--if-input-seq N` (N from an outcome line) types nothing if
  anyone typed since. `tuppet resize <id> WxH` resizes and prints the
  seq of its reflow (`-j`: the reply); to see the program's redraw,
  `tuppet wait <id> --since SEQ --settled 200ms -t 2s`, then view.
  `tuppet do <id> --resize 60x24 --settled 200ms -w 2s` does both in one
  step (it prints `same size` and waits for nothing when the size stays).

## Layout across sizes

- To check how a TUI copes with terminal sizes (after a layout change,
  or when a bug report names a size), sweep instead of resizing by hand:
  `tuppet sweep $id -s 40..160x30 --step 4 --find title='My App' --find
  status='Ready'`, or `tuppet sweep -s 60..120x24 -- ./app` for a
  session of its own that is removed afterwards. It attaches as the
  writer and gives the session its size back; it refuses (exit 5) while
  the user is attached or watching, so do not force it on their session.
- Read the table row by row: a row is a range of sizes with the same
  facts. SCREEN `changed K/N rows` is a redraw; `unchanged, wrote B
  bytes`, `wrote nothing`, and `still changing` are worth a look. A find
  at `ROW:COL` sits there, `absent` is gone, `prefix "X"` was cut to X,
  `split` wrapped onto the next row, and `stale` means the row did not
  change after the resize: the program left it alone (it may ignore
  SIGWINCH) or drew it again the same; check which on `--view`. The
  sizes where a find's state changes are the breakpoints; `--refine`
  makes them exact.
- No change is not correct: the sweep compares only the finds and the
  screen back at the starting size, and its last line says what it did
  not check. Look at the screens with `--view` or `--save DIR` before
  you call a layout good, and pass `-j` to script over the results.

## Evidence

- `tuppet png <id> shot.png` renders the screen; `-f` picks fonts (`tuppet help fonts`).
- `tuppet do <id> -k 'ihello<Esc>:w<Enter>' -m written --record-file save.trace`
  records a whole flow (here, in vim) as a trace (`.cast`: asciicast);
  exit 3 means a condition step timed out (the last changed lines are
  on stderr).
- `tuppet record <id> --start file.cast` starts an asciicast recording
  (`.trace`: a trace); `--stop` stops it and prints how it stopped.
  Conditions and `-t DUR` stop it daemon-side:
  `tuppet record <id> --start run.trace -m 'Tests passed' -e -t 10m`.

## Watching live and other daemons

- The user can watch: `tuppet` alone, in their terminal, opens a picker
  that lists your sessions with live previews, marks the ones that need
  them (a bell, an alert hit, an end), and lets them view or take over
  any of them (Ctrl-] hands it back). Outside a terminal a bare
  `tuppet` prints usage and exits 2; agents use `view` and `wait`.
- A session you end with `tuppet stop` is not marked for the user;
  one that ends by itself is, until someone looks at it.
- `tuppet --socket PATH <command>` (or `TUPPET_SOCKET=PATH`) uses a daemon
  that another program started with `tuppet daemon --socket PATH`; it never
  starts one, and fails if nothing listens there.
- `tuppet shutdown` stops every running session and the daemon (ended
  sessions are kept); `--reset` also deletes the stored sessions so ids
  start at 1 again. Both act on all of the daemon's sessions, not only
  yours, without asking: clean up your own with `stop` and `remove`.
- Programs can speak the daemon's JSON-lines protocol directly; send
  `{"cmd":"hello"}` first and check that `protocol` is 2.

## Pitfalls

- Wait for a program that is still starting before typing into it:
  `tuppet wait <id> -m PROMPT`, or start it with `tuppet run -m PROMPT`;
  a guessed `--sleep` is too short on a slow machine.
- `wait -m` matches logical lines (wrapped rows joined) on the screen,
  plus lines that scrolled away while it waited; it cannot find text
  that scrolled away before. A needle's trailing space matches only a
  space the program wrote (prompts write theirs).
- A program that stopped reading input makes `key`/`do` fail after
  5 s; check the screen. Only one batch types into a session at a time:
  another one fails with "another input batch is running".

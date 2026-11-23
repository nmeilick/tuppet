# tuppet design

This document explains how the tuppet daemon tracks screen changes, matches text, raises alerts, keeps its memory
bounded, and supports layout diagnostics; how the clients that paint a person's terminal (the drawn attach, boxes, and
groups) and `tuppet start` work; and why they work that way. It is for people who maintain tuppet. The wire format of
every request and reply is in [protocol.md](protocol.md), the commands and their options are in `tuppet help`, and the
[README](../README.md) covers installing and using tuppet.

## Principles

1. State lives in a session's status. Reads never change state. Events report status changes, lifecycle, and alert
   hits.
2. The daemon evaluates only exact, cheap things: substrings, and regular expressions that match in linear time.
   Judgment stays in clients, and the daemon never types into a session on its own. It stops a session on its own in
   three cases only: a box when the session it was started over ends, a box whose `unseen_ms` ran out, and a session
   whose lease closed.
3. One condition vocabulary and one evaluator serve waits, bundled waits, recordings, and alerts.
4. Everything is bounded. Nothing on the output path waits for a client or renders the full screen.
5. One resolver (names.zig) turns session references into sessions, in the daemon. The CLI and the protocol use the
   same words, and the CLI has no flag aliases.
6. tuppet never promises what it cannot observe, such as an identical redraw inside one read chunk, or rows lost with a
   scrollback of 0. Where it cannot tell, it says so (`lost`, `unknown`, `-`).
7. A client that paints a terminal writes only what it composes. The program's output never reaches the person's
   terminal as written, so nothing the program does can change what tuppet shows on top of it.

Durations take a unit everywhere, also in environment variables (`500ms`, `5s`, `2m`); `0` alone is allowed. Exit
codes mean the same in every command; the README lists them.

## Source map

| Module | Role |
| --- | --- |
| main.zig | The command line: dispatch of subcommands and every `tuppet help` text. |
| client.zig | The CLI's requests: connecting to the daemon (starting one when needed), sending a request, printing the reply. |
| daemon.zig | The daemon: the socket, request dispatch, and the requests that span sessions (`respawn`, `shutdown`). |
| protocol.zig, ipc.zig | The JSON-lines protocol's types, and its transport (unix sockets, Windows named pipes) with the same-user check. |
| session.zig, ptyio.zig | A session: its program on a pty, parsed by Ghostty; the reader loop, input writes, and the answers to the program's queries. |
| spawn.zig, pty.zig | Starting a session's program and its environment; making the pty (openpty or ConPTY). |
| sample.zig | Facts read from the pty rather than the output: the foreground program and whether it reads hidden input. |
| track.zig | Change tracking: settles, row hashes, seqs, scroll measurement, the input snapshot, alert masks. |
| cond.zig | Conditions and the text scan they are checked against. |
| regex.zig | The regular expressions of conditions and of `tuppet start`: a Thompson NFA, linear in the text. |
| evaluator.zig | The per-session thread that answers waits, samples the pty, finds event changes, writes trace frames, and takes alert hits. |
| alert.zig | Alert rules and the hit log. |
| names.zig | Session names and the references that pick sessions. |
| batch.zig, keys.zig, mouse.zig | Input batches and their guards; keys and mouse events encoded for the terminal's current modes. |
| attach.zig, events.zig | Attach streams and event streams. |
| over.zig | Boxes over a session: the relation, the limit of 16, `unseen_ms`, and stopping boxes whose session ended. |
| member.zig | What callers say about sessions as members of groups: numbers, labels, actions, flags, and side sessions. |
| marks.zig | Shell marks (OSC 133): the shell's state, the prompt the `prompt` guard checks, and the last commands. |
| hangup.zig | The hang-up watcher: waits whose client went, and leases. |
| status.zig | A session's status, from memory or from the store, and the cleaning of strings that programs supply. |
| limits.zig, budget.zig | Fixed limits and the daemon-wide memory budget. |
| registry.zig, store.zig | The session table, loading and unloading ended sessions, and the on-disk store. |
| record.zig, trace.zig | Recordings: asciicast and trace files, input events, and marks. |
| view.zig, styles.zig | The text of a view in plain text, VT sequences, or HTML, and the styles of a plain view. |
| render.zig, fonts.zig, png.zig | `tuppet png`: the software renderer, its font chain, and the PNG encoder. |
| sweep.zig | `tuppet sweep`. |
| config.zig, units.zig | The CLI's config file, and durations and sizes as people type them. |
| words.zig | One state word, an age, and the command line for a session, the same in `tuppet list` and the picker. |
| attach_client.zig, attach_filter.zig | The raw attach, and the filter that keeps the person's terminal from answering the program. |
| picker.zig | The session picker and its viewer. |
| paint.zig | The painter: a canvas of cells filled from session screens and tuppet's own text, written as only what changed, and the rows that leave the screen, written into the terminal's scrollback. |
| copy.zig | The stream a client's copy of a session is fed through, which says when the copy's history is about to go. |
| drawn.zig | The drawn attach: sessions' attach streams kept as local terminals, painted with paint.zig, and the person's input split into whole units for them. |
| boxes.zig | The hand-over of a drawn attach: which box is open or waits, when the keyboard moves to a box and back, and where each key goes. A pure state machine. |
| group.zig | A group attach's bookkeeping: its members, what needs attention, which fit the bar, and the switcher's keys. |
| play.zig | `tuppet play`: an asciicast played through the attach filter, at the recording's size. |
| start.zig, start_run.zig, start_record.zig | `tuppet start`: the start file and its steps; running them through `run`, `input` with `until`, `wait`, and `view`; and turning a recorded trace into a block. |
| fuzz.zig | For tests: the lines a daemon that is not trusted may send, and an allocator that catches unbounded allocation. |
| io.zig, plat.zig, win32.zig, win32_stub.zig | The process's `std.Io`, platform-neutral file and console I/O, and the Windows bindings. |

## Change tracking

Each session's reader thread parses the program's output and then settles the terminal. It settles once the pty is
drained, bounded by 20 ms or 1 MiB after the first unsettled chunk, and once synchronized output (mode 2026) is off,
bounded by 1 s. A settle runs under the session's `terminal_mutex`:

- It hashes each dirty row of the active screen twice: a full hash (codepoints with graphemes, resolved style, wide
  flag, hyperlink) and a text-only hash. The rows of the cursor are always hashed, because Ghostty does not mark a row
  dirty when a combining mark joins a cell left of the cursor. So is a row whose wrap flag changed since its last hash,
  because Ghostty can change the flag without marking the row dirty, as when an erase skips an already blank row.
- It measures how many rows scrolled into history, shifts the per-row arrays by that count, stamps the rows that
  changed with a seq, and clears the dirty bits of the active area.
- It matches the session's alerts against the lines that changed (see [Alerts and hits](#alerts-and-hits)).

Each row keeps its full hash, its text hash, the seq of its last change and of its last text change, `blank_seq`
(when it was last blank), and its alert and re-arm masks. The arrays are kept per screen. The alternate screen is
tracked without scroll measurement, and a changed screen generation in Ghostty's `ScreenSet` starts its rows anew. The
state of the last 1024 rows that scrolled into history is kept; older history rows, and rows a resize brings back from
there, have an unknown last change.

### Scroll measurement

Two tracked pins on the primary screen measure scrolling: one on the bottom row and one on the oldest row. While the
oldest row stays first, history grew by exactly the rows that scrolled into it, so a scroll region that moves rows up
in place is told apart from history growth. Only once history has dropped rows at its front does the bottom pin tell
how far the screen moved. When it cannot tell, because its rows were pruned or erased, the tracker forgets the screen's
rows, counts at least a screen's worth as `lost` (all kept history when its page was pruned), and numbers rows anew.
With a scrollback of 0 only the bottom pin is used.

During a reflow the bottom pin waits at the top of the screen and returns to the bottom row afterwards. Ghostty keeps
blank rows that hold a tracked pin, so a pin on the bottom row would push text into history when the screen gets
shorter.

### Seqs

There is one seq counter for the whole daemon, so a seq orders changes across sessions. The counter hands out seqs
from blocks of 2^20 that it records in the store first, so a restarted daemon starts above every seq an earlier one
may have used. Each session records its `start_seq`; a seq below it is `stale`.

- `input_seq` is taken under the session's write lock before the first byte of an input. The writer first waits, at
  most 50 ms and without holding `terminal_mutex`, until the output that was pending on the pty at entry (FIONREAD) is
  settled. An input that follows another without a change in between takes a seq of its own, so every input has a
  distinct `input_seq`.
- A resize settles the output pending on the pty first (at most 50 ms), takes the reflow's seq under the lock, and
  reports it as `resize_seq`. The reflow carries row seqs over by matching text hashes, so only rows whose text
  changed get a new seq. Rows are numbered anew after a reflow, and a wait counts the rows it had not checked yet as
  `lost`. A failed grid resize rolls the pty back to its old size.
- Quiet means no text change. A seq also counts style and cursor changes, because it serves `since` and
  `view --since`.

### Input snapshot

At each input the session copies the text of the visible rows, up to 256 KiB. The copy is shifted with the per-row
arrays and remapped across a reflow by text hash. Lines a reflow drops keep their text without a row, and their
occurrences offset new ones on any row. Past the cap, waits fall back to `since` the input's seq and report
`snapshot_truncated`. A session keeps one snapshot, of its latest input.

### The evaluator

Each session has one evaluator thread, started with the session and parked on the tracker's notifier. After a settle
(at most every 50 ms), at a wait's deadline, or when the session ends, it copies bounded line text and row state under
the lock and checks every wait against the copy after releasing it. A scan copies at most 10,000 rows and 2 MiB of
text; rows past either limit go unchecked and count as `lost`. The evaluator also samples the pty (at most every 50 ms
after a settle or an input, and every 250 ms while a wait or an events subscriber wants samples), finds the changes
that events report, writes trace frames, and turns due alerts into hits. It makes a final pass after the program ends,
before the session is stored.

## Matching semantics

`match TEXT` looks for a substring of logical lines: rows joined across soft wraps, the spacer cells of wide
characters skipped, and empty cells inside a line read as spaces. `icase` compares ASCII letters regardless of case.
The text holds no line break and is at most 4 KiB.

- Without `after_input` or `since`, a match is a level: the text is on the screen now, or appeared in rows that
  scrolled into history since the wait started.
- With `after_input` (the default inside `do`), only a new occurrence since the latest input counts: one absent from
  the input snapshot, or on a row blanked after the input (`blank_seq`). Echo of typed text therefore cannot
  satisfy a needle that was already on that row (`$ `, `>>> `), while the next prompt on a new row does, also after
  scrolling or `clear`. A needle contained in the typed text itself still matches.
- Bundled waits (`input`, `run`, and `do` with `until`) know the needle before the first byte. On each pass over
  changed rows the evaluator also records where the needle went away, so a needle that vanishes and returns on the
  same row between passes counts as new. A standalone wait sees new rows and blanked rows only.
- With `since SEQ`, the text must lie on a row that changed after SEQ. A client that matches by rules the daemon does
  not have uses `since` and checks the text itself.
- With `regex`, the text is a pattern of at most 256 bytes, matched on each logical line, with `^` and `$` at the
  line's ends. regex.zig simulates a Thompson NFA, so a match takes time linear in the line for any pattern and never
  backtracks; that is what makes it cheap enough for the daemon. Matches are leftmost-longest, start only where a
  character starts, and are never empty: a pattern that can match empty text is refused.
- `typed` (with `match` and `after_input`) is the text the input typed. Copies of it on the line the cursor was on at
  the input are left out before matching, and on every line when the needle is part of the typed text; without the
  input's snapshot, the lines that changed after the input stand for the cursor's line. So `cd /srv/app && pwd`
  followed by a match on `/srv/app` waits for the output of `pwd`, not for the echo. `tuppet start` sends it with
  every check that follows an input.

The other conditions:

- `idle DUR`: no text change for DUR, measured from the last text change. It is clamped to the wait's start only with
  `after_input` or `since`.
- `settled DUR`: the text or a style changed after the start point (`since`, the input, a `do --resize` step's reflow,
  or the wait's start), and then the text stayed unchanged for DUR with no output pending on the pty or held back by
  synchronized output. Quiet is measured on text, not bytes, because a blinking cursor or a clock would never let bytes
  settle. A silent pause, such as a clear followed by a draw 300 ms later, is not caught by the condition; the sweep's
  late check catches it. With `past_input_line` (and `after_input`), the change must be on a line other than the one
  the cursor was on at the input, so the echo alone is no change.
- `gone TEXT` (`absent` with `match` on the wire): the text was on the visible screen when the wait started (in `do`,
  before its input) or appeared after, and is now absent from the visible screen. Scrolling into history counts as
  gone. Text that never appeared never meets it.
- `ended`, `hidden_input`, and `hit NAME` (see [Alerts and hits](#alerts-and-hits)).
- `since` or `after_input` alone is met by any text change after that point; the outcome names it `changed`.

`since` and `after_input` cannot be combined. Rows whose last change is unknown are looked at only by a plain match;
`since`, `after_input`, and `changed` skip them, and a wait counts them as `lost` when one of them could have met the
condition. An `until` list is an OR, the fields inside one condition are an AND, and the reply's `met` is the index of
the first condition that holds.

There is no separate prompt condition: the shifting input snapshot answers the same need without knowing what a prompt
looks like. A shell that prints OSC 133 marks tells tuppet where its prompt is (see
[Shell marks](#shell-marks-and-the-prompt-guard)), but waits do not depend on it.

## Alerts and hits

An alert is a per-session rule: a name, a text of at most 256 bytes, and `icase`. A session has at most 32. Rules are
set by `run` (watching from the first byte) or added later, and are stored with the session, so `run` with `like` can
copy them. Matching alerts in the settle is the one exception to "no matching on the output path", and it is bounded:
at most 32 texts of 256 bytes over the rows that changed.

An occurrence is identified by its tracked row and alert. A hit is the row's alert bit going from 0 to 1. The bit
re-arms when it was 0 at a settle, because the row lost the needle or was blank. So a typed answer on the prompt row,
or a timer on the same line, keeps the bit at 1 and does not fire again. An identical dialog drawn again after it was
erased in an earlier settle is a new hit, and so is a line that a program blanks and redraws across settles. An alert
therefore works best on a line that changes when a dialog is reused. Rows that scroll into history are
matched once. A freshly cleared alternate screen starts empty, so a dialog drawn with the switch fires. Text already on
the screen when an alert is added, or shown by a reflow, counts as seen.

A resize must not make a visible alert fire again, also when the program redraws its screen for the new width. Each
resize of a run of resizes counts, per screen and alert, the lines that show it, and the run keeps the highest count.
Until the run ends, a line that a reflow placed fires only when more lines show the alert than that count. The run ends
5 s after its last resize, or with the next input. A program that pads or frames its line to the terminal width
therefore does not fire on a window drag, while a second line that shows the alert does.

Each alert fires at most 10 times a second; the hits left out are counted in the next hit's `suppressed`. When a burst
ends, the latest hit it left out is logged once its second is over (an evaluator timer) or when the session ends. A hit
always writes a mark into an active recording.

The hit log keeps the last 64 hits of a session, one entry per line with the alerts it matched, and is stored with the
session once it ends. The `hit` condition (name `*` for any alert) is met by a hit after the session's latest input,
so an answered dialog that is still on screen never satisfies it; with `since` or `after_input`, by a hit after that
point; with `after_hit N`, by any hit numbered above N. The wait reply returns the hits it counts, and `missed` counts
the ones the log evicted.

## Status

The fields are listed in [protocol.md](protocol.md#status). Some rules behind them:

- `idle_ms` measures text changes, `change_idle_ms` anything visible, and `output_idle_ms` bytes from the program.
- `end_seq` is the seq taken when the session ended. `exit.stopped` is true when `tuppet stop` ended the session (also
  `remove -f`, `run` with `if_exists` `replace`, and a daemon's shutdown). Such a session counts as seen from its end,
  because whoever stopped it knows, and so does a box.
- A box's `shown` and `held` are set by the attach that first counts, under `terminal_mutex`, and its `ended_by` under
  `stop_mutex` before the signal, so the status at its end says why. Each change is written to its metadata at once.
  The session underneath keeps its running boxes and reserves room for one that starts, so the limit of 16 holds; when
  it ends it closes that list and stops the boxes on threads of their own. The box's evaluator watches `unseen_ms`.
- Strings the program supplies lose C0, C1, and bidirectional controls when stored, and are capped.
- The evaluator samples the foreground process group and the tty modes under `terminal_mutex`, once the pty's master
  is known to be open, through libc with every error checked rather than `std.posix`, which treats some of them, such as
  EBADF, as unreachable. The program's name is looked up without that lock: when the group changes (scanning `/proc`
  for a member when the leader is gone), and from the leader again at most every second, so a program that exec'd
  shows its new name.
- `seen`, the counters, the alert definitions and hits, and the session's own seqs are stored in its metadata
  (`store.Meta`); the daemon-wide seq mark is a single `seq` file in the boot directory.

## Protocol design

[protocol.md](protocol.md) is the reference. These are the reasons behind parts of it.

- **Strict envelope.** An unknown field, also a nested one, fails with `bad_request` naming the field, so a typo never
  silently changes what a request does. Every failure, also in a stream, carries a code.
- **Additions keep the revision.** The revision stays 2 for every addition a client can ignore; `hello` lists in
  `features` what a newer client must check for before it sends a new field, since the daemon rejects fields it does
  not know. A feature such as `pass` or `no_keys` changes nothing on the wire and only tells a caller that the tuppet
  of that daemon has a client option.
- **One resolver.** A `session` reference (id, name, or a pattern that picks exactly one) is resolved once, under the
  table lock. `sessions` lists in `list`, `stop`, `remove`, `ack`, and `events` take patterns that skip sessions the
  action does not apply to.
- **One shutdown routine.** The `shutdown` request and SIGTERM run the same code: refuse new sessions under the spawn
  lock and every request but `hello` with `stopping`, end attach streams, stop all sessions at once, drain events and
  waits, reset under the boot lock while the endpoint still exists, reply, and exit 0. A reset keeps the boot
  directory, its lock, and the seq mark, so seqs never repeat.
- **Input batches.** One batch per session runs at a time; a second gets `busy` at once and nothing is written. Limits
  are 1024 steps, sleeps of at most 1 s each and 2 s in total, and 5 s of writing including any wait for the write
  lock. Keys are encoded per step for the terminal's current keyboard mode. Batch sleeps flush query replies and abort
  when the program exits; a hang-up of the client is checked between steps. Guards (`require`) are checked under the
  write lock. There is no guard on `seq`, because any output would race it.
- **Writers during a batch.** Attach input from a writer blocks while a batch types, and socket backpressure keeps its
  order. The writer gets `{"hold":true}` and `{"hold":false}`. If the hold lasts more than 1 s past the longest the
  batch may take, the whole buffered burst is discarded with one `error` frame with code `busy`, never a partial
  burst.
- **Size restore.** When a writer detaches, the session gets back the size it had before a writer first resized it,
  unless a `resize` request set a size since. A writer that never resizes (`--no-resize`) leaves the size alone. The
  restore applies even when the memory budget is full. Clients that size sessions for a layout (boxes, group members,
  side sessions) use `resize` requests only, so this rule never undoes their sizes.
- **Waits.** Waits and event streams do not take one of the 32 request slots; they share a pool of 256. A wait is a
  refcounted object whose outcome the evaluator produces. One hang-up watcher for the whole daemon polls every waiting
  connection plus a self-pipe, so on Linux a wait ends when its client goes away (elsewhere it runs until it is
  answered or times out); a half-closed connection keeps its wait. No
  wait holds a long-lived reference on its session, so removing a session never waits for its waits. Open waits and
  event streams keep an idle daemon alive. The daemon raises its soft open-file limit to the hard one at start.
- **Events.** A subscriber gets one snapshot per matching session, then `synced`, then changes. Changes are coalesced
  to at most 10 a second per session, except lifecycle frames and hits. A subscriber that falls behind gets `resync`
  and fresh snapshots; one that stops reading gets `end` with `too_slow`.
- **Recordings.** The reader thread writes a cast's output as each chunk arrives; trace frames come from the
  evaluator. A trace
  frame is written per evaluator pass from the rows that changed, at most every 50 ms, and always before an input, a
  resize's reflow, a mark, and the stop.
- **Reported, not acted on.** What a caller says about a session (group, label, actions, flags, `meta`) and what the
  attach reports back (`action`, `side` with `request`) only pass through the daemon. tuppet does not interpret
  actions; the caller follows the events and acts.

## Picker and attach

- Rows are listed newest first in a stable order. The first selection is the newest running session, and when a row
  disappears its neighbour is selected. STATE shows one word, chosen by priority: damaged, failed N, lost, password?,
  box waits, an alert name, bell, stopped, done, quiet (with its age, such as `quiet 3m`), running. Hit and bell words
  show only while unseen. Narrow terminals drop COMMAND, then AGE, then truncate names; below 20x5 the picker says the
  terminal is too small. Glyphs have ASCII fallbacks, and `NO_COLOR` is honored.
- A box waits over a session while it runs, its `grab` is not `never`, and it has no writer. Clients derive this from
  the session's `under` and each box's `over` and `writer`, so the daemon keeps no such mark and an ack cannot clear
  it: the session counts as needing someone (`!` in `tuppet list`, the picker's count, and Tab) until no box waits.
  `tuppet list` with sessions given lists all of them once more when a listed session has boxes, since the boxes may
  not be among those given.
- Destructive keys (`x`, `d`, `r`) are ignored for 500 ms after an attach ends or the mode changes, and for 500 ms
  after an attach ends only navigation keys, `q`, `?`, Esc, and the detach key work, so keys typed for the session are
  not taken as picker commands. An escape sequence split across reads is waited for up to 500 ms; a lone ESC counts as
  Escape after 30 ms.
- The preview attaches in the passive `preview` role, so it is not counted among the session's viewers and never acks.
  A writer attach acks at start, detach, and exit; the viewer and a terminal `attach -r` ack after showing a session
  for 1 s; Space acks explicitly. Acks carry the values that were displayed, and the daemon never moves `seen`
  backwards, so two pickers acking at once cannot undo each other.
- A row whose id equals `$TUPPET_SESSION`, on the daemon `$TUPPET_SESSION_SOCKET` names, is labelled "(this terminal)"
  and cannot be viewed or attached, so the picker never attaches to the session it runs in.
- In a raw attach only the detach key is taken. Another session gaining a mark rings the local bell once, unless the
  config turns that off. A box that waits does not count for that; in a raw attach, only the first box that comes to
  wait over the attached session rings, through its events stream, and again when one comes after none waited. A raw
  attach never shows a box. tuppet never writes the window title.
- Attaching from the picker stays on the alternate screen, and a session that exits meanwhile returns to the viewer
  with its final screen. A direct `tuppet attach` stays on the normal screen, and so does a direct drawn attach (see
  [The normal screen and the scrollback](#the-normal-screen-and-the-scrollback)). History is one key away (`o`, which
  opens it in `$PAGER`). `--history N` first writes the session's last N older lines: into the scrollback in a raw or
  drawn attach, or before the stream of `attach -r` outside a terminal.
- Bare `tuppet` opens the picker only when stdin and stdout are terminals. Otherwise it prints usage to stderr and
  exits 2, so a script or an agent reading through a pipe never gets a full-screen program. On Windows it always prints
  usage.
- `attach -r --no-keys` is the viewer with every key but the detach key ignored (Ctrl-C and Esc too) and no key shown:
  no hints, no help, and no notice that names a key. A caller that lets someone only watch must not show them keys
  that stop a session or take control. It is a client option; the hello feature `no_keys` only tells a caller that the
  tuppet it talks to has it.
- A client does not trust the daemon's text. Error messages, end reasons, and signal names it prints lose C0, C1, and
  bidi controls as status strings do (`status.cleaned`), and the picker replaces any such character in a cell when it
  paints. Replies, statuses, and frames that do not parse, or carry odd values, make the raw attach and the viewer
  refuse or end, never crash; unit tests feed both a few thousand mutated lines with a fixed seed (fuzz.zig).
- No log line reaches a terminal that a client paints. The daemon logs as before; a client process never writes the
  terminal emulator's log lines, and writes none of its own while the picker or an attach has the terminal.

## The drawn attach

A raw attach passes the program's output on to the person's terminal through a filter (attach_filter.zig), so the
program draws there itself. Anything tuppet showed on top could be painted over, or would rely on resetting whatever
state the program left the terminal in. tuppet already keeps a complete and correct copy of every session's screen, so
a drawn attach (`tuppet attach --drawn`, `run -a --drawn`, and the picker's `a` with `drawn = true`) paints the
person's terminal from that copy instead. A box over a session is then simply a second screen in the same picture.

The drawn attach is not the picker's viewer with typing switched on; the viewer was built for a quick look and keeps
its own simpler grid. The raw attach stays the default.

### The client's copy

The client holds the session's attach stream in the `write` role and feeds its `screen` and `out` frames into a
terminal of its own, fed through copy.zig. Each session it shows has a copy, painted into a layer of its own that keeps
its last good state while the copy waits for a screen or the end of a synchronized update. A frame is composed from the
layers: the session underneath or its backdrop, a `--grab never` box, the open box, and tuppet's line. Nothing in the
loop waits for the daemon: streams are read and written without blocking, opened without waiting for their reply, and
fed into their copies a slice at a time.

The copy cannot reflow the way the daemon's terminal does, so the attach asks for `redraw_on_resize`: after every
resize of the session, by this client or by anyone else, the daemon sends a fresh `screen` frame and the copy starts
again from it. The client keeps its stream and its writer role across a resize. A drawing client's `screen` frames also
carry what the copy would otherwise lose at every attach and resize: the default colours the program set (OSC 10 and
11, or OSC 110 and 111 when it set none, since a reset keeps them), the cursor shape it chose (DECSCUSR), the rows the
session wrapped (`wrapped`), whether the top row continues the history (`continued`), and the number of the top row
(`row`). To tell the program's colours from tuppet's own, the daemon keeps its theme as the terminal's default colours,
not as an override, which would look the same as a colour the program set. The frames of other attach streams do not
change. The wire details are in [protocol.md](protocol.md#attach-streams).

A drawn attach always opens an events stream for all sessions, also with `bell = false`, which only keeps the bell
quiet. Boxes, group members, and side sessions are learned from it. If the stream cannot be opened, the attach fails
with exit 1.

### Painting

paint.zig keeps a canvas of cells the size of the window and writes only what changed since the last frame.

- **The whole screen model.** Whole characters with their combining marks, joined emoji, and variation selectors;
  every attribute, including the underline styles and overline; links; the real cursor with its shape, where the
  program has it. A palette entry or default colour that the program changed is written as its RGB value; one it did
  not change is written as the palette index or the default, so the person's own theme stays. A blank cell that carries
  only a background colour is painted with that colour.
- **Only what it composes.** The person's terminal receives cursor moves, colours and attributes, printable text,
  links, and the modes tuppet chose; on the normal screen also line feeds on the bottom row, the switch to and from the
  alternate screen, autowrap on and off around a wrap seam, and erase-line. tuppet also asks the terminal for its
  colours (OSC 10 and 11, at the start), its cursor style (DECRQSS), and a few modes (DECRQM) so that it can put them
  back. It never writes "erase scrollback". Each update is written inside a synchronized update.
- **No width disagreement shifts text.** After every cell that is not plain ASCII, the cursor is placed again. When
  tuppet and the terminal disagree on how wide a character is, that one cell looks wrong and everything after it stays
  in place.
- **No right-to-left reordering.** tuppet writes `CSI 8 l` at the start and `CSI 8 h` at the end. A terminal that
  ignores this may reorder such text within one painted line; on the lines a box that takes keys sits on, no
  right-to-left character is painted beside it, so that cannot reach the box.
- **Links are limited.** A link's address is written only if it is printable ASCII of at most 2,000 bytes; otherwise
  the link is left out and its text is painted plain.
- **Promptly, and the latest state only.** A frame is 33 ms. The first output that arrives within one frame after a key
  is painted at once, so typing echoes without waiting for a frame. Other output is painted at once when the last paint
  is at least a frame old, else at the frame's end. A flood therefore shows its latest state, and what lies between is
  skipped.
- **Cropping.** A session larger than the window is cropped at the right and the bottom; a smaller one is painted at
  the top left. Boxes are placed in the window, not in the session.

### Input

tuppet sets on the person's terminal the input modes that the session which has the keyboard asked for, from a fixed
list: cursor-key and keypad modes, mouse reporting, focus reports, and the keyboard protocols (kitty's and xterm's
modifyOtherKeys). It changes them when the keyboard moves to another session. A box's program that asked for focus
reports is told when its box takes and loses the keyboard.

- Bracketed paste is always on at the person's terminal; for a session that did not ask for it, tuppet removes the
  brackets and passes the text.
- Alternate scroll (mode 1007) is turned off while attached, so the wheel is not sent as arrow keys, and put back where
  the terminal answered a query for it. While no box waits or is open, the wheel scrolls a full-screen program that did
  not ask for the mouse, as it would without tuppet.
- Input is passed on in whole units only: a key, an escape sequence, a paste, or a mouse report is never split. A lone
  ESC is the Escape key after 30 ms; the rest of a sequence that has begun is waited for up to 500 ms. A paste longer
  than 256 KiB goes to its session in pieces of that size, one right behind the other, so the client never holds an
  unbounded paste. A paste that stalls for a second goes on with what came and stays open: only its end mark ends it,
  or the detach key read on its own after the stall, for a terminal that lost the end mark. A paste cut by a reconnect
  is closed on the session; its rest is dropped and never becomes keys.

### What it passes on

A drawn attach passes on the bell, notifications (their text cleaned as titles are), clipboard writes, and links, from
the session and from its boxes. `--pass` (or `pass` in `[attach]`) chooses which of the four; `none` passes nothing.
tuppet's own bell for a box that arrives stays under `bell = false`. It never passes a request to read the clipboard,
and it never writes the window title.

### Colours

A session started by a drawn attach takes its default colours from the person's terminal (the `colors` field of
`run`), so a program on a light terminal is not told that the background is dark. A box takes the colours of the
session it is over. A restored session, after the daemon restarts, has tuppet's colours again.

When the terminal tells its colours and colour is wanted, tuppet uses them for its own cells: the backdrop behind a box
is painted in the colour halfway between the terminal's text and background, because "faint" does nothing on many
terminals with a light background; a box is painted on a shade of the background (see [Boxes](#boxes)). At the end, the
cursor style the attach found is put back, so xterm's cursor does not start blinking after an attach that found it
steady.

### The normal screen and the scrollback

A program that prints line after line (a shell, a build, an agent that prints its transcript) leaves its old lines in
the terminal's own scrollback under a raw attach. A drawn attach keeps that: it paints on the terminal's normal screen
whenever it can, so the person's own scrollback, search, and copy keep working, while tuppet still composes every
byte. In xterm, urxvt, kitty, alacritty, gnome-terminal, xfce4-terminal, ghostty, and tmux inside xterm, line feeds
written on the bottom row put every line into the scrollback, in order and with no gap, and a line the terminal wrapped
itself is copied as one line. The rules:

1. **Start.** The terminal's existing screen is scrolled away first, as the raw attach does, so nothing of the person's
   earlier lines is overwritten. On an empty screen that leaves one blank line at the top of the scrollback.
2. **Lines leave once.** Every row that leaves the session's screen while the attach paints the normal screen is
   written to the terminal once, in order, with the session's own cells and none of tuppet's. The client's copy keeps
   those rows as they leave, also just before an erase of history, a full reset, a switch of width (copy.zig sees those
   three coming), and a fresh screen frame. Each frame paints them over the window's top rows and pushes them out with
   line feeds on the bottom row.
3. **Bounded, and said.** Writing held rows is bounded per frame, so echo and a box never wait for it, and bounded in
   total. The `row` counter of screen frames lets an attach that fell behind or attached again fetch the rows it missed
   with `history_from`, at most 4096 rows; the daemon sends at most 16 MiB of older lines per attach. Where lines were
   left out, one line of tuppet's says how many; tuppet's history still has them.
4. **Wrap seams.** A row that the session wrapped is written so that the terminal marks the wrap itself: autowrap is on
   only for the last cell of the row and the first of the next, only when both are plain ASCII and the session is as
   wide as the window. Otherwise the row ends hard. A row that stops being wrapped is erased and written again, so two
   lines are never copied as one.
5. **The alternate screen.** tuppet uses the terminal's alternate screen while the program does, while a box has the
   keyboard, while the window is smaller than the session (and says so), while a side pane sits beside the member in
   front (see [Groups](#groups-side-sessions-and-shell-marks)), and always with `--alt-screen`. While a box is open, the
   switch for the program waits until the box has closed or is set aside. When the normal screen comes back, the rows
   that left meanwhile are written under rule 3.
6. **tuppet's own cells.** tuppet's line, notices, and a box that takes no keys are painted on the normal screen and
   replaced by the session's cells before their rows leave. tuppet's line sits on the bottom row, or the row above while
   the program's cursor is there, because a window that shrinks moves its top rows into the scrollback before tuppet can
   repaint; on the alternate screen it sits at the top right. tuppet's line is erased from the normal screen before a
   box switches to the alternate one, so the line feeds below do not push it out.
7. **Resize.** The real cursor stays on the session's cursor row, also while it is hidden. Rows that a resize moves
   into the session's history are held and written like any row that leaves, not pushed by line feeds, since the
   terminal may show other rows by then. A terminal that grows may take rows back from its scrollback onto the screen,
   and tuppet cannot tell how many; so before anything is painted on the normal screen after the window grew, line
   feeds on the bottom row push out as many rows as it may have taken: one for each row it grew, and when it got wider,
   one for each row marked as wrapped and one more; the whole window but its bottom row when it got wider while the
   normal screen was behind the alternate one. Before each paint the attach reads the window's size itself, so a resize
   whose signal has not come yet is handled first. A held line is not written again over a row that shows it already.
8. **xterm's alternate screen.** xterm, while the alternate screen shows, takes the rows it grows by from its scrollback
   onto that screen, where they are lost, and drops the hidden normal screen's top rows when it shrinks. So the last
   lines written into the scrollback are kept (up to 1000), and back on the normal screen as many of them as the window
   grew meanwhile are written again before the held ones. In xterm they then follow the old rows that the line feeds
   pushed out, out of order but none lost.
9. **A box nobody sees.** A person who has scrolled back is shown the alternate screen at once when it is entered in
   those terminals. xterm started with `-si` keeps the scrolled-back view and still answers the cursor
   report, so a box could open unseen. While a box is open, a drawn attach therefore sets mode 1010 (scroll to the
   bottom on output), so the box's first frame brings the view down before it takes keys. It asks for the mode first:
   where the terminal says it was off, it is set back off when the box goes and at the end; where it says it is on, it
   is left alone; where it does not say, it is set while a box is open and left on.
10. **End.** The last screen and the lines stay, the cursor goes below them, and tuppet's closing line follows. When
    the window was smaller than the session at the end, the closing message first says that the attach ended on the
    alternate screen.

tuppet promises what it writes, not what a terminal does with its scrollback: lines may repeat at a resize, about as
many as the window grew or shrank. `--history` is a usage error with `--alt-screen` and with the viewer, which have no
scrollback to write into.

### Options, recovery, and the end

- `--drawn` with `-r` is refused with exit 2; the read-only viewer stays what it is and shows no boxes, and
  `drawn = true` in the config does not apply to `-r`. `--no-drawn` overrides `drawn = true`. `--drawn` fails with
  exit 2 outside a terminal and on Windows. `--label` with `-r` is a usage error: only a writer's label shows. When a
  drawn attach is asked for and cannot work, it fails with a message that says why; it never falls back to passing
  output through. Older tuppet versions refuse a config file with the `[attach]` keys they do not know.
- After `too_slow` or a broken connection, the client attaches again without `force`, at once and then every 200 ms for
  at most 5 seconds, repaints, and drops the keys it read meanwhile. An events stream that ends is opened again in the
  same way, and no box opens until its `synced` frame has come again. After `shutdown`, a refused attach, or the 5
  seconds, the attach ends: exit 1, or 4 for a lost session. It does not hand the terminal to the shell while it is
  still trying.
- With `--no-detach`, the attach lasts until the program ends and the detach key does not detach; with no box it is
  dropped. While the client does not have the writer role, as after a forced attach took it, the key detaches all the
  same, since nothing else would end the attach. A tool that ties one session to one terminal uses this, and must then
  stop the session itself when the attach ends another way, such as a closed window. Exit code 0 then only means that
  the program ended with 0.

## Boxes

Some tools run a program in a session that they do not trust, or that runs unattended, and sometimes must put UI of
their own in front of the person who is attached: a confirmation before a critical action, a choice, a passphrase
prompt, a pager. The program underneath must not be able to change, hide, or answer that UI, and its own screen must
be back exactly afterwards.

`tuppet run --over SESSION -- CMD` starts CMD in a new, ordinary session and shows that session in a box over SESSION,
for every client that has SESSION in a drawn attach. The box is an ordinary session in every other respect: `view`,
`png`, `wait`, `key`, `do`, `stop`, and recordings work on it, so a test can drive a box with no person present.
Nothing in tuppet knows what a box is for: a confirmation, a picker bound to a key, a pager, and a passphrase prompt
use the same thing.

The daemon keeps only the relation (over.zig): the status field `over` on the box and `under` on the session, and the
two rules by which it stops a box. Everything about showing a box lives in the drawing client: boxes.zig decides which
box is open, which one tuppet's line shows, when the keyboard moves, and where each key goes, as a pure state machine
that drawn.zig feeds with boxes, where each fits, keys with their read times, cursor reports, and the time. drawn.zig
paints, attaches, and passes keys as it says.

`over` describes only the showing. A client must not conclude from it that a session will be stopped or removed.

### Starting a box

- The reference is resolved as every reference is: `no_session` when it picks none, `ambiguous` when it picks several.
  It fails with `ended` for an ended or lost session, and with `bad_request` for a box: boxes over boxes are refused.
- A session has at most 16 running boxes; one more fails with `limit`. The session underneath reserves room for a box
  that starts, so the limit holds under concurrent starts.
- `--over` cannot be combined with `-a`, conditions, a group, or an `if_exists` other than `fail`. `--backdrop`
  with `--grab never` is refused. `restart` and `like` never copy the relation.
- A box started with `run --over` is stopped when the session underneath ends (`ended_by` `under`). This is tied to how
  the box was started, not to being shown over a session.
- `-t DUR` (`unseen_ms`, 1 ms to 24 h, no default) limits how long the box may run before it is first `held` (first
  `shown`, for `--grab never`). When the time is up, the daemon stops it (`ended_by` `unseen`).
- The daemon sets `seen.ended` on a box when it ends, so no client counts an ended box as needing someone.

### What the caller gets

`run --over` prints the box's id at once, then waits, with no time limit, until the box's program has ended. It waits
in `wait` requests for `ended` of at most 10 minutes each, one after the other. At the end it removes the box, so ended
boxes do not collect in the list and their screens are not kept, and prints one outcome line (with `-j`, the box's
final status):

    ended <id> exit=N held=yes|no shown=yes|no
    stopped <id> reason=unseen|under|stopped held=yes|no shown=yes|no
    lost <id>

The exit code is the program's own only when it ended by itself and the daemon recorded `held` (`shown`, for
`--grab never`); 3 when `-t` ran out; 4 in every other case: the session underneath ended, the box was stopped another
way, the program ended without the box ever being held, or the box was lost. A program can itself exit with 3 or 4; a
caller for whom that matters reads the outcome line, and one that needs more than a code gives the program a file or a
pipe of its own. Interrupted (SIGINT, SIGTERM, SIGHUP), `run --over` stops its box, prints `reason=stopped`, removes
the box, and exits 128 + the signal's number. Killed, it leaves the box until someone stops it or the session
underneath ends.

`held` and `shown` record that some client was attached to the box in the `write` role, or in the `write` or `read`
role. A drawn attach takes those roles only as the hand-over below describes, so for it `held` means that keys counted.
A raw attach to the box, the picker's viewer, and `tuppet sweep` set them too; a caller that must exclude those keeps
other clients off the socket.

### Size and place

- `-s WxH` is the size of the program's area; a box is 64x12 unless given, and `TUPPET_SIZE` does not apply. tuppet adds
  a border of one cell and, outside it, a blank margin of one cell.
- With the box W by H cells, border and margin included, in a window of C columns by R rows, its left column is
  floor((C − W) / 2) and its top row floor((R − H) / 3), counted from 0. Programs write their newest lines low, so a
  box sits above the middle.
- In a window that is too small, the margin goes first, then the box's session is resized to fit, never below 20x5 or
  its starting size where that is smaller. When it does not fit even then, only the one-line form shows, with
  `window too small`; the session underneath keeps the keyboard, and the box opens again through the full hand-over
  once it fits. A box that was shrunk grows back toward its earlier size as far as the window allows.
- The client sizes a box with `resize` requests only, so a writer's detach never restores an older size on a box.
- A box is shown whole or it takes no keys. A change of its size or place while it is open runs the hand-over's cursor
  report and pause again.

### What is painted

- The border's title comes only from whoever started the box: `--title`, else the session's name, else `#<id>`. The
  daemon stores it cleaned (controls and bidirectional controls removed, invalid UTF-8 replaced) and cut at a character
  boundary at 64 bytes. Nothing the program in the box writes reaches the border.
- Around a box that takes keys, the session underneath stays visible on every side, as its backdrop; only the margin is
  blank. On the lines the box, its border, and its margin sit on, each right-to-left character of the session is
  painted as U+FFFD, and each cell as one code point.
- When the terminal tells its colours and colour is wanted, a box, border included, is painted on a shade of the
  terminal's background 16% of the way to its text colour, wherever its program left the background as the terminal's
  own, so a program that chose its colours for that background stays readable. An open box casts a shadow into its
  margin, one cell to the right and below, in the background halfway to black. The title is in the terminal's text
  colour, bold; the state word and the border keep the state's colour. Otherwise a box is painted on the terminal's
  background.
- Box cells are painted last in every frame, each at its own computed place.
- Where tuppet's own cells follow a cell of a session on the same row, the first of them is a blank, so no character
  of the session can join with tuppet's text on the person's terminal. On the row above and below a `--grab never` box,
  tuppet's line, or a receipt, one code point is painted per cell, so stacked marks of the session cannot reach them.
- The real cursor shows in the session that has the keyboard: in the open box, else where the program underneath has
  it. It is hidden while a box or a line covers that cell.

The border states its state in words, not by colour alone, with the picker's ASCII fallbacks and `NO_COLOR` rule:

    ┏━ confirm deploy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 1 of 3 ━┓
    ┃ (the box's session)                                        ┃
    ┗━ keys here ━ behind: 14:02:31, still runs ━ Esc later ━┛

The state word is `wait…`, `keys here`, or `asleep: any key wakes`. On a narrow border the frozen time goes first, then
the key hint shrinks (`Ctrl-] detach` to `^] detach`, with setting aside off), then the count; the title is cut last.
The key is named as it is configured.

### When a box takes the keyboard

The words: a **key** is a pressed key, a paste, or a mouse button or wheel report. Focus reports, mouse motion, and the
terminal's answers to tuppet's own queries are not keys; they end no pause and are never passed to a box before its
border says `keys here`.

**`--grab pause`** (the default) is for a box that arrives on its own, when the person did not ask for it.

1. **It arrives as one line**, tuppet's line, and the terminal's bell rings once. The session underneath stays as it is
   and keeps the keyboard: `confirm deploy waits · opens when you pause · Ctrl-] now`. Where the line does not fit,
   the title is cut first, with `…`; where not even one cell of the title fits, only `box waits` or
   `window too small` shows (`box closed` for a receipt).
2. **It opens when the person pauses.** Once no key has come for `box_pause` (`[attach] box_pause`, 1 s, at most 1 m;
   the person's setting, not the caller's), counted from the later of the line's arrival and the last key, the box
   opens. The detach key on the line opens it at once.
3. **Opening is one frame.** The input modes of the box's session are written first. Then, in one frame, the box
   appears, the backdrop is applied, and the session underneath stops receiving keys. The client attaches to the box in
   the `read` role, and the border says `wait…`.
4. **Keys count a moment later.** After that frame the client puts the cursor on the first cell of the box's program
   area and asks the terminal for a cursor report, accepting only a report that names that cell. Keys count once that
   report has come and a further 500 ms have passed without a key; every key read before that is dropped. Then the
   client attaches in the `write` role and the border says `keys here`. A program cannot produce the report, because
   nothing it writes reaches the terminal. A report that answers an earlier ask is dropped rather than passed on as a
   key. If the `write` attach is refused, the box goes back to the line `… waits · controlled elsewhere` in one frame,
   and the session underneath has the keyboard again.
5. **A terminal that does not answer** within 2 seconds puts the box back to the line,
   `… · terminal did not answer · Ctrl-] opens it`, and the session underneath has the keyboard again.
6. **It sleeps when left alone.** After 60 seconds without a key, counted from `keys here`, the border says
   `asleep: any key wakes`. An asleep box keeps the keyboard and its backdrop, no session gets keys, and the client
   holds it in the `read` role. Any key, the detach key included, wakes it and is dropped; waking runs step 4 again.

**`--grab now`** is for a box the person asked for, such as a picker bound to a key. It opens at once, in every state,
and steps 3 to 5 apply without the 500 ms: keys count as soon as the report has come. It has no pause, no sleep, no
dropped keys after it closes, and no receipt.

**`--grab never`** is for a notice or a progress display. It never takes the keyboard, rings no bell, and never holds up
a box that takes keys. The top right corner of its border is the window's, one row lower while a line shows there; it
has no margin and blanks nothing outside its border. One is shown at a time, the oldest; the others wait, and their
`-t` runs. It stays painted while a box that takes keys is open, except where that box and its margin cover it.

A paste reaches a box, of any kind, only when the box's program asked for bracketed paste; otherwise it is dropped. A
paste never reaches a box as plain keys.

### The backdrop

The backdrop applies from the opening frame until the box closes or is set aside. The session underneath keeps running
in both cases.

- Every cell outside the box is written without the program's own styles: in the dim colour when the terminal told its
  colours, else with SGR `0;2` (default colours, faint), also under `NO_COLOR`.
- One code point is painted per cell: combining marks, joiners, and variation selectors are left out, so nothing from
  a neighbouring line can be drawn over the box. Cells of the backdrop carry no links.
- `frozen` (the default) shows the screen as it was at the opening frame. The border says since when, so it is not
  taken for a hung program: `behind: 14:02:31, still runs`. When the window is resized, the frozen screen is taken
  again once and the time updated, so the picture behind the box is right after a resize. `live` keeps updating.

When the box closes or is set aside, the session underneath is painted in full again, as it is at that moment.

### The detach key and Esc

Every key but Esc belongs to the program in an open box. Esc and the detach key act on the box itself. Esc is where
every keyboard has it, and a box is meant for a short question, not for a program that needs Esc.

- While a box is open, the detach key sets it aside, and so does Esc once the box takes keys. An Esc during the
  hand-over is dropped like any key, so an Esc typed for the session underneath never sends away a box nobody has read.
  Esc counts alone, not as the start of an escape sequence, and also as the kitty keyboard protocol reports it, with
  Caps Lock or Num Lock; the release of an Esc that set a box aside goes nowhere. Set aside, the box is the one line
  again (`confirm deploy waits · 2 more · Ctrl-] opens it`), and the session underneath is painted in full and live and
  has the keyboard.
- While boxes wait, the key opens the first in the order; after a box was set aside, the box the person set aside.
  When the box on the line cannot open (`window too small`, `controlled elsewhere`, or
  `another terminal has the keyboard`), the key acts as with no box.
- Without `--no-detach`, the key dismisses a receipt while one shows, and with no box that takes keys and no receipt it
  detaches. With `--no-detach` it never detaches while the attach writes.
- For a second after a press of either key that acted on a box, and after each press in that second, that key does
  nothing (an Esc is dropped and does not reach the session underneath). A person hammering the key to get rid of a box
  therefore never detaches.
- `set_aside = false` in `[attach]` turns setting aside off: Esc goes to the box's program, and the key detaches from
  an open box, which waits for the next drawn attach; the border says `detach` instead of `Esc later`. Together with
  `--no-detach`, an open box keeps the keyboard until its program ends.

### Several boxes

- The order is `--grab now` boxes, newest first, then `--grab pause` boxes, oldest first. `N of M` on the border counts
  the open box and those that wait in that order, and shows only when M is more than 1. `--grab never` boxes are
  outside it.
- One box that takes keys is open at a time. A `--grab now` box opens at once; a box that is open then is set aside in
  the same frame and keeps its place in the order. When the `--grab now` box closes, that box arrives again as a line
  and goes through its pause and hand-over.
- When the person sets a box aside, every waiting `--grab pause` box is held: none opens by itself. Only the person's
  key starts this hold. It lasts until the box set aside has ended, and, when it ended while set aside, until its
  receipt was dismissed; after that, boxes open by themselves again. A new arrival meanwhile updates the count and
  rings.
- When a `--grab pause` box closes and another waits, the next one arrives as a line and goes through its own pause and
  hand-over. One box never takes another's place in the same frame.

### Closing

How a box ends decides what the person sees.

- **Open or asleep.** The box is removed in one frame and the session underneath is painted in full. For a
  `--grab pause` box, keys are then dropped until 500 ms have passed without a key, and the line becomes a receipt:
  `confirm deploy closed · keys go to agent` (the session underneath by name, or `#<id>`), or
  `confirm deploy closed · 2 more wait`. The receipt stays 2 seconds. When no key was ever passed to the box, it stays
  until the first key after the dropped ones, which goes to the session underneath, or, once a box waits, 2 seconds
  from then; a waiting box takes the line when the receipt goes, and its pause counts from then.
- **Set aside.** The line becomes the receipt, with no dropped keys. It stays until the detach key dismisses it. No box
  opens while it shows, and the hold on waiting boxes ends with it.
- **Waiting as a line, or behind another box.** It leaves the count, with no receipt, no bell, and no dropped keys.

When the session underneath ends while a box was open or asleep, the client keeps the terminal and drops keys until
500 ms have passed without a key, and only then ends the attach, so what the person was typing into the box never
reaches their shell.

### Who sees a box

- **The drawing client that has the writer role of the session underneath** shows boxes as described, attached to a box
  in `preview` while it waits as a line or is set aside, in `read` from the opening frame, and in `write` once keys
  count. A role change is a new attach stream; the client opens the stream in the new role first and closes the old one
  when the new reply has come.
- **A drawing client without that role** shows each box that takes keys as the line
  `… waits · another terminal has the keyboard`, attached in `preview`, with no backdrop. When it loses the role to a
  forced attach (`{"writer":"taken"}`), it turns an open box into that line in one frame and closes its stream to the
  box.
- **When another client has the box's own writer role** (a raw attach to the box, a sweep), the drawing client does not
  force it. The line says `… waits · controlled elsewhere`, and the client tries again when an event shows the box's
  writer gone.
- **A `--grab never` box** is painted by every drawing client, with or without the writer role, attached in `read`
  while painted and in `preview` while it waits behind an older one.
- The drawing client learns of a box from a `started` or `snapshot` event whose `status.over.id` is the attached
  session, and of its end from `ended` or `removed`. In a group attach, only the member in front has boxes; a box over a
  side session is not shown.

### Trust

Every process that can reach the socket can open boxes over a session and type into them with `key` and `do`, and every
session is told the socket's path in `TUPPET_SESSION_SOCKET`. A tool that shows boxes over a program it does not trust
must therefore keep that program away from the socket, from the terminal device of the box, and from tuppet's state
folder; attach with `--no-detach`; never open a `--grab now` box for something that program caused; and put no text
from that program into `--title`. [protocol.md](protocol.md#trust) states this for callers.

Against the program underneath, a box in a drawn attach guarantees that the program cannot paint inside the box or on
its border, cannot move or cover it, cannot give it a key, cannot take a key meant for it, and cannot learn what was
typed into it. Each rule above serves one of these: the program's output never reaches the terminal, box cells are
painted last at computed places, the cursor report proves the box is on the terminal before keys count, and the pause
and dropped keys keep keys meant for the program out of the box.

A box does not guarantee more. The program can paint something that looks like a box, a line, or a receipt; keys typed
into such a picture go to the program and answer nothing. It can ring the bell, raise notifications, and replace the
clipboard (`--pass` limits these), and it can choose which of the line's two places is used, by where it puts its
cursor. Accepted, and stated: a program can show a picture of a box and then cause the real one at the same place,
which the line-first arrival, the pause, and the dropped keys turn into a change the person sees, nothing more; a key
the person had already decided to press for the program can land in a box 500 ms after it opened; a terminal
multiplexer on the far side of a slow link answers the cursor report itself, before the person's own terminal has
painted; and the program's output is parsed in the process that holds the keyboard.

### Invariants

Tests check these on what the code does, not on how it does it: the painter against a second terminal model that
clusters graphemes and measures emoji otherwise, with random screens under a box (paint.zig); a model-based test of the
hand-over with random events and an oracle (boxes.zig); the input parser under random splits into reads (drawn.zig); and
tuppet run inside tuppet, comparing `view --styles` of the outer and the inner session after every step of `less`,
driven live, and of a recorded vim session (test/drawn.sh, test/scrollback.sh, test/boxes.sh, test/over.sh,
test/run_over.sh).

- The drawing client writes only cursor moves, colours and attributes, printable characters, links whose address
  passes the rule, the modes it chose, its queries, and on the normal screen the few more bytes that
  [Painting](#painting) lists.
- Every box cell lands at its computed column, whatever the cells of the session underneath hold.
- Box cells are painted last in every frame. Border text comes only from the caller.
- A box is shown whole or gets no keys. A change of its size or place runs the cursor report and the 500 ms again.
- No key reaches a `--grab pause` box before the cursor report for its frame and a further 500 ms without a key; none
  reaches a `--grab now` box before the report. Keys read before that report never reach the box, however late the
  client reads them.
- Each key, escape sequence, paste, and mouse report goes whole to one session. A paste never reaches a box whose
  program did not ask for bracketed paste.
- After an open or asleep `--grab pause` box closes, keys reach no session until 500 ms have passed without a key.
- A box that was set aside and comes back goes through the same hand-over.
- `run --over` exits with the program's own code only when the daemon recorded `held` (`shown`, for `--grab never`).
- Reading the output of the session underneath never delays the painting of a box, or input, by more than one frame.
- On the normal screen, every line the session moves to history reaches the terminal's scrollback once and in order,
  under a flood, an erase of history, a full reset, a box open across the program's screen switches, and resizes with
  the cursor at the bottom, above it, and hidden; and no text of tuppet's reaches the scrollback, apart from the stated
  exception of a window that shrinks.
- With `--pass none`, a clipboard write, a notification, and a link from the session or a box do not arrive.

## Play

`tuppet play` runs in the client, because playing a recording safely is terminal handling. It passes the recording's
output through the raw attach's filter (attach_filter.zig), so the terminal it plays into never answers a recorded
query, and it leaves recorded input out. It reads Space and q in every form that the recording's keyboard and mouse
modes make a terminal send, so the keys work whatever the recording turned on. Inside a session (with `TUPPET_SESSION`
set and the terminal at the session's size) it follows the recording's size with `resize` requests for that session;
elsewhere it plays as it is and says once when the recording is larger than the terminal. A recording that is not
trusted is safest played in a session of its own under a drawn attach, which paints only what tuppet's copy of the
screen holds.

## Groups, side sessions, and shell marks

A drawn attach can show a group of sessions one at a time, with a bar that names them and a switcher; give the session
in front a side session in a pane; keep a session alive only while its owner holds a lease; and follow a shell's prompt
marks, so text goes onto a prompt only when the shell waits there and nothing was typed since. Nothing here knows about
SSH, agents, or any caller; one session in front and at most one side pane is the whole layout.

### Members

The daemon keeps what a caller says about a session as a member of a group (member.zig) and reports it in the status
and the events; it acts on none of it. `run --group` and `update` set the group, a label, an accent, a mark, `meta`
values, and the actions the switcher offers; `flag` sets attention. Numbers are given under one lock, as the lowest
number no session of the group has, ended and stored sessions included, so an ended member that a window still shows
keeps its number until it is removed; moving to another group gives the next free number there. Member data lives in an
arena of its own per session behind a leaf lock (`member_mutex`), so a status taken under `terminal_mutex` can copy it,
and it is written to the session's metadata at every change. A program in a session can update its own session through
`TUPPET_SESSION` and `TUPPET_SESSION_SOCKET`.

Actions are objects (`key`, `name`, `confirm`, `choices`, `input`); the CLI parses its `KEY[!]:NAME[:A|B|?HINT]`
spec. Caller keys cannot be digits, `/`, `\`, `d`, `f`, or `h`, which the switcher uses itself. tuppet only reports an
action (`action` events with the key and a value); the caller does the rest.

A side session is tied to a running session by id (`run --side-of`); the session keeps the id of its running side
session and loses it when that ends. The status gives `side_of` on a side session, `side` on the session it is tied
to, and `side_view` on the side session.

### Respawn and leases

`respawn` does not restart a session in place, whose threads, pty, and store entry are built for one program. It starts
a new session seeded with the old one's screen and history (as a restored session is), with the old name, size,
alerts, colours, and member data; ties its side session to it; and removes the old one. A client sees `started` and
then `removed`, and the same number comes back under a new id; a group attach shows it in place of the ended member.
Its environment is exactly the one the request gives plus the session's own variables, so nothing leaks in from the
daemon's environment. A lease does not go along.

A lease is a connection the hang-up watcher keeps: the request's thread hands over a duplicate of its descriptor and
ends, so a lease holds no request slot and any number can be open. When the client goes, a session thread of its own
stops the session as `stop` does; the end of the session closes its leases. A caller that owns a session's lifetime,
such as a tool whose program must end when the tool ends while other sessions of the same daemon live on, holds its
lease (`run --lease` or `tuppet lease`). Leases need the hang-up watcher, which is Linux's; elsewhere the request fails
with `unsupported`.

For a daemon that a caller starts itself, `--idle-exit` applies the idle rule of an auto-started daemon (no programs
running, no clients or streams) after a minute, and `--keep-fresh` touches the socket's folder, the socket, and its
lock every hour, so that age-based cleaning of `/tmp` leaves a long-lived daemon alone.

### The group attach

`tuppet attach --drawn --group NAME` (group.zig for the bookkeeping, drawn.zig for streams and painting) shows the
group's members one at a time on the terminal's normal screen, the given session or the lowest number first. It follows
the events stream for every session: members, their boxes, and their side sessions; new members join live.

- **Streams.** It keeps one writer stream, to the member in front, a stream to the front's side session while that is
  shown, and the events stream. A switch closes the front's stream and opens one to the new front with `history_from`
  at the top row it last showed there, so the rows printed meanwhile reach the scrollback as on a reattach (at most
  4096 rows, with a note for what was left out), after a dim line `── NAME · HH:MM ──` (`switch_marks`). Only the front
  writes lines into the scrollback; a switch paints the new screen over the old one and pushes nothing out.
- **Sizes.** Every member is sized to the window minus the bar, and minus the pane while one is below, with `resize`
  requests only, so a writer that leaves never gives one its old size back, and a switch sends no resize. A window
  resize resizes every member at once. A member whose writer is another client keeps that client's size; in front it
  shows `typing in another window · Enter takes over`, and Enter takes the writer role.
- **The bar** is tuppet's own cells on the bottom row, from the moment the group has a second member, and it stays while
  the attach lives, so members are not resized when others come and go. A group of one has no bar: tuppet's line,
  notices, and an ended member's line show as in a plain drawn attach. The bar carries tuppet's line for boxes and
  notices, the front's name and the caller's label at its left end (inverted with the accent), and each member with its
  number, name, `password?` or `ended N` (`running` is left out as noise), the caller's mark, and `! TEXT` for
  attention; where they do not all fit, the front, those needing attention, and a count. The bar never reaches the
  scrollback: line feeds that push held rows out are written on the bottom row with the bar at most moving up, and
  before line feeds that push rows a resize may have pulled back, tuppet's own rows are erased.
- **Attention.** A member needs attention when a box over it waits, its program reads hidden input, it rang the bell
  since it was last in front, or the caller flagged it. A flag is cleared by the caller or when the member comes to the
  front. The bell rings once when a member not in front comes to need attention, unless `bell = false`.
- **Keys.** The switch key (F12) and the menu key (the detach key, another name for `detach_key`) open the switcher;
  with a box over the front, the menu key acts on the box as in a plain drawn attach. The menu key twice sends it to
  the program. In a group attach the menu key never detaches; the switcher's `d` does. Named keys (F1 to F12, Ctrl-X,
  `^X`, or a character) are matched in the legacy, xterm, and kitty encodings without modifiers, and a kitty release
  goes nowhere.
- **The switcher** is a panel at the bottom of the front's area: one row per member with its number, name, label,
  state, and last line, and a footer with the keys. Digits jump, `/` filters by name, arrows move, Space goes to the
  next member that needs attention, Enter goes, Esc stays, the switch key again goes back, `\` sends the switch key on,
  `d` detaches (not with `--no-detach`), `f` steps the selected member's side pane, `h` opens its history in `$PAGER`,
  and the caller's letters report actions, asking for a second press, a choice, or a line where the action says so.
  Letters do nothing for half a second after it opens, as the picker's destructive keys; the switch key, the menu key,
  digits, Space, Enter, Esc, and `/` always act. The caller's actions come before `d`, `f`, and `h` in the footer,
  which wraps onto rows above the bottom border when it does not fit, filled from the end so tuppet's own keys always
  stay on the border.
- **The hand-over.** Nothing changes the front but the person's keys. After a switch, and when the member in front
  ends, keys are dropped until the terminal answered a cursor report asked after the new picture (at the bottom left
  cell; after 2 seconds without an answer, keys count again), and the bar says how many were dropped. After the side
  pane went back to compact, keys reach the front only once they paused, so a double Enter on a card in the pane never
  reaches the front's prompt.
- **An ended member** stays in front with its last screen, dimmed, and the bar says `ended N · Enter close · r`. Enter
  or `x` removes it (the `remove` request) and goes back to the member in front before; without another member the
  attach ends with its code. `r` is reported as an action, for the caller to respawn it, and so are the caller's
  action letters; as in the switcher, an action on `x` comes first, and Enter still closes. `--end-with SESSION` ends the
  attach at once when that session ends, with its exit status.

### The side pane

A side session is shown with the session it is tied to while that is in front.

- **Placement** (`[side] layout`): `auto` puts the pane below the front with `rows` rows (8) when the window has at
  least 34 rows, else beside it when the front keeps `front_min` columns (100) and the pane gets `pane_min` (44), else
  only a strip in the bar, which shows the side session's last line. `below` and `side` pick that placement where it
  fits, else the strip; `strip` always uses the strip. Beside the front, the pane gets a third of the window, at least
  `pane_min` columns and never so many that the front keeps fewer than `front_min`, with a separator column.
- **Views.** The side key (F11) and the switcher's `f` step through `[side] sizes`, and `tuppet side --view` sets a view
  directly: `compact` keeps the keys on the front; `half` (the lower half of the area above the bar) and `full` (all of
  it) draw the side session over the front, which keeps its size underneath, and give it the keys. The side key from the
  last size, or Esc, returns to compact. On a member without a side session, the side key reports `side-requested`, and
  a caller answering it may start one at `half`, since the person's own key asked for it.
- **Resizes.** The front is resized only when the side session appears or goes. The side session is resized to its view
  at every step, as boxes are, and status and events report its current view (`side_view`), so its program can tell two
  views of the same size apart. A program in the side session can set its own view, for example back to compact after
  acting.
- **Scrollback.** With the pane below, the front's rows leave above the pane as usual. With the pane beside, the attach
  uses the alternate screen, since rows would carry the pane's cells into the scrollback, break long lines, and let a
  mouse selection run across both.

### Shell marks and the prompt guard

The session's stream handler (ptyio.zig) passes each OSC 133 mark to marks.zig after Ghostty applied it, under
`terminal_mutex`. tuppet takes the marks as they come and checks nothing about who printed them. The state:

| State | Meaning |
| --- | --- |
| `shell` | `prompt` after B of a primary prompt and before C; `running` after C and before D or A; else `unknown`, also between a command's end and the next primary prompt |
| `prompt_seq` | Counts each B of a primary prompt; continuation prompts do not count |
| prompt position | Where input starts (at B), a tracked pin that moves with scrolling and reflow |
| prompt input seq | The session's `input_seq` when B arrived |
| `last_exit` | The code from the last D |
| `paste_mode` | Whether the program turned on bracketed paste (mode 2004) |

The last 50 commands are kept: the command line from B to C (up to 4 KiB), the last 64 KiB of the output from C to D
(at most 4096 rows), and the exit code. Text between a pin and the cursor is read with Ghostty's formatter. Commands are
kept while the session is in memory; one loaded back from the store has none.

The `prompt` guard of an input batch is checked under the write lock with the other guards. It takes exactly one
`paste` step and holds only if `shell` is `prompt` and `prompt_seq` equals the caller's; nothing was written since the
prompt appeared (`input_seq` equals the prompt's); the session is on its normal screen; `paste_mode` is on; and the text
is one line of printable characters of at most 4 KiB. The text is then written wrapped in bracketed paste, never with
Enter or any control key. Otherwise nothing is written, and the reply names the condition that failed. A shell redraws
its prompt on a resize, which may advance `prompt_seq`; callers read it again and retry once.

## tuppet start

`tuppet start ID` opens a session, brings it to a known state through steps kept in a file, and hands it over by
attaching. It was built for logins through hops, and serves any automation of the shape "open a session, bring it to a
known state, hand it over": a database console, a dev server, an installer. Branching, loops, and coordination of
sessions stay in scripts, which run `tuppet start -d` and act on its exit status. The syntax is in `tuppet help start`;
this section gives the rules behind it.

All of it runs in the CLI (start.zig reads the file, start_run.zig runs it, start_record.zig records), through the
requests `run`, `input` with `until`, `wait`, `view`, `list`, and `stop`. Its only needs in the daemon are conditions
that any client can use: `typed`, `past_input_line`, and `regex` (see [Matching semantics](#matching-semantics)). Steps
that need them check the daemon's hello features `echo` and `regex` at run time, and an older daemon makes the start
fail with a hint to restart it; `--check` never asks the daemon.

### The file

The file is `$XDG_CONFIG_HOME/tuppet/start`; `TUPPET_START` names another, and an empty `TUPPET_START` reads none. It is
not config.toml: that file's parser takes one line per value, and an older tuppet refuses a config.toml with a section it
does not know.

Its steps type commands into shells that may be privileged, so tuppet refuses the file when another user owns it or
when group or others may write it, checked on the opened file (so on the target of a symlink). The recorder creates it
with mode 0600 in a directory of mode 0700. The file never holds a password, includes no other file, and runs no
command.

- A block starts with a header at the left margin (`start ID...`, `steps NAME [PARAM | PARAM=DEFAULT]...`,
  or `group NAME ID...`, a block of one line). Its lines are indented by any amount; only a `when`'s answer
  needs to be deeper. A line is a keyword, optional parameters in parentheses right after it (`expect(30s)`,
  `expect(re, 30s)`), and the rest of the line as literal text, trimmed. A value in double quotes keeps spaces at its
  ends; inside it only `\"` and `\\` are escapes, and any other backslash is an error. `expect (30s) left` is an error
  that says to write `expect(30s)` or quote the text, while `(venv) ops@host` is plain text. A comment is a line whose
  first non-blank character is `#`; a `#` later in a line is text, so `send echo # x` types it.
- `%i` (also `%{id}`) is the id that was started, `%{name}` a parameter, and `%%` a `%`. Any other `%` is itself, so a
  zsh prompt ending in `%` needs nothing, and `%{...}` is the only form that will ever be added. In a regex value,
  substituted text is escaped so it matches as written. An argument of `use` is expanded where the `use` stands and put
  in once, never read again for `%`.
- `start` takes ids or patterns with `*` and `?`; an exact id goes before a pattern. An id must be usable as a session
  name. A group's ids must be exact ids that a start block answers; a group shares the ids' namespace, never names a
  session, and `use` cannot name it.
- `use NAME [ARG...]` puts a steps block's steps at that place, or those of a start block with a single id and none of
  the settings `command`, `dir`, `size`, and `timeout`, so a jump host that is started on its own can also open other
  logins. Blocks may use blocks up to 8 deep; a cycle is an error.
- `fail TEXT` adds a failure text. At the left margin before the first block it applies to the whole file; in a block's
  settings to that block's checks and to those of the blocks it uses, since more failure texts only stop a run sooner;
  right under a check, to that check alone. `nofail` applies to the block's own checks only, so a block cannot quiet the
  failures of a block it uses.

Only structure is refused, on the steps as `use` puts them together: `or` follows an `expect` (or another `or`) of the
same block; `when` is followed by its answer; `secret` follows the `expect` of its prompt or answers a `when`; `fail`
stands at one of its three places; `ended` is the last step; `use` names a block, without cycles, at most 8 deep; ids
and names are unique; a regex compiles. A broken block other than the one started gives a warning; the started one fails
with the file, line, and chain of `use`. `--check` also notes, without refusing, loose checks: an `expect` text that is
part of an earlier hop's prompt (which that prompt coming back would meet) or of the hop's command (`ssh db1` with
`expect db1`, which an error naming the host would meet), a password prompt whose command has no check before it, a
`when` that no check or pause watches for, and a ` #` inside a text.

### Running the steps

- **Checks** (`expect`, `or`, `gone`, `settle`, `ended`) wait for something new after the input, with the block's
  `timeout` (10 s by default) or the time in parentheses, at most 10 m. Every check carries the text its input typed
  as `typed`, so the echo never meets it; a password and keys carry none.
- **Checks are optional.** An input without one is followed by a pause: `settled` 300 ms with `past_input_line`, so
  the change must be below the input's line, with a 2 s deadline, and the run goes on either way. The pause does not
  wait for a command to finish; a program that prints all the time costs the full 2 s, and a pager takes the next input.
  `tuppet help start` advises an `expect` after each command that changes where input goes (ssh, sudo, su).
- **The first input waits for the program.** Typed early, a line editor draws its prompt again after the input, where a
  `fail` line for it would match. So the first input of a run in a session it started waits for `settled` 300 ms since
  the session's `start_seq`, then reads `status.tty`: out of canonical mode (readline, zle, fish, Python's REPL, curses
  programs switch just before their prompt) the program is ready. Still canonical, it waits for another settle, or for
  `idle` 1 s, which means a program that reads whole lines (dash, `read`) and is ready too. Quiet before any output does
  not count, so a shell still reading its startup files is not taken as ready. After 5 s it types anyway and says so;
  without `tty` (Windows) the first settle is enough. Nothing shows when the remote shell behind `command ssh host` is
  ready, so such a block starts with an `expect` of its prompt, as `--record` writes it.
- **`when TEXT`** answers a question that only sometimes comes (ssh's about a new host, sudo's password prompt, an
  installer's "Overwrite?"). It applies to the checks after it up to the next input of its block, never to a used
  block's, and to the pause of an input right before it; first in a block, from the program's start. When TEXT appears
  anew after the input, the run waits for output to pause and types the answer, once per input. Its conditions go
  before the check's in the wait, so a question that shows in the same pass as the check's text is answered first;
  after an answer the checks count from the answer. The run prints a line when it answers.
- **Failing fast.** Every check also fails the run when a failure text appears anew after the input, or when the session
  ends (except for `ended`). The built-in failure texts are English messages of ssh, sudo, and shells (`Permission
  denied`, `Connection refused`, `Host key verification failed`, `Sorry, try again`, `command not found`, and others;
  `--check` lists them); a bare `nofail` turns them off. A failure text that is part of the input before the check, or
  of the check's own text, is left out for that check. So a check waits out its timeout only when nothing it knows comes,
  and the message then says whether there was no output at all or output without the text.

### Passwords

A password goes only to the prompt it was meant for. Before typing it, the run waits for the output to pause (300 ms, at
most 2 s), and the prompt's text must be on the cursor's line. It is then typed in a batch with `require` guards that
the daemon checks under the write lock: nothing typed into the session since that moment, and no writer attached. So a
key login whose banner says "Reset your password:" gets nothing, and the run stops with exit 5. Whether the terminal
hides input is not asked: behind ssh it never tells, and the cursor's line is the guard that holds everywhere. When the
person typed the answer on tuppet's terminal, the prompt line is read again before typing, in case the prompt timed out
meanwhile.

`secret $VAR` reads a variable, and the variables that secrets read are left out of the session's environment. Without a
value, or with the variable unset or empty in a terminal, tuppet asks on the terminal without echo, quoting the
session's prompt line. Secret values are masked in everything tuppet prints. A secret that is asked once is typed into
every later session of the same run that reads that variable, once the check after it was met; one that fails is
dropped and asked again.

### Sessions and outcomes

- A new session is named after the id. When a running session has that name, in a terminal tuppet asks whether to
  attach to it or start another; otherwise, and with `--new`, it takes the next free name of `ID-2`, `ID-3`, and so on.
  It never types into a session it did not start.
- A start that does not finish leaves the session's `input_seq` in a `start-failed` file of the session's store
  directory. The next start of the same id replaces that session (the daemon's `if_exists` `replace`) while its
  `input_seq` is unchanged and no client is attached, so running the same start again finishes what did not. Only the
  plain name is replaced, never `ID-2`, and not with `--new`.
- In a terminal one line on stderr shows the step, its time against its timeout, and the session's current line, with
  secrets masked. Ctrl-C stops the steps and attaches; keys typed meanwhile are dropped before the attach. When the steps
  are done, it attaches; outside a terminal, and with `--detached`, it prints the session's id instead.
- When a step fails, the report gives the step as written and as expanded, its file and line with the chain of `use`,
  what it waited for and why it stopped, the session's last lines, how many inputs before it had no check, and a `when`
  text on the screen that did not fire because it came before the input. In a terminal it then offers to attach, to
  open the file in `$EDITOR` at that line, or to stop the session; otherwise it exits with 1 (a failure text, or `ended`
  with another status), 3 (a timeout), 4 (the session ended), or 5 (nothing was typed for safety), and the session keeps
  running.
- Several ids, or a group, run one after another in one process, and none is attached. The steps of every id are put
  together first, so a broken block opens no session. A session that runs already is kept, and one whose start did not
  finish is replaced, as above. At the end tuppet prints the ids of the sessions that run and exits with the code of the
  first that failed, or 130 after Ctrl-C. A session the daemon refuses to open counts as a failed id with code 1. With
  `--atomic`, the first failure or Ctrl-C ends the run and stops every session it opened, so either all of those run or
  none; sessions it found running are left alone.

### tuppet do --use

`tuppet do SESSION --use NAME [ARG...]` runs a block's steps in a session that runs already, for a script that repeats
steps in a session it opened. The arguments are taken as given, without a second split, and `%i` is the session's name.
The block must start with an `expect` of the prompt it is used at, since nothing typed it. Before anything is typed, that
prompt must end the cursor's line once output pauses, and the terminal must not read hidden input: a line someone began
to type, or a command still running, stops the run with exit 5. Every input requires that nothing else was typed since
the one before; `--unless-attached` adds that no writer is attached. The session is never stopped.

### Recording

`tuppet start --record ID [-- COMMAND...]` starts COMMAND attached and records while the person does the steps by hand;
the detach key ends the recording. tuppet then shows the block it wrote and asks whether to append it, edit it first, or
drop it. The session records a trace into a file in tuppet's private runtime directory that is unlinked as soon as it is
open, so typed passwords never stay on disk and are never written to the start file. The recorder appends only, and
refuses an id the file has.

- `expect` with the prompt shown when the person starts typing; for each Enter, the command (the person's keys when
  they were printable text only, else the cursor's line at Enter without the prompt), then `expect` with the next
  prompt as the screen shows it.
- A line is a password, written as `secret` with no value, when the daemon saw hidden input, when the screen did not
  change while it was typed, or when its prompt asks for one (`password`, `passphrase`, `passcode`, `PIN:`). A line
  typed in one go with its Enter at an unchanged prompt is a command only when its echo follows.
- Under each `expect` whose prompt differs from the one its command was typed at (and neither holds the other), a `fail`
  with that earlier prompt, so a hop that drops back fails at once.
- `use NAME` when the first steps are those of a block without parameters whose steps are only inputs and plain
  `expect` lines.
- ssh's question about a new host key, answered `yes`, as a `when` with a `# CHECK:` comment that it accepts new host
  keys; sudo's password prompt followed by a password, as a `when` with a `secret`, since sudo asks only when it has no
  password cached.
- A time on a check only for one that took more than a third of the default timeout: three times what it took, rounded
  up to seconds.
- A step it is unsure of (a failure text in the output, a paste, keys that edited the line so it no longer starts with
  the prompt, a command or prompt it could not read) gets a `# CHECK:` comment saying why, and so does a block the file
  would not accept. The block is not appended while any is left.

## Memory limits

### Fixed limits

limits.zig holds the fixed limits: 1..1000 cells on each side, history of at most 1 GiB per session (8 MiB by
default), and 128 MiB for one PNG render. Every terminal is made by `newTerminal`, which refuses anything else, so no
caller can skip the check.

Stored files are input like requests. `store.checkMeta` turns a size outside the limits, a seq above 2^62, a time that
is not one, malformed hits, a recording path that is neither absolute nor a plain file name, or an id other than the
directory's into a `damaged` session; so does a missing or oversized `screen.vt`. A damaged session is listed with the
reason, never loaded, and removable. Damaged sessions expire like others; one whose `session.json` does not parse
counts as ended when that file last changed. A stored history limit above 1 GiB is lowered. Seq marks and ids above
2^62 count as damaged and fall back to what the directories show. The stored screen is read in 64 KiB pieces, and
Ghostty's history limit bounds what stays.

### The budget

The daemon keeps all its sessions within one memory budget, `TUPPET_MEMORY`: a quarter of the machine's memory or of
the daemon's cgroup limit, whichever is less, and at least 512 MiB. The budget charges screens and history. tuppet
does not store Kitty graphics images.

- **Screens.** Each session reserves its floor, `limits.sessionFloor` (both screens and Ghostty's spare page, in
  Ghostty's 372 KiB pages), before its terminal is made, grows, or loads, and is refused with `limit` when the floors
  of all sessions do not fit. A refusal therefore depends on sizes only, and Ghostty, which panics when an allocation
  fails mid-resize, never sees one fail. Before refusing, the daemon unloads idle ended sessions. A writer's detach
  restores the old size even over the budget.
- **History.** History is charged as Ghostty allocates it, from its pages' `page_size`, read after each chunk of
  output, a resize, or a load. Past the budget, `registry.trimHistory` first unloads ended sessions the store has in
  full, then lowers the history byte limit of the sessions that keep the most to one common level and has Ghostty drop
  their oldest pages. That frees memory without allocating, and the lowered limit makes those sessions reuse their
  oldest page instead of growing. Their status shows `history_trimmed`.
- A trimmer thread does the trimming, so reader threads never wait for it. It trims to a margin below the budget: 1/16
  of the budget, or half of what the floors leave when that is less. Limits come back, checked every 10 s, once use is
  four margins below the budget, so trimming does not run on every page. Between two charges, use can pass the budget
  by what one chunk of output allocates, several MiB for a chunk of empty lines.
- **Compression.** Once a second, a compressor thread has Ghostty compress the cold history of each session that has had
  no output for 500 ms (`Session.compressIdle`), where Ghostty can drop the memory behind a page (64-bit Linux, macOS,
  Windows, and FreeBSD). It works in bounded steps that only take a free terminal lock, with a 1 ms pause between them,
  since the lock is not fair, and stops once someone else holds the lock. Reading a page decompresses it without
  counting as activity for Ghostty, so a session is compressed again also after a request released it. The budget keeps
  charging `page_size`, the uncompressed size: a resize decompresses every page.

Reserving each session's full history up front (8 MiB at the defaults against about 2.5 MB typically used) would
refuse sessions while memory is free, which is why only screens are reserved.

### Ended sessions and streams

- Ended sessions whose results are in the store, hits included, leave memory 30 s after their last use. A reload
  stamps every row with the last seq, as after a daemon restart.
- Ended sessions whose store directory is gone (another daemon's shorter `TUPPET_KEEP`, a deleted store) leave memory
  and the list within 10 s. The next change recreates a deleted store, and new ids skip those the daemon holds.
- Attach output queues hold at most 4 MiB per client and 64 MiB for all. Past the total, a client more than its share
  behind ends with `too_slow`, and a new attach fails with `limit`.
- An attach that asks for history gets at most 16 MiB of its rows, formatted under the terminal lock with the first
  screen, and numbered by the tracker's count of rows that scrolled into history; where that count cannot follow the
  rows, a request for rows from a number on gets fewer rather than one it had.

## Diagnostics

These features help a client check how a program draws, especially across terminal sizes, without the daemon judging
a layout.

### View styles

`view` with `styles` (CLI `view --styles`, plain format only) adds the style that covers the most cells of the screen,
`base`, and runs of the cells whose style differs from it, blank cells included. Runs never split a wide character or
cross a row, carry the full attributes, and are bounded by the reply budget. The exact shape is in
[protocol.md](protocol.md#view). The CLI prints `base:` and then one line per run with only the keys that differ from
`base`.

### Redraw counters

Status carries `out_bytes` (raw bytes from the pty), `draws` (settles of program output that took a seq), and
`full_clears` (ED 2, kitty's ED 22, and ED 0 with the cursor at the top left cell; ED 3 erases only history and does
not count). They are kept out of the facts that events report, so they add no frames. `draws` depends on timing: a
frame written with a pause in the middle counts twice. `--stats` on `wait`, `do`, and `run` prints the deltas over the
condition's window plus `rows_changed` and `first_change_ms`, computed by the client from status before and after the
request, so they are approximate.

### Resize steps

`do --resize WxH` is a step of its own. Conditions after it count from its `resize_seq` rather than the latest input,
until the next input step. A resize that leaves the size as it is sends no SIGWINCH, so nothing would come: the step
reports `same size`, a condition step right after it is met by that, and later conditions count from the latest
input. The `resize` request takes `require.unattended`, so `--unless-attached` is checked by the daemon and is not a
check-then-act race.

### Sweep

`tuppet sweep` resizes a session through a list of sizes and reports, size by size, what the program drew and where
the texts it was asked to find sit. It runs in the client and reports facts; it never judges a layout. The options and
the report format are in `tuppet help sweep`.

- **Writer attach.** The sweep attaches as the writer with the label `sweep` and resizes through attach frames, so the
  daemon restores the size when the stream ends for any reason, also when the sweep is killed. An attached writer
  always refuses the sweep (exit 5); it never takes one over. Viewers or previews refuse it too, unless `-f` is given.
  The 20x5 floor applies to live sessions and is lowered with `--min-size`. The sweep never acks. Meanwhile other
  writers and `do --unless-attached` are refused, and a forced takeover aborts the sweep with a partial report.
- **Interference.** Every step checks that `input_seq` is unchanged and that `status.resize_seq` is its own; otherwise
  the sweep stops with a partial report that names the interference. Attach `resize` frames carry the reflow's seq, a
  failed resize arrives as an error frame, and any `end` frame aborts with a partial report saying why. Bytes are
  counted from `out` frames after the sweep's own `resize` frame, so they are exact.
- **Per size.** Resize, wait until settled since the `resize_seq` within the deadline, and read the view (with styles
  when saving). Just before the next resize, a `view --since` the read's seq marks the size `late` when anything
  changed. A size whose program wrote bytes and then stayed quiet ends early as `unchanged, wrote B bytes`, so
  identical redraws do not pay the deadline.
- **Finds.** Positions are 1-based cells using Ghostty's width table. A find is `at`, `absent`, `prefix` (the full text
  is absent, and its longest prefix of at least max(3, half) characters sits on the same row at the same distance from
  the left or right edge as at the neighbouring size), or `split` (the first part is at its previous position and the
  rest continues at the first non-blank cell of the next row). `stale` is a flag: the find's row did not change after
  the resize, so it shows the terminal's leftovers, not the program's layout. A find absent at the start size is a
  warning, not a refusal.
- **Report.** Consecutive sizes collapse while every fact is equal; a find whose column and right distance both move
  still collapses and prints `moves`. After the table come the way back (the baseline, read twice before the sweep,
  compared with the screen after it, excluding rows that change on their own), the hits, bells, and notifications the
  sweep caused, and a footer of what was not checked. There is never an all-clear. The sweep prints an estimate
  first and stops at `--max-time` (90 s by default) with a partial report.

## Known limits

- Transitions shorter than one evaluator pass (about 50 ms) can be missed by bundled waits.
- `clear` or Ctrl-L redrawing the prompt in place within one settle looks unchanged to `after_input`.
- An identical redraw inside one read chunk is invisible. With a scrollback of 0, or when history drops rows before a
  check, rows are counted as `lost` rather than checked.
- Alerts on a line that a program blanks and redraws across settles fire again.
- In a sweep, program-drawn identical frames read as `unchanged, wrote B bytes`; text that the program wrapped other
  than at the row end reads as `absent` or `prefix`; breakpoints between samples can be missed without `--refine`;
  results on the primary screen reflect Ghostty's reflow; live programs such as htop mostly report `still changing`
  and need a short `--settled`; slow redrawers need a longer `-t`.
- Only Linux is tested at runtime. macOS and Windows binaries are built by the release, and test/static.sh checks that
  the built binaries are self-contained.
- A drawn attach paints what the person's terminal can show: xterm shows no curly or double underline and no faint
  backdrop (the backdrop takes a color instead when the terminal tells its colors), and kitty reverses a run of
  right-to-left letters within its cells, since it ignores `CSI 8 l`. Every cell stays in its column in xterm, kitty,
  alacritty, VTE, and tmux (test/tmux_compare.sh checks tmux by hand; the others were compared by screenshots, not by
  a repeatable test).
- A drawn attach shows no pictures, since sessions store none, and nothing else the screen model does not hold. There
  is no attach on Windows.
- On the normal screen, lines may repeat in the scrollback at a resize. A frame that the terminal applies after a resize
  it did between tuppet's read of the size and the frame can still paint over a row it took back, or, after a shrink
  during a flood, write held lines below its new bottom row. A window that shrinks can move tuppet's own line, or a
  `--grab never` box, into the scrollback before tuppet repaints, and on a terminal that adds blank rows at the bottom,
  a growth can push blank rows into it.
- The program's output is parsed in the client process that holds the keyboard; there is no separate parser process
  for sessions whose program is not trusted.
- A box is always a new session started with `run --over`; a session that already runs cannot be shown as a box. Boxes
  over a side session are not shown in a group attach.
- Programs see tuppet's answers to questions about the terminal (cell size, and colours for a session not started by
  a drawn attach), not the person's terminal's.
- Leases work only on Linux, where the hang-up watcher runs.
- The prompt guard does not cover output still on its way from a remote host when it is checked; that is harmless,
  since no Enter follows the text.
- `tuppet start` replaces a session whose start did not finish only while its `input_seq` is unchanged, but input that
  comes between that check and the replace is lost with the session; closing that window would take a daemon guard on
  the replace. A program that prints nothing before reading input makes the first input wait the full 5 s.

## Out of scope

tuppet deliberately does not provide these:

- Backtracking regular expressions, application parsers, or "agent done" heuristics in the daemon; rules that type;
  matching on the raw output stream; a daemon-side display filter (boxes and groups are composed in the client);
  checking who printed an OSC 133 mark.
- Alert rules that span sessions or outlive one (the CLI's default list in the config file covers the common case).
- Layouts beyond one session in front with at most one side pane and a box over it, a prefix key while attached, copy
  mode (history opens in `$PAGER` instead), a history view that tuppet paints (Shift-PageUp reaches a program in only
  some terminals, and taking the wheel would cost plain mouse selection everywhere), and window title writes.
- A question command built into tuppet, a scripting language, boxes over boxes, boxes in a raw attach or in the viewer,
  cell coordinates or other places for boxes, and key bindings beyond the detach (menu), switch, and side keys. A box
  runs any program, and a shell binding with `$TUPPET_SESSION` opens one.
- Branching, loops, and several sessions in one start block; scripts run `tuppet start -d` and act on its exit status.
- A client attached to a daemon on another machine through a relay.
- Storing the environment of a session; `restart` uses the current environment.
- A ring buffer of its own (Ghostty's page list already reuses its oldest page), history spilled to disk (use
  `run --record`), compression as a memory limit (a resize decompresses everything), and `setrlimit` (it counts
  address space and is inherited by programs).
- Sweeps in the daemon, rectangle masks, layout verdicts, widget detection, keymap fuzzing, and deterministic clocks.

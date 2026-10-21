# tuppet design

This document explains how the tuppet daemon tracks screen changes, matches text, raises alerts, keeps its memory
bounded, and supports layout diagnostics, and why it works that way. It is for people who maintain tuppet. The wire
format of every request and reply is in [protocol.md](protocol.md), the commands and their options are in `tuppet help`,
and the [README](../README.md) covers installing and using tuppet.

## Principles

1. State lives in a session's status. Reads never change state. Events report status changes, lifecycle, and alert
   hits.
2. The daemon evaluates only exact, cheap things. Regular expressions and judgment stay in clients, and the daemon never
   types into a session on its own.
3. One condition vocabulary and one evaluator serve waits, bundled waits, recordings, and alerts.
4. Everything is bounded. Nothing on the output path waits for a client or renders the full screen.
5. One resolver (names.zig) turns session references into sessions, in the daemon. The CLI and the protocol use the
   same words, and the CLI has no flag aliases.
6. tuppet never promises what it cannot observe, such as an identical redraw inside one read chunk, or rows lost with a
   scrollback of 0. Where it cannot tell, it says so (`lost`, `unknown`, `-`).

Durations take a unit everywhere, also in environment variables (`500ms`, `5s`, `2m`); `0` alone is allowed. Exit
codes mean the same in every command; the README lists them.

## Source map

| Module | Role |
| --- | --- |
| track.zig | Change tracking: settles, row hashes, seqs, scroll measurement, the input snapshot, alert masks. |
| cond.zig | Conditions and the text scan they are checked against. |
| evaluator.zig | The per-session thread that answers waits, samples the pty, finds event changes, writes trace frames, and takes alert hits. |
| alert.zig | Alert rules and the hit log. |
| names.zig | Session names and the references that pick sessions. |
| batch.zig | Input batches and their guards. |
| attach.zig, events.zig | Attach streams and event streams. |
| limits.zig, budget.zig | Fixed limits and the daemon-wide memory budget. |
| registry.zig, store.zig | The session table, loading and unloading ended sessions, and the on-disk store. |
| styles.zig, sweep.zig | View styles and `tuppet sweep`. |
| picker.zig | The session picker and its viewer. |

## Change tracking

Each session's reader thread parses the program's output and then settles the terminal. It settles once the pty is
drained, bounded by 20 ms or 1 MiB after the first unsettled chunk, and once synchronized output (mode 2026) is off,
bounded by 1 s. A settle runs under the session's `terminal_mutex`:

- It hashes each dirty row of the active screen twice: a full hash (codepoints with graphemes, resolved style, wide
  flag, hyperlink) and a text-only hash. The rows of the cursor are always hashed, because Ghostty does not mark a row
  dirty when a combining mark joins a cell left of the cursor.
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
- With `since SEQ`, the text must lie on a row that changed after SEQ. A client that matches by its own rules, such as
  a regular expression, uses `since` and checks the text itself.

The other conditions:

- `idle DUR`: no text change for DUR, measured from the last text change. It is clamped to the wait's start only with
  `after_input` or `since`.
- `settled DUR`: the text or a style changed after the start point (`since`, the input, a `do --resize` step's reflow,
  or the wait's start), and then the text stayed unchanged for DUR with no output pending on the pty or held back by
  synchronized output. Quiet is measured on text, not bytes, because a blinking cursor or a clock would never let bytes
  settle. A silent pause, such as a clear followed by a draw 300 ms later, is not caught by the condition; the sweep's
  late check catches it.
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
looks like.

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
  because whoever stopped it knows.
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
  restore applies even when the memory budget is full.
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

## Picker and attach

- Rows are listed newest first in a stable order. The first selection is the newest running session, and when a row
  disappears its neighbour is selected. STATE shows one word, chosen by priority: damaged, failed N, lost, password?,
  an alert name, bell, stopped, done, quiet (with its age, such as `quiet 3m`), running. Hit and bell words show only while unseen. Narrow terminals drop COMMAND,
  then AGE, then truncate names; below 20x5 the picker says the terminal is too small. Glyphs have ASCII fallbacks,
  and `NO_COLOR` is honored.
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
- While attached, only the detach key is taken. Another session gaining a mark rings the local bell once, unless the
  config turns that off. tuppet never writes the window title.
- Attaching from the picker stays on the alternate screen, and a session that exits meanwhile returns to the viewer
  with its final screen. A direct `tuppet attach` stays on the normal screen. History is one key away (`o`, which
  opens it in `$PAGER`).
- Bare `tuppet` opens the picker only when stdin and stdout are terminals. Otherwise it prints usage to stderr and
  exits 2, so a script or an agent reading through a pipe never gets a full-screen program. On Windows it always prints
  usage.

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

Reserving each session's full history up front (8 MiB at the defaults against about 2.5 MB typically used) would
refuse sessions while memory is free, which is why only screens are reserved.

### Ended sessions and streams

- Ended sessions whose results are in the store, hits included, leave memory 30 s after their last use. A reload
  stamps every row with the last seq, as after a daemon restart.
- Ended sessions whose store directory is gone (another daemon's shorter `TUPPET_KEEP`, a deleted store) leave memory
  and the list within 10 s. The next change recreates a deleted store, and new ids skip those the daemon holds.
- Attach output queues hold at most 4 MiB per client and 64 MiB for all. Past the total, a client more than its share
  behind ends with `too_slow`, and a new attach fails with `limit`.

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
- Only Linux is tested at runtime. macOS and Windows binaries are built by the release, and test/static.sh checks that the built binaries are self-contained.

## Out of scope

tuppet deliberately does not provide these:

- Regular expressions, application parsers, or "agent done" heuristics in the daemon; rules that type; matching on
  the raw output stream; a daemon-side display filter; OSC 133 prompt marks.
- Alert rules that span sessions or outlive one (the CLI's default list in the config file covers the common case).
- Panes, a prefix key while attached, copy mode (history opens in `$PAGER` instead), and window title writes.
- Storing the environment of a session; `restart` uses the current environment.
- A ring buffer of its own (Ghostty's page list already reuses its oldest page), history spilled to disk (use
  `run --record`), compression as a memory limit (a resize decompresses everything), and `setrlimit` (it counts
  address space and is inherited by programs).
- Sweeps in the daemon, rectangle masks, layout verdicts, widget detection, a replay engine, keymap fuzzing, and
  deterministic clocks.

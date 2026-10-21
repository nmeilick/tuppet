# tuppet daemon protocol

This document describes the protocol a program uses to drive the tuppet daemon directly, without the CLI. It covers
protocol revision 2, as reported by `hello`. A client checks `hello` first (see [Versioning](#versioning)).

## Transport

The daemon listens on a unix socket: the path given to `tuppet daemon --socket PATH` or `TUPPET_SOCKET` (supervised
mode), otherwise `$XDG_RUNTIME_DIR/tuppet-<uid>.sock`, or `/tmp/tuppet-<uid>/tuppet.sock` when `XDG_RUNTIME_DIR` is
unset or empty. The socket is mode 0600, with a lock file `<path>.lock` beside it that makes the endpoint exclusive. The
daemon refuses peers running as another user, and the CLI refuses a daemon running as another user. On Windows the
endpoint is the named pipe `\\.\pipe\tuppet-<user SID>`, and `attach` is not available.

Each message is one line of UTF-8 JSON ending in `\n`. A client connects, sends one request line, reads one reply line,
and closes. `run` and `input` with `until` reply with a second line, and `attach` and `events` are the exceptions: after
their reply the connection becomes a stream (see [Attach streams](#attach-streams) and [events](#events)).

## Sessions and ids

All daemons of a user share one session store per machine and boot (see `tuppet help daemon`). Ids count up from 1 after
each boot and are never reused within it, so a session is identified by the boot and its id; `hello` reports the boot. A
[shutdown](#shutdown) with `reset` starts the ids over and changes the boot that daemons report. A
daemon serves the sessions it started, including ended ones: their final screen and exit status survive the daemon, and
a later daemon on the same endpoint serves them again. An id that belongs to another endpoint, or to a session lost when
its daemon died, gets an error that says so.

Replies carry ids as numbers (`"id":3`). Requests pick sessions by reference, a string:

- an id, digits only (`"3"`);
- a name (`"build"`), given with `run`: it starts with an ASCII letter or digit, continues with letters, digits, `.`,
  `_`, and `-`, has at most 64 characters, and is not all digits;
- a pattern (`"ci-*"`), in which `*` matches any run of characters and `?` one character. An unnamed session's name is
  empty, so `"*"` matches it too.

The daemon resolves references itself, once per request. A request about one session takes `"session":REF`, which
must pick exactly one: a name or pattern that picks none fails with `no_session`, one that picks several fails with
`ambiguous` and lists them. Requests about several sessions take `"sessions":[REF, ...]`: each session counts once,
however many references pick it, in the order the references pick them. A pattern there picks only the sessions the
request applies to (`stop`: running ones; `remove`: ended ones), while an id or a name picks its session whatever its
state, and the result explains a mismatch.

A daemon started without `--socket` exits after 30 seconds with no programs running, no open waits or event streams, and
no clients (`TUPPET_IDLE_EXIT` in its environment changes that; Windows daemons do not exit when idle). Exiting closes
its listener, which resets any connection that was still waiting to be accepted; the daemon never read that request, so
a client that gets a connection reset before any reply may send it again, to a new daemon. A daemon that is shutting
down (see [shutdown](#shutdown)) fails every request but `hello` with `stopping`; a client waits until nothing answers
on the endpoint and sends the request again, which on the default endpoint starts the next daemon. When the next daemon
reports another `boot`, the store was reset meanwhile, and a request that names sessions by id or name is not sent
again.

## Limits

- A request line may be at most 1 MiB, and a reply line at most 16 MiB. A client that closes its side of the
  connection after the request may leave out the request's newline.
- The request line must arrive within 10 seconds of connecting.
- The daemon serves at most 32 requests at once; further connections wait in the listen queue until a slot frees up.
  Attach streams do not count toward that limit; there can be at most 256 of them in total. While their clients have
  64 MiB of output waiting to be read in all, an attach fails with `limit`.
- Waits (`wait`, and `run` and `input` with `until`) and event streams do not count toward the 32 either once they
  wait; at most 256 of them can be open at once, and one more fails with `limit`. A wait waits at most 10 minutes.
- An `input` batch has at most 1024 steps and sleeps at most 2 seconds; see [input](#input).
- The `sessions` list of `list`, `stop`, `remove`, `ack`, and `events` takes at most 1024 references; a longer one fails
  with `limit` before any session is touched.

## Requests and replies

A request is an object with `cmd` and the command's fields. The daemon parses it strictly: a field it does not know,
also inside a nested object, fails the request with `bad_request` and an `err` that names the field, such as
`"bad run request: unknown field 'record.pathx'"`. A missing required field or a value of the wrong type is named the
same way. Clients check `hello` before they use a field or command that a later release adds.

Replies may gain fields, and clients must ignore fields they do not know. Replies carry all of their fields, with
`null` where there is no value; the examples below shorten them with `…`.

A request succeeds with `{"ok":true, …}`. A reply about one session also carries that session's `status` (see
[Status](#status)), taken after the request did its part.

A request fails with:

```json
{"ok":false,"code":"no_session","err":"no session named 'build'","status":null}
```

`code` is for programs to act on, `err` for people; do not match on `err`. `status` is the session's status when the
failure is about a known session, else `null`. An `ambiguous` failure also has `matches`, the status of every session
the reference picked. A request line that is too long or arrives too late also gets a failure, after which the daemon
closes the connection.

| Code | Meaning |
| --- | --- |
| `bad_request` | The request is malformed: not JSON, an unknown command or field, a wrong value, an invalid reference. |
| `no_session` | No session has that id or name, or matches that pattern. |
| `ambiguous` | A reference that must pick one session picked several; see `matches`. |
| `elsewhere` | The id belongs to a session of another daemon's endpoint. |
| `ended` | The session has ended, so it cannot take input, a resize, or a recording; also a lost session, which has no screen. |
| `running` | The session is still running, so it cannot be removed. |
| `stale` | A seq older than the session (`since` below its `start_seq`), or an `after_input` that is not the latest input. |
| `guard` | A guard of `input` or `resize` refused the request; nothing was typed or resized. `guard` names it. |
| `stalled` | The program stopped reading its input for 5 seconds, or an input batch took longer than 5 seconds to write; part of the input may have been delivered. |
| `busy` | The resource is in use: another input batch runs, another input is stalled, a recording is active (a second `record` start), the session has a writer. |
| `limit` | A size or count limit: the request or reply size, the PNG render size, the number of attach streams, of waits and event streams, of a session's alerts, or of the references in `sessions`; or the daemon's memory budget, which the screens of a session that would start, grow, or load from the store do not fit (`err` gives the numbers). History never makes a session fail: it is trimmed instead (see `history_trimmed`). |
| `exists` | `run` or `rename`: a running session already has that name; `alert` add: the session has an alert of that name. |
| `no_alert` | `alert` remove, or a `hit` condition of `wait`, `run`, `input`, or a recording's `until`: the session has no alert of that name. |
| `unsupported` | Not possible here: the program's keyboard or mouse mode cannot express the key or event, attach and events on Windows, `hidden_input` on Windows. |
| `stopping` | The daemon is shutting down and takes no more work; only `hello` is still answered. |
| `damaged` | The stored session cannot be loaded: its files hold what tuppet never writes, such as a size outside 1..1000. Its status's `damaged` says why; only `list`, `ack`, and `remove` work on it. |
| `internal` | Anything else, such as a failed write to the pty or out of memory. |

Clients treat a code they do not know like `internal`.

## Versioning

`hello` reports `protocol`, the revision the daemon speaks; this document describes revision 2. The number changes only
for an incompatible change: a removed or renamed field or command, or a changed meaning. Additions that a client can
ignore keep the number, and `hello` lists in `features` those a client may need to check for:

| Feature | What the daemon supports |
| --- | --- |
| `alerts` | The [alert](#alert) request, `alerts` in [run](#run), the `hit` condition, and hit frames in [events](#events). |
| `shutdown` | The [shutdown](#shutdown) request. |
| `limits` | The memory budget (`limit` for screens that do not fit), the `damaged` code and status field, and `history_trimmed`. |
| `fonts` | `fonts`, `bitmap`, and `font_size` in [png](#png). |

A client checks `hello` before its first request and refuses a daemon that speaks another revision. The tuppet CLI
then names both revisions: for an older tuppet daemon it says how to stop that daemon, and for a newer one it suggests
the newer tuppet. It also checks `features` before it
relies on one: `tuppet shutdown` refuses a daemon without `shutdown`, and `tuppet png` with fonts other than the
default refuses one without `fonts`.

## Status

Every session has a status. `list` returns them, and every reply about one session carries one:

```json
{"id":3,"name":"build","state":"running","pid":4242,"argv":["make","-j8"],"cols":120,"rows":40,
 "started_ms":1792517898035,"ended_ms":null,"exit":null,"seq":1187,"start_seq":1001,"end_seq":null,"input_seq":1100,
 "resize_seq":null,"idle_ms":2300,"change_idle_ms":800,"output_idle_ms":800,"input_idle_ms":9100,"title":"make: building",
 "cwd":{"path":"/home/me/src","host":"box"},"foreground":{"pgid":4242,"name":"make"},"tty":{"canonical":true,"echo":true},
 "hidden_input":false,"sample_age_ms":0,"writer":{"label":"pts/3"},"viewers":1,"previews":0,"recording":null,"bell_count":2,
 "notification_count":1,"notification":{"title":"make","text":"build done","at_ms":1792517998035},"hit_seq":2,
 "hit_alerts":["error"],"alerts":["error"],"seen":{"seq":1100,"bell_count":1,"notification_count":0,"hit_seq":null,"ended":false,"at_ms":1792517958035},
 "out_bytes":48211,"draws":96,"full_clears":3,"history_trimmed":false,"damaged":null}
```

| Field | Meaning |
| --- | --- |
| `id`, `name` | The session id; its name, or `null`. |
| `state` | `running`, `exited`, or `lost`: its daemon stopped while it ran, so how it ended and its final screen are unknown. |
| `damaged` | Why the stored session cannot be loaded, such as `its stored size 65535x65535 is outside 1..1000`; `null` when it can. Only a stored session is damaged, and every request but `list`, `ack`, and `remove` fails on it with `damaged`. |
| `history_trimmed` | `true` while the daemon's memory budget holds the session's history below its limit: the sessions together used more than the budget, so the oldest lines of those that keep the most went. The limit comes back once the sessions use less than three quarters of the budget. |
| `pid` | The program's process id, or `null` when unknown. |
| `argv` | The command line, as `run` received it. |
| `cols`, `rows` | The terminal size. |
| `started_ms`, `ended_ms` | Unix time in milliseconds; `ended_ms` is `null` until the session has ended. |
| `exit` | How the program ended, once it has: `{"code":N,"signal":null,"stopped":false}` or `{"code":null,"signal":"SIGKILL","stopped":false}`. `stopped` is `true` when [stop](#stop) ended it (also through `remove` with `force`, `run` with `if_exists` `replace`, or a [shutdown](#shutdown)). `null` while it runs and when it was lost. |
| `seq` | The seq of the latest visible change (see below); `null` for a lost session. |
| `start_seq` | The seq the session started at. A seq below it is `stale` for this session. |
| `end_seq` | The seq taken when the session ended; `null` until then. |
| `input_seq` | `seq` when the latest input was written (an input batch, attach data); `null` before any input. |
| `resize_seq` | The seq of the latest resize's reflow (see [resize](#resize)); `null` before any resize. A client that resized can tell from it that another client resized since. |
| `idle_ms` | Milliseconds since the text on the screen last changed. For a lost session this and the next two count from its start, the last time anything was known about it. |
| `change_idle_ms` | Milliseconds since anything visible last changed: text, colors and other styles, the cursor. |
| `output_idle_ms` | Milliseconds since the program last wrote output. |
| `input_idle_ms` | Milliseconds since the latest input; `null` before any input and once the session has ended. |
| `title` | The window title the program set (OSC 0 or 2), or `null`. |
| `cwd` | The working directory the program reported (OSC 7), `{"path":…,"host":…}` with the path percent-decoded and `host` `null` when the report named none; `null` without a report. `file://HOST/PATH`, `kitty-shell-cwd://HOST/PATH`, and a bare absolute path are understood. |
| `foreground` | The terminal's foreground process group, `{"pgid":N,"name":…}`, where `name` is its program's name (`null` when it cannot be found); `null` when the terminal has none. |
| `tty` | The terminal's input modes, `{"canonical":bool,"echo":bool}`: whether input is read a line at a time, and whether it is echoed. |
| `hidden_input` | `true` while input is read a line at a time without echo, as password prompts do (sudo, ssh, `read -s`); a hint, not a guarantee. |
| `sample_age_ms` | Milliseconds since `foreground`, `tty`, and `hidden_input` were sampled. |
| `writer` | The attached writer, `{"label":…}` with the label it sent (or `null`), or `null` when there is none. |
| `viewers` | How many attached clients only watch; previews (attach `mode` `preview`) are not counted. |
| `previews` | How many previews are attached. |
| `recording` | The active recording, `{"path":…,"format":"cast"|"trace","input":bool,"started_ms":…}`, or `null`. Once the session has ended (or was lost), the recording that `run` started with `record`, so its file can be found; `null` without one. |
| `bell_count` | How often the program rang the bell (BEL). |
| `notification_count`, `notification` | How many desktop notifications the program sent (OSC 9, OSC 777), and the latest one, `{"title":…,"text":…,"at_ms":…}`, with `title` `null` for OSC 9; `null` before the first. |
| `hit_seq` | The number of the latest [alert hit](#alerts-and-hits); `null` before the first, and for a lost session. |
| `hit_alerts` | The alerts the latest hit matched; `[]` without hits. |
| `alerts` | The names of the session's alerts, in the order they were added. |
| `seen` | What a client last showed of the session, as [ack](#ack) recorded it: `{"seq":…,"bell_count":…,"notification_count":…,"hit_seq":…,"ended":bool,"at_ms":…}`, with `at_ms` the time of the latest ack (`null` before any). All zero, `false`, and `null` until the first ack. |
| `out_bytes` | The bytes the program wrote to the pty. |
| `draws` | The settles of the program's output that took a seq (see below): how often its output changed something visible. A frame that the program writes with a pause in the middle counts twice, so the number depends on timing. |
| `full_clears` | How often the program erased the whole screen: ED 2 (`ESC[2J`), kitty's ED 22, and ED 0 (`ESC[J`) with the cursor at the top left cell. ED 3, which erases only the history, does not count. |

The title, the working directory, the counters, the latest notification, the hits, and `seen` stay once the session has
ended, also across daemon restarts. `out_bytes`, `draws`, and `full_clears` are `null` for a lost session; events do not
report their changes. Strings lose control characters (C0, C1, and bidirectional controls) and are cut at 256 bytes
(the title and a notification's title), 1024 bytes (a notification's text), or 4096 bytes (the path), the program's
name at 64.

A session needs attention when its `bell_count`, `notification_count`, or `hit_seq` is above what `seen` holds, or it
has ended (or was lost) and `seen.ended` is `false`; `tuppet list` marks such a session with `!`. A session whose
`exit.stopped` is `true` has `seen.ended` `true` from its end on: whoever stopped it knows.

`foreground`, `tty`, `hidden_input`, and `sample_age_ms` are sampled from the pty while the program runs, and are
`null` once it has ended and on Windows. A reply samples them anew; between replies the daemon samples right before
each input, at most every 50 ms after the screen changes, and every 250 ms while a wait waits for `hidden_input`.

A seq numbers visible changes. The daemon settles the screen after each burst of output (once the program pauses, or
after 20 ms or 1 MiB of output; synchronized output, mode 2026, holds it back for up to 1 s), and a settle that finds a
change takes the next seq from one counter shared by all sessions of the daemon. An input that follows another without a
change in between takes one too, so every input has an `input_seq` of its own. Seqs only grow, also across daemon
restarts, so a seq orders changes in all sessions. A session loaded from the store (after a daemon restart, or after it
left memory) keeps its seqs and idle times, but not when each row changed: `view` with `since` reports all its rows as
changed at its final `seq`.

## Requests

### hello

`{"cmd":"hello"}` → `{"ok":true,"version":"<release>","protocol":2,"features":["alerts","shutdown","limits","fonts"],"variant":"medium","boot":"<boot id>"}`

`variant` names the build's built-in PNG fonts: `lean`, `medium`, or `full`.

`boot` is the machine's boot id, and after a [reset](#shutdown) the boot id, a dot, and how many resets there were in
this boot (`"<boot id>.2"`). Clients treat it as opaque: two replies about the same id name one session only when their
`boot` is the same. A daemon reads it anew for every reply, as another daemon may have reset the store.

### run

Start a session:

```json
{"cmd":"run","argv":["vim","notes.txt"],"name":"edit","cols":120,"rows":40,"cwd":"/home/me","env":["HOME=/home/me","PATH=/usr/bin"]}
```

The reply is `{"ok":true,"status":{…},"boot":"<boot id>"}` with the new session's status and the boot its id belongs
to, as `hello` reports it.

| Field | Meaning |
| --- | --- |
| `argv` | Required unless `like` gives it; non-empty, without NUL bytes. `argv[0]` is resolved through the `PATH` in `env`, or the daemon's `PATH` without `env`. |
| `cols`, `rows` | Grid size, each 1..1000. Default 120x40. |
| `cwd` | Working directory; must be absolute, without NUL bytes, as must a recording's `path`. Default: `/`, the daemon's own. |
| `env` | `"NAME=value"` entries. Omitted or `null` means the daemon's own environment. In both cases `TERM` is set to `xterm-256color`, `TUPPET_SESSION` to the session's id, `TUPPET_SESSION_SOCKET` to the daemon's endpoint, and `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TMUX`, `TMUX_PANE`, and `STY` are removed. |
| `name` | A name for the session (see [Sessions and ids](#sessions-and-ids)); an empty name means none. Names are unique among the daemon's sessions: an ended or lost session that has the name is removed, as `remove` would, once the new program has started. |
| `if_exists` | What happens when a running session has the name: `fail` (default) fails with `exists` and that session's status; `keep` starts nothing and replies with that session's status; `replace` stops that session, as `stop` does, and starts the new one. |
| `scrollback` | History limit in bytes of the emulator's memory, at most 1 GiB. Default 8 MiB. |
| `record` | `{"path":"/abs/file","format":"cast"}` starts a recording together with the program. `format` is `cast` (default) or `trace`; without `path` it goes into the session's store directory as `output.cast` or `output.trace` and is deleted with the session. The status's `recording` gives its path, also after the session has ended. |
| `until`, `timeout_ms` | Wait for these [conditions](#conditions) too, as `wait` does; `timeout_ms` is required with `until`. Conditions cannot use `since` or a numbered `after_input`, since the session has no seqs yet. |
| `alerts` | `[{"name":…,"match":…,"icase":false}, …]`: [alerts](#alerts-and-hits) that watch from the program's first byte, at most 32 (more fail with `limit`), with names unique among them. |
| `like` | A reference to a session, running, ended, or lost, to start again: `argv`, `cwd`, `name`, `cols`, `rows`, `scrollback`, and `alerts` that the request leaves out come from it. Its environment and its hits do not: `env` applies as without `like`. A session that gives its name and has ended is replaced, as above. |

With `until`, the reply is followed by a second line, the reply of a [wait](#wait) on the new session. The wait starts
with the program's first byte, so text that the program printed and that scrolled away before the wait could start
still counts. A `run` with `if_exists` `keep` waits on the session it kept instead, from the request on. If the wait
fails, the session keeps running. When a validation error is found in `until`, nothing is started.

### list

`{"cmd":"list"}` → `{"ok":true,"sessions":[{…},{…}]}`

The status of every session, ordered by id. With `"sessions":[REF, ...]` only the sessions those references pick; a
reference that picks none is no error, so the list can be empty.

### view

`{"cmd":"view","session":"3","format":"plain","scrollback":false,"unwrap":false}` →
`{"ok":true,"text":"...","cursor":{"row":5,"col":1},"truncated":false,"rows":null,"history_dropped":false,"styles":null,"status":{…}}`

The text, the cursor, and the status come from one snapshot: output parsed before the request is settled first, so
`status.seq` covers everything in `text`.

| Field | Meaning |
| --- | --- |
| `format` | `plain` (text, trailing spaces trimmed), `vt` (with the escape sequences that reproduce colors and styles), or `html` (a fragment with inline styles: a `<style>` block that defines the palette, then one `<div>` with the theme's colors). |
| `scrollback` | Add the history above the screen. |
| `unwrap` | Join rows that the terminal soft-wrapped into one line. |
| `since` | A seq: show only the lines that changed after it (see below). |
| `styles` | `true` (`plain` only; with `vt` or `html` it fails with `bad_request`): add `styles`, the styles of the rows the text shows (see below). |

`cursor` is 1-based within the screen. `truncated` is `true` when older lines were left out so that the reply fits its
16 MiB limit; the newest lines are kept. `history_dropped` is `true` once the history has lost lines at its top since the
session started, to its `scrollback` limit or because the program erased it, so `scrollback` does not show everything the
program printed. Only `plain` text and `since` lines are cut that way: a whole `vt` or `html`
view that does not fit fails with `limit`, because a cut would lose the styles set before it.

**`since`.** With `since`, `text` holds only the lines in which a row changed after that seq: its text, a style, or
anything else visible. Each line is formatted on its own in the requested format and followed by `\n`, in screen order;
an `html` line is a `<div>` of its own with the theme's colors and every color resolved, without the palette `<style>`.
`rows` has one entry per line: the row the line starts on, where the top row of the screen is 1, the history row just
above the screen 0, the one above that -1, and so on. Without `unwrap` every row is a line of its own; with it, a
soft-wrapped line is included when any of its rows changed. Without `scrollback` only the screen counts; with it also
the history rows the daemon still tracks, which are the last 1024 rows that scrolled into history. Rows a resize brought
back from older history are left out. Pass the reply's
`status.seq` as the next `since` to see only what changed in between. A `since` at or above the current seq gives an
empty text; one below the session's `start_seq` fails with `stale`.

**`styles`.** With `styles`, the reply's `styles` is `{"base":ATTRS,"runs":[…],"truncated":false}`:

```json
{"base":{"fg":"default","bg":4,"underline":"none","underline_color":"default","bold":false,"faint":false,"italic":false,
 "blink":false,"inverse":false,"invisible":false,"strikethrough":false,"overline":false,"link":null},
 "runs":[{"row":1,"col":1,"cols":2,"text":"ab","attrs":{"fg":1,"bg":4,"bold":true,…}}],"truncated":false}
```

`base` is the style that covers the most cells of the screen, blank cells included; when several cover as many, the
default style wins. It comes from the whole screen, also with `since`. `runs` lists, row by row and left to right, every
stretch of cells in a row of the text whose style differs from `base`, blank cells included: an inverse blank, or a
cell without text whose background differs. `row` counts as `rows` does with `since` (the top row of the screen is 1,
the history row above it 0), `col` is the first cell, counting from 1, and `cols` how many cells the run takes; a run
never crosses a row and never splits a wide character. `text` is the run's text, blank cells as spaces. `attrs` has
every attribute: `fg`, `bg`, and `underline_color` as a palette index (0..255), `"#rrggbb"`, or `"default"` (so a run
can say `"bg":"default"` where the base has a color); `underline` as `none`, `single`, `double`, `curly`, `dotted`, or
`dashed`; the flags `bold`, `faint`, `italic`, `blink`, `inverse`, `invisible`, `strikethrough`, and `overline`; and
`link`, the URI of an OSC 8 link cut to 512 bytes, or `null`. Text and runs get half the reply's room each: runs of the
rows at the top are left out first, and `truncated` is then `true`.

### wait

```json
{"cmd":"wait","session":"3","until":[{"match":"$ ","after_input":"latest"},{"ended":true}],"timeout_ms":30000}
```

→

```json
{"ok":true,"outcome":"met","met":0,"text":null,"cursor":null,"text_too_large":false,"hits":[],"missed":0,"snapshot_truncated":false,"lost":0,"status":{…}}
```

Wait until one of the [conditions](#conditions) in `until` holds, at most `timeout_ms` milliseconds (0..600000; 0 checks
once). The daemon checks after every change on the screen, at most every 50 ms, and at the deadline. A check settles the
output parsed before it, as `view` does, but while synchronized output (mode 2026) holds the settle back, text in the
frame still being drawn is not checked.

| Field | Meaning |
| --- | --- |
| `until` | The conditions, at most 64; the wait is met when any of them holds. |
| `timeout_ms` | Required: how long to wait. |
| `format`, `scrollback`, `unwrap` | Return the screen as `view` does, in `text` and `cursor`; without `format` both are `null`. |

| Reply field | Meaning |
| --- | --- |
| `outcome` | `met`; `timeout`; `ended`: the session ended before a condition was met (it is checked once more first, so a needle in the last output still counts); `removed`: the session was removed. |
| `met` | The index in `until` of the condition that was met, else `null`. With several that hold at once, the first. |
| `text`, `cursor` | The screen when the wait ended, as `view` returns it, if `format` was given. |
| `text_too_large` | `true` when that screen did not fit the 16 MiB reply limit (a whole `vt` or `html` screen; `plain` text keeps the newest lines that fit): `text` and `cursor` are then `null`, and the rest of the reply holds as usual. |
| `hits` | The [hits](#alerts-and-hits) the session's log keeps that meet one of the `hit` conditions, oldest first; `[]` without such conditions. |
| `missed` | Hits numbered above a condition's `after_hit` that the log dropped before the answer, so they could not be checked. |
| `snapshot_truncated` | An `after_input` condition fell back to `since` the input, because the screen held more text at the input than the snapshot keeps (256 KiB). |
| `lost` | Rows the wait could not check: they scrolled out of the history before a check, went by while the daemon could not tell how far the screen scrolled (with a scrollback of 0, or when the history dropped them first; at least a screen's worth each time) or before a resize, or a check had more than 10,000 rows or 2 MiB of text. With `since` or `after_input`, also rows whose last change is no longer known (history past the last 1024 rows, or rows a resize brought back from there) when one of them could have met the condition. |
| `status` | The session's status when the wait ended; `null` when it was removed. |

The status is taken when the wait ends, so its `seq` and `input_seq` can be the `since` of the next wait or view. A wait
on a session that has ended is answered at once: `met` if a condition holds (such as `ended`), else `ended`.

A wait that has started holds none of the 32 request slots. On Linux, if the client hangs up before the answer, the wait
ends and nothing is replied; on macOS and Windows the wait lasts until its answer or its deadline. A client that only
shuts down its sending side (a half-close) keeps its wait and gets the answer.
Removing a session never waits for its waits; they end with `removed` (or `ended`, when the session ended first).

### Conditions

A condition is an object; the fields that are set must all hold:

| Field | Holds when |
| --- | --- |
| `match` | This text is on a line of the screen. At most 4 KiB, without `\n` or `\r`. |
| `icase` | With `match`: ASCII letters match regardless of case. |
| `idle_ms` | The screen's text has not changed for this many milliseconds, counted from its last text change (`status.idle_ms`); colors, styles, and the cursor do not count. |
| `settled_ms` | The screen changed after the start, its text or a style (the start: `since`, the input with `after_input`, else the wait's start), and then its text did not change for this many milliseconds, counted from the wait's start at the earliest, while no output waits on the pty to be read and settled and no synchronized-output frame is held back. Use it instead of `idle_ms` after an input or a resize, where `idle_ms` can hold before the program reacted. On Windows, output still waiting on the pty is not seen. |
| `absent` | `true`, with `match`: the text was on a line of the screen when the wait started, or came on one later, and is now on none of the screen's lines. Text that scrolled into the history is gone; text that never came never meets it. `icase` applies. It takes no `since` or `after_input` (`bad_request`). |
| `ended` | `true`: the program has ended. |
| `hidden_input` | `true`: the terminal reads input a line at a time without echo (`status.hidden_input`). Not on Windows, where it fails with `unsupported`. |
| `since` | A seq: only what happened after it counts. `match` needs a line whose text changed after the seq, `ended` an end after it (`status.end_seq`), `hidden_input` hidden input that began after it, and `idle_ms` counts from the wait's start at the earliest. A seq below the session's `start_seq` fails with `stale`. |
| `after_input` | `"latest"`, or the `input_seq` of the latest input: only what is new since that input counts (see below). An `input_seq` that is not the latest input's fails with `stale`; when another input arrives during the wait, any line whose text changed after that `input_seq` counts as new. `ended` needs an end after the input; `hidden_input` hidden input that began after it; `idle_ms` counts from the wait's start at the earliest. |
| `hit` | `{"name":…}`: the alert of that name (`"*"`: any alert of the session) hit after the latest input, so a dialog that was answered and is still on the screen does not count. With `since` or `after_input`, a hit after that seq or input instead; with `"after_hit":N`, any hit numbered above N. A name the session has no alert of fails the request at once with `no_alert`. |

`since` and `after_input` cannot be combined, and a condition must have one of `match`, `idle_ms`, `settled_ms`, `ended`,
`hidden_input`, `hit`, or be `since` or `after_input` alone.

**Settled and gone.** `settled_ms` measures quiet on the text, as `idle_ms` does, so a blinking cursor or a clock that
only changes colors does not hold it off; a style change only starts it. It holds on what the program drew by then: a
program that pauses longer than `settled_ms` in the middle of a redraw (it clears the screen, then draws 300 ms later)
meets it in the pause, and a redraw of identical text changes nothing, so the wait runs to its deadline. `absent` is
checked as `match` is, after each change and at most every 50 ms, so text that came and went between two checks can be
missed; text that scrolled into the history between two checks is seen.

**Hidden input.** Hidden input begins when a sample finds input read a line at a time without echo after one that did
not, or when the text on the screen changed after an input that came while input was hidden, and input is still hidden:
the prompt that follows the answer to another, such as "Retype new password". With `after_input`, a prompt that hid
input before the input, such as the password prompt the input answered, does not count, though input is still hidden
while the program reads it. The pty is sampled right before each input, so hidden input that began before it is never
new after it. With `since`, hidden input that began without a change on the screen after the seq does not count.

**Changed.** A condition of only `since` (or only `after_input`) holds when the text of some line changed after that
seq (or input): a line on the screen, or one that scrolled into the history after the wait started. Changes of color,
style, or the cursor alone do not count. A client that matches with its own rules, such as a regular expression, waits
with `{"since":S}`, reads `view` with `since` S, checks the lines, and repeats with the new `status.seq`.

**Lines.** Text is matched on logical lines: rows that the terminal soft-wrapped are joined, the spacer cells of wide
characters are skipped, and empty cells inside a line, such as a tab leaves, are spaces. Empty cells at the end of a
line are not spaces, so a trailing space in `match` matches only a space that the program wrote. Without `since` or
`after_input`, `match` is met by the text on the screen now, or on rows that scrolled into the history after the wait
started, so output that scrolled away between two checks still counts.

**After an input.** At each input (an input batch, attach data) the daemon keeps a copy of the screen's text,
line by line, and the copy moves with the rows as they scroll or reflow. With `after_input`, `match` needs a new
occurrence: on a line that shows the text more often than the copy showed it on those rows, or on a row that went blank
after the input. The echo of a command typed at a prompt `$ ` is therefore not a new `$ `, while the next prompt is, also
after the screen scrolled or was cleared. Limits:

- Text within the typed text itself is a new occurrence and matches.
- A line cleared and redrawn within one settle (as `clear` or Ctrl-L redraws a prompt in place) shows nothing new.
- Lines that a resize took off the screen (a shorter full-screen program loses its top rows) still count as shown: a
  program that draws them again after the resize, on any row, shows nothing new.
- A `run` or `input` with `until` knows its needle before the first byte, so the needle going away from a row after the
  input and coming back there counts as new; a change that lasts less than one check (about 50 ms) can be missed. A
  separate `wait` sees new rows and rows that went blank only.
- When the copy exceeded 256 KiB, or does not describe the screen shown now (the input went to the other screen), any
  line whose text changed after the input counts as new; the former sets `snapshot_truncated`.

### png

```json
{"cmd":"png","session":"3","fonts":["/home/me/fonts/terminus.psf.gz","default"],"bitmap":false,"font_size":14}
```

→ `{"ok":true,"png_b64":"<base64 PNG>","renderer":"bitmap","cell":"8x16","faces":["drawn","/home/me/fonts/terminus.psf.gz","unifont"],"status":{…}}`

`fonts` lists the fonts to try, in order: built-in names (`unifont` in every build, `jetbrains` in medium and full,
`julia`, `nerd`, and `cjk` in full), `default` for the build's built-in fonts (`unifont` in lean; `jetbrains`, `unifont`
in medium; `jetbrains`, `julia`, `nerd`, `cjk`, `unifont` in full), and absolute paths of font files: `.ttf`, `.otf`,
`.ttc` (`file.ttc#N` names face N of a collection), `.otb`, `.pcf`, and `.bdf` (the last two also gzip-compressed),
which FreeType reads in medium and full builds, and the bitmap fonts `.hex`, `.psf`, and `.psf.gz`. It holds at most 16
fonts once `default` is expanded, and an empty or missing list means `default`. Box drawing, blocks, braille, Powerline
and sextant glyphs are drawn first; color emoji, Unifont, and U+FFFD close every list. The first font sets the cell
size: JetBrains Mono at 14 pixels gives 9x19 cells, Unifont 8x16. `bitmap` leaves out every font FreeType reads,
skipping such paths and built-in names in `fonts`; `bitmap` as an entry of `fonts` does the same. `font_size` (6 to 64,
default 14) sets the size of TrueType fonts; bitmap fonts, and the bitmap sizes FreeType picks the nearest of, keep
theirs, and a font with only bitmap sizes, none of them within a quarter to four times `font_size`, fails the request.
The client resolves presets, `~`, and relative paths before it sends the request; the daemon reads font files of at most
64 MiB (gzip members one after another, nothing else after them) and reads a file again when its size or modification
time changed. It keeps up to 32 files loaded, holding at most 256 MiB together once parsed or unpacked, and drops the
least recently used first; a request whose own fonts need more fails.

A font the daemon cannot use fails the request with code `bad_request` and an `err` that names the font and the reason,
for example `"/x/y.ttf: this tuppet build (lean) has no TrueType support; use a .hex or .psf font, or a medium or full
build"`, `"/x/y.ttf: FreeType cannot read it (UnknownFileFormat)"`, or, for a font only full builds have, `"this tuppet
build (medium) does not include cjk; a full build does"`.

The reply says what drew the image: `renderer` is `ttf` when a font FreeType reads set the cell or drew something, else
`bitmap`; `cell` is the cell
size in pixels; `faces` lists the fonts that drew something: `drawn` for the drawn glyphs, built-in
names, paths, and `emoji`.

### resize

`{"cmd":"resize","session":"3","cols":100,"rows":30,"require":{"unattended":true}}` → `{"ok":true,"resize_seq":N|null,"status":{…}}`

`resize_seq` is the seq of the reflow. Output the program wrote before the request is settled first (waiting at most
50 ms for what is still on the pty), and the program's redraw for the new size changes the screen after it. So
`since: resize_seq` sees only the program's changes after the reflow, and `since: resize_seq - 1` also the rows the
reflow changed; `status.seq` is at least `resize_seq`. To see the program's redraw, wait with
`{"since":resize_seq,"settled_ms":200}` within a deadline, then `view`. `status.seq` is no substitute: a fast redraw
can be in it already, and a seq from before the request is passed by the reflow itself.

A resize to the current size changes nothing and sends the program no SIGWINCH: `resize_seq` is `null` then. A failed
resize leaves the pty at its old size and its reply carries no `resize_seq`.

`require` takes `{"unattended":true}`, the guard of [input](#input): while a writer is attached, the resize is refused
with code `guard` and `"guard":"unattended"`, and the size stays. It is checked under the lock the resize takes, so no
writer can attach in between.

### rename

`{"cmd":"rename","session":"3","name":"web"}` → `{"ok":true,"status":{…}}`

The name follows the rules of [names](#sessions-and-ids); an empty name takes the name away. While a running session has
the name, the request fails with `exists` and that session's status. An ended or lost session that has it is removed,
as `remove` would.

### input

```json
{"cmd":"input","session":"3","steps":[{"text":"make"},{"keys":["<Enter>"]}],"require":{"unattended":true},
 "until":[{"match":"$ ","after_input":"latest"}],"timeout_ms":600000}
```

→ `{"ok":true,"done":2,"status":{…}}`

This types the steps in order, as one batch: the daemon holds the session's input for the whole batch, so no other
input, an attached writer's included, lands between its steps. `done` is the number of steps that ran. A step has
exactly one of these fields:

| Step | Meaning |
| --- | --- |
| `{"text":"…"}` | Written to the session's input as it is. |
| `{"paste":"…"}` | Pasted the way a terminal pastes: CRLF and LF become CR, and if the program enabled bracketed paste (mode 2004), the text is wrapped in `ESC[200~` … `ESC[201~`, with any end marker inside it removed. |
| `{"keys":["<C-c>","ihello","<Esc>"]}` | Keys in vim notation, encoded for the program's keyboard mode as it is when the step runs. A key that mode cannot express fails the step with `unsupported`. `tuppet help key` describes the notation. |
| `{"mouse":{"button":"left","action":"press","mods":"c","x":10,"y":2}}` | A mouse event, encoded for the program's mouse mode; nothing is sent while the program has mouse reporting off, and an event its mode cannot report fails with `unsupported`. See below. |
| `{"focus":true}` | A focus-in (`true`) or focus-out (`false`) event, sent only if the program enabled mode 1004. |
| `{"sleep_ms":500}` | A pause of at most 1000 ms; the pauses of a batch add up to at most 2000 ms. The daemon still answers the program's queries meanwhile. |

A `text` or `paste` step with `"secret":true` is kept out of recordings: a trace shows `{"ev":"in","kind":"secret"}`
and a cast a marker event, `secret input`, instead of the text. So is every text, paste, or key, from a batch or an
attached writer, that the program reads while it hides its input (`hidden_input`), such as a password typed by hand.
Texts must not be empty.

| Mouse field | Values |
| --- | --- |
| `button` | `left`, `right`, `middle`, `up`, `down`, `none` (motion only), or `1`..`9` |
| `action` | `press` (default), `release`, `motion` |
| `mods` | Modifier letters in any order, each at most once: `c` (Ctrl), `a` or `m` (Alt), `s` (Shift) |
| `x`, `y` | Zero-based cells inside the grid; checked before the first byte and again when the step runs (`bad_request`) |

`require` holds guards, checked under the session's input lock before the first byte. A guard that fails refuses the
whole batch with code `guard`, a `guard` field that names it, and the session's status:

| Guard | Refuses the batch unless |
| --- | --- |
| `"unattended":true` | No writer is attached. |
| `"input_seq":N` | The latest input is still the one with this `input_seq`: nobody typed since. |
| `"hidden_input":true` | The terminal reads input without echo, as a password prompt does (`status.hidden_input`). Not on Windows, where it fails with `unsupported`. |
| `"hit_seq":N` | The latest hit is the one numbered N. |
| `"reply_to":N` | Hit N is not answered: no input came after it (an input at or after its `seq`), and the log still keeps it. |

One batch runs per session at a time: another fails at once with `busy`, and nothing of it is written. A batch must be
written within 5 seconds, counting the wait for another input to finish but not its pauses; past that it fails with
`stalled`. It fails with `ended` when the program exits during the batch, and, on Linux, it stops between steps without
a reply when its client hangs up. Every failure carries `done`, also one that comes before the first step:

```json
{"ok":false,"code":"stalled","err":"…","status":{…},"done":3,"guard":null,"matches":null}
```

`until` and `timeout_ms` wait for [conditions](#conditions) too, as `wait` does: the reply is followed by a second line,
the reply of a wait that knew its conditions before the batch's first byte. `after_input` there means the batch, as
`"latest"`; a numbered `after_input` is refused. When the batch fails, no second line follows.

### alert

Add, remove, or list a session's alerts. A request has exactly one of `add`, `remove`, and `list`:

```json
{"cmd":"alert","session":"3","add":{"name":"approve","match":"Do you want to proceed?","icase":false}}
```

→ `{"ok":true,"alerts":[{"name":"approve","match":"Do you want to proceed?","icase":false}],"status":{…}}`

| Field | Meaning |
| --- | --- |
| `add` | An alert to add. Its `name` follows the rules of [names](#sessions-and-ids); its `match` has 1 to 256 bytes and no `\n` or `\r`. A name the session has fails with `exists`, a 33rd alert with `limit`. Text on the screen when it is added counts as seen. |
| `remove` | The name of an alert to remove; one the session does not have fails with `no_alert`. |
| `list` | `true`: only reply with the alerts. |

The reply lists the session's alerts, in the order they were added. They are kept with the session in the store, also
once it has ended, and `run` with `like` copies them.

### record

Start, mark, or stop a recording. A request has exactly one of `start`, `mark`, and `stop`.

```json
{"cmd":"record","session":"3","start":{"path":"/tmp/s.trace","format":"trace","until":[{"match":"$ ","after_input":"latest"}],"max_ms":60000}}
```

→ `{"ok":true,"active":true,"reason":null,"path":"/tmp/s.trace","status":{…}}`

| Field | Meaning |
| --- | --- |
| `start` | Start a recording, with the fields below. A session that records already fails it with `busy`, one that has ended with `ended`. |
| `start.path` | Absolute path of the file. Without it the recording goes into the session's store directory as `record-N.cast` or `record-N.trace`, and is deleted with the session. |
| `start.format` | Required: `cast` (asciicast v2) or `trace` (JSONL). |
| `start.input` | A cast records input events too; a trace always does. |
| `start.until` | [Conditions](#conditions), as `wait` takes them: the recording stops once one holds, with reason `met`. They are checked the way a wait checks them, and a stale `since` or `after_input` fails the start with `stale`. |
| `start.max_ms` | 1..86400000: the recording stops this many milliseconds after its start, with reason `max_ms`. |
| `mark` | A label: append a marker to the active recording. |
| `stop` | `true`: stop the active recording. When it has stopped by itself since the last stop, the reply says how instead. |

Without an active recording, `mark` and `stop` fail with `bad_request`, or with `ended` once the session has ended. A
`stop` that reported a recording which stopped by itself does so once; the next `stop` fails the same way.

The reply describes the session's latest recording:

| Reply field | Meaning |
| --- | --- |
| `active` | Whether it is still recording. |
| `reason` | How it stopped: `request` (a `stop`), `met` (a condition of `until`), `max_ms`, or `ended` (the session ended, or was removed); `null` while it records. |
| `path` | Its file. |

A recording whose `until` holds already at the start stops at the daemon's first check, within about 50 ms, so the
start reply may still say `active`. Its conditions hold none of the 256 places of waits and event streams.

A cast holds the program's output as it arrives. A trace holds a `start` event and a `snap` of the screen, an `in` event
per input, `diff` events with the rows whose text changed (or a `snap` when more than 60% of them did, or the screen or
its size changed), `mark` events, and a final `snap` and `stop` event with the reason (and for `ended` the `exit_code`,
or the `signal` that killed the program, such as `"SIGKILL"`). Changes are collected into one frame at most every 50 ms,
and always before an input (a resize: before its reflow), a mark, or the stop. Secret input (`"secret":true`, and
anything typed while the program hides its input) appears in either only as a marker.

### stop

`{"cmd":"stop","sessions":["3","ci-*"]}` →
`{"ok":true,"results":[{"ref":"3","id":3,"ok":true,"code":null,"err":null,"status":{…}}, …]}`

This sends SIGHUP and SIGTERM to each session's process group, then SIGKILL to whatever is left after 0.5 seconds. It
stops all sessions at once and returns once they have exited. A session that an id or a name picks after it has ended
already (or was lost) gets the result code `ended`.

The request succeeds even when some sessions could not be stopped. `results` has one entry per session, in the order the
references pick them, and one for each reference that picked no session at all; a reference given twice counts once:

| Field | Meaning |
| --- | --- |
| `ref` | The reference that picked the session, as the request gave it. |
| `id` | The session id; `null` for a name or pattern that picked nothing. |
| `ok` | Whether the action succeeded for this session. |
| `code`, `err` | Why not, as in a failed reply; `null` on success. |
| `status` | The session's status after the action (for `remove`, just before it), when there is one. |

### remove

`{"cmd":"remove","sessions":["3"],"force":false}` → `{"ok":true,"results":[…]}`

This deletes ended (or lost) sessions and their stored data, including a recording in the store directory. A running
session gets the result code `running`; with `"force":true` it is stopped first (all of them at once, as `stop` does),
and patterns pick running sessions too. The results are those of `stop`.

### shutdown

`{"cmd":"shutdown","reset":false}` →

```json
{"ok":true,"socket":"/run/user/1000/tuppet-1000.sock","stopped":[{…}],"failed":[],"removed":0,"kept":5,"next_id":8,"boot":"<boot id>"}
```

This stops the daemon. From the request on, every other request but `hello` fails with `stopping`, and no session
starts. The daemon ends every attach stream with reason `shutdown`, stops every running session at once as [stop](#stop)
does, so its screen, exit status, and any recording are saved, answers each open wait as its session ends, and ends
every events stream with `{"type":"end","reason":"shutdown"}` after the frames about those ends. It gives streams and
other requests up to 2.5 seconds to finish, then sends the reply, removes the endpoint, and exits with status 0, also
when it is supervised. A daemon told to stop by SIGTERM or SIGINT does the same, without a reply.

| Reply field | Meaning |
| --- | --- |
| `socket` | The daemon's endpoint. |
| `stopped` | The status of each session it stopped, after the stop. |
| `failed` | `{"id":N,"code":…,"err":…,"status":{…}}` for each session it could not stop, such as one whose process did not exit after SIGKILL. The daemon exits anyway. |
| `removed` | How many sessions the reset deleted; 0 without `reset`. |
| `kept` | How many sessions are left in the store: without `reset`, this endpoint's, which the next daemon on it serves again; after a reset, those of other daemons that still run. |
| `next_id` | The id the next session gets. |
| `boot` | The boot, as `hello` reports it from now on. |

**Reset.** With `"reset":true`, the daemon also resets the store, under the lock that serializes changes to it across
daemons, and before it removes its endpoint, so a daemon that starts there meanwhile finds the reset done. It deletes:

- every session of this endpoint, also one it could not stop;
- every other session that no running program holds and whose endpoint (the `socket` its daemon listened on) does not
  answer `hello`: what daemons that are gone left behind;
- the recordings in those sessions' store directories. A recording at a path the client gave is never touched;
- the session that `tuppet attach -` returns to.

Each session directory is renamed to a hidden name before it is deleted, so a half-deleted one is never taken for a
session. The sessions of daemons that still run stay, and ids continue above the highest of them; with none left, ids
start at 1 again. Seqs are not reset: they keep rising, so a `since` from before the reset is `stale` for any new
session. The reset counts the boot's resets up, so `boot` changes in `hello`, `run`, and `events` replies, and an id
cached with the old `boot` is not taken for a new session of the same number. When the reset fails, the reply is a
failure with code `internal`; the sessions have stopped, and the daemon exits all the same.

### ack

`{"cmd":"ack","sessions":["3"],"shown":{"seq":1187,"bell_count":2,"notification_count":1,"hit_seq":null,"ended":false}}`
→ `{"ok":true,"results":[{"ref":"3","id":3,"ok":true,"code":null,"err":null,"status":{…}}, …]}`

This records what a client showed of each session, so that it no longer needs attention for that. Each field of
`seen` moves to the value in `shown`, but never past the session's current value and never back:
`max(seen, min(shown, current))`. A field left out of `shown` stays; without `shown`, every field takes the current
value. Two clients that ack what they each showed therefore never undo each other. Patterns pick every session they
match. The results are those of [stop](#stop), with each session's status after the ack. A change of `seen` is an
event (`seen`, below).

### events

`{"cmd":"events","sessions":["build","ci-*"],"idle_ms":30000}` → `{"ok":true,"boot":"<boot id>"}`, then frames.

After its reply the connection carries one JSON line per frame from the daemon until the client closes it; the client
sends nothing more. Off Linux, a client that shuts down its sending side ends the stream too. Not on Windows
(`unsupported`).

| Field | Meaning |
| --- | --- |
| `sessions` | References that pick the sessions, as in other requests. Names and patterns are matched as sessions are named now, so a session started or renamed later can match. Missing or empty: every session, also later ones. A reference that picks nothing is no error. |
| `idle_ms` | 1..86400000: also send `idle` when a session's screen text has not changed for this many milliseconds (`status.idle_ms`), also right after `synced` for a session that is quiet already, and `active` when it changes again. |

First comes one `snapshot` frame for each session that matches, then `{"type":"synced"}`. Every other frame is a change,
and every frame about a session carries its `id` and its `status`, taken when the frame was sent:

```json
{"type":"changed","id":3,"fields":["title","bell"],"status":{…}}
```

| Frame | Meaning |
| --- | --- |
| `snapshot` | The session as it is; after `synced`, a session that newly matches because it was renamed. |
| `started` | A new session. One that has ended already by the time the frame is sent is followed by `ended` at once. |
| `ended` | The program ended; `status.exit` says how. `status` is `null` when the session was removed meanwhile, as it is for `seen`. |
| `removed` | The session was removed; `status` is `null`. |
| `renamed` | The session has another name and still matches. |
| `left` | The session was renamed and no longer matches; no more frames come about it. |
| `changed` | `fields` names what changed: `seq` (anything visible), `input` (an input), `title`, `cwd`, `foreground`, `tty` (and with it `hidden_input`), `writer`, `viewers`, `bell` (`bell_count`), `notification`, `size`. |
| `seen` | An [ack](#ack) moved `seen`. |
| `hit` | An [alert hit](#alerts-and-hits): `{"type":"hit","id":3,"hit":{…},"status":{…}}`. One the log dropped before the frame was sent is left out. |
| `idle`, `active` | With `idle_ms`: the screen's text has not changed for that long, and it changed again. |
| `resync` | The client fell too far behind and missed frames: the stream starts over with a `snapshot` frame for each session that matches, and `synced`. |
| `end` | `{"type":"end","reason":"too_slow"}`: the client took nothing for 30 seconds; `"shutdown"`: the daemon is stopping (see [shutdown](#shutdown)). The daemon closes the connection after it. |

Clients ignore frame types they do not know.

Frames about one session come at most ten times a second: changes that happen meanwhile are merged into one `changed`
frame, and `idle` and `active` take their turn too. `started`, `ended`, `removed`, `renamed`, `left`, `seen`, and `hit`
frames are never held back, and changes still pending for the session are sent right before them. Sessions with a running
program have their pty sampled every 250 ms while any stream is open, so `foreground` and `tty` changes show without
other output.

An event stream holds none of the 32 request slots, but one of the 256 shared with waits, and keeps an idle daemon
running. On Linux the daemon notices within a second that the client hung up; elsewhere when it next sends a frame.

## Alerts and hits

An alert watches a session's screen for its text, matched on logical lines as `match` conditions match. The daemon
matches a session's alerts when it settles the screen, against the lines that changed: a line that comes to show an
alert's text is due to fire, and the session's evaluator takes it as a hit within about 50 ms. A hit always writes a
mark into the session's active recording (`hit N <alerts>`), and events streams get a `hit` frame.

A line fires once. Its alert keeps quiet while the line keeps showing the text, so a spinner, a timer, or the answer typed
on a dialog's line does not fire again; it fires again once a settle found the text gone from the line, so the same
dialog drawn again after it was erased is a new hit. Programs that erase a line and draw it again in two bursts of
output fire each time, and a dialog shown for less than about 50 ms can be missed. Put an alert on a line that changes
when a dialog is reused, such as the one that names the file or command it asks about.

Text that a resize reflows does not fire again, and neither does a program that draws its screen again after a resize,
such as during a window drag. A run of resizes lasts until the next input, or until 5 seconds after its last resize,
whichever comes first; while it lasts, a line on the screen at a resize (rather than one that output scrolled in since)
that comes to show an alert's text fires only when more lines of the screen show it than at any resize of the run, the
lowest of them first. Output that scrolls in fires as always. The part of a wrapped line that stays on the screen when
its first row scrolls into the history does not fire again either. A program that switches to the alternate screen draws
it anew, so a dialog drawn with the switch fires. On the alternate screen rows are places: text that a program scrolls
up there shows on another row. Rows that scroll into the history are matched once, also rows that scrolled past between
two settles while the history still has them. Text on the screen when an alert is added counts as seen.

An alert fires at most 10 times a second; the hits left out are counted in the next hit's `suppressed`. When a burst
ends, the latest hit it left out is logged once its second is over (or when the session ends), so the log shows how the
burst ended; its `seq`, `region`, and `row` are those of when its line was found. A session keeps its last 64 hits in
memory, and in the store once it has ended; a lost session keeps its alerts but has no hits.

A hit:

```json
{"n":4,"alerts":["approve"],"line":"Do you want to proceed?","seq":1187,"region":"visible","row":12,"suppressed":0}
```

| Field | Meaning |
| --- | --- |
| `n` | The hit's number, counting from 1 in each session. `status.hit_seq` is the latest. |
| `alerts` | The alerts whose text the line came to show, in the order they were added. |
| `line` | The line's text, without control characters, cut at 512 bytes. |
| `seq` | The seq of the settle that found it. An input whose `input_seq` is at or above it came after the hit. |
| `region` | Where the line was when the hit was taken: `visible` on a screen, `scrollback` in the history, or `lost` when the history dropped it before its text could be read (`line` is then empty). |
| `row` | Its row then, counted as `view` with `since` counts them (the top row of the screen is 1); `null` when `lost`. |
| `suppressed` | Hits of its alerts that the rate limit, or a flood of lines faster than the daemon takes them, left out since each one's previous hit. |

## Attach streams

`{"cmd":"attach","session":"3","mode":"read","force":false,"label":null}`

- `mode` is `read` (a viewer), `write` (the writer), or `preview`: a viewer in a passive role, for a client that shows
  the session in passing, such as a picker's preview. It gets the same frames as a viewer but is not counted in
  `status.viewers`.
- A session has any number of viewers and at most one writer. A second write attach fails with `busy` unless `force` is
  `true`. In that case the previous writer receives `{"writer":"taken"}` and continues as a viewer.
- A writer may send a `label`, at most 64 bytes (control characters are removed), which its status shows as
  `writer.label`.
- A writer may send its terminal size as `cols` and `rows` (both, 1..1000). The session is resized to it, as by a
  `resize` frame, before the first `screen` frame, so that redraw already has the size the client shows it at.

The reply is one line, `{"ok":true,"status":{…}}` with the attach counted, or a failure. After a successful reply, the
connection carries JSON lines in both directions until either side closes it.

### Daemon to client

| Frame | Meaning |
| --- | --- |
| `{"screen":"<base64>"}` | Sent first, and again after `{"writer":"taken"}`, `{"hold":false}`, and, to the writer, after a `resize` frame of its that changed the size: a full redraw of the current screen as VT bytes. It starts with a terminal reset (`ESC c`), then sets the palette, modes, screen content, and cursor. The daemon takes it under the same lock as the subscription, so the following `out` frames continue exactly where it ends. |
| `{"out":"<base64>"}` | Raw pty output, as it arrives. |
| `{"resize":{"cols":C,"rows":R,"seq":N}}` | The session's size changed; `seq` is the seq of the resize's reflow, as `resize_seq` in a [resize](#resize) reply. It comes after the reflow took its seq and before the output the program writes for the new size. A writer whose `resize` frame asked for the size the session has already gets this frame alone, with `"seq":null`. |
| `{"writer":"taken"}` | A forced attach took the writer role; this client is now read-only. A `screen` frame follows, so a client that showed a notice over the screen can draw it afresh. |
| `{"hold":true}`, `{"hold":false}` | The writer's input waits for an input batch, and then went through (see below). A `screen` frame follows `{"hold":false}`. |
| `{"exit":{"code":N,"signal":null,"stopped":false},"status":{…}}` | The program ended (`{"code":null,"signal":"SIGKILL",…}` when killed), as `status.exit` describes it; `status` is the session's final status. An `end` frame follows. |
| `{"error":{"code":"bad_request","err":"…"}}` | A client frame was rejected (codes as in failed replies). The stream continues, except after a frame longer than the 1 MiB line limit (`limit`), after which the daemon closes it. |
| `{"end":{"reason":"…"}}` | The last frame: `exited` (after `exit`), `detach` (the client asked), `too_slow` (this client fell more than 4 MiB behind, or more than its share of 64 MiB while all clients together are that far behind), or `shutdown` (the daemon is stopping, on a [shutdown](#shutdown) request or on SIGTERM or SIGINT; it stops the session too). |

Attaching to a session that has ended already gives the reply, the `screen`, the `exit` frame, and `end`.

### Client to daemon (writer only)

| Frame | Meaning |
| --- | --- |
| `{"data":"<base64>"}` | Input to the pty, written as it is. |
| `{"resize":{"cols":C,"rows":R}}` | Resize the session, as with `resize`; the `resize` frame back carries the seq of the reflow, and a resize that fails gets an `error` frame. |
| `{"detach":true}` | End the stream. Viewers may send this too. |

Client frames are parsed as strictly as requests. A viewer's `data` and `resize` frames are answered with an `error`
frame, and the stream continues. Clients may send frames right behind the attach request without waiting for the reply.
Clients skip empty lines.

While an [input](#input) batch runs, a writer's `data` waits for it. The daemon stops reading the stream meanwhile, so
what the client sends next stays behind it, in order; the client gets `{"hold":true}`, and `{"hold":false}` once the
input went through. If the hold lasts more than a second past the longest the batch that held it may take (as when
batches follow each other), that `data` and every `data` frame the client has sent by then are discarded, all of
them, with one `error` frame (`busy`) before `{"hold":false}`.

When the writer detaches, the session gets back the size it had before a writer first resized it (with its attach
request or a `resize` frame), unless a `resize` request set a size since. A writer that never resizes leaves the size alone.

The daemon answers the program's terminal queries itself, and `out` frames carry them unchanged. A client that shows
`out` frames in a real terminal should remove queries, ENQ, kitty clipboard requests (OSC 5522), and kitty drag and drop
requests (OSC 72), and the modes 2031, 2048, and 5522, which make a terminal send reports on its own, before writing
them, as `tuppet attach` does; otherwise the terminal's replies reach the program a second time, or the user's shell
after the attach ends. Compare parameters by value (`ESC[?02048h` sets mode 2048), and treat C1 controls encoded in
UTF-8 like their ESC forms: some terminals act on them.

When the stream is ending (after the exit, a detach, a shutdown, or a `too_slow` end), the daemon gives a client that is not
reading one second to take the rest, then closes the connection.

A slow viewer never blocks the session, the daemon, or other viewers: each viewer has its own queue and sender. Other
requests (`input`, `resize`, `view`, recordings) keep working while clients are attached.

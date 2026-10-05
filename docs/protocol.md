# tuppet daemon protocol

This document describes the protocol a program uses to drive the tuppet daemon directly, without the CLI. It covers
protocol revision 1, as reported by `hello`.

## Transport

The daemon listens on a unix socket: the path given to `tuppet daemon --socket PATH` or `TUPPET_SOCKET` (supervised
mode), otherwise `$XDG_RUNTIME_DIR/tuppet-<uid>.sock`, or `/tmp/tuppet-<uid>/tuppet.sock` when `XDG_RUNTIME_DIR` is unset
or empty. The socket is mode 0600, with a lock file `<path>.lock` beside it that makes the endpoint exclusive. The daemon refuses
peers running as another user, and the CLI refuses a daemon running as another user. On Windows the endpoint is the
named pipe `\\.\pipe\tuppet-<user SID>`, and `attach` is not available.

Each message is one line of UTF-8 JSON ending in `\n`. A client connects, sends one request line, reads one reply line,
and closes. `attach` is the exception: after its reply the connection becomes a stream (see below).

Session ids are decimal strings in requests (`"id":"3"`, digits only) and numbers in replies (`"id":3`).

## Sessions and ids

All daemons of a user share one session store per machine and boot (see `tuppet help daemon`). Ids count up from 1 after
each boot and are never reused within it, so a session is identified by the boot and its id; `hello` reports the boot. A
daemon serves the sessions it started, including ended ones: their final screen and exit status survive the daemon, and
a later daemon on the same endpoint serves them again. An id that belongs to another endpoint, or to a session lost when
its daemon died, gets an error that says so.

A daemon started without `--socket` exits after 30 seconds with no programs running and no clients (`TUPPET_IDLE_EXIT` in
its environment changes that; Windows daemons do not exit when idle). Exiting closes its listener, which resets any
connection that was still waiting to be accepted; the daemon never read that request, so a client that gets a
connection reset before any reply may send it again, to a new daemon.

## Limits

- A request line may be at most 1 MiB, and a reply line at most 16 MiB.
- The request line must arrive within 10 seconds of connecting.
- The daemon serves at most 32 requests at once; further connections wait in the listen queue until a slot frees up.
  Attach streams do not count toward that limit; there can be at most 256 of them in total.

## Fields and errors

A request with a field the daemon does not know is rejected (`bad <cmd> request`), so clients check `hello` before
using a newer field or command. Replies may gain fields, and clients must ignore fields they do not know. Replies also
carry the reply type's other fields with default values, such as `"err":null` on success; the examples below leave
them out.

A failed request replies with `"ok":false` and an `err` message, including a request line that is too long or arrives
too late (the daemon then closes the connection). The message is meant for people, not for matching.

## Versioning

`hello` reports `protocol`, an integer that is bumped only for incompatible changes: a removed or renamed field or
command, or a changed meaning. Compatible additions keep the number and add an entry to `features` where a client needs
to know about them.

| Revision | Since tuppet | Features |
| --- | --- | --- |
| 1 | 0.1.0 | `attach`, `paste`, `store`, `scrollback`, `run-record` |

## Requests

### hello

`{"cmd":"hello"}` →
`{"ok":true,"version":"0.1.0","protocol":1,"features":["attach","paste","store","scrollback","run-record"],"boot":"<boot id>"}`

### run

Start a session:

```json
{"cmd":"run","argv":["vim","notes.txt"],"name":"edit","cols":120,"rows":40,"cwd":"/home/me","env":["HOME=/home/me","PATH=/usr/bin"]}
```

The reply is `{"ok":true,"id":3}`.

| Field | Meaning |
| --- | --- |
| `argv` | Required, non-empty. `argv[0]` is resolved through the `PATH` in `env`, or the daemon's `PATH` without `env`. |
| `cols`, `rows` | Grid size, each 1..1000. Default 120x40. |
| `cwd` | Working directory; must be absolute. Default: `/`, the daemon's own. |
| `env` | `"NAME=value"` entries. Omitted or `null` means the daemon's own environment. In both cases `TERM` is set to `xterm-256color`, and `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TMUX`, `TMUX_PANE`, and `STY` are removed. |
| `name` | A label shown by `list`. |
| `scrollback` | History limit in bytes of the emulator's memory, at most 1 GiB. Default 512 KiB. |
| `record` | `{"path":"/abs/file","format":"cast"}` starts a recording together with the program. `format` is `cast` (default) or `trace`; without `path` it goes into the session's store directory and is deleted with the session. |

### list

`{"cmd":"list"}` →
`{"ok":true,"sessions":[{"id":3,"name":"edit","state":"exited","pid":4242,"cols":120,"rows":40,"exit_code":0}]}`

`state` is `running`, `exited`, or `lost` (the daemon running it died). `exit_code` is set once the program has
exited; death by signal `n` is `-n`. Each entry also carries `argv`, `started_ms` and `ended_ms` (Unix time in
milliseconds), and the attached clients: `writer` (whether one controls the session) and `viewers` (how many watch).

### send

`{"cmd":"send","id":"3","data":"ls -la"}` → `{"ok":true}`

This writes `data` (a JSON string) to the session's input as it is.

With `"paste":true`, the data is pasted the way a terminal pastes. CRLF and LF become CR. If the program enabled
bracketed paste (mode 2004), the text is wrapped in `ESC[200~` … `ESC[201~`, with any end marker inside the text
removed. The reply is `{"ok":true,"bracketed":true}` or `{"ok":true,"bracketed":false}`.

An input write fails if the program stops reading its input for 5 seconds. A write fails at once if another write
to the same session is already stalled.

### key

`{"cmd":"key","id":"3","keys":["<C-c>","ihello","<Esc>"]}` → `{"ok":true}`

Keys use vim notation and are encoded for the program's current keyboard mode. If any key cannot be expressed in that
mode, the request fails and nothing is sent. `tuppet help key` describes the notation.

### mouse

```json
{"cmd":"mouse","id":"3","button":"left","action":"press","mods":"c","x":10,"y":2}
```

The reply is `{"ok":true}`.

| Field | Values |
| --- | --- |
| `button` | `left`, `right`, `middle`, `up`, `down`, `none` (motion only), or `1`..`9` |
| `action` | `press`, `release`, `motion` |
| `mods` | Modifier letters in any order, each at most once: `c` (Ctrl), `a` or `m` (Alt), `s` (Shift) |
| `x`, `y` | Zero-based cells inside the grid |

If the program has mouse reporting off, nothing is sent and the request succeeds.

### focus

`{"cmd":"focus","id":"3","focused":true}` → `{"ok":true}`

This is sent only if the program enabled mode 1004.

### resize

`{"cmd":"resize","id":"3","cols":100,"rows":30}` → `{"ok":true}`

### view

`{"cmd":"view","id":"3","format":"plain","scrollback":false}` →
`{"ok":true,"text":"...","cols":100,"rows":30,"cursor_row":5,"cursor_col":1,"exited":false,"exit_code":null,"idle_ms":120,"recording":null}`

- `format` is `plain`, `vt`, `html`, or `json`. The reply has the same shape for every format; for `json` the daemon
  returns plain text, and the CLI builds its JSON output from the reply's fields.
- The text covers the visible screen. `scrollback:true` (not with `json`) adds the history above it.
- The cursor position is 1-based.
- `exit_code` is set once the session has exited. Death by signal `n` is reported as `-n`.
- `recording` is the path of a recording started with the session (`run` with `record`).

### png

`{"cmd":"png","id":"3"}` → `{"ok":true,"png_b64":"<base64 PNG>","cols":100,"rows":30}`

### record

Start, mark, or stop a recording. Paths must be absolute.

- **Start:**
  `{"cmd":"record","id":"3","path":"/tmp/s.cast","format":"cast","input":false,"until_match":null,"until_timeout_ms":null}`
  - `format` is `cast` (asciicast v2) or `trace` (JSONL).
  - `until_match` stops the recording when the text appears on the screen or in the output.
  - `until_timeout_ms` stops it after that many milliseconds.
- **Mark:** `{"cmd":"record","id":"3","mark":"label"}` appends a marker.
- **Stop:** `{"cmd":"record","id":"3"}` stops the recording. It succeeds even if the recording already stopped by
  itself.

The reply is `{"ok":true,"active":true|false,"reason":null|"request"|"match"|"timeout"|"exit"}`. `active` tells whether a
recording is running after the request; a start can already be over if `until_match` is on screen. On a stop reply,
`reason` tells how the recording ended; start and mark replies carry `null`.

### stop

`{"cmd":"stop","id":"3"}` → `{"ok":true}`

This sends SIGHUP and SIGTERM to the session's process group, then SIGKILL to whatever is left after 0.5 seconds. It
returns once the session has exited.

### remove

`{"cmd":"remove","id":"3"}` → `{"ok":true}`

This deletes an ended (or lost) session and its stored data, including a recording in its store directory. A running
session gets `session still running`.

## Attach streams

`{"cmd":"attach","id":"3","mode":"read","force":false}`

- `mode` is `read` (a viewer) or `write` (the writer).
- A session has any number of viewers and at most one writer. A second write attach fails unless `force` is `true`. In
  that case the previous writer receives `{"writer":"taken"}` and continues as a viewer.

The reply is one line: `{"ok":true,"cols":C,"rows":R}`, or `{"ok":false,"err":"..."}`. After a successful reply, the
connection carries JSON lines in both directions until either side closes it.

### Daemon to client

| Frame | Meaning |
| --- | --- |
| `{"screen":"<base64>"}` | Sent first: a full redraw of the current screen as VT bytes. It starts with a terminal reset (`ESC c`), then sets the palette, modes, screen content, and cursor. The daemon takes it under the same lock as the subscription, so the following `out` frames continue exactly where it ends. |
| `{"out":"<base64>"}` | Raw pty output, as it arrives. |
| `{"resize":{"cols":C,"rows":R}}` | The session's size changed. |
| `{"exit":{"code":N,"signal":null}}` or `{"exit":{"code":null,"signal":"SIGKILL"}}` | The program exited. The daemon then closes the stream. |
| `{"writer":"taken"}` | A forced attach took the writer role; this client is now read-only. |
| `{"error":"<message>"}` | A rejected client frame. The stream continues. |
| `{"error":"too slow; reattach"}` | This client fell more than 4 MiB behind. The daemon disconnects it after this line (best effort). |

### Client to daemon (writer only)

| Frame | Meaning |
| --- | --- |
| `{"data":"<base64>"}` | Input to the pty, as with `send`. |
| `{"resize":{"cols":C,"rows":R}}` | Resize the session, as with `resize`. |
| `{"detach":true}` | End the stream. Viewers may send this too. |

The daemon answers the program's terminal queries itself, and `out` frames carry them unchanged. A client that shows
`out` frames in a real terminal should remove queries (and the modes 2031 and 2048, which make a terminal send reports
on its own) before writing them, as `tuppet attach` does; otherwise the terminal's replies reach the program a second
time, or the user's shell after the attach ends.

A viewer's `data` and `resize` frames are answered with an `error` frame, and the stream continues. A client frame
longer than the 1 MiB line limit ends the stream after an `error` frame. Clients may send frames right behind the
attach request without waiting for the reply. Clients skip empty lines.

When the stream is ending (after the exit event, a detach, or a "too slow" line), the daemon gives a client that is not
reading one second to take the rest, then closes the connection.

A slow viewer never blocks the session, the daemon, or other viewers: each viewer has its own queue and sender. Other
requests (`send`, `key`, `mouse`, `resize`, `view`, recordings) keep working while clients are attached.

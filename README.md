# tuppet

tuppet (TUI puppet) lets scripts drive terminal programs. It runs vim, htop, a REPL, or any curses or Bubble Tea app in a
headless terminal, sends it keys and mouse events, waits for text to appear, and reads the screen back as text, JSON,
HTML, or a PNG.

It is made for coding agents and end-to-end tests: anything that must operate a program that needs a real terminal.
Terminal emulation comes from [Ghostty](https://github.com/ghostty-org/ghostty)'s VT core, so programs see an
xterm-compatible terminal that answers cursor-position, color, and mode queries.

With `tuppet` and `vim` on your `PATH`:

```console
$ id=$(tuppet run vim notes.txt)                                 # start vim in a session
$ tuppet wait $id --match notes.txt                              # wait until vim shows the file name
$ tuppet key $id i 'Hello from tuppet' '<Esc>' ':wq' '<Enter>'   # type a line, save, and quit
$ tuppet wait $id --exit                                         # wait for vim to exit
$ tuppet remove $id                                              # delete the ended session
$ cat notes.txt
Hello from tuppet
```

## Install

Download the archive for your platform from the [releases page](https://github.com/nmeilick/tuppet/releases), unpack it,
and put `tuppet` on your `PATH`. Each release lists SHA-256 checksums in `SHA256SUMS`.

To build from source you need [Zig 0.16.0](https://ziglang.org/download/) and network access for the first build, which
downloads Ghostty:

```sh
git clone https://github.com/nmeilick/tuppet && cd tuppet
make                              # or: zig build -Doptimize=ReleaseSafe
cp zig-out/bin/tuppet ~/.local/bin/
```

Linux is the supported platform for now; see [Platform support](#platform-support).

## Usage

| Command | What it does |
| --- | --- |
| `tuppet run [-a] [--name n] [--size WxH] [--cwd dir] [--record] <cmd...>` | Start a session and print its id, or attach to it (`-a`). |
| `tuppet list` | List sessions with id, pid, name, state, size, and exit status. |
| `tuppet stop <id>` | Hang up and terminate the program's process group, killing what is left after 0.5 s. |
| `tuppet remove <id>` | Delete an ended session and what tuppet kept of it. |
| `tuppet key <id> <keys...>` | Send keys in vim notation, such as `<C-c>`, `<Esc>`, `<Up>`, `<S-Tab>`, or `<F5>`. Other tokens are typed as text. |
| `tuppet send <id> [--paste] <text...>` | Write raw text, or paste it (`--paste` must directly follow the id). |
| `tuppet mouse <id> <button> <x> <y>` | Send a mouse event at zero-based cell coordinates. |
| `tuppet focus <id> on\|off` | Send a focus-in or focus-out event. |
| `tuppet resize <id> WxH` | Resize the terminal. |
| `tuppet view <id> [--format plain\|vt\|html\|json] [--scrollback]` | Print the visible screen, or with `--scrollback` also the history above it. |
| `tuppet png <id> <file>` | Render the visible screen to a PNG file. |
| `tuppet wait <id> [--match s] [--idle ms] [--exit]` | Block until text appears, output goes quiet, or the program exits. |
| `tuppet watch <id>` | Print the screen every 500 ms until the session ends. |
| `tuppet record <id> [<file>]` | Start or stop an asciicast or trace recording. |
| `tuppet trace <id> <file> <steps...>` | Run a scripted flow and record it in one call. |
| `tuppet attach [<id>]` | Show a session live in your terminal and type into it; without an id, open the session picker. |

`tuppet help <command>` describes each option and its default, usually with an example.

### Waiting instead of sleeping

Keys reach the program before it has redrawn, so read the screen only after waiting for the state you expect.
`tuppet wait --match` polls the visible screen for a string, `--idle` waits for output to pause, and `--exit` waits for
the program to end. On timeout (30 s by default) `wait` exits 1 and prints the screen it saw, which usually shows why. If
the program exits before the text appears, `wait --match` fails at once.

Matching works on the visible screen one row at a time. Text that wrapped onto the next row does not match as a single
string, and text that has scrolled away is only visible to `view --scrollback`.

### Keys, paste, and mouse

`tuppet key` encodes keys for the program's current keyboard mode, including application cursor keys and the kitty
keyboard protocol, so `<Up>` sends whatever the program expects. Quote bracketed keys for the shell: `'<Enter>'`. The
command fails without sending anything if one of its keys cannot be expressed in the program's keyboard mode, such as
F13 outside the kitty protocol.

`tuppet send --paste` delivers text the way a terminal pastes it. Line endings become carriage returns, and if the
program enabled bracketed paste the text is wrapped in paste markers. A multi-line message then reaches a chat-style TUI
as one message instead of being submitted line by line.

`tuppet mouse` and `tuppet focus` follow the program's reporting modes like a real terminal: if the program has mouse or
focus reporting turned off, nothing is sent.

### Snapshots

`tuppet view` prints the screen as plain text by default. `--format json` adds the size, the cursor position (1-based),
whether the program has exited and with which code, and how long the output has been idle. `--format vt` keeps colors as
escape sequences, and `--format html` produces an HTML fragment with inline styles.

`tuppet png` draws the screen with an 8x16 VGA font that covers Latin-1, box drawing, and block elements; other
characters appear as a replacement glyph. Screens larger than roughly 480x480 cells exceed the renderer's 128 MiB limit.

### Recording and traces

`tuppet record <id> demo.cast` starts an [asciicast v2](https://docs.asciinema.org/manual/asciicast/v2/) recording that
asciinema and agg can play; `tuppet record <id>` stops it. With `--format trace` it writes a JSON-lines timeline instead:
every input, a row-level diff after every chunk of output, markers, and the reason the recording stopped, with the exit
code when the program ended. Traces are plain text you can grep, and they keep short-lived states such as spinners and
flicker. `--until-match` and `--until-timeout` let the daemon end a recording on its own.

`tuppet run --record` starts a recording together with the program, so even a program that exits at once is recorded in
full. The recording is kept with the session; `tuppet view <id> --format json` shows its path.

`tuppet trace` runs a whole flow and records it. In a vim session, this types a line, saves, and checks that vim confirmed
the write:

```sh
tuppet trace $id save.trace --key i --send hello --key '<Esc>' --send ':w' --key '<Enter>' --expect written
```

It checks every step before sending anything, always stops its recording, and prints a JSON summary such as
`{"ok":true,"steps":6,"elapsed_ms":103}`. When an `--expect` fails it exits 3 and prints the screen at that moment.

Recordings are readable only by you, because they contain everything typed into the session.

### Live attach and the session picker

`tuppet attach` without an id opens the session picker: your sessions, newest first, with a live preview of the selected
one. Enter shows a session full screen without controlling it, and ←/→ step through the others; `a` takes control, and
Ctrl-] brings you back to the picker. `?` lists every key.

`tuppet attach <id>` connects your terminal to one session directly: you see the program, your keystrokes reach it, and
your terminal size is applied to it. `tuppet run -a <cmd...>` starts a session and attaches to it in one step. Ctrl-]
detaches, and the program keeps running; tuppet prints the session id so you can come back.

A session can have any number of viewers (`--read-only`) and one writer; `--force` takes the writer role from someone
else. Attach lets you watch an agent work and take over by hand. Other commands keep working while clients are attached.

## Use with coding agents

`tuppet llm-skill` prints a skill file that teaches a coding agent when and how to use tuppet. Install it where your agent
looks for skills, for example for Claude Code:

```sh
mkdir -p ~/.claude/skills/tuppet && tuppet llm-skill > ~/.claude/skills/tuppet/SKILL.md
```

## How it works

The first tuppet command starts a background daemon for your user. The daemon owns every session: it runs each program on
a pseudo-terminal, feeds the program's output through the emulator, and answers terminal queries the way a real terminal
would. CLI commands are short requests to the daemon, so a session keeps running between commands and can be driven from
any shell. The daemon runs detached, so Ctrl-C or a closed terminal does not take it or its sessions down. Once no
programs are running, it exits after 30 seconds (except on Windows), and the next command starts a new one.

Sessions start in your current directory with your environment and `TERM=xterm-256color`, without the variables that
describe your own terminal (`TERM_PROGRAM`, `TMUX`, `STY`). Each session's terminal is 120x40, whatever the size of your
own terminal; `--size` sets another size for one session.

### What tuppet keeps

When a program ends, tuppet keeps its final screen, its history, and its exit status, so you can still `view`, `png`, or
`attach` to it, even after the daemon has exited. `tuppet list` shows ended sessions with their exit code until you
`tuppet remove` them, or for 7 days after they ended.

Session ids count up from 1 after each boot and are never reused before the next one, so an id only ever means one
session. If a daemon dies while a program runs, the program gets a hangup and usually ends; one that ignores the hangup
keeps running without tuppet. Either way, `tuppet list` reports the session as `lost`.

History is limited to 512 KiB of the emulator's memory per session, about 700 lines at the default width. To keep
everything a program prints, start it with `tuppet run --record`.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `TUPPET_SIZE` | `120x40` | Terminal size of new sessions. |
| `TUPPET_SCROLLBACK` | `512K` | History memory per session, in bytes or with `K`, `M`, or `G`; `0` keeps none. |
| `TUPPET_KEEP` | `7d` | How long ended sessions are kept, with `s`, `m`, `h`, or `d`; `0` keeps them until removed. |
| `TUPPET_IDLE_EXIT` | `30` | Seconds the daemon waits with no programs running before it exits; `0` keeps it running. |
| `TUPPET_SOCKET` | | Use the daemon on this socket and never start one (same as `--socket`). |

`TUPPET_SIZE` and `TUPPET_SCROLLBACK` apply to each `tuppet run`; `--size` and `--scrollback` override them.
`TUPPET_KEEP` and `TUPPET_IDLE_EXIT` are read by the daemon when it starts, so set them for the command that starts it.

The daemon listens on `$XDG_RUNTIME_DIR/tuppet-<uid>.sock`, or on `/tmp/tuppet-<uid>/tuppet.sock` when
`XDG_RUNTIME_DIR` is unset, and logs next to it with `.log` in place of `.sock`. Only you can connect. Session data lives
in `$XDG_STATE_HOME/tuppet` (by default `~/.local/state/tuppet`), in one directory per machine and boot, so a home
directory shared between machines keeps them apart. Only you can read it. A starting daemon deletes data from this
machine's earlier boots.

## Running the daemon yourself

A program that manages tuppet's lifetime, such as an agent runner, can start the daemon on a socket of its choice:

```sh
tuppet daemon --socket /run/app/tuppet.sock --log /var/log/app/tuppet.log &
TUPPET_SOCKET=/run/app/tuppet.sock tuppet run vim notes.txt
```

With `--socket` or `TUPPET_SOCKET`, commands talk only to that daemon and never start one. This daemon does not exit when
idle; on SIGTERM or SIGINT it stops every session and exits. On Linux, the sessions' programs are killed even if the
daemon is killed with SIGKILL; background jobs that ignore SIGHUP can survive that. All your daemons share the session
data, so the shortest `TUPPET_KEEP` among them applies to every session.

Programs can also skip the CLI and speak the daemon's JSON-lines protocol directly; [docs/protocol.md](docs/protocol.md)
describes every request and reply.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Runtime failure, such as an unknown session, an unreachable daemon, or a `wait` timeout. The message is on stderr. |
| 2 | Invalid arguments. Nothing was sent. |
| 3 | A `tuppet trace` expectation failed. |
| 128+n | Interrupted by signal n (`tuppet trace`, `tuppet attach`). |

`tuppet attach` exits with the program's exit code when the session ends while attached.

## Upgrading

A running daemon keeps its version until it exits. After you install a new tuppet, the old daemon exits 30 seconds after
your last program ends (on Windows, stop it yourself), and the next command starts the new version. To switch at once, stop your running sessions and
run `pkill -u "$USER" -x tuppet`; this also ends attach clients and daemons other programs started. Ended sessions survive
the switch.

## Platform support

| Platform | Status |
| --- | --- |
| Linux (x86_64, aarch64) | Supported. The test suite runs on x86_64. |
| macOS (x86_64, aarch64) | Builds; not tested at runtime. |
| Windows (x86_64, aarch64) | Builds with ConPTY sessions and named-pipe IPC; not tested at runtime. `attach` and the picker are not available, and the daemon does not exit when idle. |

Linux binaries are static. macOS binaries link only the system library, and Windows binaries only system DLLs.

## Development

```sh
make check      # format check, unit tests, end-to-end tests
make test       # unit tests only
make e2e        # end-to-end scripts, each against its own isolated daemon
make dist       # release archives for all six targets in zig-out/dist
make help       # all targets
```

`make` builds in ReleaseSafe mode, which is also what releases ship. Avoid plain Debug builds for real use: the
emulator's internal checks make heavy output so slow that `tuppet wait` can time out. The end-to-end tests need bash and
python3.

GitHub Actions runs `make check` and cross-compiles every target on each push to `main` and each pull request. To
release, set `.version` in `build.zig.zon` and push a matching tag such as `v0.1.0`: the release workflow then runs the
tests, builds the archives with `make dist`, and publishes them with `SHA256SUMS` on the tag's GitHub release.

## License

MIT; see [LICENSE](LICENSE). Release binaries include code from Ghostty and other projects under their own licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

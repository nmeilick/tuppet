//! tuppet - a TUI puppet: puppeteer for TUIs, built on libghostty-vt.
//!
//! Architecture: a daemon owns PTY sessions and parses their output with
//! Ghostty's terminal emulation core. A small CLI talks to the daemon over
//! a unix socket with JSON-lines messages.

const std = @import("std");
const io_mod = @import("io.zig");
const daemon = @import("daemon.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const plat = @import("plat.zig");
const protocol = @import("protocol.zig");

/// A panic while the picker or an attach holds the terminal raw must not
/// leave it unusable.
pub const panic = std.debug.FullPanic(struct {
    fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        attach_client.restoreAfterPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.onPanic);

/// The emulator logs every escape sequence it does not implement; child
/// output must not be able to grow the daemon log without bound.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .stream, .level = .err }},
};

const usage_text =
    \\tuppet - a TUI puppet: drive terminal programs from scripts
    \\
    \\usage: tuppet [--socket PATH] <command> [arguments]
    \\
    \\--socket PATH (or TUPPET_SOCKET=PATH) talks to the daemon listening on
    \\PATH and never starts one; see 'tuppet help daemon'.
    \\
    \\sessions:
    \\  tuppet run [-a] [--name n] [--size WxH] [--cwd dir] [--record] <cmd...>
    \\                                    start a session and print its id, or attach
    \\                                    to it (-a)
    \\  tuppet list                       list sessions (id, pid, name, state, size,
    \\                                    exit status)
    \\  tuppet stop <id>                  terminate the program's process group
    \\  tuppet remove <id>                delete an ended session
    \\
    \\input:
    \\  tuppet send <id> [--paste] <text...>
    \\                                    write raw bytes to the session, or paste
    \\                                    them (--paste)
    \\  tuppet key <id> [--delay ms] <keys...>
    \\                                    send vim-notation keys, encoded against the
    \\                                    live terminal state, e.g. <C-c> <Esc> <Up>
    \\                                    <S-Tab> ! q
    \\  tuppet mouse <id> <button> <x> <y>
    \\               [--action press|release|motion] [--mods cas] [--delay ms]
    \\                                    send a mouse event; button: left, right,
    \\                                    middle, up, down, none, or 1..9 (x/y are
    \\                                    zero-based cell coordinates)
    \\  tuppet focus <id> <on|off>        send a focus-in/out event (mode 1004)
    \\  tuppet resize <id> WxH            resize the pty and reflow the screen
    \\
    \\output:
    \\  tuppet view <id> [--format plain|vt|html|json] [--scrollback]
    \\                                    snapshot the screen (json adds cursor, exit
    \\                                    state, and idle time)
    \\  tuppet png <id> <file.png>        render the screen to a PNG file
    \\  tuppet record <id> <file> [--format cast|trace] [--input]
    \\                [--until-match s] [--until-timeout ms]
    \\                                    start a recording: cast is asciicast v2
    \\                                    (--input adds input events), trace a JSONL
    \\                                    timeline of input, screen diffs, and the
    \\                                    stop; --until-* stop it daemon-side when
    \\                                    text appears or time runs out
    \\  tuppet record <id> --mark label   append a marker to the active recording
    \\  tuppet record <id>                stop the recording
    \\  tuppet trace <id> <file> [--format trace|cast] [--timeout ms]
    \\               <steps...>
    \\                                    record a whole flow in one call; steps run
    \\                                    in order: --key k, --send t, --mouse b x y,
    \\                                    --sleep ms, --expect s [--within ms], --mark
    \\                                    label. Exit 3 when an expect fails (the
    \\                                    screen is printed to stderr); a JSON summary
    \\                                    goes to stdout unless the arguments are
    \\                                    invalid
    \\  tuppet wait <id> [--exit] [--match s] [--idle ms] [--timeout ms]
    \\                                    block until a condition (--timeout defaults
    \\                                    to 30 s; fails on timeout, printing the
    \\                                    screen)
    \\  tuppet watch <id> [--format plain|json] [--interval ms]
    \\                                    print snapshots until the session exits
    \\  tuppet attach [<id>] [--read-only] [--force] [--detach-key KEY]
    \\                [--no-resize]
    \\                                    connect this terminal to the session live
    \\                                    (detach with Ctrl-]); without an id, open
    \\                                    the session picker
    \\
    \\coding agents:
    \\  tuppet llm-skill                  print a SKILL.md that teaches a coding agent
    \\                                    how to drive terminal programs with tuppet
    \\
    \\other:
    \\  tuppet daemon [--socket PATH] [--log PATH]
    \\                                    run the daemon in the foreground
    \\  tuppet help [<command>]           full usage, or one command's options,
    \\                                    defaults, and examples (also: tuppet
    \\                                    <command> --help)
    \\  tuppet --version | -V             show the version
    \\
;

const run_help =
    \\tuppet run - start a session in a new emulated terminal
    \\
    \\usage: tuppet run [-a] [--name n] [--size WxH] [--cwd dir]
    \\                  [--scrollback SIZE] [--record] [--record-file FILE]
    \\                  [--record-format cast|trace] [--] <cmd...>
    \\
    \\Runs <cmd...> on a pty owned by the daemon and prints the new
    \\session id to stdout. The command runs in your current directory
    \\with your environment and TERM=xterm-256color, without the
    \\variables that describe your own terminal (TERM_PROGRAM, TMUX,
    \\STY). The session keeps running after this command exits; use
    \\'tuppet stop <id>' to terminate it.
    \\
    \\When the program ends, its final screen and exit status are kept
    \\(see 'tuppet help list'). Ids count up from 1 after each boot and are
    \\never reused before the next one.
    \\
    \\options:
    \\  -a, --attach attach this terminal to the session right away
    \\               instead of printing its id, as 'tuppet attach' does
    \\  --name n     label shown by 'tuppet list'
    \\  --size WxH   terminal size in cells, 1..1000 per side
    \\               (default 120x40, or TUPPET_SIZE; with -a this
    \\               terminal's size, and an explicit size stays fixed)
    \\  --cwd dir    working directory for the command (default: the
    \\               current directory)
    \\  --scrollback SIZE
    \\               memory for history, in bytes or with K, M, or G
    \\               (default 512K, about 700 lines of 120 columns; 0
    \\               keeps none; TUPPET_SCROLLBACK sets the default)
    \\  --record     record everything from the first byte into the
    \\               session's data, deleted with the session; 'tuppet
    \\               view <id> --format json' shows the path
    \\  --record-file FILE
    \\               record to FILE instead, which tuppet never deletes
    \\  --record-format f
    \\               cast (default) or trace; see 'tuppet help record'
    \\  --           treat the rest as the command even if it starts
    \\               with a dash
    \\
    \\examples:
    \\  tuppet run vim
    \\  tuppet run -a htop
    \\  tuppet run --record --scrollback 4M make test
    \\  tuppet run --name build --size 120x40 -- make -j8
    \\
;

const list_help =
    \\tuppet list - list all sessions
    \\
    \\usage: tuppet list
    \\
    \\Prints one tab-separated line per session:
    \\
    \\  id  pid  name  state  size  exit
    \\
    \\state is "running", "exited", or "lost" (its daemon stopped while
    \\it ran, so how it ended is unknown); size is the terminal size in
    \\cells; exit is the exit code, or the signal that killed the
    \\program, and empty while it runs. Ended sessions stay listed,
    \\even across daemon restarts, until 'tuppet remove <id>' or 7 days
    \\after they ended (TUPPET_KEEP, see 'tuppet help daemon').
    \\
;

const stop_help =
    \\tuppet stop - terminate a session
    \\
    \\usage: tuppet stop <id>
    \\
    \\Sends SIGHUP and SIGTERM to the program's process group, as closing a
    \\terminal would (shells pass the hangup on to their jobs), then
    \\SIGKILL to whatever is left after 0.5 s. Processes that left the
    \\session (setsid, daemons) are not tracked. The session stays
    \\listed as "exited" until 'tuppet remove <id>'.
    \\
;

const remove_help =
    \\tuppet remove - delete an ended session
    \\
    \\usage: tuppet remove <id>
    \\
    \\Deletes the session and everything tuppet kept about it: its screen,
    \\its exit status, and a recording made with 'tuppet run --record'
    \\(but not one written to a file you named). Only ended sessions
    \\can be removed; stop a running one first with 'tuppet stop <id>'.
    \\Its id is never used again until the machine reboots.
    \\
;

const send_help =
    \\tuppet send - write raw bytes to a session
    \\
    \\usage: tuppet send <id> [--paste] <text...>
    \\
    \\Joins the text arguments with single spaces and writes them to the
    \\session's pty verbatim: no newline is appended and nothing is
    \\interpreted. Use 'tuppet key' for enter, escape, arrows, and control
    \\keys.
    \\
    \\--paste (directly after the id) delivers the text as a terminal
    \\paste: line endings become CR, and if the program enabled
    \\bracketed paste (mode 2004) the text is wrapped in ESC[200~ and
    \\ESC[201~, so a multi-line message arrives as one input instead of
    \\being submitted line by line.
    \\
    \\If the program stops reading its input for 5 s, the command
    \\fails; part of the text may have been delivered.
    \\
    \\examples:
    \\  tuppet send 2 ls -la; tuppet key 2 '<Enter>'
    \\  tuppet send 2 --paste "$(cat prompt.txt)"
    \\
;

const key_help =
    \\tuppet key - send keys in vim-style notation
    \\
    \\usage: tuppet key <id> [--delay ms] <keys...>
    \\
    \\A bracketed token is one key: <enter>, <esc>, <tab>, <space>, <bs>,
    \\<del>, <home>, <end>, <ins>, <up>, <down>, <left>, <right>, <pgup>,
    \\<pgdown>, <f1>..<f25>, or a single character. Modifiers go inside
    \\the brackets: C ctrl, M or A alt, S shift, D super; e.g. <C-c>,
    \\<S-Tab>, <M-x>, <C-->. As in vim, <C-C> is <C-c>; write <C-S-c>
    \\for Ctrl+Shift. A bracketed name that is not a key is rejected, so
    \\a typo is never typed as text.
    \\
    \\Any other token is typed as text, character by character: 'Enter'
    \\types five letters; use <Enter> for the key. Tabs, newlines, and
    \\other control characters in text are sent as the keys that type
    \\them. A key the program's keyboard mode cannot express (F13 and
    \\above outside the kitty protocol) is an error.
    \\
    \\Keys are encoded against the live terminal state (application
    \\cursor keys, kitty keyboard protocol, ...), so <Up> sends whatever
    \\bytes the running program actually expects.
    \\
    \\options:
    \\  --delay ms   wait before sending (default 0); useful right
    \\               after 'tuppet run' while the program is still starting
    \\
    \\examples:
    \\  tuppet key 2 i hello '<Esc>'
    \\  tuppet key 2 '<C-c>'
    \\
;

const mouse_help =
    \\tuppet mouse - send a mouse event
    \\
    \\usage: tuppet mouse <id> <button> <x> <y>
    \\                    [--action press|release|motion] [--mods cas] [--delay ms]
    \\
    \\button is left, right, middle, up or down (wheel), none (motion
    \\with no button held, with --action motion), or a number in
    \\Ghostty's numbering: 1 left, 2 right, 3 middle, 4 and 5 wheel,
    \\6..9 extra buttons. The wheel has no release. x and y are
    \\zero-based cell coordinates; coordinates outside the session grid
    \\are rejected. The event is encoded in the mouse mode the
    \\program requested: a program that never enabled mouse
    \\reporting sees nothing (and the command succeeds), while an event
    \\the active mode cannot report is an error.
    \\
    \\options:
    \\  --action a   press (default), release, or motion
    \\  --mods cas   held modifiers, each at most once: c ctrl, a (or m)
    \\               alt, s shift
    \\  --delay ms   wait before sending (default 0)
    \\
    \\examples:
    \\  tuppet mouse 2 left 10 3                    (click)
    \\  tuppet mouse 2 left 10 3 --action release
    \\  tuppet mouse 2 up 0 0                       (scroll up)
    \\
;

const focus_help =
    \\tuppet focus - send a focus-in/out event
    \\
    \\usage: tuppet focus <id> <on|off>
    \\
    \\Emulates the terminal gaining ('on') or losing ('off') focus.
    \\Only programs that enabled focus reporting (mode 1004) see
    \\these events.
    \\
;

const resize_help =
    \\tuppet resize - change the terminal size
    \\
    \\usage: tuppet resize <id> WxH
    \\
    \\Resizes the pty and the emulated screen; W and H are in cells,
    \\1..1000 per side. The program receives SIGWINCH and the
    \\screen reflows, as in a real terminal.
    \\
    \\example:
    \\  tuppet resize 2 120x40
    \\
;

const view_help =
    \\tuppet view - snapshot the screen
    \\
    \\usage: tuppet view <id> [--format plain|vt|html|json] [--scrollback]
    \\
    \\Shows the visible screen. --scrollback adds the history above it
    \\(plain, vt, and html only).
    \\
    \\formats:
    \\  plain   screen text with trailing whitespace trimmed (default)
    \\  vt      text plus the escape sequences that reproduce colors
    \\  html    an HTML fragment with inline styles
    \\  json    plain text plus size, cursor position (1-based, unlike
    \\          the zero-based cells of 'tuppet mouse'), exit state,
    \\          idle_ms (milliseconds since the last output), and the
    \\          path of a recording made with 'tuppet run --record'
    \\
    \\An ended session shows its final screen, even after the daemon
    \\that ran it has exited.
    \\
    \\example:
    \\  tuppet view 2 --format json
    \\
;

const png_help =
    \\tuppet png - render the screen to a PNG file
    \\
    \\usage: tuppet png <id> <file.png>
    \\
    \\Renders the visible screen, colors included, and writes a PNG to
    \\the given path (relative to your working directory). The bitmap
    \\font covers Latin-1, box drawing, and blocks; other characters
    \\draw as a replacement glyph.
    \\
;

const record_help =
    \\tuppet record - start, annotate, or stop a screen recording
    \\
    \\usage: tuppet record <id> <file> [--format cast|trace] [--input]
    \\                     [--until-match s] [--until-timeout ms]
    \\       tuppet record <id> --mark label
    \\       tuppet record <id>
    \\
    \\With a file path a recording starts; with neither path nor --mark
    \\the active recording stops (safe even after an automatic stop).
    \\Paths are relative to your working directory.
    \\
    \\formats:
    \\  cast    asciicast v2 (default), playable with asciinema
    \\  trace   a JSONL timeline: a start event and an initial snap,
    \\          an "in" event per accepted input, a "diff" (or "snap"
    \\          when most of the screen changed) after each output
    \\          chunk, "mark" events, and a final snap plus "stop"
    \\
    \\options at start:
    \\  --format f           cast (default) or trace
    \\  --input              record input events in a cast file too
    \\                       (trace always records them)
    \\  --until-match s      stop automatically when s appears on screen
    \\                       or in the output
    \\  --until-timeout ms   stop automatically after this long
    \\
    \\The stop event records its reason: "request" (stopped via
    \\'tuppet record <id>'), "match", "timeout", or "exit" (the session
    \\ended). --until-match and --until-timeout are enforced by the
    \\daemon, so they fire even when this command is no longer running.
    \\
    \\'tuppet record <id> --mark label' appends a marker to the active
    \\recording and takes no other options.
    \\
    \\examples:
    \\  tuppet record 2 demo.cast
    \\  tuppet record 2 flow.trace --format trace --until-timeout 5000
    \\  tuppet record 2 --mark before-quit
    \\  tuppet record 2
    \\
;

const trace_help =
    \\tuppet trace - record a whole interaction flow in one call
    \\
    \\usage: tuppet trace <id> <file> [--format trace|cast] [--timeout ms]
    \\                    <steps...>
    \\
    \\Starts a recording, runs the steps in order, then stops the
    \\recording, even on errors and Ctrl-C. All steps, including mouse
    \\coordinates against the session size, are validated before
    \\anything is sent, so a malformed trace fails without touching the
    \\session (exit 2).
    \\
    \\steps:
    \\  --key k         send one key (same notation as 'tuppet key')
    \\  --send t        write raw text (same as 'tuppet send')
    \\  --mouse b x y   click button b at cell (x, y): press, then
    \\                  release (the wheel only presses)
    \\  --sleep ms      wait
    \\  --expect s      wait until s appears on screen (trailing
    \\                  spaces in s are ignored, as for tuppet wait)
    \\  --within ms     per-expect deadline; must directly follow an
    \\                  --expect (default: the --timeout value)
    \\  --mark label    append a marker to the recording
    \\
    \\options:
    \\  --format f    trace (default) or cast; see 'tuppet help record'
    \\  --timeout ms  default deadline for --expect (default 10000)
    \\
    \\output: a JSON summary line on stdout on every exit except bad
    \\arguments (exit 2), e.g.
    \\  {"ok":true,"steps":5,"elapsed_ms":1234}
    \\
    \\exit codes:
    \\  0  all steps ran and every expect matched
    \\  1  a daemon request failed mid-flow ("error" in the summary)
    \\  2  bad arguments (nothing was sent)
    \\  3  an expect failed: the screen at that moment is printed to
    \\     stderr and the summary has "ok":false, "failed_step"
    \\     (counted from 1), and "reason" ("timeout", or "exited" if
    \\     the session ended)
    \\  128+n  interrupted by signal n ("interrupted":true)
    \\
    \\example:
    \\  tuppet trace 2 quit.trace --key : --send 'q!' --key '<Enter>' \
    \\      --expect '$' --within 3000
    \\
;

const wait_help =
    \\tuppet wait - block until a condition holds
    \\
    \\usage: tuppet wait <id> [--exit] [--match s] [--idle ms] [--timeout ms]
    \\
    \\At least one condition is required; several are OR-ed:
    \\  --exit      the session's process has exited
    \\  --match s   s appears on the visible screen (rows have trailing
    \\              spaces trimmed, so trailing spaces in s are ignored)
    \\  --idle ms   no new output for this many milliseconds
    \\
    \\options:
    \\  --timeout ms   give up after this long (default 30000). On
    \\                 timeout the current screen is printed to stderr
    \\                 and the exit code is 1.
    \\
    \\Polls every 100 ms.
    \\
    \\examples:
    \\  tuppet wait 2 --match 'Press any key' --timeout 5000
    \\  tuppet wait 2 --exit
    \\
;

const watch_help =
    \\tuppet watch - print snapshots until the session exits
    \\
    \\usage: tuppet watch <id> [--format plain|json] [--interval ms]
    \\
    \\Prints a screen snapshot every --interval milliseconds (default
    \\500) until the session exits. Formats are plain and json (the
    \\same shape as 'tuppet view --format json').
    \\
;

const daemon_help =
    \\tuppet daemon - run the daemon in the foreground
    \\
    \\usage: tuppet daemon [--socket PATH] [--log PATH]
    \\
    \\The daemon owns the sessions and their ptys. Any other command
    \\starts it detached when it cannot reach one, so running it by hand
    \\is only needed for debugging or under a supervisor. It listens on
    \\$XDG_RUNTIME_DIR/tuppet-<uid>.sock, or /tmp/tuppet-<uid>/tuppet.sock when
    \\XDG_RUNTIME_DIR is unset or empty. An auto-started daemon logs to
    \\the same path with .log in place of .sock.
    \\
    \\Without --socket the daemon exits after 30 s with no programs
    \\running and no clients (not on Windows); the next command starts a
    \\new one. TUPPET_IDLE_EXIT=s sets the wait in seconds, and
    \\TUPPET_IDLE_EXIT=0 keeps the daemon running.
    \\
    \\Session data lives in $XDG_STATE_HOME/tuppet (~/.local/state/tuppet;
    \\%LOCALAPPDATA%\\tuppet on Windows), one directory per machine and boot,
    \\readable only by you. Every daemon of yours shares it, so session
    \\ids are unique per boot, but each daemon shows only its own
    \\sessions. A starting daemon deletes its machine's data of other
    \\boots, and ended sessions are deleted 7 days after they ended.
    \\TUPPET_KEEP, read when a daemon starts, sets that (e.g. 12h, 30d; 0
    \\keeps them until 'tuppet remove'); the shortest setting among your
    \\daemons applies.
    \\
    \\Supervised mode (--socket): for a program that owns tuppet's lifetime.
    \\The daemon listens on exactly PATH (mode 0600), fails if a daemon is
    \\already live there, and replaces a stale socket file. SIGTERM or
    \\SIGINT stops every session (as 'tuppet stop' does) and exits. On Linux
    \\each session's program is killed if the daemon dies, even by
    \\SIGKILL; background jobs that ignore SIGHUP can survive that.
    \\Clients reach it with 'tuppet --socket PATH <command>' or TUPPET_SOCKET;
    \\they never start a daemon of their own and fail with exit 1 when
    \\nothing listens on PATH.
    \\
    \\options:
    \\  --socket PATH  listen on PATH (supervised mode; TUPPET_SOCKET=PATH
    \\                 does the same)
    \\  --log PATH     append the daemon's log to PATH (with --socket)
    \\
    \\example:
    \\  tuppet daemon --socket /run/app/tuppet.sock --log /var/log/app/tuppet.log &
    \\  TUPPET_SOCKET=/run/app/tuppet.sock tuppet list
    \\
;

const help_help =
    \\tuppet help - show help
    \\
    \\usage: tuppet help [<command>]
    \\       tuppet <command> --help
    \\
    \\Without an argument, lists all commands. With a command name,
    \\shows that command's options, defaults, and examples.
    \\'tuppet --version' prints the version.
    \\
;

const attach_help =
    \\tuppet attach - connect this terminal to a session live
    \\
    \\usage: tuppet attach <id> [--read-only] [--force] [--detach-key KEY]
    \\                     [--no-resize]
    \\       tuppet attach
    \\
    \\Shows the session's screen in this terminal and keeps it live. By
    \\default this attach is the session's writer: keystrokes go to the
    \\program and this terminal's size is applied to the session, also
    \\when it changes. A session has any number of read-only viewers and
    \\at most one writer; other commands (send, key, mouse, resize) keep
    \\working meanwhile.
    \\
    \\Without an id, opens the session picker: your sessions, newest
    \\first, with a live preview. Enter shows a session full screen
    \\without controlling it, ←/→ switch to the previous or next one, 'a'
    \\takes control, Ctrl-] returns to the picker, and '?' lists every
    \\key. Outside a terminal it lists the sessions.
    \\
    \\The detach key (Ctrl-] unless set) ends the attach and is never
    \\passed to the program. The terminal is restored on every exit.
    \\
    \\options:
    \\  --read-only       only watch; keyboard input other than the detach
    \\                    key is ignored
    \\  --force           take over writing from the current writer, which
    \\                    continues read-only
    \\  --detach-key KEY  ^X, <C-x>, or one character (default ^])
    \\  --no-resize       never resize the session to this terminal
    \\
    \\exit codes:
    \\  0     detached
    \\  N     the session's program exited with code N (128+n when killed
    \\        by signal n)
    \\  1     error, the writer role is taken, or this viewer fell too far
    \\        behind
    \\  2     bad arguments
    \\  128+n this attach was ended by signal n; the session keeps running
    \\
    \\examples:
    \\  tuppet attach 2
    \\  tuppet attach 2 --read-only
    \\
;

const llm_skill_help =
    \\tuppet llm-skill - print a coding-agent skill for tuppet
    \\
    \\usage: tuppet llm-skill
    \\
    \\Prints a SKILL.md (YAML front matter plus instructions) that tells a
    \\coding agent when to use tuppet and how: the run/wait/key/view loop,
    \\key notation, evidence capture, cleanup, and common pitfalls. Save
    \\it where your agent loads skills, e.g.
    \\
    \\  mkdir -p ~/.claude/skills/tuppet && tuppet llm-skill > ~/.claude/skills/tuppet/SKILL.md
    \\
;

/// The skill text printed by `tuppet llm-skill`.
const llm_skill = @embedFile("llm_skill.md");

const help_entries = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "run", .text = run_help },
    .{ .name = "list", .text = list_help },
    .{ .name = "stop", .text = stop_help },
    .{ .name = "remove", .text = remove_help },
    .{ .name = "send", .text = send_help },
    .{ .name = "key", .text = key_help },
    .{ .name = "mouse", .text = mouse_help },
    .{ .name = "focus", .text = focus_help },
    .{ .name = "resize", .text = resize_help },
    .{ .name = "view", .text = view_help },
    .{ .name = "png", .text = png_help },
    .{ .name = "record", .text = record_help },
    .{ .name = "trace", .text = trace_help },
    .{ .name = "wait", .text = wait_help },
    .{ .name = "watch", .text = watch_help },
    .{ .name = "daemon", .text = daemon_help },
    .{ .name = "llm-skill", .text = llm_skill_help },
    .{ .name = "attach", .text = attach_help },
    .{ .name = "help", .text = help_help },
};

fn commandHelp(name: []const u8) ?[]const u8 {
    for (&help_entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.text;
    }
    return null;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// Print the full usage to stderr and fail with the usage-error exit
/// code (2). Used for missing or unknown commands.
fn usageFail(comptime fmt: []const u8, args: anytype) error{UsageError} {
    // Allocated because the message embeds user input of unbounded
    // length; on OOM the usage text alone still goes out.
    const s = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return error.UsageError;
    defer std.heap.page_allocator.free(s);
    plat.stderrWriteAll("tuppet: ") catch {};
    plat.stderrWriteAll(s) catch {};
    plat.stderrWriteAll("\nrun 'tuppet help' for usage\n") catch {};
    return error.UsageError;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    io_mod.init(gpa, init.environ);

    var arg_it = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer arg_it.deinit();
    var argv_list: std.ArrayList([]const u8) = .empty;
    while (arg_it.next()) |a| {
        // next() reuses the iterator's internal buffer; copy each arg.
        const dup = try gpa.dupe(u8, a);
        try argv_list.append(gpa, dup);
    }
    const argv = try argv_list.toOwnedSlice(gpa);
    defer {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }

    runMain(gpa, argv[1..]) catch |err| switch (err) {
        // Usage errors already printed their message and hint.
        error.UsageError => std.process.exit(2),
        else => {
            if (err == error.NoDaemon) {
                const msg = std.fmt.allocPrint(gpa, "tuppet: no tuppet daemon is listening on {s}\n", .{client.socket_override.?}) catch std.process.exit(1);
                plat.stderrWriteAll(msg) catch {};
            } else if (client.errorText(err)) |text| {
                if (text.len > 0) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "tuppet: {s}\n", .{text}) catch std.process.exit(1);
                    plat.stderrWriteAll(msg) catch {};
                }
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "tuppet: {s}\n", .{@errorName(err)}) catch std.process.exit(1);
                plat.stderrWriteAll(msg) catch {};
            }
            std.process.exit(1);
        },
    };
}

/// Global options, then the command. `--socket PATH` (or TUPPET_SOCKET)
/// selects an explicit daemon endpoint.
fn runMain(gpa: std.mem.Allocator, args_in: []const []const u8) !void {
    var args = args_in;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--socket")) {
        if (args.len < 2) return usageFail("missing value for --socket", .{});
        if (args[1].len == 0) return usageFail("--socket needs a non-empty path", .{});
        client.socket_override = args[1];
        args = args[2..];
    } else if (std.c.getenv("TUPPET_SOCKET")) |env| {
        const value = std.mem.span(env);
        if (value.len > 0) client.socket_override = value;
    }
    if (args.len == 0) {
        // No command at all: full usage on stderr, nonzero exit.
        plat.stderrWriteAll(usage_text) catch {};
        std.process.exit(2);
    }
    return runCommand(gpa, args[0], args[1..]);
}

fn runCommand(gpa: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) !void {
    // `tuppet <command> --help`: per-command help. Only honored as the
    // first argument, so payloads such as `tuppet send 2 --help` reach the
    // session untouched.
    if (rest.len > 0 and isHelpFlag(rest[0])) {
        if (commandHelp(cmd)) |text| {
            plat.stdoutWriteAll(text) catch {};
            return;
        }
    }
    if (std.mem.eql(u8, cmd, "daemon")) {
        var opts: daemon.Options = .{ .socket = client.socket_override };
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const a = rest[i];
            if (std.mem.eql(u8, a, "--socket") or std.mem.eql(u8, a, "--log")) {
                if (i + 1 >= rest.len) return usageFail("missing value for {s}", .{a});
                i += 1;
                if (rest[i].len == 0) return usageFail("{s} needs a non-empty path", .{a});
                if (a[2] == 's') opts.socket = rest[i] else opts.log = rest[i];
            } else {
                return usageFail("unknown argument '{s}' for 'daemon' (usage: tuppet daemon [--socket PATH] [--log PATH])", .{a});
            }
        }
        if (opts.log != null and opts.socket == null) return usageFail("--log requires --socket", .{});
        // The daemon changes to / before it opens either path.
        if (opts.socket) |p| opts.socket = try client.absolutePath(gpa, p);
        if (opts.log) |p| opts.log = try client.absolutePath(gpa, p);
        return daemon.run(gpa, opts);
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        if (rest.len == 0) {
            plat.stdoutWriteAll(usage_text) catch {};
            return;
        }
        if (rest.len > 1) return usageFail("'help' takes at most one argument (got '{s}')", .{rest[1]});
        const text = commandHelp(rest[0]) orelse
            return usageFail("unknown command '{s}'", .{rest[0]});
        plat.stdoutWriteAll(text) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "llm-skill")) {
        if (rest.len != 0) return usageFail("'llm-skill' takes no arguments (got '{s}')", .{rest[0]});
        plat.stdoutWriteAll(llm_skill) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        if (rest.len != 0) return usageFail("'--version' takes no arguments (got '{s}')", .{rest[0]});
        plat.stdoutWriteAll("tuppet " ++ protocol.version ++ "\n") catch {};
        return;
    }

    return dispatch(gpa, cmd, rest);
}

fn dispatch(gpa: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) !void {
    const session_commands = [_][]const u8{ "send", "key", "mouse", "focus", "resize", "view", "png", "wait", "watch", "record", "trace", "stop", "remove", "attach" };
    for (session_commands) |name| {
        if (!std.mem.eql(u8, cmd, name)) continue;
        if (rest.len == 0 or protocol.parseDecimal(u64, rest[0]) != null) break;
        if (std.mem.startsWith(u8, rest[0], "-")) {
            // attach explains this itself: without an id it is the picker.
            if (std.mem.eql(u8, cmd, "attach")) break;
            return client.cliFail("the session id comes first: tuppet {s} <id> {s}", .{ cmd, rest[0] });
        }
        return client.cliFail("invalid session id '{s}'", .{rest[0]});
    }
    if (std.mem.eql(u8, cmd, "run")) {
        return client.cmdRun(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "list")) {
        return client.cmdList(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "send")) {
        return client.cmdSend(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "key")) {
        return client.cmdKey(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "mouse")) {
        return client.cmdMouse(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "focus")) {
        return client.cmdFocus(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "resize")) {
        return client.cmdResize(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "view")) {
        return client.cmdView(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "png")) {
        return client.cmdPng(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "wait")) {
        return client.cmdWait(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "watch")) {
        return client.cmdWatch(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "record")) {
        return client.cmdRecord(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "trace")) {
        return client.cmdTrace(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "stop")) {
        return client.cmdStop(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "remove")) {
        return client.cmdRemove(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "attach")) {
        return attach_client.cmdAttach(gpa, rest);
    }
    return usageFail("unknown command '{s}'", .{cmd});
}

// Zig 0.16 only collects test blocks from files the root file references
// directly, so every file with tests is listed here.
comptime {
    _ = @import("client.zig");
    _ = @import("plat.zig");
    _ = @import("session.zig");
    _ = @import("trace.zig");
    _ = @import("keys.zig");
    _ = @import("mouse.zig");
    _ = @import("input/mouse_encode.zig");
    _ = @import("protocol.zig");
    _ = @import("ipc.zig");
    _ = @import("render.zig");
    _ = @import("png.zig");
    _ = @import("font.zig");
    _ = @import("pty.zig");
    _ = @import("attach.zig");
    _ = @import("attach_client.zig");
    _ = @import("attach_filter.zig");
    _ = @import("store.zig");
    _ = @import("picker.zig");
}

test "every dispatched command has a help text" {
    const commands = [_][]const u8{
        "run",       "list",   "stop", "remove", "send",  "key",  "mouse", "focus",
        "resize",    "view",   "png",  "record", "trace", "wait", "watch", "daemon",
        "llm-skill", "attach",
    };
    for (commands) |name| {
        const text = commandHelp(name) orelse return error.MissingHelp;
        try std.testing.expect(std.mem.startsWith(u8, text, "tuppet "));
        try std.testing.expect(std.mem.indexOf(u8, text, "usage: tuppet ") != null);
    }
    try std.testing.expect(commandHelp("bogus") == null);
}

//! tuppet - a TUI puppet: puppeteer for TUIs, built on libghostty-vt.
//!
//! Architecture: a daemon owns PTY sessions and parses their output with
//! Ghostty's terminal emulation core. A small CLI talks to the daemon over
//! a unix socket with JSON-lines messages.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const daemon = @import("daemon.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const sweep = @import("sweep.zig");
const play = @import("play.zig");
const start_run = @import("start_run.zig");
const plat = @import("plat.zig");
const protocol = @import("protocol.zig");
const build_options = @import("build_options");
const fonts = @import("fonts.zig");
const names = @import("names.zig");

/// A panic while the picker or an attach holds the terminal raw must not
/// leave it unusable.
pub const panic = std.debug.FullPanic(struct {
    fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        attach_client.restoreTerminal();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.onPanic);

/// The emulator logs every escape sequence it does not implement; child
/// output must not be able to grow the daemon log without bound.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .stream, .level = .err }},
    .logFn = logFn,
};

/// Whether this process is `tuppet daemon`.
var serving = false;

/// The daemon logs as daemon.logFn does. A client writes no line of the
/// terminal emulator's, which are about a session's output and not about
/// the command, and none at all while it paints a terminal.
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (!serving) {
        if (scope != .default and scope != .gpa) return;
        if (attach_client.painting.load(.acquire)) return;
    }
    daemon.logFn(level, scope, format, args);
}

const usage_text =
    \\tuppet - a TUI puppet: drive terminal programs from scripts
    \\
    \\usage: tuppet [--socket PATH] <command> [arguments]
    \\       tuppet            the session picker (in a terminal)
    \\
    \\--socket PATH (or TUPPET_SOCKET=PATH) talks to the daemon listening on
    \\PATH and never starts one; see 'tuppet help daemon'.
    \\
    \\A <session> is its id, its name (run --name), or a pattern in which *
    \\matches any run of characters and ? one character; quote patterns for
    \\the shell. '*' matches every session, named or not. A DUR is a number
    \\with a unit: 500ms, 5s, 2m, 1h, or 0.
    \\
    \\sessions:
    \\  tuppet run [-a] [-n NAME] [-s WxH] [-C DIR] [-r] [conditions] [-j] <cmd...>
    \\                                    start a session and print its id, then wait
    \\                                    for the conditions; or attach to it (-a)
    \\  tuppet run --over <session> [-t DUR] [-j] <cmd...>
    \\                                    show the new session in a box over another,
    \\                                    wait until its program ends, and say how
    \\  tuppet start [<id>...] [-d] [--new] [-A]
    \\                                    open a session, bring it to a known state
    \\                                    with the steps of the start file (a login,
    \\                                    say), then attach; several ids or a group
    \\                                    one after another, detached; --check,
    \\                                    --record ID; see 'tuppet help start'
    \\  tuppet list [<session>...] [-j]   list sessions: id, name, state, age, command
    \\  tuppet stop <session>... [-j]     terminate the programs' process groups
    \\  tuppet remove <session>... [-f] [-j]
    \\                                    delete ended sessions (-f: stop them first)
    \\  tuppet restart <session> [-j]     run an ended session's command again
    \\  tuppet rename <session> <name> [-j]
    \\                                    give a session another name
    \\  tuppet update <session> [--label TEXT] [--group G] [--action SPEC]...
    \\                                    change what a drawn attach of a group
    \\                                    shows about a session; also flag,
    \\                                    side, respawn, lease, commands
    \\  tuppet events [<session>...] [-i DUR] [--count N] [-t DUR] [-v] [-j]
    \\                                    follow what happens to sessions: starts,
    \\                                    ends, bells, notifications, alert hits
    \\  tuppet ack <session>... [-j]      mark sessions as seen, clearing their !
    \\  tuppet alert add <session> NAME=TEXT [--icase]
    \\                                    watch a session for TEXT: a line that
    \\                                    comes to show it is a hit (also run
    \\                                    --alert); alert list, alert remove
    \\
    \\input:
    \\  tuppet key <session> <keys...>    type keys in vim notation, encoded for the
    \\                                    live terminal state, e.g. <C-c> <Esc> <Up>
    \\                                    ':q!<Enter>'
    \\  tuppet do <session> STEP...       type text (-s), keys (-k), pastes (-p),
    \\                                    secrets, mouse clicks (left, right, middle,
    \\                                    up, down, none, or 1..9 at zero-based
    \\                                    cells), and wait for what follows (-m,
    \\                                    --gone, -e, --settled), with guards; or
    \\                                    the steps of a start-file block (--use);
    \\                                    see 'tuppet help do'
    \\  tuppet resize <session> WxH [-j]  resize the pty and reflow the screen
    \\
    \\output:
    \\  tuppet view <session> [-f plain|vt|html] [-s] [--unwrap] [--since SEQ]
    \\              [--styles] [-j]       snapshot the screen (--styles adds colors
    \\                                    and emphasis; -j adds the cursor and the
    \\                                    session's status)
    \\  tuppet png <session> <file.png> [-f SPEC] [--font-size N] [-j]
    \\                                    render the screen to a PNG file; 'tuppet
    \\                                    help fonts' explains SPEC
    \\  tuppet record <session> --start FILE [conditions] [-t DUR] [--input]
    \\                                    start a recording: FILE.cast is asciicast
    \\                                    v2 (--input adds input events), FILE.trace
    \\                                    a JSONL timeline of input, screen diffs,
    \\                                    and the stop; the daemon stops it when a
    \\                                    condition holds or after -t DUR
    \\  tuppet record <session> --mark LABEL
    \\                                    append a marker to the active recording
    \\  tuppet record <session> --stop    stop the recording
    \\  tuppet play FILE.cast [--speed N] [--max-pause DUR]
    \\                                    play a recording into this terminal: Space
    \\                                    pauses, q quits
    \\  tuppet wait <session>... [conditions] [--any] [--view] [-j]
    \\                                    block until a condition holds: -m TEXT on
    \\                                    screen, --gone TEXT gone, -e the program
    \\                                    ended, --settled DUR redrawn and quiet,
    \\                                    -i DUR quiet, --hit NAME an alert; see
    \\                                    'tuppet help conditions'
    \\  tuppet attach [<session> | -] [--read-only] [--force] [--detach-key KEY]
    \\                [--no-resize] [--drawn | --no-drawn] [--no-detach]
    \\                                    connect this terminal to the session live
    \\                                    (detach with Ctrl-]; - is the session
    \\                                    detached from last); without a session,
    \\                                    open the session picker
    \\
    \\diagnostics:
    \\  tuppet view <session> --styles    the screen's colors and emphasis, run by
    \\                                    run, after its text
    \\  tuppet wait|do|run ... --stats    add what the program did to the outcome
    \\                                    line: bytes, draws, full clears, rows
    \\  tuppet do <session> --resize WxH --settled DUR
    \\                                    resize, then wait for the redraw
    \\  tuppet sweep <session> -s SIZES [--find NAME=TEXT]...
    \\                                    resize through many sizes and report what
    \\                                    the program drew and where the texts sit;
    \\                                    see 'tuppet help sweep'
    \\
    \\Options may come before or after the session. Most have a short
    \\form, such as -n for --name; see 'tuppet help <command>'.
    \\
    \\exit codes: 0 ok, 1 error, 2 bad arguments, 3 timeout, 4 the session
    \\ended (or was removed) first, 5 a guard refused the input (do) or a
    \\sweep refused to start, 128+n interrupted by signal n. The
    \\exceptions are attach (and run -a), which exits with the program's
    \\own code when it ends (see 'tuppet help attach'), and run --over
    \\(see 'tuppet help run').
    \\
    \\coding agents:
    \\  tuppet llm-skill                  print a SKILL.md that teaches coding agents
    \\                                    how to drive terminal programs with tuppet
    \\
    \\other:
    \\  tuppet daemon [--socket PATH] [--log PATH]
    \\                                    run the daemon in the foreground
    \\  tuppet shutdown [--reset] [--all] [-j]
    \\                                    stop every running session and the
    \\                                    daemon; --reset also deletes the stored
    \\                                    sessions and starts ids at 1 again
    \\  tuppet help [<command>]           full usage, or one command's options,
    \\                                    defaults, and examples (also: tuppet
    \\                                    <command> --help); 'tuppet help
    \\                                    conditions' explains what waits wait for,
    \\                                    'tuppet help fonts' the PNG fonts
    \\  tuppet --version | -V             show the version
    \\
;

const run_help =
    \\tuppet run - start a session in a new emulated terminal
    \\
    \\usage: tuppet run [-a [--drawn | --no-drawn] [--no-detach] [--alt-screen]
    \\                  [--pass LIST] [-k KEY]] [-n NAME] [-s WxH] [-C DIR]
    \\                  [--scrollback SIZE]
    \\                  [-r [--record-format cast|trace] | --record-file FILE]
    \\                  [--passwords]
    \\                  [--alert NAME=TEXT]... [--no-default-alerts]
    \\                  [--if-exists fail|keep|replace] [conditions] [--stats]
    \\                  [--group G] [--label TEXT] [--accent] [--mark M]
    \\                  [--meta K=V]... [--action SPEC]...
    \\                  [--side-of SESSION [--side-view VIEW]] [--lease]
    \\                  [-j] [--] <cmd...>
    \\       tuppet run --over <session> [-s WxH] [--title TEXT]
    \\                  [--backdrop frozen|live] [--grab pause|now|never]
    \\                  [-t DUR] [-n NAME] [-j] [--] <cmd...>
    \\
    \\Runs <cmd...> on a pty owned by the daemon and prints the new
    \\session id to stdout. The command runs in your current directory
    \\with your environment and TERM=xterm-256color, without the
    \\variables that describe your own terminal (TERM_PROGRAM, TMUX,
    \\STY); TUPPET_SESSION holds the session's id, and
    \\TUPPET_SESSION_SOCKET its daemon's socket. The session keeps running
    \\after this command exits; use 'tuppet stop <session>' to terminate
    \\it.
    \\
    \\With conditions (see 'tuppet help conditions'), run prints the id
    \\and then waits as 'tuppet wait' does, from the program's first byte,
    \\so output that came and went before the wait could start still
    \\counts. It prints the same outcome line and exits with the same
    \\codes; when the wait fails, the session keeps running, and the
    \\message says how to stop it. -a cannot be combined with conditions.
    \\
    \\With --over, the new session is a box: a drawn attach of <session>
    \\shows it over that session (see 'tuppet help attach'), and it is an
    \\ordinary session otherwise, which view, key, do, and wait work on.
    \\run prints the box's id, waits as long as it takes until the box's
    \\program has ended, removes the box, and prints one line:
    \\
    \\  ended <id> exit=N held=yes|no shown=yes|no
    \\  stopped <id> reason=unseen|under|stopped held=yes|no shown=yes|no
    \\  lost <id>
    \\
    \\held says that a client typed into the box (an attach that writes),
    \\shown that one showed it. reason is unseen when -t ran out, under
    \\when <session> ended, and stopped when the box was stopped another
    \\way; lost is a box lost with its daemon, or removed meanwhile. The
    \\exit code is the program's own when it ended by itself in a box that
    \\was held (shown, with --grab never), 3 for reason=unseen, and 4
    \\otherwise; the outcome line tells these apart from a program that
    \\exits with 3 or 4 itself. Interrupted, run stops the box first and
    \\exits 128+n; killed, it leaves the box running. --over cannot be
    \\combined with -a, conditions, --if-exists, or --group.
    \\
    \\Alerts watch the session from the program's first byte (see 'tuppet
    \\help alert'): the ones --alert gives, and the defaults in the
    \\[alerts] section of the config file, unless --no-default-alerts.
    \\
    \\When the program ends, its final screen and exit status are kept
    \\(see 'tuppet help list'). Ids count up from 1 after each boot and are
    \\never reused before the next one, or before 'tuppet shutdown
    \\--reset' starts them over.
    \\
    \\A name works wherever a session id does. It starts with a letter or
    \\digit, continues with letters, digits, '.', '_', and '-', has at most
    \\64 characters, and is not all digits. Names are unique: while a
    \\running session has the name, run fails (see --if-exists); an ended
    \\session that has it is removed, as 'tuppet remove' would, once the
    \\new one has started.
    \\
    \\options:
    \\  -a, --attach      attach this terminal to the session right away
    \\                    instead of printing its id, as 'tuppet attach' does
    \\  --drawn, --no-drawn, --no-detach, --alt-screen, --pass LIST,
    \\  -k, --detach-key KEY
    \\                    with -a: as for 'tuppet attach' (see 'tuppet help
    \\                    attach'); a drawn attach the daemon cannot serve
    \\                    fails before the session starts
    \\  -n, --name NAME   name the session
    \\  -s, --size WxH    terminal size in cells, 1..1000 per side
    \\                    (default 120x40, or TUPPET_SIZE; with -a this
    \\                    terminal's size, and an explicit size stays fixed;
    \\                    with --over 64x12, the box's program area)
    \\  -C, --cwd DIR     working directory for the command (default: the
    \\                    current directory)
    \\  --scrollback SIZE memory for history, in bytes or with K, M, or G
    \\                    (default 8M, about 7500 lines of 120 columns, at
    \\                    most 1G; 0 keeps none; TUPPET_SCROLLBACK sets the
    \\                    default)
    \\  -r, --record      record everything from the first byte into the
    \\                    session's directory in the store, as output.cast
    \\                    or output.trace; it is deleted with the session,
    \\                    and 'tuppet view <id> -j' shows its path
    \\  --record-format F with -r: cast (default) or trace; see 'tuppet help
    \\                    record'
    \\  --record-file FILE
    \\                    record to FILE instead, which tuppet never deletes:
    \\                    asciicast for FILE.cast, a trace for FILE.trace
    \\  --passwords       with -r or --record-file: record passwords as
    \\                    typed, not as a marker (see 'tuppet help record')
    \\  --alert NAME=TEXT watch for TEXT under NAME (see 'tuppet help alert');
    \\                    one per alert, at most 32 with the defaults
    \\  --no-default-alerts
    \\                    leave out the config file's alerts, and do not
    \\                    read it
    \\  --if-exists W     what to do when a running session has the name:
    \\                    fail (default), keep (print its id and start
    \\                    nothing), or replace (stop it and start anew)
    \\  --over SESSION    start the session as a box over SESSION (see
    \\                    above)
    \\  --title TEXT      with --over: the text on the box's border, at
    \\                    most 64 bytes (default: the name, or #<id>)
    \\  --backdrop B      with --over: how SESSION shows while the box has
    \\                    the keyboard: frozen (default) or live; not with
    \\                    --grab never
    \\  --grab G          with --over: when the box takes the keyboard:
    \\                    pause (default: once you pause typing), now, or
    \\                    never (a notice that takes no keys)
    \\  -t, --timeout DUR with conditions: as for 'tuppet wait' (default
    \\                    30s, at most 10m); with --over: stop the box when
    \\                    it was not held (shown, with --grab never)
    \\                    within DUR (1ms to 24h)
    \\  --group G         a member of group G, with the lowest free number;
    \\                    --label, --accent, --mark, --meta, and --action
    \\                    as for 'tuppet update'
    \\  --side-of SESSION the side session of SESSION, shown first at
    \\                    --side-view (compact, half, or full; default
    \\                    compact); see 'tuppet help side'
    \\  --lease           print the id and keep the session alive only while
    \\                    this command runs (see 'tuppet help lease')
    \\  --stats           with conditions: add what the program did while
    \\                    run waited to the outcome line (see 'tuppet help
    \\                    conditions')
    \\  -j, --json        print the session's status as JSON instead of
    \\                    its id (and the wait's reply as a second line,
    \\                    instead of the outcome line with --over)
    \\  --                treat the rest as the command even if it starts
    \\                    with a dash
    \\
    \\examples:
    \\  tuppet run vim
    \\  tuppet run -m 'Listening on' -t 1m -- npm start
    \\  tuppet run -a htop
    \\  tuppet run -r --scrollback 4M make test
    \\  tuppet run -n build --if-exists replace -s 120x40 -- make -j8
    \\  tuppet run -n agent --alert 'approve=Do you want to proceed?' -- ./agent
    \\  tuppet run --over agent --title 'confirm deploy' -t 10m -- ./confirm
    \\
;

const list_help =
    \\tuppet list - list sessions
    \\
    \\usage: tuppet list [<session>...] [-j]
    \\
    \\Prints one aligned table, the same in a terminal and in a pipe:
    \\
    \\  !  ID  NAME  STATE     AGE  CMD
    \\      3  web   running    2m  npm start
    \\  !  12  -     failed 2   5s  make
    \\
    \\STATE is "running", "quiet 3m" (running, but its screen text has not
    \\changed for that long), "password?" (running, and reading input
    \\without echo, as password prompts do), "box waits" (a box that
    \\takes the keyboard runs over it, and nobody types into the box yet;
    \\see 'tuppet help run'), the name of an alert (cut to
    \\12 characters) that hit since the session was last seen, "bell" (the
    \\program rang the bell since the session was last seen), "done"
    \\(exited 0), "stopped" (by 'tuppet stop'), "failed N" (exit code N,
    \\or the signal that killed it), or "lost" (its daemon stopped while
    \\it ran, so how it ended is unknown). AGE is the time since it
    \\started, and NAME is "-" without a name. With sessions given, only
    \\those are listed; one that matches nothing is no error.
    \\
    \\! marks a session that needs you: since it was last seen, it rang
    \\the bell, sent a desktop notification (OSC 9 or OSC 777), had an
    \\alert hit, or ended, unless 'tuppet stop' ended it (whoever stopped
    \\it knows). 'tuppet ack' marks it as seen. A box that waits over it
    \\marks it too, until no box waits; an ack does not clear that.
    \\
    \\Ended sessions stay listed, even across daemon restarts, until
    \\'tuppet remove' or 7 days after they ended (TUPPET_KEEP, see 'tuppet
    \\help daemon').
    \\
    \\options:
    \\  -j, --json  print {"sessions":[...]} with each session's full
    \\              status (see docs/protocol.md)
    \\
;

const stop_help =
    \\tuppet stop - terminate sessions
    \\
    \\usage: tuppet stop <session>... [-j]
    \\
    \\Sends SIGHUP and SIGTERM to each program's process group, as closing
    \\a terminal would (shells pass the hangup on to their jobs), then
    \\SIGKILL to whatever is left after 0.5 s. Processes that left the
    \\session (setsid, daemons) are not tracked. The sessions stay listed
    \\until 'tuppet remove'.
    \\
    \\Each session is stopped once, however many arguments pick it, and all
    \\at the same time. A pattern must match at least one session and skips
    \\those that have ended. When a session cannot be stopped, the others
    \\still are, and the exit code is 1, or 4 when each such session (named
    \\by id or name) had ended already.
    \\
    \\options:
    \\  -j, --json  print {"results":[...]}: per session the reference,
    \\              id, ok, and on failure code and err
    \\
    \\To stop the daemon itself, see 'tuppet shutdown'.
    \\
    \\examples:
    \\  tuppet stop build
    \\  tuppet stop 3 4 'ci-*'
    \\  tuppet stop '*'
    \\
;

const remove_help =
    \\tuppet remove - delete ended sessions
    \\
    \\usage: tuppet remove <session>... [-f] [-j]
    \\
    \\Deletes each session and everything tuppet kept about it: its
    \\screen, its exit status, and a recording made with 'tuppet run
    \\--record' (but not one written to a file you named). Only ended
    \\sessions can be removed unless -f stops them first. A removed
    \\session's id is never used again until the machine reboots or
    \\'tuppet shutdown --reset' starts the ids over.
    \\
    \\Each session is removed once, however many arguments pick it. A
    \\pattern must match at least one session and skips the running ones
    \\(with -f it picks those too). When a session cannot be removed, the
    \\others still are, and the exit code is 1.
    \\
    \\options:
    \\  -f, --force  stop running sessions first, and do not fail when a
    \\               session matches nothing
    \\  -j, --json   print {"results":[...]}, as 'tuppet stop -j' does
    \\
    \\examples:
    \\  tuppet remove build
    \\  tuppet remove '*'
    \\  tuppet remove -f 'job-*'
    \\
;

const key_help =
    \\tuppet key - type keys in vim-style notation
    \\
    \\usage: tuppet key <session> <keys...>
    \\
    \\Types the keys as one input. In each argument, <...> names a key:
    \\<enter>, <esc>, <tab>, <space>, <bs>, <del>, <home>, <end>, <ins>,
    \\<up>, <down>, <left>, <right>, <pgup>, <pgdown>, <f1>..<f25>, or a
    \\character with modifiers. Modifiers go inside the brackets: C ctrl,
    \\M or A alt, S shift, D super; e.g. <C-c>, <S-Tab>, <M-x>, <A-é>,
    \\<C-->. As in vim, <C-C> is <C-c>; write <C-S-c> for Ctrl+Shift. A
    \\name of letters, digits, and '-' that is not a key is rejected, so a
    \\typo is never typed as text.
    \\
    \\Everything else is typed as text, character by character: 'Enter'
    \\types five letters, ':q!<Enter>' types :q! and then presses Enter,
    \\and a '<' that starts no key (as in 'a < b') is typed. Tabs,
    \\newlines, and other control characters in text are sent as the keys
    \\that type them. <C-i>, <C-m>, <C-[>, and <C-@> are Tab, Enter, Esc,
    \\and NUL, unless the program asked for the kitty keyboard protocol.
    \\A key the program's keyboard mode cannot express fails the command,
    \\and nothing is typed: Ctrl with Shift, or with a key that has no
    \\control character (<C-S-c>, <C-;>, <C-->), needs the kitty protocol.
    \\
    \\key takes no options: an argument that starts with a dash is typed,
    \\so 'tuppet key 2 -v' types "-v". Only a '--' before the session or
    \\right after it is not typed: 'tuppet key 2 -- --' types "--".
    \\
    \\Keys are encoded against the live terminal state (application
    \\cursor keys, kitty keyboard protocol, ...), so <Up> sends whatever
    \\bytes the running program actually expects. While 'tuppet do' types
    \\into the session, key fails; 'tuppet do' also types text, pastes,
    \\and waits for what follows.
    \\
    \\examples:
    \\  tuppet key 2 i hello '<Esc>'
    \\  tuppet key 2 ':wq<Enter>'
    \\  tuppet key 2 '<C-c>'
    \\
;

const do_help =
    \\tuppet do - type, click, and wait, step by step
    \\
    \\usage: tuppet do <session> STEP... [-t DUR] [--if-input-seq N]
    \\                 [--reply-to N] [--unless-attached] [--any-input]
    \\                 [--record-file FILE [--passwords]] [--stats] [-j]
    \\       tuppet do <session> [-t DUR] [--unless-attached]
    \\                 --use NAME [ARG...]
    \\
    \\Runs its steps in order. Input steps that follow each other are
    \\typed as one batch: no other input, a person's at an attached
    \\terminal included, lands between them, each key is encoded when its
    \\step runs, and the program's queries are answered meanwhile. A
    \\condition step waits. Right after input steps it waits from before
    \\their first byte, for what is new since that input, as 'tuppet wait
    \\--after-input' does: the echo of a command typed at a '$ ' prompt
    \\does not meet -m '$ ', the next prompt does.
    \\
    \\input steps:
    \\  -k, --keys KEYS   keys as 'tuppet key' takes them, several in one
    \\                    string: -k ':wq<Enter>'
    \\  -s, --text TEXT   text, written as it is (no newline is added)
    \\  -p, --paste TEXT  text as a terminal pastes it: line endings become
    \\                    CR, and it is wrapped in bracketed-paste marks when
    \\                    the program asks for them (mode 2004)
    \\  --stdin           paste standard input (at most 768 KiB)
    \\  --secret VAR      type the value of the environment variable VAR;
    \\                    recordings show a marker instead. It starts a batch
    \\                    of its own, and the program must be reading hidden
    \\                    input (a password prompt) when that batch starts, or
    \\                    nothing of it is typed, unless --any-input is given.
    \\                    An unset or empty VAR fails do (exit 1) before
    \\                    anything is typed
    \\  --sleep DUR       wait; a batch sleeps at most 1s at a time and 2s in
    \\                    all. Longer sleeps, and sleeps before a batch's
    \\                    first key, run between batches, where other input
    \\                    can come in between
    \\  --mouse SPEC X Y  SPEC is BUTTON[:ACTION[:MODS]]: button left, right,
    \\                    middle, up or down (the wheel), none (motion with no
    \\                    button held), or 1..9; action press, release, or
    \\                    motion; modifiers c, a, s. Without an action, a click:
    \\                    press and release (the wheel only presses). X and Y
    \\                    are zero-based cells
    \\  --focus on|off    a focus-in or focus-out event, sent only if the
    \\                    program asks for them (mode 1004)
    \\
    \\resize step:
    \\  --resize WxH      resize the session, as 'tuppet resize' does, as a
    \\                    step of its own, never inside a batch. The
    \\                    conditions after it count from its reflow instead
    \\                    of the latest input, until the next input step.
    \\                    When the size stays, the program gets no SIGWINCH:
    \\                    the step prints 'same size 3 seq=...' (with -j the
    \\                    resize's reply with "outcome":"same_size"), a
    \\                    condition step right after it is met by that, and
    \\                    later conditions count from the latest input
    \\
    \\condition steps (several in a row are alternatives of one step):
    \\  -m, --match TEXT  TEXT appears anew on a line
    \\  --gone TEXT       TEXT, on the screen before the input or after it,
    \\                    is gone from the screen
    \\  -e, --ended       the program ends
    \\  --settled DUR     the screen changed after the input, and then its
    \\                    text stayed unchanged for DUR with no output left
    \\                    to process: use it after a key rather than -i
    \\  -i, --idle DUR    the screen's text stays unchanged for DUR
    \\  --hidden-input    the program begins to read hidden input
    \\  --hit NAME        the alert NAME ('*': any alert) hits
    \\  --after-hit N     --hit in this step counts hits numbered above N
    \\                    instead of hits after the latest input
    \\  --icase           -m and --gone in this step ignore the case of ASCII
    \\                    letters
    \\  --regex           -m and --gone in this step take a regex ('tuppet
    \\                    help conditions')
    \\  -w, --within DUR  this step's deadline, at most 10m
    \\'tuppet help conditions' explains them; in do they always count what
    \\came after the latest input.
    \\
    \\options:
    \\  -t, --timeout DUR   deadline of a condition step without -w
    \\                      (default 30s, at most 10m)
    \\  --if-input-seq N    type nothing unless the latest input is still
    \\                      the one with input_seq N, as an outcome line
    \\                      printed it
    \\  --reply-to N        type nothing unless hit N, as a 'hit N' line
    \\                      printed it, is not answered yet: no input came
    \\                      after it, and the session still keeps it
    \\  --unless-attached   type and resize nothing while a writer is
    \\                      attached
    \\  --at-prompt SEQ     type nothing unless the shell waits at its prompt
    \\                      with prompt_seq SEQ (see 'tuppet help commands'),
    \\                      nothing was typed since it appeared, the session
    \\                      is on its normal screen, and bracketed paste is
    \\                      on; the first batch must be one -p of one line
    \\                      of printable text, pasted without Enter
    \\  --any-input         let --secret type without hidden input
    \\  --record-file FILE  record the whole run to FILE with its input
    \\                      events: asciicast for FILE.cast, a trace for
    \\                      FILE.trace (see 'tuppet help record'); the
    \\                      recording stops when do ends, also on Ctrl-C
    \\  --passwords         with --record-file: record passwords as typed,
    \\                      not as a marker (see 'tuppet help record')
    \\  --stats             add what the program did to each condition step's
    \\                      line (see 'tuppet help conditions')
    \\  -j, --json          print each condition step's reply as JSON, as
    \\                      'tuppet wait -j' does, and a refused or failed
    \\                      step as the daemon's failure (code, err, guard,
    \\                      status) with step and done
    \\
    \\The guards apply to every batch, --if-input-seq and --reply-to to the
    \\first one, and --unless-attached to resize steps too; a guard that
    \\refuses a batch does so before its first byte. Each condition step
    \\prints the line 'tuppet wait' prints:
    \\
    \\  met match#0 3 seq=1187 input_seq=1100 hit_seq=-
    \\
    \\followed by a 'hit N <alerts> <line>' line for each hit a --hit
    \\condition counts. A step that fails ends do with that line, or with
    \\one that names the guard or the error code (guard unattended 3
    \\seq=...), followed by step=K done=N: step K failed after the N steps
    \\before it.
    \\
    \\exit codes: 0 every condition step was met; 1 error; 2 bad
    \\arguments; 3 a condition step timed out; 4 the session ended or was
    \\removed first; 5 a guard refused the input.
    \\
    \\--use NAME [ARG...] runs the steps of the block NAME of the start file
    \\(see 'tuppet help start') instead: the words after NAME are its
    \\arguments, as given, and -t is how long a check waits unless it
    \\says (default 10s). The block must start with the expect of the
    \\prompt it is used at, and nothing is typed unless the cursor's line
    \\ends with that prompt and no input comes in between. Steps, failure
    \\texts, passwords, and exit codes are those of 'tuppet start -d';
    \\on success it prints nothing. Pass a password as '$APP_PW' in single
    \\quotes, so that the shell does not put its value on the command
    \\line.
    \\
    \\examples:
    \\  tuppet do 2 -s make -k '<Enter>' -m '$ ' -t 10m
    \\  tuppet do 2 -k j --settled 200ms
    \\  tuppet do 2 --resize 60x24 --settled 200ms -w 2s
    \\  tuppet do 2 -k '<Enter>' --gone Loading -w 10s
    \\  tuppet do 2 -k 'sudo true<Enter>' --hidden-input --secret PW \
    \\      -k '<Enter>' -m '$ '
    \\  tuppet do 2 --mouse left 10 3 -m Saved -w 2s
    \\  tuppet do 2 --reply-to 4 -k 'y<Enter>' --hit approve -w 10m
    \\  tuppet do 2 --use become app '$APP_PW'
    \\  tuppet do vim -k ':wq<Enter>' -e --record-file quit.trace
    \\
;

const events_help =
    \\tuppet events - follow what happens to sessions
    \\
    \\usage: tuppet events [<session>...] [-i DUR] [--count N] [-t DUR] [-v]
    \\                     [-j]
    \\
    \\Prints a line for each thing that happens to the sessions, as it
    \\happens: the time, the session's id and name, and what happened:
    \\
    \\  14:02:07  3 build  started: make -j8
    \\  14:02:31  3 build  bell
    \\  14:02:40  3 build  notification: Build: done
    \\  14:02:41  3 build  hit 1 error: make: *** [all] Error 2
    \\  14:02:41  3 build  failed 2
    \\
    \\Sessions start, end ("done", "failed N", "stopped"), are removed, and
    \\renamed; programs ring the bell, send desktop notifications (OSC 9
    \\and OSC 777), and ask for a password ("password?"); alerts hit (the
    \\hit's number, its alerts, and its line); writers attach and detach;
    \\the person chooses an action in a group attach's switcher ("action
    \\KEY [VALUE]") or asks for a side session ("side-requested"); a side
    \\session's view changes ("side-view VIEW"); a shell's marks report a
    \\command's end ("command-ended CODE").
    \\Without sessions every session counts, also the ones started later;
    \\names and patterns pick sessions as they are named now, so a session
    \\renamed to a matching name joins, and one renamed away leaves ("no
    \\longer picked").
    \\
    \\The command runs until it is interrupted, --count events came (exit
    \\0), -t ran out (exit 0, or 3 when --count was given, with a line on
    \\stderr that says how many came), or the daemon shuts down (exit 0,
    \\or 4 when --count was given; a line on stderr says so). Events about
    \\one session come at most ten times a second; a burst of changes
    \\shows as one.
    \\
    \\options:
    \\  -i, --idle DUR  also print "idle" when a session's screen text has
    \\                  not changed for DUR (also for one that is quiet
    \\                  already), and "active" when it changes again
    \\  --count N       exit after N events: printed lines, or with -j
    \\                  frames after "synced"
    \\  -t, --timeout DUR
    \\                  exit after DUR
    \\  -v, --verbose   also print changes of the title, the working
    \\                  directory, the foreground program, the size, the
    \\                  viewers, and acks
    \\  -j, --json      print the daemon's frames as JSON lines instead,
    \\                  with each session's status (see docs/protocol.md)
    \\
    \\examples:
    \\  tuppet events
    \\  tuppet events 'ci-*' -i 30s
    \\  tuppet events build --count 1 -t 10m -j
    \\
;

const ack_help =
    \\tuppet ack - mark sessions as seen
    \\
    \\usage: tuppet ack <session>... [-j]
    \\
    \\Marks what each session shows now as seen: its bells, its desktop
    \\notifications, its alert hits, and its end, so 'tuppet list' no
    \\longer marks it with ! and its state no longer says "bell" or names
    \\an alert. What comes later marks it again. A pattern picks every
    \\session it matches.
    \\
    \\options:
    \\  -j, --json  print {"results":[...]}, as 'tuppet stop -j' does
    \\
    \\examples:
    \\  tuppet ack build
    \\  tuppet ack '*'
    \\
;

const restart_help =
    \\tuppet restart - run an ended session's command again
    \\
    \\usage: tuppet restart <session> [-j]
    \\
    \\Starts the command of an ended session again, in a new session with
    \\a new id, as 'tuppet run' would: in the same working directory, with
    \\the same name, size, history size, and alerts, and it prints the new
    \\id. It gets the environment of this command: the old one is not
    \\restored, and neither are the old session's hits. A named session
    \\gives its name to the new one and is removed, as with 'tuppet run
    \\--name'. Only ended sessions restart; stop a running one first.
    \\
    \\options:
    \\  -j, --json  print the new session's status as JSON instead of its
    \\              id
    \\
    \\example:
    \\  tuppet restart build
    \\
;

const rename_help =
    \\tuppet rename - give a session another name
    \\
    \\usage: tuppet rename <session> <name> [-j]
    \\
    \\Names follow the rules of 'tuppet run --name'; an empty name ('')
    \\takes the name away. While a running session has the name, rename
    \\fails; an ended session that has it is removed, as 'tuppet remove'
    \\would.
    \\
    \\options:
    \\  -j, --json  print the session's status as JSON
    \\
    \\examples:
    \\  tuppet rename 3 web
    \\  tuppet rename web ''
    \\
;

const resize_help =
    \\tuppet resize - change the terminal size
    \\
    \\usage: tuppet resize <session> WxH [-j]
    \\
    \\Resizes the pty and the emulated screen; W and H are in cells,
    \\1..1000 per side. The program receives SIGWINCH and the
    \\screen reflows, as in a real terminal.
    \\
    \\It prints the seq of the reflow, or - when the size stays: what
    \\the program draws after the resize changes the screen after it.
    \\To see the program's redraw, wait until it changed the screen after
    \\that seq and settled:
    \\
    \\  seq=$(tuppet resize 2 120x40)
    \\  tuppet wait 2 --since "$seq" --settled 200ms -t 2s
    \\  tuppet view 2
    \\
    \\options:
    \\  -j, --json  print the daemon's reply: resize_seq and the status
    \\
;

const view_help =
    \\tuppet view - snapshot the screen
    \\
    \\usage: tuppet view <session> [-f plain|vt|html] [-s] [--unwrap]
    \\                   [--since SEQ] [--styles] [-j]
    \\
    \\Shows the visible screen.
    \\
    \\options:
    \\  -f, --format F    plain (default), vt, or html; see below
    \\  -s, --scrollback  include the history above the screen
    \\  --unwrap          join rows that the terminal wrapped into one line
    \\  --since SEQ       only the lines that changed after SEQ, such as the
    \\                    seq of an earlier 'view -j' (nothing when none
    \\                    changed); a seq older than the session fails
    \\  --styles          after the text, its styles; plain text only (see
    \\                    below)
    \\  -j, --json        print the text, the cursor (1-based, unlike the
    \\                    zero-based cells of 'tuppet do --mouse'), and the
    \\                    session's status, whose seq is the latest change
    \\
    \\formats:
    \\  plain   screen text with trailing whitespace trimmed (default)
    \\  vt      text plus the escape sequences that reproduce colors
    \\  html    an HTML fragment with inline styles
    \\
    \\--styles prints, after the text, the style that most cells of the
    \\screen have, blanks included, and then a line for each run of cells
    \\in a row whose style differs from it: the row, the first and the
    \\last cell (counting from 1), the attributes that differ, the text.
    \\
    \\  base: default
    \\  3:5-12 fg=1 bold "ERROR: x"
    \\  7:1-80 inverse " Save  Quit"
    \\
    \\Colors are a palette index, #rrggbb, or default. The attributes are
    \\fg, bg, underline (single, double, curly, dotted, dashed),
    \\underline_color, bold, faint, italic, blink, inverse, invisible,
    \\strikethrough, overline, and link (an OSC 8 link); a flag prints as
    \\its name when it is on, and as bold=false when it is off where the
    \\base has it on. At most 200 runs print; -j gives them all (see
    \\docs/protocol.md).
    \\
    \\An ended session shows its final screen, even after the daemon
    \\that ran it has exited.
    \\
    \\examples:
    \\  tuppet view 2 -j
    \\  tuppet view build --since 1234
    \\  tuppet view 2 --styles
    \\
;

const png_help =
    \\tuppet png - render the screen to a PNG file
    \\
    \\usage: tuppet png <session> <file.png> [-f SPEC] [--font-size N] [-j]
    \\
    \\Renders the visible screen, colors included, and writes a PNG to
    \\the given path (relative to your working directory). Box drawing,
    \\blocks, braille, and Powerline glyphs are drawn to join at any cell
    \\size; color emoji come from a built-in Noto Color Emoji atlas; text
    \\comes from the fonts SPEC lists, then GNU Unifont, then U+FFFD.
    \\
    \\  -f, --fonts SPEC  the fonts to try first, a comma-separated list of
    \\
++ (if (fonts.has_truetype)
    \\                    built-in names, presets, and font files; see
    \\                    'tuppet help fonts'. Else TUPPET_PNG_FONTS, else
    \\                    [png] fonts in the config, else this build's
    \\                    default.
    \\  --font-size N     the size of TrueType fonts in pixels (6 to 64,
    \\                    default 14, which makes 9x19 cells with
    \\                    jetbrains); else the size of a preset -f names,
    \\                    TUPPET_PNG_FONT_SIZE, a preset's size, or
    \\                    [png] font_size.
    \\
else
    \\                    built-in names, presets, and files (.hex, .psf,
    \\                    .psf.gz); see 'tuppet help fonts'. Else
    \\                    TUPPET_PNG_FONTS, else [png] fonts in the config,
    \\                    else this build's default.
    \\  --font-size N     the size of TrueType fonts in pixels (6 to 64);
    \\                    else the size of a preset -f names,
    \\                    TUPPET_PNG_FONT_SIZE, a preset's size, or
    \\                    [png] font_size. This build has only bitmap
    \\                    fonts, which keep their size.
    \\
) ++
    \\  -j, --json        print what drew the PNG: renderer, cell (WxH),
    \\                    faces, and the session's status
    \\
    \\examples:
    \\  tuppet png web s.png
    \\  tuppet png web s.png -f bitmap
    \\
++ (if (fonts.has_truetype)
    \\  tuppet png web s.png -f ~/fonts/Iosevka.ttf,default --font-size 16
    \\
else
    \\  tuppet png web s.png -f ~/fonts/terminus.psf.gz,default -j
    \\
) ++ (if (build_options.variant == .full)
    \\  tuppet png web s.png -f cjk      (Noto Sans Mono CJK first)
    \\
else
    "") ++
    \\  tuppet png web s.png -f code     (a preset of your config)
    \\
;

const fonts_help =
    \\tuppet help fonts - the fonts of tuppet png
    \\
    \\usage: tuppet png <session> <file.png> -f SPEC [--font-size N]
    \\
    \\SPEC is a comma-separated list, tried in order. An entry is:
    \\
++ switch (build_options.variant) {
    .lean =>
    \\  a built-in name   in this build: unifont (GNU Unifont); jetbrains
    \\                    needs a medium or full build, and julia, nerd,
    \\                    and cjk a full one
    \\
    ,
    .medium =>
    \\  a built-in name   in this build: jetbrains (JetBrains Mono) and
    \\                    unifont (GNU Unifont); julia, nerd, and cjk
    \\                    need a full build
    \\
    ,
    .full =>
    \\  a built-in name   in this build: jetbrains (JetBrains Mono), julia
    \\                    (JuliaMono: math and symbols), nerd (Symbols
    \\                    Nerd Font: icons), cjk (Noto Sans Mono CJK SC:
    \\                    Chinese, Japanese, Korean), unifont (GNU Unifont)
    \\
    ,
} ++
    \\  default           this build's built-in fonts, in order
    \\  bitmap            leave out every TrueType font: the first bitmap
    \\                    font file sets the cells, else Unifont's 8x16
    \\                    (TrueType files in the list are skipped, so a
    \\                    list made for other builds still works)
    \\  a preset          a name from [png.presets] in the config
    \\  a file            anything with a / or a dot, or starting with ~:
    \\
++ (if (fonts.has_truetype)
    \\                    .ttf, .otf, .ttc (file.ttc#N for its face N),
    \\                    .otb, .pcf(.gz), .bdf(.gz), or the bitmap fonts
    \\                    .hex, .psf, and .psf.gz; relative paths start at
    \\                    your working directory, or at the config file's
    \\                    directory for paths the config gives
    \\
    \\Drawn glyphs (box drawing, blocks, braille, Powerline, sextants)
    \\always come first; color emoji, GNU Unifont, and U+FFFD close every
    \\list. The first entry sets the cell size: 9x19 for jetbrains at the
    \\default 14 pixels, 8x16 for unifont. TrueType fonts without bold or
    \\italic faces are made bold or slanted; bitmap fonts get only bold.
    \\bitmap skips .otb, .pcf, and .bdf files too: FreeType reads them
    \\like TrueType fonts.
    \\
    \\
else
    \\                    .hex, .psf, or .psf.gz bitmap fonts; relative
    \\                    paths start at your working directory, or at
    \\                    the config file's directory for paths the
    \\                    config gives. This build (lean) has no
    \\                    TrueType support: .ttf, .otf, .ttc, .otb, .pcf,
    \\                    and .bdf files need a medium or full build
    \\
    \\Drawn glyphs (box drawing, blocks, braille, Powerline, sextants)
    \\always come first; color emoji, GNU Unifont, and U+FFFD close every
    \\list. When the first entry is a font file, it sets the cell size;
    \\otherwise cells are 8x16.
    \\
    \\
) ++
    \\SPEC comes from -f, else TUPPET_PNG_FONTS, else [png] fonts in the
    \\config, else default. The size (6 to 64 pixels, for TrueType fonts)
    \\comes from --font-size, else the size of a preset -f names, else
    \\TUPPET_PNG_FONT_SIZE, else the size of a preset in SPEC, else [png]
    \\font_size. The daemon picks up changed settings and font files with
    \\the next png.
    \\
    \\config:
    \\  [png]
    \\
++ (if (fonts.has_truetype)
    \\  fonts = ["~/fonts/Iosevka.ttf", "default"]
    \\
else
    \\  fonts = ["~/fonts/terminus.psf.gz", "default"]
    \\
) ++
    \\  font_size = 16
    \\  [png.presets]
    \\  term = "~/fonts/terminus.psf.gz,bitmap"
    \\  big = { fonts = "default", size = 28 }
    \\
;

const record_help =
    \\tuppet record - start, annotate, or stop a screen recording
    \\
    \\usage: tuppet record <session> --start FILE [conditions] [-t DUR]
    \\                     [--input] [--passwords] [-j]
    \\       tuppet record <session> --mark LABEL [-j]
    \\       tuppet record <session> --stop [-j]
    \\
    \\--start records the session into FILE, relative to your working
    \\directory; its name gives the format. A session records into one
    \\file at a time: --start fails while a recording runs.
    \\
    \\formats:
    \\  FILE.cast   asciicast v2, playable with asciinema: the program's
    \\              output as it arrives, resizes, and markers
    \\  FILE.trace  a JSONL timeline: a start event and an initial snap,
    \\              an "in" event per input, a "diff" with the rows whose
    \\              text changed (or a "snap" when most of the screen did),
    \\              at most every 50 ms and before each input or mark,
    \\              "mark" events, and a final snap plus "stop"
    \\
    \\options at start:
    \\  conditions     stop when one holds, as 'tuppet wait' waits for
    \\                 them (-m TEXT, -e, -i DUR, --hidden-input, --hit
    \\                 NAME, and the modifiers; see 'tuppet help
    \\                 conditions')
    \\  -t, --timeout DUR
    \\                 stop after DUR (at most 24h)
    \\  --input        record input events in a cast too (a trace always
    \\                 has them)
    \\  --passwords    record passwords as typed instead of a marker
    \\  -j, --json     print the daemon's reply
    \\
    \\The daemon checks the conditions and the time, so they stop the
    \\recording also when this command is long gone. --stop prints how
    \\the recording stopped and its file:
    \\
    \\  met /home/me/flow.trace
    \\
    \\The reason is "request" (--stop), "met" (a condition), "max_ms"
    \\(-t), or "ended" (the session ended); a trace's stop event carries
    \\it too. After a recording stopped by itself, one --stop reports it;
    \\without a recording, --stop and --mark fail.
    \\
    \\Passwords: what tuppet knows is one is recorded as a marker
    \\("secret input"), not as typed: a 'tuppet do --secret', and what
    \\is typed while the program reads without echo, as sudo, ssh, and
    \\read -s do. tuppet sees that only for programs on its own terminal:
    \\a password typed on a host that ssh reached looks like any other
    \\input and is recorded as typed. --passwords records every password
    \\as typed.
    \\
    \\examples:
    \\  tuppet record 2 --start demo.cast
    \\  tuppet record 2 --start flow.trace -m 'Tests passed' -e -t 10m
    \\  tuppet record 2 --mark before-quit
    \\  tuppet record 2 --stop
    \\
;

const start_help =
    \\tuppet start - open a session and bring it to a known state
    \\
    \\usage: tuppet start [<id>...] [-d] [--new] [-A]
    \\       tuppet start --check [<id>]
    \\       tuppet start --record <id> [-- <command>...]
    \\
    \\Runs the steps of the start block for <id> in a new session named
    \\<id>: each types something and waits for the text that should
    \\follow, as 'tuppet do' does; then it attaches this terminal. The
    \\steps may log in through hops, start a dev server, or answer an
    \\installer. A step that fails stops the run: tuppet says which step,
    \\where it is in the file, and what the session showed, and offers
    \\to attach, to edit the file at that line, or to stop the session.
    \\Without <id>, it lists the ids and groups the file has.
    \\
    \\Several ids, or a group, start one after another, and none is
    \\attached: each says when it is ready, and tuppet prints the
    \\sessions' ids and exits with the code of the first that failed. A
    \\session that runs already is kept; one whose start failed or was
    \\cut short with Ctrl-C is replaced, unless something was typed into
    \\it since or someone is attached. So running the same start again
    \\finishes what did not.
    \\
    \\The steps live in $XDG_CONFIG_HOME/tuppet/start (by default
    \\~/.config/tuppet/start; TUPPET_START names another file, empty
    \\reads none). tuppet refuses the file when another user owns it or
    \\group or others may write it. A block starts with a line at the
    \\left margin; its lines are indented, a keyword and the rest of the
    \\line as literal text. Quotes ("...", with \" and \\ inside, and no
    \\other backslash) keep spaces at its ends. A check may take how
    \\long it waits in parentheses right after the keyword: expect(30s).
    \\With (re), a text is a regex, taken as written ('tuppet help
    \\conditions'): expect(re, 30s) ^me@db\d+:. Lines starting with # are
    \\comments; a # later in a line is text.
    \\
    \\  steps jump
    \\      send     ssh jump.example.com
    \\      expect   me@jump:~$
    \\
    \\  steps become user pw=$SUDO_PW
    \\      send     sudo -iu %{user}
    \\      when     [sudo] password for me:
    \\          secret %{pw}
    \\      expect   %{user}@
    \\
    \\  start db1 db2 db*
    \\      use      jump
    \\      send     ssh %i.internal
    \\      expect(30s) me@%i:~$
    \\      fail     me@jump:~$
    \\      use      become app $APP_PW
    \\      send     cd /srv/app && git status
    \\
    \\blocks:
    \\  start ID...       ids or patterns (* and ?); an exact id goes
    \\                    before a pattern. %i or %{id} is the id started
    \\  steps NAME [P | P=DEFAULT]...
    \\                    steps for 'use' only; %{P} is a parameter
    \\  use NAME [ARG]... the steps of a steps block, or of a start block
    \\                    with a single id and no command, dir, size, or
    \\                    timeout, at this place (8 deep at most)
    \\  group NAME ID...  ids that 'tuppet start NAME' starts, on this line
    \\                    alone: exact ids of start blocks, not groups
    \\
    \\inputs:
    \\  send TEXT         type TEXT and Enter
    \\  type TEXT         type TEXT
    \\  keys KEYS         keys as 'tuppet key' takes them: <C-c>, <Up>
    \\  secret [$VAR]     type a password and Enter: the variable's
    \\                    value, or asked on the terminal without echo
    \\  ask               type an answer asked on the terminal, and Enter
    \\
    \\checks, each with an optional (DUR) and (re) where it takes a text:
    \\  expect TEXT       wait for TEXT to appear anew anywhere on a line
    \\                    after the input; the input's own echo does not
    \\                    count
    \\  or TEXT           another text for the expect above
    \\  gone TEXT         wait for TEXT to leave the screen
    \\  settle QUIET      wait for the screen to change, then stay
    \\                    unchanged for QUIET
    \\  ended [STATUS]    wait for the program to end, with exit status
    \\                    STATUS if given; the last step, and then
    \\                    nothing is attached
    \\Checks are optional. An input without one waits until the screen
    \\changed below the input's line and then stayed still for 300 ms,
    \\at most 2s, and goes on either way: it does not wait for a command
    \\to finish, a program that prints all the time costs the 2s, and a
    \\pager takes the next input (PAGER=cat helps). A block may end with
    \\an input, typed before the terminal attaches. After each command
    \\that changes where input goes (ssh, sudo, su), an expect tells
    \\where it went; without one, a failed hop shows only later.
    \\A block's first input waits until the program takes input: a
    \\shell with line editing or a full-screen program once it reads
    \\keys one at a time and its output paused 300 ms, a program that
    \\reads whole lines once its output stayed still 1s; at most 5s,
    \\which a program that prints nothing always waits.
    \\For a remote shell (command ssh HOST), start with an expect for
    \\its prompt, as --record does.
    \\
    \\questions that only sometimes come:
    \\  when TEXT         when TEXT appears anew after the input, once
    \\                    the output pauses, type the answer below it,
    \\                    indented deeper: a send, type, keys, or secret
    \\                    line. It answers once per input, while the
    \\                    checks after it wait, up to the next input, or
    \\                    while an input right before it pauses; first in
    \\                    a block, from the program's start. The checks
    \\                    wait as usual whether it comes or not:
    \\
    \\      send     ssh web1
    \\      when     continue connecting (yes/no/[fingerprint])?
    \\          send yes
    \\      expect   me@web1:~$
    \\
    \\settings, above a block's first step:
    \\  command WORDS     the program (default $SHELL); for variables,
    \\                    command env LC_ALL=C bash -l
    \\  dir PATH          its directory (default the current one)
    \\  size WxH          the session's size (default the terminal's)
    \\  timeout DUR       how long a check waits (default 10s, at most 10m)
    \\  fail TEXT         text that fails the checks of this block and of
    \\                    the blocks it uses
    \\  nofail [TEXT]     leaves a failure text out of this block's own
    \\                    checks; without TEXT, all the built-in ones
    \\The first four are for start blocks only. 'fail' and 'nofail' at the
    \\left margin before the first block apply to the whole file; a fail
    \\right under a check (and its or lines) fails that check only, as
    \\when the prompt a hop started from comes back:
    \\
    \\      expect   me@db1:~$
    \\      fail     me@jump:~$
    \\
    \\A check fails at once when a failure text appears after the input,
    \\or when the session ends, except for ended. Besides the fail lines,
    \\built-in English texts fail checks (Permission denied, Connection
    \\refused, Host key verification failed, Sorry, try again, command
    \\not found, and others; see --check); a bare nofail turns them off,
    \\and under another language LC_ALL=C keeps them working. A failure
    \\text that is part of the input, or of what the check waits for, is
    \\left out of that check.
    \\
    \\Passwords: a secret follows the expect of its prompt, or answers a
    \\when that waits for it, which suits a sudo that asks only
    \\sometimes. tuppet types the password only where a program waits for
    \\it: its prompt on the cursor's line once output pauses, and nothing
    \\typed into the session since. Variables that secrets read are left
    \\out of the session's environment, and their values out of what
    \\tuppet prints. An unset one is asked once in a run: once it worked,
    \\the next sessions that read it get it too.
    \\
    \\options:
    \\  -d, --detached    do not attach (also outside a terminal): print
    \\                    the session's id; exit 1 when a failure text
    \\                    stopped the run or the program ended with
    \\                    another status, 3 on a timeout, 4 when the
    \\                    session ended, 5 when nothing was typed for
    \\                    safety (input came after a password prompt, or
    \\                    the prompt was not on the cursor's line)
    \\  --new             another session even if one has the name: ID-2
    \\  -A, --atomic      when a start fails or Ctrl-C ends it, stop every
    \\                    session this run opened, and start no more:
    \\                    all run, or none of those it opened
    \\  --check [ID]      read the file and report every problem, with
    \\                    notes on loose checks; with an id, print the
    \\                    steps as they would run
    \\  --record ID       start COMMAND (default $SHELL) attached; do the
    \\                    steps by hand, then press the detach key; tuppet
    \\                    shows the block it wrote and asks before
    \\                    appending it to the file
    \\
    \\While the steps run, a line shows the step and the session's
    \\current line; Ctrl-C stops them and attaches. 'tuppet do SESSION
    \\--use NAME' runs a block's steps in a session that runs already.
    \\
    \\examples:
    \\  tuppet start db3
    \\  tuppet start --check db3
    \\  APP_PW=$(pass show app) tuppet start -A db1 db2 web
    \\  APP_PW=$(pass show app) tuppet start -d db3
    \\
;

const play_help =
    \\tuppet play - play a recording into this terminal
    \\
    \\usage: tuppet play FILE.cast [--speed N] [--max-pause DUR]
    \\
    \\Plays an asciicast v2 recording, such as 'tuppet record' and 'tuppet
    \\run --record' make, in this terminal at the pace it was recorded.
    \\Space pauses and resumes, q or Ctrl-C quits, and after the last
    \\frame play waits for any key. These keys work whatever keyboard and
    \\mouse modes the recording turns on.
    \\
    \\The recording passes through the filter of 'tuppet attach', which
    \\removes queries and the modes that make a terminal report on its
    \\own, so this terminal never answers the recording. Recorded input
    \\is left out. At the end play leaves the alternate screen, resets
    \\the modes the recording may have set, and puts the cursor below
    \\the last frame.
    \\
    \\Inside a tuppet session ($TUPPET_SESSION and $TUPPET_SESSION_SOCKET
    \\set, and this terminal at the session's size, which a tmux pane in a
    \\session is not), play resizes the session to the recording's size
    \\and follows its resizes; an attach that resizes the session
    \\meanwhile gets the recording's size back, and at the end the
    \\session gets the size it had before, or the one the attach asked
    \\for. Anywhere else the recording plays as it is: when it is larger
    \\than this terminal, play says so once and waits 1.5 seconds.
    \\
    \\options:
    \\  --speed N        play N times as fast (a number above 0, such as
    \\                   2 or 0.5)
    \\  --max-pause DUR  wait at most DUR between two frames (default:
    \\                   the recording's idle_time_limit, else no limit)
    \\
    \\Outside a terminal play fails with exit 2. A recording you do not
    \\trust is safest played in a session of its own under a drawn
    \\attach, which paints only what tuppet's copy of the screen holds:
    \\
    \\  tuppet run -a --drawn -- tuppet play demo.cast
    \\
    \\exit codes: 0 after q or the key after the last frame, 1 a recording
    \\that cannot be read or the terminal gone, 128+n interrupted by
    \\signal n.
    \\
    \\examples:
    \\  tuppet play demo.cast
    \\  tuppet play demo.cast --speed 2 --max-pause 1s
    \\
;

const wait_help =
    \\tuppet wait - block until a condition holds
    \\
    \\usage: tuppet wait <session>... [-m TEXT] [--gone TEXT] [-e] [-i DUR]
    \\                   [--settled DUR] [--hidden-input] [--hit NAME]
    \\                   [--icase] [--regex] [--after-input] [--since SEQ]
    \\                   [--after-hit N] [-t DUR] [--any] [--view] [--stats]
    \\                   [-j]
    \\
    \\Waits until one of the conditions holds; the daemon checks them
    \\after every change on the screen. Give at least one:
    \\  -m, --match TEXT  TEXT is on screen
    \\  --gone TEXT       TEXT, on the screen when the wait starts or later,
    \\                    is gone from it
    \\  -e, --ended       the program has ended
    \\  --settled DUR     the screen changed, and then its text did not
    \\                    change for DUR, with no output left to process
    \\  -i, --idle DUR    the screen's text has not changed for DUR
    \\  --hidden-input    the program reads a line without echo, as a
    \\                    password prompt does
    \\  --hit NAME        the alert NAME ('*': any alert) hit after the
    \\                    latest input, or with --after-hit N after hit N
    \\Several are alternatives. --after-input and --since apply to all of
    \\them but --gone, --icase and --regex to -m and --gone, and --after-hit
    \\to --hit; 'tuppet help conditions' explains each one and its limits.
    \\
    \\It prints one line with the outcome, the condition that was met (its
    \\kind and its place among the conditions, counting from 0), the
    \\session, and the session's seqs, '-' standing for what is not known:
    \\
    \\  met match#0 3 seq=1187 input_seq=1100 hit_seq=-
    \\
    \\With --hit, a line follows for each hit it counts:
    \\
    \\  hit 4 approve Do you want to proceed?
    \\
    \\The outcome is met, timeout, ended (the program ended first), or
    \\removed (the session was removed first). Once the program has ended
    \\the line ends with its exit=CODE or exit=SIGNAL. After a timeout or
    \\an end, the last lines that changed since the latest input go to
    \\stderr. The seqs feed --since and 'tuppet view --since'. A program
    \\that 'tuppet stop' ended shows exit=stopped, as 'tuppet list' does.
    \\
    \\options:
    \\  -t, --timeout DUR  give up after this long (default 30s, at most 10m)
    \\  --any              wait on several sessions: the first that meets a
    \\                     condition wins (several sessions need it); a
    \\                     pattern stands for every session it matches
    \\                     when the wait starts, and must match one
    \\  --view             print the screen after the line
    \\  --stats            add what the program did during the wait to the
    \\                     line (see 'tuppet help conditions')
    \\  -j, --json         print the daemon's reply as JSON instead (see
    \\                     docs/protocol.md)
    \\
    \\exit codes: 0 a condition was met, also -e when the program failed;
    \\3 timed out; 4 the session ended or was removed before a condition
    \\was met.
    \\
    \\examples:
    \\  tuppet wait 2 -m 'Press any key' -t 5s
    \\  tuppet key 2 'make<Enter>'; tuppet wait 2 -m '$ ' --after-input -t 5m
    \\  tuppet wait build -e
    \\  tuppet wait web api -m ERROR --any
    \\  tuppet wait agent --hit approve -t 10m
    \\
;

const conditions_help =
    \\conditions - what tuppet wait, run, and do wait for
    \\
    \\usage: tuppet wait <session> CONDITION... [MODIFIER...] [-t DUR]
    \\       tuppet run CONDITION... [MODIFIER...] [-t DUR] -- <cmd...>
    \\       tuppet do <session> STEP... CONDITION... [-w DUR]
    \\       tuppet record <session> --start FILE CONDITION... [MODIFIER...]
    \\
    \\conditions (several are alternatives; the first that holds wins):
    \\  -m, --match TEXT  TEXT is on a line of the screen, or was on a line
    \\                    that scrolled into the history while waiting.
    \\                    Lines are matched as the program wrote them: rows
    \\                    that wrapped are joined, empty cells inside a line
    \\                    (as a tab leaves them) are spaces, and a trailing
    \\                    space matches only where the program wrote one.
    \\                    TEXT has at most 4 KiB and no line breaks.
    \\  --gone TEXT       TEXT is gone from the screen, after it was on it
    \\                    when the wait started (in tuppet do: before the
    \\                    input) or came later. Text that scrolled into the
    \\                    history is gone; text that never came never meets
    \\                    it. Lines are matched as with -m
    \\  -e, --ended       the program has ended, however it ended
    \\  --settled DUR     the screen changed (its text or a style) after the
    \\                    start (--since SEQ, the input with --after-input
    \\                    and in tuppet do, else the wait's start), and then
    \\                    its text did not change for DUR, counted from the
    \\                    wait's start at the earliest, with no output left
    \\                    on the pty to process and no synchronized frame
    \\                    held back. Use it, not -i, after a key or a
    \\                    resize: -i is met by a screen that has not reacted
    \\                    yet
    \\  -i, --idle DUR    the screen's text has not changed for DUR,
    \\                    counted from its last change (cursor moves and
    \\                    colors do not count)
    \\  --hidden-input    the terminal reads input a line at a time without
    \\                    echo, as password prompts do (sudo, ssh, read -s).
    \\                    The daemon checks the terminal's modes after each
    \\                    change and every 250 ms. Not on Windows
    \\  --hit NAME        the alert NAME hit after the latest input ('*':
    \\                    any alert of the session; see 'tuppet help alert'),
    \\                    so a dialog that was answered and is still on the
    \\                    screen does not count. A NAME the session has no
    \\                    alert of fails at once
    \\  --after-hit N     with --hit: any hit numbered above N (such as an
    \\                    outcome line's hit_seq) counts instead of the
    \\                    ones after the latest input
    \\  --icase           with -m and --gone: ignore the case of ASCII
    \\                    letters
    \\  --regex           with -m and --gone: TEXT is a regex of at most 256
    \\                    bytes, matched on each line: . [a-z] [^ ] \d \w \s
    \\                    (and \D \W \S), \t, * + ? {n} {n,} {n,m} (m at
    \\                    most 32), | and ( ), and ^ and $ for the line's
    \\                    ends; a backslash before one of \ . ^ $ | ? * + ( )
    \\                    [ ] { } / stands for that character. A pattern
    \\                    that can match empty text fails
    \\
    \\modifiers (they apply to every condition; --gone takes none):
    \\  --after-input     only what is new since the latest input counts:
    \\                    -m needs TEXT on a line that did not show it at
    \\                    the input, or on a row that went blank after it;
    \\                    -i counts from the wait's start at the earliest;
    \\                    -e needs an end after the input; --hidden-input
    \\                    needs hidden input that began after the input, so
    \\                    the prompt just answered does not count. Before
    \\                    the session's first input, everything since its
    \\                    start is new
    \\  --since SEQ       only what changed after SEQ counts: -m needs TEXT
    \\                    on a line whose text changed after SEQ, -e an end
    \\                    after it, --hidden-input hidden input that began
    \\                    after it; -i counts from the wait's start at the
    \\                    earliest. SEQ comes from an outcome line or a
    \\                    status; one from before the session fails. Not
    \\                    for tuppet run, whose session has no seqs yet
    \\  -t, --timeout DUR give up after DUR (default 30s, at most 10m)
    \\
    \\Without a condition, --since SEQ or --after-input alone waits until
    \\the text of some line changes after that point (the outcome line
    \\names it 'changed'); then 'tuppet view <session> --since SEQ' shows
    \\what changed.
    \\
    \\--after-input makes a prompt a reliable sign that a command is done:
    \\after typing 'make' and Enter at '$ ', the echo on the prompt's row
    \\does not meet -m '$ ', and the next prompt does, also after the
    \\screen scrolled or was cleared. Limits:
    \\  - TEXT inside the typed text itself is new, so it still matches.
    \\  - A program that clears and redraws a line within one burst of
    \\    output (as clear or Ctrl-L redraws the prompt in place) shows
    \\    nothing new there.
    \\  - A separate wait sees new rows and rows that went blank: TEXT that
    \\    goes away and comes back on the same row is not new to it. The
    \\    waits of 'tuppet run' and 'tuppet do' know TEXT before the input
    \\    and count that as new, if TEXT was gone for longer than about
    \\    50 ms.
    \\  - When the screen held more than 256 KiB of text at the input, any
    \\    line that changed after the input counts as new
    \\    (snapshot_truncated in the JSON reply).
    \\
    \\--hidden-input with --after-input waits for the next password prompt:
    \\after 'sudo make install' and Enter, it is met once sudo asks, and
    \\after the answer to 'New password:', once passwd asks to retype it.
    \\A prompt that shows nothing new on the screen after the answer to
    \\the one before is not new.
    \\
    \\--settled is met by what the program drew by then: a program that
    \\pauses longer than DUR inside a redraw (it clears, then draws 300 ms
    \\later) meets it in the pause, and one that draws the same text again
    \\changes nothing, so the wait runs to its deadline. --gone is checked
    \\after each change, at most every 50 ms: text that came and went in
    \\between can be missed.
    \\
    \\Rows that scrolled out of the history before the daemon checked them
    \\are counted as lost in the JSON reply.
    \\
    \\--stats (wait, run, do) adds what the program did to the outcome line:
    \\
    \\  met settled#0 3 seq=1190 input_seq=1187 hit_seq=- out_bytes=4120
    \\  draws=3 full_clears=1 rows_changed=24/24 first_change_ms=9
    \\
    \\out_bytes counts the bytes the program wrote; draws the times the
    \\daemon found a change in its output; full_clears its erases of the
    \\whole screen (ED 2, or ED 0 from the top left cell; not ED 3, which
    \\erases the history); rows_changed the rows of the screen that
    \\changed, of all of them; first_change_ms when the screen last
    \\changed, counted from the input (do) or the request, which is its
    \\first change when draws is 1. They come from the session's status
    \\before and after the request, so they are approximate; - stands for
    \\what is not known, such as the counters of a lost session.
    \\
;

const alert_help =
    \\tuppet alert - watch a session for a text
    \\
    \\usage: tuppet alert add <session> NAME=TEXT [--icase] [-j]
    \\       tuppet alert list [<session>...] [-j]
    \\       tuppet alert remove <session> NAME [-j]
    \\
    \\An alert watches a session's screen for TEXT, on lines as 'tuppet wait
    \\-m' matches them: a line that comes to show it is a hit. A hit marks
    \\the session with ! in 'tuppet list', where its state names the
    \\alert until 'tuppet ack'; it is an event ('tuppet events'), a mark
    \\in an active recording, and what --hit NAME waits for.
    \\
    \\Each line fires once: a spinner, a timer, or a typed answer on the
    \\line does not fire again, nor does the text a resize moves or a
    \\program redraws after a resize: until the next input, or until 5
    \\seconds after the last of a run of resizes, the lines on the screen
    \\at the resize fire only once more of them show the text than before
    \\it, while output that scrolls in fires as always. The same text on
    \\another line, a line that lost the text and shows it again, and a
    \\dialog drawn on a freshly switched alternate screen fire anew. So a
    \\program that reuses a dialog fires again only once the line
    \\changed: put the alert on a line that changes when the dialog is
    \\reused, such as the one that names the file or command it asks
    \\about, rather than its fixed buttons. Text that is on the screen
    \\when an alert is added counts as seen. A dialog shown for less than
    \\about 50 ms can be missed, and a program that erases and redraws
    \\its line in two bursts of output fires each time.
    \\
    \\An alert fires at most ten times a second; the hit after a pause
    \\counts the ones left out. A session keeps its last 64 hits, while
    \\the daemon runs; its alerts are kept with it, and 'tuppet restart'
    \\copies them.
    \\
    \\NAME follows the rules of session names, and TEXT has at most 256
    \\bytes and no line breaks; a session has at most 32 alerts. 'tuppet
    \\run --alert NAME=TEXT' adds alerts from the program's first byte,
    \\with the defaults from the config file: $XDG_CONFIG_HOME/tuppet/
    \\config.toml (~/.config/tuppet/config.toml), or the file
    \\TUPPET_CONFIG names, where TUPPET_CONFIG= reads none:
    \\
    \\  # alerts tuppet run adds to every session
    \\  [alerts]
    \\  approve = "Do you want to proceed?"
    \\  sudo = 'password for'
    \\
    \\The file is a small subset of TOML: comments, sections, and
    \\key = value lines. Besides [alerts], with NAME = "TEXT" lines, it
    \\takes [attach] and [side] for attaching (see 'tuppet help
    \\attach'), and [png] and [png.presets] for the fonts of tuppet png
    \\(see 'tuppet help fonts'); anything else fails with the file and
    \\line. Only the CLI reads it.
    \\
    \\options:
    \\  --icase    TEXT matches regardless of the case of ASCII letters
    \\  -j, --json print the daemon's reply (list: {"sessions":[{"id":N,
    \\             "alerts":[...]}]})
    \\
    \\examples:
    \\  tuppet alert add build 'error=error:' --icase
    \\  tuppet alert list
    \\  tuppet alert remove build error
    \\
;

const daemon_help =
    \\tuppet daemon - run the daemon in the foreground
    \\
    \\usage: tuppet daemon [--socket PATH] [--log PATH] [--idle-exit] [--keep-fresh]
    \\
    \\The daemon owns the sessions and their ptys. Any other command
    \\starts it detached when it cannot reach one, so running it by hand
    \\is only needed for debugging or under a supervisor. It listens on
    \\$XDG_RUNTIME_DIR/tuppet-<uid>.sock, or on
    \\/tmp/tuppet-<uid>/tuppet.sock when XDG_RUNTIME_DIR is unset,
    \\empty, or relative. An auto-started daemon logs to the same path
    \\with .log in place of .sock.
    \\
    \\Without --socket the daemon exits after 30 s with no programs
    \\running and no clients (not on Windows); the next command starts a
    \\new one. TUPPET_IDLE_EXIT sets the wait as a duration (such as 30s
    \\or 5m), and TUPPET_IDLE_EXIT=0 keeps the daemon running.
    \\--idle-exit makes any daemon, also one with --socket, exit after a
    \\minute with no programs running and no clients. --keep-fresh
    \\refreshes the times of the socket's folder, the socket, and its
    \\lock every hour, so that age-based cleaning of /tmp leaves a
    \\long-lived daemon alone. SIGTERM or
    \\SIGINT shuts it down as 'tuppet shutdown' does: every session stops
    \\and is saved, and the daemon exits 0. A second signal makes it exit
    \\at once, with status 1.
    \\
    \\Session data lives in $XDG_STATE_HOME/tuppet (~/.local/state/tuppet;
    \\%LOCALAPPDATA%\tuppet on Windows), one directory per machine and boot,
    \\readable only by you. Every daemon of yours shares it, so session
    \\ids are unique per boot, but each daemon shows only its own
    \\sessions. A starting daemon deletes its machine's data of other
    \\boots, and ended sessions are deleted 7 days after they ended.
    \\TUPPET_KEEP, read when a daemon starts, sets that (e.g. 12h, 30d; 0
    \\keeps them until 'tuppet remove'); the shortest setting among your
    \\daemons applies. An ended session leaves memory 30 s after its last
    \\use and loads from disk again when needed. A stored session whose
    \\files hold what tuppet never writes, such as a size outside 1..1000,
    \\is listed as damaged and never loaded; 'tuppet remove' deletes it,
    \\and it expires as other ended sessions do.
    \\
    \\The daemon keeps its sessions within a memory budget. A session is
    \\refused only when the screens of all sessions would not fit (about
    \\1.1 MiB each at the default size). History counts as it is used:
    \\when the sessions use more than the budget, the oldest lines of
    \\those that keep the most go first ('list -j' shows
    \\history_trimmed), and the full limit comes back once there is room
    \\again. The budget is a quarter of the machine's memory
    \\(or of the daemon's cgroup limit), at least 512 MiB. TUPPET_MEMORY,
    \\read when a daemon starts, sets it (e.g. 2G), and TUPPET_MEMORY=off
    \\turns it off.
    \\
    \\A client checks that the daemon speaks its protocol revision first.
    \\An older daemon that is still running after an upgrade is refused
    \\with a message that says how to stop it.
    \\
    \\Supervised mode (--socket): for a program that owns tuppet's lifetime.
    \\The daemon listens on exactly PATH (mode 0600), fails if a daemon is
    \\already live there, replaces a stale socket file, and never exits
    \\when idle. On Linux each session's program is killed if the daemon
    \\dies, even by SIGKILL; background jobs that ignore SIGHUP can
    \\survive that.
    \\Clients reach it with 'tuppet --socket PATH <command>' or TUPPET_SOCKET;
    \\they never start a daemon of their own and fail with exit 1 when
    \\nothing listens on PATH.
    \\
    \\To stop the daemon itself, see 'tuppet shutdown'.
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

const shutdown_help =
    \\tuppet shutdown - stop the daemon and every session it runs
    \\
    \\usage: tuppet shutdown [--reset] [--all] [-j]
    \\
    \\Asks the daemon (the default one, or the one on --socket PATH or
    \\TUPPET_SOCKET) to stop every running session, as 'tuppet stop' does,
    \\and then to exit. Their screens and recordings are saved, attached
    \\clients and 'tuppet events' end, and open waits get their answer as
    \\the sessions end. Ended sessions are kept, and the next command
    \\starts a new daemon that shows them again. It prints what it stopped
    \\and waits until the daemon is gone. With no daemon running it says
    \\so and exits 0; it never starts one.
    \\
    \\A daemon that is shutting down refuses new work; a command that
    \\meets it waits until it is gone and tries again with the next
    \\daemon. It fails instead with --socket, and when a reset meanwhile
    \\may have given its session ids to other sessions.
    \\
    \\--reset also deletes this daemon's stored sessions, with the
    \\recordings kept in the store (never one written to a file you
    \\named), and every stored session that no running daemon serves. It
    \\forgets the session 'attach -' returns to, and ids start at 1
    \\again, or above the highest id kept when other daemons still have
    \\sessions. Seqs keep rising, and the boot that hello reports gains
    \\a count of resets (<boot>.<n>), so cached ids and seqs from before
    \\are not mistaken for new ones. With no daemon running, the reset
    \\happens in this command.
    \\
    \\There is no confirmation: the command does what it says and reports
    \\what it did.
    \\
    \\options:
    \\  --reset    also delete the stored sessions and start ids over
    \\  --all      first shut down every other daemon whose sessions are
    \\             in the store and that still answers
    \\  -j, --json print each daemon's reply as one line of JSON, with
    \\             "daemon": true; without a daemon {"socket":PATH,
    \\             "daemon":false}, or with --reset what the reset did
    \\
    \\exit codes: 0 done, also with no daemon running; 1 an error, also
    \\when sessions could not be stopped (their ids are on stderr); 2 bad
    \\arguments; 3 a daemon did not exit within 30 s.
    \\
    \\examples:
    \\  tuppet shutdown
    \\  tuppet shutdown --reset
    \\  tuppet --socket /run/app/tuppet.sock shutdown
    \\  tuppet shutdown --all --reset
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

const update_help =
    \\tuppet update - change what a caller says about a session
    \\
    \\usage: tuppet update <session> [--label TEXT] [--accent | --no-accent]
    \\                     [--mark M | --no-mark] [--group G] [--meta K=V]...
    \\                     [--action SPEC]... [--no-actions] [-j]
    \\
    \\Changes, after 'tuppet run', what a drawn attach of a group shows
    \\about the session (see 'tuppet help attach'). Only the options given
    \\change; an empty --label or --mark takes it away. --group moves the
    \\session into another group, where it gets the next free number (the
    \\lowest no session of that group has); --group '' takes it out of
    \\its group. --meta stores short values that the status returns and
    \\tuppet does not read; an empty value takes a key away. --action
    \\replaces the actions the switcher offers, and --no-actions takes
    \\them away. A program in a session can update its own session
    \\through TUPPET_SESSION and TUPPET_SESSION_SOCKET.
    \\
    \\An action SPEC is KEY[!]:NAME, where KEY is one character other than
    \\a digit, / \ d f h; '!' asks for a second press while the session's
    \\program runs. KEY:NAME:A|B|C makes the switcher ask for one of the
    \\choices, KEY:NAME:?HINT for a line of text. tuppet only reports the
    \\action ('tuppet events' prints action KEY [VALUE]).
    \\
    \\options:
    \\  --label TEXT    the label shown next to the name (at most 64 bytes)
    \\  --accent        show the name inverted at the bar's left end
    \\  --mark M        a short mark next to the member (at most 16 bytes)
    \\  --group G       move the session into group G
    \\  --meta K=V      keep V under K
    \\  --action SPEC   an action of the switcher, once per action
    \\  -j, --json      print the reply
    \\
;

const side_help =
    \\tuppet side - set the view of a side session
    \\
    \\usage: tuppet side <session> --view compact|half|full [-j]
    \\       tuppet side <session> --request [-j]
    \\
    \\A side session ('tuppet run --side-of NAME') is shown in a pane with
    \\the session it is tied to. --view sets its view: compact, a few rows
    \\with the keys on the session in front; half or full, drawn over it
    \\with the keys on the side session. <session> is the side session or
    \\the session it is tied to. A program in the side session sets its own
    \\view with 'tuppet side $TUPPET_SESSION --view compact', for example
    \\after acting. Events report the view as side-view.
    \\
    \\--request reports side-requested for a session without a side
    \\session, as the side key of a drawn attach does; whoever follows the
    \\events may start one.
    \\
;

const lease_help =
    \\tuppet lease - keep a session alive while this command runs
    \\
    \\usage: tuppet lease <session> [-j]
    \\
    \\Prints the session's id (its status with -j) and waits. When this
    \\command ends for any reason, the daemon stops the session as 'tuppet
    \\stop' does; when the session ends first, this command exits 0.
    \\'tuppet run --lease' starts a session and holds its lease the same
    \\way. Leases are kept by the daemon's hang-up watcher, not by request
    \\slots, so any number of them can be open. Linux only.
    \\
;

const respawn_help =
    \\tuppet respawn - start an ended session's program again in its place
    \\
    \\usage: tuppet respawn <session> [--env NAME=VALUE]... [-j]
    \\
    \\Starts the command of an ended session again in a new session that
    \\takes its place: it shows the old screen and history, and keeps the
    \\name, directory, size, alerts, group, number, label, actions, and
    \\the side session tied to it; the ended session is removed. It
    \\prints the new session's id. Its environment is exactly the --env
    \\entries plus the session's own variables (TERM, TUPPET_SESSION,
    \\TUPPET_SESSION_SOCKET); nothing comes from this command's or the
    \\daemon's environment, so give PATH when the command needs it.
    \\
;

const flag_help =
    \\tuppet flag - flag a session as needing attention
    \\
    \\usage: tuppet flag <session> --attention TEXT | --clear [-j]
    \\
    \\A drawn attach of the session's group marks a flagged member with !
    \\and the text, and Space in its switcher goes there. The flag stays
    \\until --clear, or until the member comes to the front of an attach.
    \\
;

const commands_help =
    \\tuppet commands - the commands a session's shell reported
    \\
    \\usage: tuppet commands <session> [N] [-j]
    \\
    \\A shell that prints OSC 133 marks (A and B around its primary prompt,
    \\C when a command starts, D;CODE when it ended) tells tuppet its
    \\commands. tuppet keeps the last 50: each command line (from B to C,
    \\up to 4 KiB), its output (from C to D, the last 64 KiB), and its
    \\exit code. This prints the last N (all kept by default): a line with
    \\the number, the exit code, and the command, then the output indented.
    \\The status gains shell (unknown, prompt, or running), prompt_seq,
    \\last_exit, and paste_mode, and events report command-ended. tuppet
    \\takes the marks as they come and checks nothing about who printed
    \\them. 'tuppet do --at-prompt SEQ -p TEXT' puts one line on a prompt
    \\that waits (see 'tuppet help do').
    \\
;

const attach_help =
    \\tuppet attach - connect this terminal to a session live
    \\
    \\usage: tuppet attach <session> [-r [--no-keys]] [-f] [-k KEY]
    \\                         [--label TEXT] [--no-resize]
    \\                         [--drawn | --no-drawn] [--no-detach]
    \\                         [--alt-screen] [--pass LIST] [--history N]
    \\       tuppet attach - [options]
    \\       tuppet attach [-k KEY] [--no-resize] [--drawn | --no-drawn]
    \\       tuppet attach [<session>] --drawn --group NAME [--end-with SESSION]
    \\                         [--title TEXT] [--quiet-detach] [--no-detach]
    \\                         [options]
    \\
    \\Shows the session's screen in this terminal and keeps it live. By
    \\default this attach is the session's writer: keystrokes go to the
    \\program and this terminal's size is applied to the session, also
    \\when it changes. When the writer detaches, the session gets the size
    \\back that it had before, unless 'tuppet resize' set one meanwhile. A
    \\session has any number of read-only viewers and at most one writer;
    \\other commands keep working meanwhile. While 'tuppet do' types into
    \\the session, what you type waits for it ("held: automation is
    \\typing"), and is discarded if the hold lasts too long. A writer marks
    \\what it showed as seen (see 'tuppet ack') when it attaches, detaches,
    \\and when the session ends. While attached, this terminal's bell rings
    \\once when another session comes to need you.
    \\
    \\'-' attaches to the session you detached from last, on this machine
    \\since it started. In a terminal, --read-only opens the picker's
    \\viewer for the session: it fits the session to this terminal, says
    \\when it shows only part of it, and marks it seen after a second.
    \\A session cannot be attached from its own terminal ($TUPPET_SESSION).
    \\
    \\A writer needs a terminal: outside one (a script, an agent's pipe)
    \\attach without -r fails with exit 2; use 'tuppet view', 'tuppet
    \\wait', or 'tuppet events' there. 'tuppet attach -r' outside a
    \\terminal writes the session's output as it comes, marks nothing
    \\seen, and ends when the session does.
    \\
    \\--history N first writes the session's last N older lines, the ones
    \\above its screen: in a terminal they go into its scrollback, right
    \\above the session and in order; outside one, 'attach -r' writes them
    \\before the stream. A daemon too old for it says so on stderr, and the
    \\attach goes on without them. It is a usage error with -r in a
    \\terminal.
    \\
    \\Without a session, opens the session picker, as a bare 'tuppet'
    \\does: your sessions, newest first, with a live preview, and a header
    \\that counts the ones that need you. Enter shows a session full
    \\screen without controlling it, ←/→ switch to the previous or next
    \\one, 'a' takes control, Tab goes to the next session that needs you,
    \\Space marks it seen, x stops it (after asking), 'o' shows its history
    \\in $PAGER, the detach key returns to the picker, and '?' lists every
    \\key. Outside a terminal it lists the sessions.
    \\
    \\The detach key ends the attach and is never passed to the program.
    \\It is Ctrl-] unless --detach-key, TUPPET_DETACH_KEY, or detach_key in
    \\the [attach] section of the config file sets another; 'bell = false'
    \\there keeps the bell quiet. The terminal is restored on every exit.
    \\
    \\--drawn paints the session itself, from tuppet's copy of its screen;
    \\the program's output never reaches this terminal as written. It
    \\paints on the normal screen, so lines that leave the session's
    \\screen go into this terminal's own scrollback, once and in order,
    \\and its search and copy keep working. It paints on the alternate
    \\screen while the program is on its own, while a box has the
    \\keyboard, while the window is smaller than the session (it says
    \\so), and always with --alt-screen. When the window is resized, lines
    \\next to the cut may appear twice in the scrollback; and a window that
    \\shrinks can move tuppet's own line, or a --grab never box, into the
    \\scrollback before tuppet repaints. At the end the last screen stays,
    \\with the cursor below it. tuppet sets the input modes the
    \\program asked for (cursor keys, keypad, mouse, focus, keyboard
    \\protocols), keeps bracketed paste on and passes the brackets only to
    \\a program that asked for them, and passes on the bell,
    \\notifications, clipboard writes, and links (--pass chooses which),
    \\never a clipboard read or the window title. After a broken stream it attaches again for up to 5 s.
    \\When the program ends, so does the attach. What a drawn attach does
    \\not do:
    \\  - pictures, which tuppet's sessions do not store
    \\  - anything else tuppet's copy of the screen does not hold
    \\  - Windows, which has no attach
    \\'drawn = true' in [attach] makes it the default for attach, run -a,
    \\and the picker's 'a'; --no-drawn overrides that, and it never applies
    \\to -r. Older tuppet versions refuse a config file with keys they do
    \\not know, such as drawn, box_pause, set_aside, alt_screen, or pass.
    \\
    \\A drawn attach also shows boxes that 'tuppet run --over' starts over
    \\the session. A box arrives as a line at the bottom right (the top
    \\right on the alternate screen) and rings the bell once; it opens
    \\once you paused typing for box_pause (1s unless [attach] says
    \\otherwise), and takes keys only after the terminal
    \\answered a cursor report and keys paused another 500 ms. The border
    \\says wait…, then keys here. When it closes, a receipt shows and keys
    \\are dropped until they pause for 500 ms. Every key but Esc and the
    \\detach key goes to the program in the box. Esc (once the box has the
    \\keys) or the detach key sets an open box aside (no other box opens by
    \\itself until that one ended); the detach key opens a box that waits
    \\and dismisses a receipt, and detaches only when no box is there. For
    \\a second after either key acted on a box, more presses of it do
    \\nothing, so pressing it over and over never detaches. With
    \\'set_aside = false' in [attach], Esc goes to the box's program and
    \\the detach key detaches from an open box. With --no-detach the
    \\detach key never detaches while this attach writes; with both, an
    \\open box keeps the keys until its program ends.
    \\
    \\options:
    \\  -r, --read-only       only watch; keyboard input other than the
    \\                        detach key is ignored
    \\  --no-keys             with -r: the viewer takes no key but the
    \\                        detach key and shows no keys, for a caller
    \\                        that lets someone only watch
    \\  -f, --force           take over writing from the current writer,
    \\                        which continues read-only
    \\  -k, --detach-key KEY  ^X, <C-x>, or one character (default ^])
    \\  --label TEXT          what this writer calls itself, shown as the
    \\                        session's writer (default: the terminal's
    \\                        name, such as pts/3); at most 64 bytes,
    \\                        without control characters
    \\  --no-resize           never resize the session to this terminal
    \\  --drawn               paint the session from tuppet's copy of its
    \\                        screen (not with -r, not outside a terminal)
    \\  --no-drawn            pass the program's output on, also when the
    \\                        config file says drawn = true
    \\  --pass LIST           with --drawn: what of the session's and its
    \\                        boxes' output reaches this terminal: a list of
    \\                        bell, notifications, clipboard, and links, or
    \\                        none (default all four; pass in [attach]).
    \\                        tuppet's own bell for a box stays under bell
    \\  --alt-screen          with --drawn: always paint on the alternate
    \\                        screen, leaving this terminal's scrollback
    \\                        alone (alt_screen = true in [attach])
    \\  --no-detach           with --drawn: the detach key does nothing, and
    \\                        the attach lasts until the program ends (exit
    \\                        0 then means the program exited with 0); once
    \\                        another client took over writing, the key
    \\                        detaches again
    \\  --history N           first write the last N older lines, 0 to
    \\                        100000 (default 0)
    \\  --group NAME          with --drawn: show the members of group NAME one
    \\                        at a time, <session> first (default: the lowest
    \\                        number); see 'Groups' below
    \\  --end-with SESSION    with --group: end when SESSION ends, with its
    \\                        code
    \\  --title TEXT          with --group: the switcher's frame shows TEXT
    \\                        instead of the group's name
    \\  --quiet-detach        with --group: print nothing on detach (by
    \\                        default tuppet says how to return)
    \\
    \\Groups: 'tuppet run --group NAME' makes sessions members of a group,
    \\with numbers. --group shows them one at a time. From the second
    \\member on, a bar on the bottom row names the member in front and the
    \\others, with their numbers, state, marks, and ! with what needs
    \\attention. F12 (switch_key) or the detach key (menu_key) opens the
    \\switcher: digits, / to filter, Space for the next member that needs
    \\attention, Enter to go, Esc to stay, F12 again to go back, \ sends
    \\F12 on, d detaches (not with --no-detach), f steps the side pane, h
    \\shows the history in $PAGER, and the caller's action letters ('tuppet
    \\help update'); letters wait half a second after it opened. The
    \\detach key twice sends it on. After a switch, keys are dropped until
    \\the terminal answered; only the member in front writes into this
    \\terminal's scrollback, after a dim line with its name (switch_marks).
    \\An ended member stays dimmed until Enter or x closes (removes) it; r
    \\and the caller's action letters are reported as actions (an action
    \\on x comes first). A member another window types in shows
    \\read-only until Enter takes it over. F11 ([side] key) steps the side
    \\session ('tuppet run --side-of') through compact (a pane below, or
    \\beside on wide windows, or a strip in the bar; keys stay on the
    \\member), half, and full (keys go to it); Esc goes back to compact.
    \\On a member without one, F11 reports side-requested.
    \\
    \\exit codes (the one exception to the codes every other command
    \\uses: attach and run -a end with the program's own code):
    \\  0     detached
    \\  N     the session's program exited with code N (128+n when killed
    \\        by signal n)
    \\  1     error, the writer role is taken, or this viewer fell too far
    \\        behind
    \\  2     bad arguments, or a writer attach outside a terminal
    \\  4     the session was lost, so there is no screen to show, also
    \\        while a drawn attach attached again
    \\  128+n this attach was ended by signal n; the session keeps running
    \\
    \\config file ($XDG_CONFIG_HOME/tuppet/config.toml, or TUPPET_CONFIG):
    \\  [attach]
    \\  bell = false
    \\  detach_key = "^A"
    \\  drawn = true
    \\  alt_screen = false
    \\  pass = "bell,notifications"
    \\  box_pause = "1s"
    \\  set_aside = false
    \\
    \\examples:
    \\  tuppet attach 2
    \\  tuppet attach build -r
    \\  tuppet attach build -r --no-keys -k ^Q
    \\  tuppet attach -
    \\  tuppet attach agent --drawn --no-detach
    \\  tuppet attach build --history 1000
    \\
;

const sweep_help =
    \\tuppet sweep - resize through many sizes and report what was drawn
    \\
    \\usage: tuppet sweep <session> -s SIZES [--step N] [--find NAME=TEXT]...
    \\                    [--icase] [--settled DUR] [-t DUR] [--refine]
    \\                    [--save DIR] [--view] [--min-size WxH]
    \\                    [--max-time DUR] [-f] [-j]
    \\       tuppet sweep -s SIZES [options] [-C DIR] -- <cmd...>
    \\
    \\Resizes the session to each size in turn and reports, for each, what
    \\the program did and where the texts given with --find sit. It judges
    \\nothing: a screen that did not change, or a find in its place, is not
    \\a correct layout, and the report ends with what it did not check.
    \\
    \\The sweep attaches as the session's writer, labelled "sweep", and
    \\resizes through that stream, so the session gets its size back however
    \\the sweep ends, also when it is killed. Meanwhile 'tuppet list -j' and
    \\the picker show the writer, and 'tuppet do --unless-attached' refuses.
    \\It never takes over: an attached writer refuses the sweep (exit 5), and
    \\so do viewers and previews unless -f, and sizes below 20x5 unless
    \\--min-size. A takeover (attach -f), another client's input or resize,
    \\or the end of the stream stops it with a partial report.
    \\
    \\At each size it waits until the screen changed after the resize and
    \\then stayed quiet for --settled, within -t, and reads it. SCREEN says
    \\what the program did:
    \\  same size                  the session had that size already
    \\  changed K/N rows, B bytes  it changed K of the N rows, writing B bytes
    \\  unchanged, wrote B bytes   it wrote, and its output then stayed quiet
    \\                             for --settled, but the screen did not change
    \\  wrote nothing              it wrote nothing within -t
    \\  still changing             the screen changed but never settled
    \\  ended exit=N               the program ended; the sweep stops there
    \\with ", late" when the screen changed after the read, before the next
    \\resize, and ", blank" when it was empty.
    \\
    \\Each find's column (cells count from 1; right counts from the right
    \\edge to the text's last cell):
    \\  R:C                        the first place it sits, in reading order
    \\  R:C1..C2 right=N           over a range of sizes, its right edge stays
    \\  moves R:C1..C2             it moves at every size of the range
    \\  prefix "X" at R:C          the text is not there, but its first part X
    \\                             (half of it or more, at least 3 characters)
    \\                             is, on the row the size before or after had
    \\                             it (or the starting size), as far from the
    \\                             left or the right edge
    \\  split R:C                  its first part ends that row, and the rest
    \\                             starts the next row at its first non-blank
    \\  absent                     none of these
    \\then " xN" when it is there N times, and " stale" when its row did not
    \\change after the resize: the program left it alone, or drew it again
    \\the same, which cannot be told apart. A find that is not on the
    \\screen where the sweep starts gets a warning.
    \\
    \\Sizes in a row whose facts are equal print as one range, as soon as
    \\the range ends; the counts in SCREEN may vary over it, and a find's
    \\place too, as right=N or moves show. Then 'back at WxH: same' or
    \\'differs in rows ...' compares the screen back at the starting size,
    \\text and styles, with the one before the sweep, which is read twice,
    \\max(--settled, 1s) apart: rows that changed on their own are named
    \\and left out. Then the hits, bells, and notifications during the
    \\sweep, and what was not checked. An estimate of the time goes to
    \\stderr first.
    \\
    \\SIZES is WxH, where either side can be a range A..B, taken every
    \\--step cells with B last: 60..160x40, 80x10..50, or 60..160x20..40
    \\(every pair: all the widths at each height); several go with commas:
    \\80x24,120x40. At most 256.
    \\
    \\options:
    \\  -s, --sizes SIZES  the sizes, in order
    \\  --step N           cells between the sizes of a range (default 1)
    \\  --find NAME=TEXT   report where TEXT sits, as the column NAME; rows
    \\                     are read with trailing spaces trimmed, so TEXT
    \\                     cannot end in a space
    \\  --icase            finds ignore the case of ASCII letters
    \\  --settled DUR      how long the screen stays quiet to count as
    \\                     drawn (default 200ms)
    \\  -t, --timeout DUR  deadline per size (default 2s, at most 10m)
    \\  --refine           also sweep between neighbouring sizes whose facts
    \\                     differ (SCREEN, and each find's state, row, count,
    \\                     and staleness), until the edge between them is
    \\                     exact
    \\  --save DIR         write WxH.txt and WxH.styles per size, and
    \\                     baseline.txt and baseline.styles, into DIR, which
    \\                     must be new or empty, for 'diff -r' between runs
    \\  --view             print the screen at the first size of each range
    \\  --min-size WxH     allow sizes down to WxH (default 20x5)
    \\  --max-time DUR     stop after DUR, go back to the starting size, and
    \\                     report what was swept (default 90s, at most 1h)
    \\  -f, --force        sweep although viewers or previews watch
    \\  -j, --json         print a JSON line per size and one at the end
    \\  -C, --cwd DIR      with a command: where it runs
    \\
    \\With -- CMD, the sweep runs CMD in a session of its own at the size
    \\'tuppet run' gives (120x40, or TUPPET_SIZE), without default alerts,
    \\waits until its screen settled within -t, sweeps it with no smallest
    \\size, and removes it afterwards, also on Ctrl-C. Ctrl-C detaches, and
    \\the session gets its size back.
    \\
    \\With -j, a size line is {"type":"size"} with cols, rows, screen
    \\(same_size, changed, unchanged, wrote_nothing, still_changing, or
    \\ended), rows_changed, bytes, exit, late, blank, resize_seq, seq, and
    \\finds: {NAME: {state, row, col, right, prefix, count, stale}}, where
    \\state is at, absent, prefix, or split and null stands for no value.
    \\The end line, {"type":"end"}, has sizes, planned, ms, start, back,
    \\back_rows, back_base_differs, own_rows, hits, bells, notifications,
    \\stopped and why (null when it finished), absent (finds absent at
    \\every size), stale, settled_ms, timeout_ms, step, and refined.
    \\
    \\exit codes: 0 the sweep finished, or --max-time ran out, whatever it
    \\found; 1 error, interference, or a takeover; 2 bad arguments; 4 the
    \\program ended or the session was removed; 5 refused; 128+n
    \\interrupted. A sweep never exits 3.
    \\
    \\examples:
    \\  tuppet sweep app -s 40..160x30 --step 2 --find title='TaskBoard v0.3'
    \\  tuppet sweep app -s 60..120x24 --find status='sync ok' --refine
    \\  tuppet sweep -s 80x24,120x40 --save before -- ./tui
    \\  tuppet sweep app -s 80x10..50 -j | jq -c 'select(.type == "size")'
    \\
;

const llm_skill_help =
    \\tuppet llm-skill - print a coding-agent skill for tuppet
    \\
    \\usage: tuppet llm-skill
    \\
    \\Prints a SKILL.md (YAML front matter plus instructions) that tells a
    \\coding agent when to use tuppet and how: the run/do/wait/view loop,
    \\key notation, evidence capture, cleanup, and common pitfalls. Save
    \\it as tuppet/SKILL.md in the directory your agent loads skills
    \\from, here SKILLS_DIR:
    \\
    \\  mkdir -p "$SKILLS_DIR/tuppet"
    \\  tuppet llm-skill > "$SKILLS_DIR/tuppet/SKILL.md"
    \\
;

/// The skill text printed by `tuppet llm-skill`.
const llm_skill = @embedFile("llm_skill.md");

const help_entries = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "run", .text = run_help },
    .{ .name = "list", .text = list_help },
    .{ .name = "stop", .text = stop_help },
    .{ .name = "remove", .text = remove_help },
    .{ .name = "restart", .text = restart_help },
    .{ .name = "rename", .text = rename_help },
    .{ .name = "update", .text = update_help },
    .{ .name = "side", .text = side_help },
    .{ .name = "lease", .text = lease_help },
    .{ .name = "respawn", .text = respawn_help },
    .{ .name = "flag", .text = flag_help },
    .{ .name = "commands", .text = commands_help },
    .{ .name = "events", .text = events_help },
    .{ .name = "ack", .text = ack_help },
    .{ .name = "alert", .text = alert_help },
    .{ .name = "key", .text = key_help },
    .{ .name = "do", .text = do_help },
    .{ .name = "resize", .text = resize_help },
    .{ .name = "view", .text = view_help },
    .{ .name = "png", .text = png_help },
    .{ .name = "record", .text = record_help },
    .{ .name = "play", .text = play_help },
    .{ .name = "wait", .text = wait_help },
    .{ .name = "conditions", .text = conditions_help },
    .{ .name = "fonts", .text = fonts_help },
    .{ .name = "daemon", .text = daemon_help },
    .{ .name = "shutdown", .text = shutdown_help },
    .{ .name = "llm-skill", .text = llm_skill_help },
    .{ .name = "attach", .text = attach_help },
    .{ .name = "sweep", .text = sweep_help },
    .{ .name = "start", .text = start_help },
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
    plat.stderrWriteAll("\n") catch {};
    plat.stderrWriteAll(client.usageHint()) catch {};
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

    runMain(gpa, argv[@min(1, argv.len)..]) catch |err| switch (err) {
        // Usage errors already printed their message and hint.
        error.UsageError => std.process.exit(2),
        else => {
            attach_client.restoreTerminal();
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
        // The endpoint travels in JSON strings too: the store, replies.
        if (!std.unicode.utf8ValidateSlice(args[1])) return usageFail("the --socket path '{f}' is not valid UTF-8", .{std.unicode.fmtUtf8(args[1])});
        client.socket_override = args[1];
        args = args[2..];
    } else if (std.c.getenv("TUPPET_SOCKET")) |env| {
        const value = std.mem.span(env);
        if (!std.unicode.utf8ValidateSlice(value)) client.runtimeFail("TUPPET_SOCKET '{f}' is not valid UTF-8", .{std.unicode.fmtUtf8(value)});
        if (value.len > 0) client.socket_override = value;
    }
    // Arguments travel to the daemon in JSON strings, which carry UTF-8
    // only.
    for (args) |a| if (!std.unicode.utf8ValidateSlice(a))
        return usageFail("the argument '{f}' is not valid UTF-8", .{std.unicode.fmtUtf8(a)});
    if (args.len == 0) {
        // In a terminal, the picker; anywhere else (a script, an agent's
        // pipe) the usage, and a usage error.
        if (builtin.os.tag != .windows and std.c.isatty(0) == 1 and std.c.isatty(1) == 1) {
            return attach_client.cmdAttach(gpa, &.{});
        }
        plat.stderrWriteAll(usage_text) catch {};
        std.process.exit(2);
    }
    return runCommand(gpa, args[0], args[1..]);
}

const daemon_usage = "usage: tuppet daemon [--socket PATH] [--log PATH] [--idle-exit] [--keep-fresh]";

fn runCommand(gpa: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) !void {
    // `tuppet <command> --help`: per-command help. Later, help is an
    // option the command's parser recognizes where it takes options, so
    // payloads such as `tuppet key 2 --help` reach the session untouched.
    if (rest.len > 0 and isHelpFlag(rest[0])) {
        if (commandHelp(cmd)) |text| {
            plat.stdoutWriteAll(text) catch {};
            return;
        }
    }
    // Usage errors from here on point to this command's help.
    if (commandHelp(cmd) != null and !std.mem.eql(u8, cmd, "help")) {
        client.command = cmd;
        client.command_help = commandHelp(cmd);
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
            } else if (std.mem.eql(u8, a, "--idle-exit")) {
                opts.idle_exit = true;
            } else if (std.mem.eql(u8, a, "--keep-fresh")) {
                opts.keep_fresh = true;
            } else {
                if (std.mem.startsWith(u8, a, "-")) return client.unknownOption(a, daemon_usage);
                return usageFail("unexpected argument '{s}' ({s})", .{ a, daemon_usage });
            }
        }
        if (opts.log != null and opts.socket == null) return usageFail("--log requires --socket", .{});
        // The daemon changes to / before it opens either path.
        if (opts.socket) |p| opts.socket = try client.absolutePath(gpa, p);
        if (opts.log) |p| opts.log = try client.absolutePath(gpa, p);
        serving = true;
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
        if (std.mem.eql(u8, rest[0], "fonts")) try client.printFontPresets(gpa);
        return;
    }
    if (std.mem.eql(u8, cmd, "llm-skill")) {
        if (rest.len != 0) return usageFail("'llm-skill' takes no arguments (got '{s}')", .{rest[0]});
        plat.stdoutWriteAll(llm_skill) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        if (rest.len != 0) return usageFail("'--version' takes no arguments (got '{s}')", .{rest[0]});
        plat.stdoutWriteAll("tuppet " ++ protocol.version ++ " (variant: " ++ protocol.variant ++ ")\n") catch {};
        return;
    }

    return dispatch(gpa, cmd, rest);
}

fn dispatch(gpa: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) !void {
    if (std.mem.eql(u8, cmd, "run")) {
        return client.cmdRun(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "list")) {
        return client.cmdList(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "key")) {
        return client.cmdKey(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "do")) {
        return client.cmdDo(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "rename")) {
        return client.cmdRename(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "restart")) {
        return client.cmdRestart(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "resize")) {
        return client.cmdResize(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "view")) {
        return client.cmdView(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "png")) {
        return client.cmdPng(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "wait")) {
        return client.cmdWait(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "record")) {
        return client.cmdRecord(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "stop")) {
        return client.cmdStop(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "remove")) {
        return client.cmdRemove(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "ack")) {
        return client.cmdAck(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "alert")) {
        return client.cmdAlert(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "events")) {
        return client.cmdEvents(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "attach")) {
        return attach_client.cmdAttach(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "sweep")) {
        return sweep.cmdSweep(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "play")) {
        return play.cmdPlay(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "shutdown")) {
        return client.cmdShutdown(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "start")) {
        return start_run.cmdStart(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "update")) {
        return client.cmdUpdate(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "side")) {
        return client.cmdSide(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "lease")) {
        return client.cmdLease(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "respawn")) {
        return client.cmdRespawn(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "flag")) {
        return client.cmdFlag(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "commands")) {
        return client.cmdCommands(gpa, rest);
    }
    return usageFail("unknown command '{s}'", .{cmd});
}

// Zig 0.17 only collects test blocks from files the root file references
// directly, so every file with tests is listed here.
comptime {
    _ = @import("client.zig");
    _ = @import("plat.zig");
    _ = @import("session.zig");
    _ = @import("spawn.zig");
    _ = @import("ptyio.zig");
    _ = @import("record.zig");
    _ = @import("trace.zig");
    _ = @import("keys.zig");
    _ = @import("mouse.zig");
    _ = @import("input/mouse_encode.zig");
    _ = @import("protocol.zig");
    _ = @import("ipc.zig");
    _ = @import("render.zig");
    _ = @import("png.zig");
    _ = @import("fonts.zig");
    _ = @import("fonts/bitmap.zig");
    _ = @import("fonts/compose.zig");
    _ = @import("fonts/drawn.zig");
    _ = @import("fonts/emoji.zig");
    _ = @import("fonts/unifont.zig");
    _ = @import("pty.zig");
    _ = @import("attach.zig");
    _ = @import("attach_client.zig");
    _ = @import("attach_filter.zig");
    _ = @import("store.zig");
    _ = @import("picker.zig");
    _ = @import("names.zig");
    _ = @import("track.zig");
    _ = @import("units.zig");
    _ = @import("limits.zig");
    _ = @import("budget.zig");
    _ = @import("registry.zig");
    _ = @import("status.zig");
    _ = @import("view.zig");
    _ = @import("styles.zig");
    _ = @import("paint.zig");
    _ = @import("drawn.zig");
    _ = @import("boxes.zig");
    _ = @import("words.zig");
    _ = @import("cond.zig");
    _ = @import("regex.zig");
    _ = @import("evaluator.zig");
    _ = @import("hangup.zig");
    _ = @import("sample.zig");
    _ = @import("batch.zig");
    _ = @import("events.zig");
    _ = @import("over.zig");
    _ = @import("marks.zig");
    _ = @import("member.zig");
    _ = @import("group.zig");
    _ = @import("alert.zig");
    _ = @import("config.zig");
    _ = @import("sweep.zig");
    _ = @import("play.zig");
    _ = @import("start.zig");
    _ = @import("start_run.zig");
    _ = @import("start_record.zig");
}

test "every dispatched command has a help text" {
    const commands = [_][]const u8{
        "run",    "list",  "stop",    "remove", "restart",  "rename", "key",       "do",
        "resize", "view",  "png",     "record", "wait",     "daemon", "llm-skill", "attach",
        "events", "ack",   "alert",   "sweep",  "shutdown", "play",   "start",     "update",
        "side",   "lease", "respawn", "flag",   "commands",
    };
    for (commands) |name| {
        const text = commandHelp(name) orelse return error.MissingHelp;
        try std.testing.expect(std.mem.startsWith(u8, text, "tuppet "));
        try std.testing.expect(std.mem.indexOf(u8, text, "usage: tuppet ") != null);
    }
    try std.testing.expect(commandHelp("bogus") == null);
}

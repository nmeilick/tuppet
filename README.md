# tuppet

tuppet (TUI puppet) lets scripts drive terminal programs. It runs vim, htop, a REPL, or any curses or Bubble Tea app in a
headless terminal, types keys and mouse events into it, waits for text to appear, and reads the screen back as text, JSON,
HTML, or a PNG.

It is made for coding agents and end-to-end tests: anything that must operate a program that needs a real terminal.
Terminal emulation comes from [Ghostty](https://github.com/ghostty-org/ghostty)'s VT core, so programs see an
xterm-compatible terminal that answers cursor-position, color, and mode queries.

With `tuppet` and `vim` on your `PATH`:

```console
$ id=$(tuppet run vim notes.txt)                                 # start vim in a session
$ tuppet wait $id --match notes.txt                              # wait until vim shows the file name
met match#0 1 seq=4 input_seq=- hit_seq=-
$ tuppet key $id i 'Hello from tuppet' '<Esc>' ':wq<Enter>'      # type a line, save, and quit
$ tuppet wait $id --ended                                        # wait for vim to exit
met ended#0 1 seq=12 input_seq=9 hit_seq=- exit=0
$ tuppet remove $id                                              # delete the ended session
$ cat notes.txt
Hello from tuppet
```

## Install

Download the archive for your platform from the [releases page](https://github.com/nmeilick/tuppet/releases), unpack it,
and put `tuppet` on your `PATH`. Each release lists SHA-256 checksums in `SHA256SUMS`.

Every platform comes in three builds, which differ only in `tuppet png`: in the fonts it has built in, and in the font
files it reads. Medium and full builds read fonts through FreeType; lean builds have no FreeType, its only C font code,
and read only the bitmap formats `.hex`, `.psf`, and `.psf.gz`. All three draw box drawing and color emoji the same way
and fall back to GNU Unifont. Take medium, unless you want screenshots of Chinese, Japanese, or Korean text and Nerd
Font icons in matching TrueType fonts (full), or the smallest binary (lean).

| Build | Archive | Built-in fonts | Size |
| --- | --- | --- | --- |
| medium | `tuppet-<version>-<platform>` | JetBrains Mono; reads your TrueType, OpenType, and bitmap fonts through FreeType | 14.1 MB |
| lean | `tuppet-<version>-<platform>-lean` | GNU Unifont only, in 8x16 cells; reads only `.hex`, `.psf`, and `.psf.gz` fonts | 12.6 MB |
| full | `tuppet-<version>-<platform>-full` | medium's, plus JuliaMono, Symbols Nerd Font Mono, and Noto Sans Mono CJK SC | 34.9 MB |

The sizes are those of the x86_64 Linux binaries. `tuppet --version` names the build.

To build from source you need [Zig 0.17.0](https://ziglang.org/download/) and network access for the first build, which
downloads Ghostty, GNU Unifont, FreeType, and JetBrains Mono. A lean build (`zig build -Dfonts=lean`) skips the last
two; a full build (`-Dfonts=full`) also downloads JuliaMono, Symbols Nerd Font, and Noto Sans Mono CJK SC, about 52 MB:

```sh
git clone https://github.com/nmeilick/tuppet && cd tuppet
make                              # or: zig build -Doptimize=ReleaseSafe
cp zig-out/bin/tuppet ~/.local/bin/
```

Linux is the supported platform for now; see [Platform support](#platform-support).

## Usage

| Command | What it does |
| --- | --- |
| `tuppet` | Open the session picker (in a terminal). |
| `tuppet run [-a] [-n NAME] [-s WxH] [-C DIR] [-r] [--alert NAME=TEXT] [--if-exists W] [conditions] <cmd...>` | Start a session and print its id, then wait for the conditions; or attach to it (`-a`). |
| `tuppet list [<session>...]` | List sessions with id, name, state, age, and command. |
| `tuppet stop <session>...` | Hang up and terminate each program's process group, killing what is left after 0.5 s. |
| `tuppet remove <session>... [-f]` | Delete ended sessions and what tuppet kept of them; `-f` stops running ones first. |
| `tuppet restart <session>` | Run an ended session's command again, with your current environment. |
| `tuppet rename <session> <name> [-j]` | Give a session another name. |
| `tuppet events [<session>...] [-i DUR] [-v] [-j]` | Follow what happens to sessions as it happens: starts, ends, bells, notifications, alert hits, renames. |
| `tuppet ack <session>...` | Mark sessions as seen, which clears their `!` in `tuppet list`. |
| `tuppet alert add <session> NAME=TEXT \| list \| remove` | Watch a session for a text: a line that comes to show it is a hit. |
| `tuppet key <session> <keys...>` | Type keys in vim notation, such as `<C-c>`, `<Esc>`, `<Up>`, `<S-Tab>`, or `<F5>`. Other text is typed as it is. |
| `tuppet do <session> <steps...>` | Type text, keys, pastes, secrets, mouse clicks, and focus events, resize, and wait for what follows, with guards. |
| `tuppet resize <session> WxH [-j]` | Resize the terminal and print the seq of the reflow. |
| `tuppet view <session> [-f plain\|vt\|html] [-s] [--since SEQ] [--styles] [-j]` | Print the visible screen, with `-s` also the history above it, with `--since` only what changed, with `--styles` its colors and emphasis. |
| `tuppet png <session> <file> [-f SPEC] [--font-size N] [-j]` | Render the visible screen to a PNG file, with the fonts SPEC lists. |
| `tuppet wait <session>... [-m TEXT] [--gone TEXT] [--settled DUR] [-i DUR] [-e] [--hidden-input] [--hit NAME] [--after-input] [--any]` | Block until text appears or goes, the screen settles or goes quiet, the program asks for a password, an alert hits, or it ends. |
| `tuppet record <session> --start FILE \| --mark LABEL \| --stop` | Start, mark, or stop an asciicast or trace recording. |
| `tuppet sweep <session> -s SIZES [--find NAME=TEXT]...` | Resize through many sizes and report what the program drew at each and where the texts sit. |
| `tuppet attach [<session> \| -]` | Show a session live in your terminal and type into it (`-`: the one you detached from last); without a session, open the session picker. |
| `tuppet shutdown [--reset] [--all]` | Stop every running session and the daemon; `--reset` also deletes the stored sessions. |

`tuppet help <command>` describes each option, its short form, and its default, usually with an example. Options may
come before or after the session. Durations always take a unit: `500ms`, `5s`, `2m`, `1h`, or plain `0`. `list`,
`view`, `run`, `restart`, `rename`, `stop`, `remove`, `ack`, `wait`, `do`, `record`, `alert`, `events`, `resize`, `png`,
`sweep`, and `shutdown` print JSON with `-j`: the daemon's reply with the full status of each session, as
[docs/protocol.md](docs/protocol.md) describes it.

`tuppet rename build web` renames a session; `tuppet restart build` starts an ended session's command again, in its
directory, under its name, at its size, and with its alerts, but with your current environment: the old one is not
restored.

### Names and patterns

A `<session>` is its id, its name, or a pattern. `tuppet run --name build make` (or `-n build`) names a session, and
`tuppet wait build --ended` then finds it. A name starts with a letter or digit, continues with letters, digits, `.`,
`_`, and `-`, has at most 64 characters, and is not all digits, so it never reads as an id. Names are unique: `run`
fails while a running session has the name, and an ended session with the name is removed once the new session has
started, so rerunning a named job needs no cleanup. `--if-exists keep` prints the running session's id instead of
failing, and `--if-exists replace` stops it and starts the new one.

A pattern uses `*` for any run of characters and `?` for one character; quote it for the shell. Commands that act on
one session fail unless the pattern picks exactly one. `stop` and `remove` take any number of sessions and act on each
one once. Their patterns must match at least one session and skip the ones the action does not apply to, so
`tuppet stop '*'` stops every running session and `tuppet remove '*'` deletes every ended one, named or not.
`tuppet remove -f 'job-*'` stops and deletes them all, and does not fail when nothing matches.

### Waiting instead of sleeping

Keys reach the program before it has redrawn, so read the screen only after waiting for the state you expect. The daemon
checks a wait's conditions after every change on the screen. `tuppet wait --match TEXT` (`-m`) waits for text on the
screen, `--idle DUR` (`-i`) for the screen's text to stay unchanged that long, and `--ended` (`-e`) for the program to
end. Several conditions are alternatives, and the first that holds ends the wait. `tuppet help conditions` describes
them all.

`wait` prints one line that scripts can read, such as `met match#0 3 seq=1187 input_seq=1100 hit_seq=-`: the outcome,
the condition that was met (its kind and its place among the conditions, counting from 0), the session, and its seqs.
On timeout (30 s by default, `-t` sets it) it prints `timeout` instead, exits 3, and shows on stderr the last lines
that changed. If the program ends before a condition is met, `wait` ends at once with exit code 4; `--ended` is met
however the program ended, and the line shows its exit code (`exit=stopped` after `tuppet stop`). `wait a b --any`
waits on several sessions and reports the first that meets a condition; there a pattern such as `'ci-*'` stands for
every session it matches.

Text is matched on logical lines: rows that the terminal wrapped are joined, and text that scrolled into the history
while waiting counts too. `--after-input` counts only what is new since the latest input. After
`tuppet key 3 'make<Enter>'`, `tuppet wait 3 -m '$ ' --after-input -t 10m` ignores the prompt on which `make` was
typed and is met by the next prompt, even when the screen scrolled or was cleared meanwhile.

`tuppet do` types and waits in one call, and its waits count what is new since its input:
`tuppet do 3 -s make -k '<Enter>' -m '$ ' -t 10m` types the command and waits for the next prompt, and prints the same
line as `wait`. Input steps in a row go to the program as one batch that nothing else interrupts, and the wait after
them knows its text before the first key, so it cannot miss a prompt that came and went.

After a key that redraws a full-screen program, or after `tuppet resize`, wait with `--settled DUR` rather than
`--idle`: `tuppet do 3 -k j --settled 200ms` is met once the screen changed after the key and its text then stayed
unchanged for 200 ms, with no output left to process, while `--idle` can be met before the program reacted. A redraw
of identical text changes nothing and never meets it. `--gone TEXT` waits until text that was on the screen, or came
later, has left it: `tuppet do 3 -k '<Enter>' --gone Loading -w 30s`. `--stats` on `wait`, `do`, and `run` adds what
the program did meanwhile to the outcome line, such as `out_bytes=4120 draws=3 full_clears=1 rows_changed=24/24
first_change_ms=9`; these counts are taken around the request, so they are approximate.

`--hidden-input` waits until the program reads a line without echo, as password prompts do: after
`tuppet key 3 'sudo make install<Enter>'`, `tuppet wait 3 --hidden-input --after-input` is met once sudo asks. The
status says so too: `hidden_input` is `true`, and `tuppet list` shows the session as `password?`. The status also carries
the foreground program (`foreground.name`), the window title, and the working directory that shells report with OSC 7.
Windows has the title and the working directory, but neither hidden input nor the foreground program.

### Sessions that need you

`tuppet list` marks a session with `!` when something happened that nobody has seen yet: the program rang the bell,
sent a desktop notification (OSC 9 or OSC 777), had an alert hit, or ended; a session that `tuppet stop` ended is not
marked, since whoever stopped it knows. Its state then reads the alert's name, `bell`, `done`, or `failed N`.
`tuppet ack <session>...` marks what the session shows now as seen; the status keeps `bell_count`,
`notification_count`, the latest `notification`, and what was `seen`, also across daemon restarts.

`tuppet events` prints a line for each thing that happens, as it happens, such as
`14:02:31  3 build  bell` or `14:02:41  3 build  failed 2`; with sessions given, only theirs, by name or pattern also
when they are renamed or start later. `-i 30s` adds `idle` and `active` lines, `-v` title, directory, and foreground
program changes, `--count N` and `-t DUR` end it (exit 3, with a line on stderr, when `-t` runs out before `--count N`
events came), and `-j` prints the daemon's frames with each session's status. On Windows, `events` is not available.

An alert watches a session for a text: `tuppet run -n agent --alert 'approve=Do you want to proceed?' -- ./agent` (or
`tuppet alert add`) fires a hit each time a line comes to show it. A line fires once, so a spinner, a timer, or the
typed answer on it does not fire again, and neither does text that a resize reflows or the program redraws after one;
the same dialog drawn again after it was erased does. Put an alert on a line that changes when a dialog is reused, such
as the one that names the file or command. Dragging a window's edge resizes the session again and again without firing:
such a run of resizes lasts until the next input, or until 5 s after its last resize, and while it lasts, a line on the
screen fires only when more lines show the text than at its first resize. Output that scrolls in fires as always.
`tuppet wait agent --hit approve` waits for a hit after the latest input, so a dialog that was answered and is still on
the screen does not count, and prints `hit N approve <line>` after its outcome line. `tuppet do agent --reply-to N -k
'y<Enter>'` types only if nobody typed since hit N. Default alerts for every `run` go into the config file,
`$XDG_CONFIG_HOME/tuppet/config.toml` (by default `~/.config/tuppet/config.toml`; `TUPPET_CONFIG` names another file,
and an empty one none):

```toml
[alerts]
approve = "Do you want to proceed?"
```

`tuppet run -m 'Listening on' -- npm start` starts a program and waits for it in one step, from the program's first
byte. It prints the session id first and then the outcome line, and the session keeps running when the wait fails.

### Keys, paste, mouse, and guards

`tuppet key` encodes keys for the program's current keyboard mode, including application cursor keys and the kitty
keyboard protocol, so `<Up>` sends whatever the program expects. Quote bracketed keys for the shell: `'<Enter>'`. The
command fails without sending anything if one of its keys cannot be expressed in the program's keyboard mode, such as
Ctrl+Shift+Space outside the kitty protocol. It takes no options, so `tuppet key 3 -v` types `-v`.

`tuppet do` takes its steps as options: `-k KEYS` as `key` takes them, `-s TEXT` written as it is, and `-p TEXT` or
`--stdin` pasted the way a terminal pastes. Line endings become carriage returns, and if the program enabled bracketed
paste the text is wrapped in paste markers, so a multi-line message reaches a chat-style TUI as one message instead of
being submitted line by line. `--mouse left 10 3` clicks at zero-based cell coordinates and `--focus on` reports focus;
both follow the program's reporting modes like a real terminal, so nothing is sent while the program has them off.

`--secret VAR` types the value of an environment variable and keeps it out of recordings, as tuppet does with anything
typed while a program hides its input, such as a password typed by hand. `--secret` is refused unless the
program is reading hidden input at that moment, so a password never lands at a shell prompt:
`tuppet do 3 -k 'sudo make install<Enter>' --hidden-input --secret PW -k '<Enter>' -m '$ '`. `--unless-attached`
refuses to type while someone is attached as the writer, and `--if-input-seq N` refuses when anybody typed after the
input that an earlier outcome line reported. A refused batch types nothing, and `do` exits 5.

### Snapshots

`tuppet view` prints the screen as plain text by default. `--format vt` keeps colors as escape sequences, and
`--format html` produces an HTML fragment with inline styles. `--unwrap` joins lines that the terminal wrapped. `-j`
prints the text with the cursor position (1-based) and the session's status: its state, exit status, size, idle times,
and `seq`, which numbers the screen's latest change. `tuppet view <id> --since SEQ` then prints only the lines that
changed after that seq. `--styles` adds the styles to plain text: `base: …`, the style of most cells, then a line such
as `3:5-12 fg=1 bold "ERROR: x"` for each run of cells styled otherwise, at most 200 (`-j` gives them all).

`tuppet png` draws text with JetBrains Mono at 14 pixels, in 9x19 cells, with its real bold, italic, and bold italic
faces; GNU Unifont, which covers the Basic Multilingual Plane, CJK included, fills in what JetBrains Mono lacks. Box
drawing, blocks, braille, Powerline separators, and sextants are drawn so that lines join, and wide emoji come in
color from a built-in atlas of Noto Color Emoji, ZWJ sequences, skin tones, and flags included when the program turns
on grapheme clustering (mode 2027). Combining accents are drawn over their letter, in its precomposed form when a
font has one, and modern Hangul jamo are joined into syllables. A character no font has appears as U+FFFD. The renderer
refuses an image that could take more than 128 MiB: in the default 9x19 cells, a screen larger than 417x417 cells (or
1000x174), and in Unifont's 8x16 cells one larger than 482x482 (or 1000x232).

`-f SPEC` puts fonts first: a comma-separated list of font files, built-in names, `default` for the built-in fonts,
`bitmap`, and presets from the config file. The built-in names are `unifont` in every build, `jetbrains` in medium and
full builds, and in full builds also `julia`, `nerd`, and `cjk`; `-f cjk` puts the CJK font first. Font files are
TrueType and OpenType fonts (`.ttf`, `.otf`, `.ttc`, with `file.ttc#N` for face N of a collection), the bitmap formats
FreeType reads (`.otb`, `.pcf`, `.bdf`, the last two also gzip-compressed), and `.hex`, `.psf`, or `.psf.gz` bitmap
fonts; a lean build reads only the last three. The first entry sets the cell size: `-f ~/fonts/Iosevka.ttf,default` puts
your font in front of the built-in ones and sizes the cells to it, and `-f ~/fonts/ter-u32n.psf.gz,default` gives 16x32
cells. `--font-size N` (6 to 64, default 14) sizes TrueType fonts; bitmap fonts keep their size. A TrueType font without
bold or italic faces is made bold or slanted; bitmap fonts get only a synthetic bold. `-f bitmap` gives the lean look:
it leaves out every font FreeType reads, and such files in the list are skipped then rather than refused, so
`TUPPET_PNG_FONTS=bitmap` works with any configured list. The cells are then those of the first font left in the list:
Unifont's 8x16, unless a `.hex`, `.psf`, or `.psf.gz` file comes first. `-f` overrides `TUPPET_PNG_FONTS`, which
overrides `[png] fonts`, and the next `png` uses a changed setting or font file without a daemon restart. The size comes
from `--font-size`, else from a preset that `-f` names, else `TUPPET_PNG_FONT_SIZE`, else a preset in the other lists,
else `[png] font_size`. Relative font paths start at your working directory, and those in the config file at its
directory. `-j` reports the renderer (`ttf` or `bitmap`), the cell size, and the fonts that drew something. `tuppet help
fonts` lists the names this build knows and your presets:

```toml
[png]
fonts = ["~/fonts/Iosevka.ttf", "default"]
font_size = 16

[png.presets]
term = "~/fonts/ter-u32n.psf.gz,bitmap"
big = { fonts = "default", size = 28 }
```

Builds differ in their built-in fonts and in the font files they read, and `tuppet --version` names the build;
[Install](#install) compares them. In a full build, `default` is `jetbrains,julia,nerd,cjk,unifont`: JuliaMono adds math
symbols and arrows, Symbols Nerd Font Mono the icons of Nerd Font prompts, and Noto Sans Mono CJK SC Chinese, Japanese,
and Korean text. Each of these is loaded on the first character that reaches it, once per daemon.

### Resizes and sweeps

`tuppet do <id> --resize 60x24 --settled 200ms -w 2s` resizes the session as a step of its own and waits for the
program's redraw: the conditions after a resize count from its reflow, not from the latest input. When the session has
that size already, the program gets no SIGWINCH, and the step prints `same size …` instead of waiting.

`tuppet sweep` resizes a session through many sizes and reports, size by size, what the program drew and where the
texts given with `--find` sit:

```
$ tuppet sweep app -s 40..75x20 --step 5 --find 'title=TaskBoard v0.3' --find 'task=Review PR #42 (picker preview)'
COLS    ROWS    SCREEN                          title               task
40      20      changed 4/20 rows, 66 bytes     absent              absent
45      20      changed 3/20 rows, 93 bytes     1:3                 prefix "Review PR #42 (" at 3:30
50      20      changed 3/20 rows, 98 bytes     1:3                 prefix "Review PR #42 (picke" at 3:30
55      20      changed 3/20 rows, 103 bytes    1:3                 prefix "Review PR #42 (picker pre" at 3:30
60      20      changed 3/20 rows, 108 bytes    1:3                 3:30
65..75  20      changed 2/20 rows, 108 bytes    1:3                 3:30 stale
back at 80x20: same
during the sweep: hits 0, bells 0, notifications 0
not checked: only finds and the return screen were compared; settle 200ms, deadline 2s, sizes sampled every 5; 3 stale
```

Sizes in a row with the same facts print as one range. SCREEN says what the program did after each resize: `changed
K/N rows`, `unchanged, wrote B bytes` (it redrew the same text), `wrote nothing`, `still changing` (the screen never
stayed quiet for `--settled` within `-t`), or `ended`; `late` marks a screen that changed again after it was read. A
find is at `ROW:COL` (cells counting from 1), `absent`, a `prefix` when only its first part sits where the text was at
the size before or after (or the starting size), or `split` across two rows; `stale` means its row did not change after
the resize: the program left it alone, or drew it again the same. A right-aligned text collapses as `1:47..57 right=2`,
and one that moves at every size, such as a centred title, as `moves 1:20..30`; the counts in SCREEN can vary over a
range. The report ends with the screen back at the starting size, compared with the one before the sweep,
and with what the sweep did not check. It judges nothing: a screen that did not change is not a correct layout.

The sweep attaches as the session's writer, labelled `sweep`, so the daemon gives the session its size back however
the sweep ends, also when it is killed. It refuses (exit 5) while another writer is attached, while viewers or previews
watch (`-f` sweeps anyway), and for live sizes below 20x5 (`--min-size` lowers that), and stops with a partial report
when someone types, resizes, or takes over. `--refine` measures between neighbouring sizes whose facts differ until
the edge is exact, `--view` prints the screen at the start of each range, `-j` prints a JSON line per size, and
`tuppet sweep -s SIZES -- <cmd...>` sweeps a command in a session of its own and removes it afterwards. `tuppet help
sweep` has the details.

Recipes:

- Golden snapshots: `tuppet view app > golden.txt` keeps a screen, and `tuppet view app | diff golden.txt -` compares a
  later one. For every size, `tuppet sweep app -s 60..120x30 --step 10 --save before`, rebuild, the same with `--save
  after`, then `diff -r before after`; the `.styles` files hold the colors and emphasis.
- A clean environment: a session gets the environment of the command that starts it, so `env -i HOME="$HOME"
  PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" tuppet sweep -s 80x24 -- ./tui` sweeps the program without your
  shell's settings. Keep `XDG_RUNTIME_DIR` (or `TUPPET_SOCKET`) so that it reaches the same daemon.
- Capability variants: `TERM` is always `xterm-256color`, but other variables change what programs draw:

  ```sh
  for v in NO_COLOR=1 COLORTERM=truecolor LC_ALL=C; do
      env "$v" tuppet sweep -s 60..120x30 --step 20 --save "sweep-${v%%=*}" -- ./tui
  done
  ```

### Recordings

`tuppet record <id> --start demo.cast` starts an [asciicast v2](https://docs.asciinema.org/manual/asciicast/v2/)
recording that asciinema and agg can play; `tuppet record <id> --stop` stops it and prints how it stopped. A file named
`.trace` gets a JSON-lines timeline instead: every input, the rows whose text changed (collected at most every 50 ms and
before each input), markers, and the reason the recording stopped, with the exit code when the program ended. Traces
are plain text you can grep. The conditions of `tuppet wait` and `-t DUR` let the daemon end a recording on its own:
`tuppet record <id> --start build.trace -m 'Tests passed' -t 10m`.

`tuppet run --record` starts a recording together with the program, so even a program that exits at once is recorded in
full. The recording is kept in the session's directory in the store (see [What tuppet keeps](#what-tuppet-keeps)) as
`output.cast` or `output.trace`, and deleted with the session. `tuppet view <id> -j` (or `tuppet list <id> -j`) shows
its path as `status.recording.path`, also after the program has ended.

`tuppet do --record-file` records a whole flow: an asciicast for a `.cast` file, a trace for a `.trace` file. In a vim
session, this types a line, saves, and waits until vim confirms the write:

```sh
tuppet do $id -k 'ihello<Esc>:w<Enter>' -m written --record-file save.trace
```

It checks every step before sending anything and always stops its recording, also when a wait times out (exit 3) or you
press Ctrl-C.

Recordings are readable only by you, because they contain everything typed into the session.

### Live attach and the session picker

`tuppet` alone, in a terminal, opens the session picker (so does `tuppet attach` without a session): your sessions,
newest first, with a live preview of the selected one, under a header such as `tuppet · 5 sessions, 3 running · 2 need
you`. Each row shows `!` when the session needs you, its id, name, state, age, the writer attached to it (`◆ pts/3`),
and its command; a narrow terminal leaves out the command first, then the age, then shortens names, and last leaves out
the writer. Enter shows a session full screen without controlling it, and ←/→ step through the others there; `a` takes
control, `A` takes it over from another writer, and the detach key (Ctrl-]) brings you back, with the cursor on the
session you left. A session that ends while you are attached comes back in the viewer with its final screen and how it
ended.

| Key | In the list and the viewer |
| --- | --- |
| Tab, Shift-Tab | Go to the next or previous session that needs you. |
| Space | Mark the session seen; the viewer does this itself after showing a session for a second. |
| `-` | Go to the session you attached to before. |
| `x`, `r`, `d` | Stop the session, or restart or remove an ended one, after asking `stop #6 build? y/N`. |
| `R` | Rename the session; Ctrl-U clears the name. |
| `/` | Filter by name, command, directory, or title; `*` and `?` make it a pattern, and Ctrl-U clears it. |
| `o` | Show the session's history in `$PAGER` (`less -R +G`, which starts at the newest output, without one); a pager other than less, such as `cat`, gets a key press to return. |
| `i` | Turn the preview off and on; in the viewer, keep the overlay that names the session. |
| `?` | List every key. |
| `q`, Esc | `q` quits, or leaves the viewer; Esc leaves the viewer and clears a filter, but never quits. |

Stop, remove, and restart ignore their keys for half a second after an attach ends or the picker switches between the
list and the viewer, and right after an attach ends only keys that move around, Esc, `q`, and `?` work for that long,
so keys you typed for the session do nothing in the picker. The mouse selects rows in the list (a second click opens
the viewer) and is left to your terminal in the viewer, for selecting text. Without a UTF-8 locale the picker draws
ASCII, and `NO_COLOR` turns its colors off. When the daemon cannot be reached, the picker dims the list and says so in
its header until it is back. Outside a terminal, a bare `tuppet` prints its usage and exits 2, so a script or an agent
never ends up in the picker.

`tuppet attach <id>` connects your terminal to one session directly: you see the program, your keystrokes reach it, and
your terminal size is applied to it, also when you resize your terminal. What your terminal showed before moves into its
scrollback. `tuppet attach -` returns to the session you detached from last, and `tuppet run -a <cmd...>` starts a
session and attaches to it in one step. The detach key detaches, and the program keeps running; tuppet prints the
session id below the session's text so you can come back. Both need a terminal: in a script or an agent's pipe they
exit 2 and point to `view`, `wait`, and `events`, while `tuppet attach -r` there writes the session's output until it
ends. While you are attached, your terminal's bell rings once when another
session comes to need you, and the only key tuppet takes is the detach key. An attach marks what it showed as seen when
it starts, when you detach, and when the session ends.

A session can have any number of viewers (`--read-only`, which in a terminal opens the picker's viewer for that one
session) and one writer; `--force` takes the writer role from someone else, whose terminal then says so and goes on
read-only. Attach lets you watch an agent work and take over by hand. Other commands keep working while clients are
attached. While `tuppet do` types, what you type waits for it, in order, and the terminal shows `held: automation is
typing`. When you detach, the session gets back the size it had before you attached, unless `tuppet resize` set one
meanwhile. Inside a session (where `TUPPET_SESSION` is set), the picker of the same daemon labels that session `(this
terminal)` and does not show or attach it, and warns that an attach around this terminal takes Ctrl-] first; `-k`,
`TUPPET_DETACH_KEY`, or the config file sets another detach key:

```toml
[attach]
detach_key = "^A"   # also <C-a>, or one character
bell = false        # no bell while attached
```

## Use with coding agents

`tuppet llm-skill` prints a skill file that teaches a coding agent when and how to use tuppet. Save it as
`tuppet/SKILL.md` in the directory your agent loads skills from, here `$SKILLS_DIR`:

```sh
mkdir -p "$SKILLS_DIR/tuppet" && tuppet llm-skill > "$SKILLS_DIR/tuppet/SKILL.md"
```

## How it works

The first tuppet command starts a background daemon for your user. The daemon owns every session: it runs each program on
a pseudo-terminal, feeds the program's output through the emulator, and answers terminal queries the way a real terminal
would. CLI commands are short requests to the daemon, so a session keeps running between commands and can be driven from
any shell. The daemon runs detached, so Ctrl-C or a closed terminal does not take it or its sessions down. Once no
programs are running, it exits after 30 seconds (except on Windows), and the next command starts a new one.

Sessions start in your current directory with your environment and `TERM=xterm-256color`, without the variables that
describe your own terminal (`TERM_PROGRAM`, `TMUX`, `STY`), with `TUPPET_SESSION` set to the session's id, and with
`TUPPET_SESSION_SOCKET` set to its daemon's socket. Each session's terminal is 120x40, whatever the size of your own
terminal; `--size` sets another size for one session.

### What tuppet keeps

When a program ends, tuppet keeps its final screen, its history, and its exit status, so you can still `view`, `png`, or
`attach` to it, even after the daemon has exited. `tuppet list` shows ended sessions with their exit code until you
`tuppet remove` them, or for 7 days after they ended.

Session ids count up from 1 after each boot and are never reused before the next one or a `tuppet shutdown --reset`, so
an id only ever means one session. If a daemon dies while a program runs, the program gets a hangup and usually ends;
one that ignores the hangup keeps running without tuppet. Either way, `tuppet list` reports the session as `lost`.

History is limited to 8 MiB of the emulator's memory per session, about 7500 lines at the default width, and less
while the daemon's memory budget is full (see below). To keep
everything a program prints, start it with `tuppet run --record`.

An ended session leaves the daemon's memory 30 s after its last use and is loaded from disk again when you look at it.
A stored session whose files hold something tuppet never writes, such as a size outside 1..1000, shows as `damaged` in
`tuppet list`; `tuppet list -j` says why. tuppet never loads it, and `tuppet remove` deletes it.

The daemon also keeps a memory budget for all sessions together. Only screens must fit: a session that would start,
grow, or load from disk is refused when the screens of all sessions would not fit, with a message that says how much
they take. A session's screens take about 1.1 MiB at the default size and about 18 MiB at 1000x1000. History counts as
it is used. When the sessions together use more than the budget, the daemon trims the oldest lines of the
sessions that keep the most history, down to one common amount, and `tuppet list -j` reports `history_trimmed` for
them. They get their full history limit back once the sessions use less than three quarters of the budget. The
budget is a quarter of the machine's memory (or of the daemon's cgroup limit, if that is lower), at least 512 MiB;
`TUPPET_MEMORY` changes it.

### Stopping the daemon

`tuppet shutdown` stops every running session, as `tuppet stop` does, and then the daemon, and says what it stopped:

```console
$ tuppet shutdown
stopped 2 running sessions (3 build, 7) and the daemon on /run/user/1000/tuppet-1000.sock; kept 5 ended sessions
```

Ended sessions are kept, and the next command starts a new daemon that shows them again. `tuppet shutdown --reset` also
deletes the stored sessions, with the recordings tuppet kept for them (never a file you named with `--record-file`), so
ids start at 1 again, as after a reboot; sessions of other daemons that still run are kept, and ids continue above them.
`--all` first shuts down every other daemon whose sessions are in the store. There is no confirmation. With no daemon
running, `tuppet shutdown` exits 0 without starting one, and `--reset` resets the store itself. A command that reaches a
daemon while it shuts down waits until it is gone and then runs in the next one. SIGTERM or SIGINT sent to the daemon
shuts it down the same way.

A running daemon keeps its version until it exits, and the next command then starts the tuppet you have installed. A
command that reaches a daemon speaking another protocol revision refuses to use it and says how to stop it; `tuppet
shutdown` stops it at once. Ended sessions survive the switch.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `TUPPET_SIZE` | `120x40` | Terminal size of new sessions. |
| `TUPPET_SCROLLBACK` | `8M` | History memory per session, in bytes or with `K`, `M`, or `G`, at most `1G`; `0` keeps none. |
| `TUPPET_MEMORY` | a quarter of memory | The daemon's memory budget for all sessions, in bytes or with `K`, `M`, or `G`; `off` turns it off. |
| `TUPPET_KEEP` | `7d` | How long ended sessions are kept, with `ms`, `s`, `m`, `h`, or `d`; `0` keeps them until removed. |
| `TUPPET_IDLE_EXIT` | `30s` | How long the daemon waits with no programs running before it exits, with `ms`, `s`, `m`, or `h`; `0` keeps it running. |
| `TUPPET_SOCKET` | | Use the daemon on this socket and never start one (same as `--socket`). |
| `TUPPET_DETACH_KEY` | `^]` | The key that detaches an attach (`^X`, `<C-x>`, or one character); `-k` overrides it, and it overrides the config file's `detach_key`. |
| `TUPPET_PNG_FONTS` | `default` | The fonts of `tuppet png` when `-f` is not given; it overrides the config file's `[png] fonts`. |
| `TUPPET_PNG_FONT_SIZE` | `14` | The size of TrueType fonts in `tuppet png`, 6 to 64 pixels, when neither `--font-size` nor a preset that `-f` names gives one; bitmap fonts keep their size. |
| `TUPPET_CONFIG` | `$XDG_CONFIG_HOME/tuppet/config.toml`, by default `~/.config/tuppet/config.toml` | The config file: `[alerts]` for `tuppet run`, `[attach]` for attaching and the picker, `[png]` and `[png.presets]` for `tuppet png`; empty reads none. |

`TUPPET_SIZE` and `TUPPET_SCROLLBACK` apply to each `tuppet run`; `--size` and `--scrollback` override them.
`TUPPET_KEEP`, `TUPPET_IDLE_EXIT`, and `TUPPET_MEMORY` are read by the daemon when it starts, so set them for the
command that starts it.

The daemon listens on `$XDG_RUNTIME_DIR/tuppet-<uid>.sock`, or on `/tmp/tuppet-<uid>/tuppet.sock` when `XDG_RUNTIME_DIR`
is unset or empty, and logs next to it with `.log` in place of `.sock`. Only you can connect. Session data lives in
`$XDG_STATE_HOME/tuppet` (by default `~/.local/state/tuppet`), in one directory per machine and boot, so a home
directory shared between machines keeps them apart. Only you can read it. A starting daemon deletes data from this
machine's earlier boots.

## Running the daemon yourself

A program that manages tuppet's lifetime, such as an agent runner, can start the daemon on a socket of its choice:

```sh
tuppet daemon --socket /run/app/tuppet.sock --log /var/log/app/tuppet.log &
TUPPET_SOCKET=/run/app/tuppet.sock tuppet run vim notes.txt
```

With `--socket` or `TUPPET_SOCKET`, commands talk only to that daemon and never start one. This daemon does not exit when
idle; on SIGTERM or SIGINT, or `tuppet --socket PATH shutdown`, it stops every session and exits with status 0. On Linux,
the sessions' programs are killed even if the daemon is killed with SIGKILL; background jobs that ignore SIGHUP can
survive that. All your daemons share the session data, so the shortest `TUPPET_KEEP` among them applies to every session.

Programs can also skip the CLI and speak the daemon's JSON-lines protocol directly; [docs/protocol.md](docs/protocol.md)
describes every request and reply.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or the condition was met. |
| 1 | Runtime failure, such as an unknown session or an unreachable daemon. The message is on stderr. |
| 2 | Invalid arguments. Nothing was sent. |
| 3 | Timeout: a `wait`, a `run` with conditions, a condition step of `tuppet do`, or a daemon that did not exit within 30 seconds of `tuppet shutdown`. |
| 4 | The session ended (or was removed) first: input to an ended session, a `wait` condition it never met, a `stop` of a session that had ended, a sweep whose program ended, `tuppet events --count` when the daemon shut down first. |
| 5 | A guard of `tuppet do` refused an input batch, which typed nothing (earlier steps ran); or `tuppet sweep` refused to start. |
| 128+n | Interrupted by signal n (`tuppet do --record-file`, `tuppet attach`, `tuppet sweep`). |

`tuppet attach` and `tuppet run -a` are the one exception: when the session ends while attached, they exit with the
program's own exit code, so `tuppet run -a make` returns make's status. They exit 0 after a detach, 1 when another
client has the writer role, and 4 when the session was lost.

## Platform support

| Platform | Status |
| --- | --- |
| Linux (x86_64, aarch64) | Supported. The test suite runs on x86_64. |
| macOS (x86_64, aarch64) | Builds; not tested at runtime. A `wait` whose client went away lasts until its timeout. |
| Windows (x86_64, aarch64) | Builds with ConPTY sessions and named-pipe IPC; not tested at runtime. `attach`, the picker, `events`, hidden input (`--hidden-input` and `--secret`), and the foreground program are not available, the daemon does not exit when idle, and a `wait` whose client went away lasts until its timeout. |

Linux binaries are static. macOS binaries link only the system library, and Windows binaries only system DLLs.

## Development

```sh
make check      # format check, unit tests, end-to-end tests
make test       # unit tests only
make e2e        # end-to-end scripts, each against its own isolated daemon
make dist       # release archives for six targets in three builds, in zig-out/dist
make static     # check that the binaries of `zig build matrix` are self-contained
make help       # all targets
```

`make` builds in ReleaseSafe mode, which is also what releases ship. Avoid plain Debug builds for real use: the
emulator's internal checks make heavy output so slow that `tuppet wait` can time out. The end-to-end tests need bash and
python3.

A compile of tuppet takes up to about 2 GB of memory, and `zig build` runs one per CPU core, so `make dist`, which
compiles six targets at once, can run out of memory on a smaller machine; `make dist JOBS=2` runs only two at a time.
`make dist` gives the same archives, byte for byte, for the same commit only when it runs in a checkout at the same
path: Highway, which Ghostty compiles in, records the path of a header in the Zig cache, and that path changes with the
checkout's location.

GitHub Actions runs on Ubuntu 24.04, pinned rather than `ubuntu-latest` so that a new runner image cannot change the
build unannounced. It runs `make check` on each push to `main` and each pull request, builds and tests the lean and
full builds, cross-compiles all three for every target, and checks with `test/static.sh` that each binary is
self-contained. To release, set `.version` in `build.zig.zon` and push a matching tag such as `v0.3.0`: the release
workflow then runs the tests, builds the 18 archives with `make dist`, and publishes them with `SHA256SUMS` on the
tag's GitHub release.

## License

MIT; see [LICENSE](LICENSE). Release binaries include code from Ghostty and other projects under their own licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

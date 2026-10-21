//! The CLI's config file: $XDG_CONFIG_HOME/tuppet/config.toml (by default
//! ~/.config/tuppet/config.toml; %APPDATA%\tuppet\config.toml on Windows),
//! or the file TUPPET_CONFIG names, where an empty TUPPET_CONFIG means
//! none. The daemon never reads it.
//!
//! It is a strict subset of TOML: comments, sections, and `key = value`
//! lines, where a key is bare or a quoted string and a value a string, an
//! integer, true or false, an array of strings, or an inline table of
//! those. Anything else fails with the file and line:
//!
//!     [alerts]
//!     approve = "Do you want to proceed?"
//!
//!     [attach]
//!     bell = false
//!     detach_key = "^]"
//!
//!     [png]
//!     fonts = ["~/fonts/terminus.psf.gz", "default"]
//!     font_size = 16
//!
//!     [png.presets]
//!     big = { fonts = "default", size = 28 }
//!     term = "~/fonts/terminus.psf.gz,bitmap"

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const alert = @import("alert.zig");
const fonts = @import("fonts.zig");

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Alerts `run` gives every session unless told not to.
    alerts: []const alert.Rule = &.{},
    /// Ring this terminal's bell while attached when another session
    /// comes to need attention.
    bell: bool = true,
    /// The byte that detaches, when the file sets one.
    detach_key: ?u8 = null,
    /// `[png] fonts`: font list entries, as a font spec's.
    png_fonts: ?[]const []const u8 = null,
    png_font_size: ?u16 = null,
    png_presets: []const Preset = &.{},
    /// The config file's directory, absolute: its relative font paths
    /// start there.
    dir: ?[]const u8 = null,

    pub fn deinit(c: *Config) void {
        c.arena.deinit();
    }
};

/// A named font list of `[png.presets]`, with a size of its own if it sets one.
pub const Preset = struct {
    name: []const u8,
    fonts: []const []const u8,
    size: ?u16 = null,
};

const min_font_size = fonts.min_font_size;
const max_font_size = fonts.max_font_size;

/// Split a font spec at its commas into trimmed entries; on
/// error.EmptyEntry, `empty` is the 1-based position of an empty one.
pub fn splitFonts(a: std.mem.Allocator, spec: []const u8, empty: *usize) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        const entry = std.mem.trim(u8, part, " \t");
        if (entry.len == 0) {
            empty.* = out.items.len + 1;
            return error.EmptyEntry;
        }
        try out.append(a, entry);
    }
    return out.items;
}

const isFontPath = fonts.isPath;

/// Names a font spec gives meaning to, which presets cannot take.
fn isReservedFont(name: []const u8) bool {
    return std.meta.stringToEnum(fonts.Builtin, name) != null or std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "bitmap");
}

/// What a failed load says, naming the file and the line.
pub const Diagnostic = struct {
    buf: [1024]u8 = undefined,
    message: []const u8 = "",

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        d.message = std.fmt.bufPrint(&d.buf, fmt, args) catch d.buf[0..];
    }
};

const Found = struct {
    path: []u8,
    /// TUPPET_CONFIG named it, so it must exist.
    given: bool = false,
};

/// The config file's path in `gpa`; null when there is none to read.
fn path(gpa: std.mem.Allocator) !?Found {
    const env = io_mod.environ;
    if (env.getAlloc(gpa, "TUPPET_CONFIG")) |given| {
        if (given.len > 0) return .{ .path = given, .given = true };
        gpa.free(given);
        return null;
    } else |_| {}
    const sep = std.fs.path.sep_str;
    if (builtin.os.tag == .windows) {
        const appdata = env.getAlloc(gpa, "APPDATA") catch return null;
        defer gpa.free(appdata);
        return .{ .path = try std.mem.concat(gpa, u8, &.{ appdata, sep ++ "tuppet" ++ sep ++ "config.toml" }) };
    }
    if (env.getAlloc(gpa, "XDG_CONFIG_HOME")) |dir| {
        defer gpa.free(dir);
        // The XDG spec ignores relative paths.
        if (std.fs.path.isAbsolute(dir)) return .{ .path = try std.mem.concat(gpa, u8, &.{ dir, "/tuppet/config.toml" }) };
    } else |_| {}
    const home = env.getAlloc(gpa, "HOME") catch return null;
    defer gpa.free(home);
    if (!std.fs.path.isAbsolute(home)) return null;
    return .{ .path = try std.mem.concat(gpa, u8, &.{ home, "/.config/tuppet/config.toml" }) };
}

/// Read the config file. A default path with no file is an empty config;
/// on error.BadConfig, `diag` says what is wrong.
pub fn load(gpa: std.mem.Allocator, diag: *Diagnostic) !Config {
    var config: Config = .{ .arena = .init(gpa) };
    errdefer config.deinit();
    const a = config.arena.allocator();
    const found = try path(a) orelse return config;
    const file = found.path;
    const text = std.Io.Dir.cwd().readFileAlloc(io_mod.io(), file, a, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound) {
            if (!found.given) return config;
            diag.set("{s}: no such file (TUPPET_CONFIG names it)", .{file});
        } else diag.set("{s}: cannot read it: {s}", .{ file, readError(err) });
        return error.BadConfig;
    };
    try parse(&config, file, text, diag);
    config.dir = std.fs.path.dirname(try absolute(a, file));
    return config;
}

fn readError(err: anyerror) []const u8 {
    return switch (err) {
        error.IsDir => "it is a directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.StreamTooLong => "it is larger than 1 MiB",
        else => @errorName(err),
    };
}

fn absolute(a: std.mem.Allocator, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io_mod.io(), &buf);
    return std.fs.path.resolve(a, &.{ buf[0..n], file });
}

const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    strings: []const []const u8,
    table: []const Field,
};

const Field = struct { key: []const u8, value: Value };

const Section = enum { alerts, attach, png, png_presets };

/// Parse a detach key: ^X (caret notation), <C-x>, or a single
/// character. Returns the byte the terminal sends for it.
/// ESC is refused: it starts every arrow key and mouse report.
pub fn parseDetachKey(spec: []const u8) ?u8 {
    const key = if (spec.len == 2 and spec[0] == '^')
        controlByte(spec[1])
    else if (spec.len == 5 and std.ascii.startsWithIgnoreCase(spec, "<c-") and spec[4] == '>')
        controlByte(spec[3])
    else if (spec.len == 1) spec[0] else null;
    return if (key == 0x1b) null else key;
}

/// The byte Ctrl and `ch` send, or null when there is none.
pub fn controlByte(ch: u8) ?u8 {
    if (ch == '?') return 0x7f;
    const up = std.ascii.toUpper(ch);
    if (up < '@' or up > '_') return null;
    return up - '@';
}

/// Read `text`, the content of the file `name`, into `config`.
fn parse(config: *Config, name: []const u8, text: []const u8, diag: *Diagnostic) !void {
    const a = config.arena.allocator();
    var alerts: std.ArrayListUnmanaged(alert.Rule) = .empty;
    var presets: std.ArrayListUnmanaged(Preset) = .empty;
    var fonts_line: usize = 0;
    var section: ?Section = null;
    var seen_sections: std.EnumSet(Section) = .empty;
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    // Editors on Windows may start the file with a byte order mark.
    var lines = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        var p: Parser = .{ .a = a, .text = std.mem.trimEnd(u8, raw, "\r") };
        const why = blk: {
            if (!std.unicode.utf8ValidateSlice(p.text)) break :blk "the line is not valid UTF-8";
            p.space();
            if (p.done()) continue;
            if (p.peek() == '[') {
                p.i += 1;
                p.space();
                const start = p.i;
                _ = p.bareKey() orelse break :blk "expected a section name";
                while (p.eat('.')) _ = p.bareKey() orelse break :blk "expected a section name after the dot";
                const key = p.text[start..p.i];
                p.space();
                if (!p.eat(']')) break :blk "expected ] after the section name";
                if (!p.end()) break :blk "unexpected text after the section";
                const named = std.meta.stringToEnum(Section, key);
                const found: Section = if (std.mem.eql(u8, key, "png.presets")) .png_presets else if (named != null and named.? != .png_presets) named.? else break :blk try std.fmt.allocPrint(a, "unknown section [{s}] (known: [alerts], [attach], [png], [png.presets])", .{key});
                if (seen_sections.contains(found)) break :blk try std.fmt.allocPrint(a, "section [{s}] appears twice", .{key});
                seen_sections.insert(found);
                section = found;
                keys.clearRetainingCapacity();
                continue;
            }
            const key = (p.key() catch |err| break :blk errorText(err)) orelse break :blk "expected a key, a section, or a comment";
            p.space();
            if (!p.eat('=')) break :blk "expected = after the key";
            p.space();
            const value = (p.value(true) catch |err| break :blk errorText(err)) orelse break :blk "expected a value: a quoted string, a number, true, false, an array, or a table";
            if (!p.end()) break :blk "unexpected text after the value";
            const in = section orelse break :blk try std.fmt.allocPrint(a, "'{s}' comes before any section", .{key});
            if ((try keys.getOrPut(a, key)).found_existing) break :blk try std.fmt.allocPrint(a, "'{s}' is given twice", .{key});
            switch (in) {
                .alerts => {
                    if (value != .string) break :blk try std.fmt.allocPrint(a, "alert '{s}' needs its text as a quoted string", .{key});
                    const rule: alert.Rule = .{ .name = key, .match = value.string };
                    if (alert.ruleError(rule)) |e| break :blk try std.fmt.allocPrint(a, "alert '{s}': {s}", .{ key, e });
                    if (alerts.items.len == alert.max_alerts) break :blk try std.fmt.allocPrint(a, "at most {d} alerts", .{alert.max_alerts});
                    try alerts.append(a, rule);
                },
                .attach => if (std.mem.eql(u8, key, "bell")) {
                    if (value != .boolean) break :blk "bell must be true or false";
                    config.bell = value.boolean;
                } else if (std.mem.eql(u8, key, "detach_key")) {
                    if (value != .string) break :blk "detach_key needs a quoted string, such as \"^]\"";
                    config.detach_key = parseDetachKey(value.string) orelse
                        break :blk try std.fmt.allocPrint(a, "invalid detach_key '{s}' (use ^X, <C-x>, or one character)", .{value.string});
                } else break :blk try std.fmt.allocPrint(a, "unknown key '{s}' in [attach] (known: bell, detach_key)", .{key}),
                .png => if (std.mem.eql(u8, key, "fonts")) {
                    const list = try fontList(a, value, "fonts");
                    config.png_fonts = list.ok orelse break :blk list.err;
                    fonts_line = number;
                } else if (std.mem.eql(u8, key, "font_size")) {
                    config.png_font_size = fontSize(value) orelse break :blk try std.fmt.allocPrint(a, "font_size must be a number from {d} to {d}", .{ min_font_size, max_font_size });
                } else break :blk try std.fmt.allocPrint(a, "unknown key '{s}' in [png] (known: fonts, font_size)", .{key}),
                .png_presets => {
                    if (key.len == 0) break :blk "a preset needs a name";
                    for (key) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-')
                        break :blk try std.fmt.allocPrint(a, "preset '{s}': a name has letters, digits, _ and - only", .{key});
                    if (isReservedFont(key) or isFontPath(key)) break :blk try std.fmt.allocPrint(a, "preset '{s}': the name is taken by a built-in font or looks like a path", .{key});
                    var preset: Preset = .{ .name = key, .fonts = &.{} };
                    switch (value) {
                        .table => |fields| for (fields) |f| {
                            if (std.mem.eql(u8, f.key, "fonts")) {
                                const list = try fontList(a, f.value, key);
                                preset.fonts = list.ok orelse break :blk list.err;
                            } else if (std.mem.eql(u8, f.key, "size")) {
                                preset.size = fontSize(f.value) orelse break :blk try std.fmt.allocPrint(a, "preset '{s}': size must be a number from {d} to {d}", .{ key, min_font_size, max_font_size });
                            } else break :blk try std.fmt.allocPrint(a, "preset '{s}': unknown key '{s}' (known: fonts, size)", .{ key, f.key });
                        },
                        else => {
                            const list = try fontList(a, value, key);
                            preset.fonts = list.ok orelse break :blk list.err;
                        },
                    }
                    if (preset.fonts.len == 0) break :blk try std.fmt.allocPrint(a, "preset '{s}' names no fonts", .{key});
                    for (preset.fonts) |entry| if (!isReservedFont(entry) and !isFontPath(entry))
                        break :blk try std.fmt.allocPrint(a, "preset '{s}': '{s}' is no built-in font or path (presets cannot name presets)", .{ key, entry });
                    try presets.append(a, preset);
                },
            }
            continue;
        };
        diag.set("{s}:{d}: {s}", .{ name, number, why });
        return error.BadConfig;
    }
    config.alerts = alerts.items;
    config.png_presets = presets.items;
    // [png] fonts may name presets from anywhere in the file.
    if (config.png_fonts) |entries| for (entries) |entry| {
        if (isReservedFont(entry) or isFontPath(entry)) continue;
        for (presets.items) |preset| {
            if (std.mem.eql(u8, preset.name, entry)) break;
        } else {
            diag.set("{s}:{d}: fonts: '{s}' is no built-in font, path, or preset", .{ name, fonts_line, entry });
            return error.BadConfig;
        }
    };
}

/// A font list from a spec string or an array of entries; `what` names the
/// key in errors.
fn fontList(a: std.mem.Allocator, value: Value, what: []const u8) !struct { ok: ?[]const []const u8, err: []const u8 = "" } {
    switch (value) {
        .string => |spec| {
            var empty: usize = 0;
            const entries = splitFonts(a, spec, &empty) catch |err| switch (err) {
                error.EmptyEntry => return .{ .ok = null, .err = try std.fmt.allocPrint(a, "{s}: entry {d} is empty", .{ what, empty }) },
                else => return err,
            };
            return .{ .ok = entries };
        },
        .strings => |list| {
            if (list.len == 0) return .{ .ok = null, .err = try std.fmt.allocPrint(a, "{s} names no fonts", .{what}) };
            for (list, 1..) |entry, i| if (entry.len == 0) return .{ .ok = null, .err = try std.fmt.allocPrint(a, "{s}: entry {d} is empty", .{ what, i }) };
            return .{ .ok = list };
        },
        else => return .{ .ok = null, .err = try std.fmt.allocPrint(a, "{s} needs a font list: a quoted string or an array of them", .{what}) },
    }
}

fn fontSize(value: Value) ?u16 {
    if (value != .integer) return null;
    if (value.integer < min_font_size or value.integer > max_font_size) return null;
    return @intCast(value.integer);
}

const ParseError = error{ BadEscape, Unterminated, BadArray, BadTable, BadNumber, OutOfMemory };

fn errorText(err: ParseError) []const u8 {
    return switch (err) {
        error.BadEscape => "invalid escape in a quoted string",
        error.Unterminated => "a quoted string does not end on its line",
        error.BadArray => "an array holds quoted strings, separated by commas, and ends with ] on its line",
        error.BadTable => "an inline table holds key = value pairs (strings, numbers, arrays), separated by commas, within { } on its line",
        error.BadNumber => "invalid number",
        error.OutOfMemory => "out of memory",
    };
}

/// One line of the file.
const Parser = struct {
    a: std.mem.Allocator,
    text: []const u8,
    i: usize = 0,

    fn peek(p: *const Parser) u8 {
        return if (p.i < p.text.len) p.text[p.i] else 0;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() != c or p.i >= p.text.len) return false;
        p.i += 1;
        return true;
    }

    fn space(p: *Parser) void {
        while (p.i < p.text.len and (p.text[p.i] == ' ' or p.text[p.i] == '\t')) p.i += 1;
    }

    /// Nothing but a comment is left.
    fn done(p: *const Parser) bool {
        return p.i >= p.text.len or p.text[p.i] == '#';
    }

    fn end(p: *Parser) bool {
        p.space();
        return p.done();
    }

    fn bareKey(p: *Parser) ?[]const u8 {
        const start = p.i;
        while (p.i < p.text.len and (std.ascii.isAlphanumeric(p.text[p.i]) or p.text[p.i] == '_' or p.text[p.i] == '-')) p.i += 1;
        return if (p.i > start) p.text[start..p.i] else null;
    }

    fn key(p: *Parser) ParseError!?[]const u8 {
        return switch (p.peek()) {
            '"' => try p.basic(),
            '\'' => try p.literal(),
            else => p.bareKey(),
        };
    }

    /// A value; tables only when `table`, since they do not nest.
    fn value(p: *Parser, table: bool) ParseError!?Value {
        switch (p.peek()) {
            '"' => return .{ .string = try p.basic() },
            '\'' => return .{ .string = try p.literal() },
            '[' => {
                p.i += 1;
                var items: std.ArrayListUnmanaged([]const u8) = .empty;
                while (true) {
                    p.space();
                    if (p.eat(']')) return .{ .strings = items.items };
                    const item = switch (p.peek()) {
                        '"' => try p.basic(),
                        '\'' => try p.literal(),
                        else => return error.BadArray,
                    };
                    try items.append(p.a, item);
                    p.space();
                    if (!p.eat(',') and p.peek() != ']') return error.BadArray;
                }
            },
            '{' => {
                if (!table) return error.BadTable;
                p.i += 1;
                var fields: std.ArrayListUnmanaged(Field) = .empty;
                p.space();
                if (p.eat('}')) return .{ .table = fields.items };
                while (true) {
                    p.space();
                    const k = try p.key() orelse return error.BadTable;
                    p.space();
                    if (!p.eat('=')) return error.BadTable;
                    p.space();
                    const v = try p.value(false) orelse return error.BadTable;
                    for (fields.items) |f| if (std.mem.eql(u8, f.key, k)) return error.BadTable;
                    try fields.append(p.a, .{ .key = k, .value = v });
                    p.space();
                    if (p.eat('}')) return .{ .table = fields.items };
                    if (!p.eat(',')) return error.BadTable;
                }
            },
            '-', '0'...'9' => {
                const start = p.i;
                p.i += 1;
                while (p.i < p.text.len and std.ascii.isDigit(p.text[p.i])) p.i += 1;
                const digits = std.mem.trimStart(u8, p.text[start..p.i], "-");
                // TOML has no leading zeros.
                if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return error.BadNumber;
                return .{ .integer = std.fmt.parseInt(i64, p.text[start..p.i], 10) catch return error.BadNumber };
            },
            else => {
                const word = p.bareKey() orelse return null;
                if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
                return null;
            },
        }
    }

    /// A literal string: 'text', taken as it is.
    fn literal(p: *Parser) ParseError![]const u8 {
        p.i += 1;
        const close = std.mem.indexOfScalarPos(u8, p.text, p.i, '\'') orelse return error.Unterminated;
        defer p.i = close + 1;
        return p.text[p.i..close];
    }

    /// A basic string: "text" with TOML's escapes.
    fn basic(p: *Parser) ParseError![]const u8 {
        p.i += 1;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (true) {
            if (p.i >= p.text.len) return error.Unterminated;
            const c = p.text[p.i];
            p.i += 1;
            switch (c) {
                '"' => return out.items,
                '\\' => {
                    if (p.i >= p.text.len) return error.BadEscape;
                    const e = p.text[p.i];
                    p.i += 1;
                    switch (e) {
                        'b' => try out.append(p.a, 0x08),
                        't' => try out.append(p.a, '\t'),
                        'n' => try out.append(p.a, '\n'),
                        'f' => try out.append(p.a, 0x0c),
                        'r' => try out.append(p.a, '\r'),
                        '"', '\\' => try out.append(p.a, e),
                        'u', 'U' => {
                            const n: usize = if (e == 'u') 4 else 8;
                            if (p.i + n > p.text.len) return error.BadEscape;
                            const cp = std.fmt.parseInt(u21, p.text[p.i..][0..n], 16) catch return error.BadEscape;
                            p.i += n;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(cp, &buf) catch return error.BadEscape;
                            try out.appendSlice(p.a, buf[0..len]);
                        },
                        else => return error.BadEscape,
                    }
                },
                else => try out.append(p.a, c),
            }
        }
    }
};

fn parsed(text: []const u8, diag: *Diagnostic) !Config {
    var config: Config = .{ .arena = .init(std.testing.allocator) };
    errdefer config.deinit();
    try parse(&config, "config.toml", text, diag);
    return config;
}

test "the config file takes alerts and attach settings, and fails with its file and line" {
    var diag: Diagnostic = .{};
    var config = try parsed(
        \\# defaults for tuppet run
        \\[alerts]   # watched everywhere
        \\approve = "Do you want to proceed?"
        \\"sudo.pw" = 'password for'
        \\esc = "quote \" \u00e9"
        \\[attach]
        \\bell = false
        \\detach_key = "<C-a>"
        \\
    , &diag);
    defer config.deinit();
    try std.testing.expect(!config.bell);
    try std.testing.expectEqual(@as(?u8, 0x01), config.detach_key);
    try std.testing.expectEqual(@as(usize, 3), config.alerts.len);
    try std.testing.expectEqualStrings("sudo.pw", config.alerts[1].name);
    try std.testing.expectEqualStrings("quote \" \u{e9}", config.alerts[2].match);
    var bom = try parsed("\xef\xbb\xbf[attach]\nbell = false\n", &diag);
    defer bom.deinit();
    try std.testing.expect(!bom.bell);
    const bad = [_]struct { text: []const u8, message: []const u8 }{
        .{ .text = "x = \"y\"", .message = "config.toml:1: 'x' comes before any section" },
        .{ .text = "[alerts]\n\na = x", .message = "config.toml:3: expected a value: a quoted string, a number, true, false, an array, or a table" },
        .{ .text = "[pager]", .message = "config.toml:1: unknown section [pager] (known: [alerts], [attach], [png], [png.presets])" },
        .{ .text = "[attach]\nbell = \"no\"", .message = "config.toml:2: bell must be true or false" },
        .{ .text = "[attach]\ndetach_key = \"^^^\"", .message = "config.toml:2: invalid detach_key '^^^' (use ^X, <C-x>, or one character)" },
        .{ .text = "[attach]\ndetach_key = \"^[\"", .message = "config.toml:2: invalid detach_key '^[' (use ^X, <C-x>, or one character)" },
        .{ .text = "[attach]\ntitle = true", .message = "config.toml:2: unknown key 'title' in [attach] (known: bell, detach_key)" },
        .{ .text = "[alerts]\na = \"x\"\na = \"y\"", .message = "config.toml:3: 'a' is given twice" },
        .{ .text = "[alerts]\na = \"x\" b", .message = "config.toml:2: unexpected text after the value" },
        .{ .text = "[alerts]\na = \"x", .message = "config.toml:2: a quoted string does not end on its line" },
        .{ .text = "[alerts]\nok = true", .message = "config.toml:2: alert 'ok' needs its text as a quoted string" },
        .{ .text = "[alerts]\n-a = \"x\"", .message = "config.toml:2: alert '-a': the alert name must start with a letter or digit" },
        .{ .text = "[alerts]\na = \"\xff\"", .message = "config.toml:2: the line is not valid UTF-8" },
    };
    for (bad) |case| {
        var d: Diagnostic = .{};
        var c: Config = .{ .arena = .init(std.testing.allocator) };
        defer c.deinit();
        try std.testing.expectError(error.BadConfig, parse(&c, "config.toml", case.text, &d));
        try std.testing.expectEqualStrings(case.message, d.message);
    }
}

test "the png section and presets take font lists and sizes" {
    var diag: Diagnostic = .{};
    var config = try parsed(
        \\[png]
        \\fonts = ["a,b.psf", "default"]
        \\font_size = 16
        \\[png.presets]
        \\term = "~/t.psf.gz, bitmap"
        \\big = { fonts = ["default"], size = 28 }
        \\
    , &diag);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 2), config.png_fonts.?.len);
    try std.testing.expectEqualStrings("a,b.psf", config.png_fonts.?[0]);
    try std.testing.expectEqual(@as(?u16, 16), config.png_font_size);
    try std.testing.expectEqualStrings("bitmap", config.png_presets[0].fonts[1]);
    try std.testing.expectEqual(@as(?u16, 28), config.png_presets[1].size);
    const bad = [_]struct { text: []const u8, message: []const u8 }{
        .{ .text = "[png]\nfont_size = 100", .message = "config.toml:2: font_size must be a number from 6 to 64" },
        .{ .text = "[png]\nfonts = \"a.psf,,b.psf\"", .message = "config.toml:2: fonts: entry 2 is empty" },
        .{ .text = "[png.presets]\na = \"b\"", .message = "config.toml:2: preset 'a': 'b' is no built-in font or path (presets cannot name presets)" },
        .{ .text = "[png.presets]\nbitmap = \"x.psf\"", .message = "config.toml:2: preset 'bitmap': the name is taken by a built-in font or looks like a path" },
        .{ .text = "[png.presets]\na = { fonts = \"x.psf\", font = 3 }", .message = "config.toml:2: preset 'a': unknown key 'font' (known: fonts, size)" },
        .{ .text = "[png]\nfonts = \"term\"\n[png.presets]\nother = \"x.psf\"", .message = "config.toml:2: fonts: 'term' is no built-in font, path, or preset" },
        .{ .text = "[png]\nfont_size = 016", .message = "config.toml:2: invalid number" },
        .{ .text = "[png]\nfonts = \"x.psf\" \"y\"]", .message = "config.toml:2: unexpected text after the value" },
        .{ .text = "[png]\nfonts = [\"x.psf\" \"y\"]", .message = "config.toml:2: an array holds quoted strings, separated by commas, and ends with ] on its line" },
    };
    for (bad) |case| {
        var d: Diagnostic = .{};
        var c: Config = .{ .arena = .init(std.testing.allocator) };
        defer c.deinit();
        try std.testing.expectError(error.BadConfig, parse(&c, "config.toml", case.text, &d));
        try std.testing.expectEqualStrings(case.message, d.message);
    }
}

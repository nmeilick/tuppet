const std = @import("std");

const MatrixTarget = struct {
    label: []const u8,
    query: std.Target.Query,
};

/// The six release targets: the three desktop platforms in both
/// mainstream architectures, each for the baseline CPU of its architecture
/// so that the binaries run on every processor of it.
const matrix_targets = [_]MatrixTarget{
    .{ .label = "x86_64-linux", .query = .{ .cpu_model = .baseline, .cpu_arch = .x86_64, .os_tag = .linux } },
    .{ .label = "aarch64-linux", .query = .{ .cpu_model = .baseline, .cpu_arch = .aarch64, .os_tag = .linux } },
    .{ .label = "x86_64-macos", .query = .{ .cpu_model = .baseline, .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .label = "aarch64-macos", .query = .{ .cpu_model = .baseline, .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .label = "x86_64-windows", .query = .{ .cpu_model = .baseline, .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
    .{ .label = "aarch64-windows", .query = .{ .cpu_model = .baseline, .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
};

/// Which built-in fonts `tuppet png` has.
const Variant = enum { lean, medium, full };

/// What every build of tuppet shares, whatever its target.
const Shared = struct {
    variant: Variant,
    /// Unifont packed by tools/unifont.zig; null until the lazy dependency
    /// is fetched, when the build runner runs build() again.
    unifont: ?std.Build.LazyPath,
    /// The TrueType fonts of medium and full builds, deflated by
    /// tools/deflate.zig or stored as is; empty in lean builds and until
    /// the lazy dependencies are fetched.
    fonts: []const Packed,
    /// The combining-mark tables tools/marks.zig writes.
    marks: std.Build.LazyPath,
};

/// A font file a medium or full build embeds as the anonymous import `name`.
const FontFile = struct {
    dependency: []const u8,
    path: []const u8,
    name: []const u8,
    /// Embedded as is rather than deflated.
    stored: bool = false,
};

/// A font file packed for embedding.
const Packed = struct { name: []const u8, file: std.Build.LazyPath };

/// The fonts of medium builds: JetBrains Mono's four styles.
const medium_fonts = [_]FontFile{
    .{ .dependency = "jetbrains_mono", .path = "fonts/ttf/JetBrainsMono-Regular.ttf", .name = "jetbrains-Regular.bin" },
    .{ .dependency = "jetbrains_mono", .path = "fonts/ttf/JetBrainsMono-Bold.ttf", .name = "jetbrains-Bold.bin" },
    .{ .dependency = "jetbrains_mono", .path = "fonts/ttf/JetBrainsMono-Italic.ttf", .name = "jetbrains-Italic.bin" },
    .{ .dependency = "jetbrains_mono", .path = "fonts/ttf/JetBrainsMono-BoldItalic.ttf", .name = "jetbrains-BoldItalic.bin" },
};

/// The fonts of full builds: medium's, then JuliaMono's regular and bold,
/// Symbols Nerd Font Mono, and Noto Sans Mono CJK SC's regular. The CJK
/// font's CFF outlines barely deflate, so it is stored as is and read in
/// place instead of unpacked.
const full_fonts = medium_fonts ++ [_]FontFile{
    .{ .dependency = "juliamono", .path = "JuliaMono-Regular.ttf", .name = "julia-Regular.bin" },
    .{ .dependency = "juliamono", .path = "JuliaMono-Bold.ttf", .name = "julia-Bold.bin" },
    .{ .dependency = "nerd_fonts_symbols", .path = "SymbolsNerdFontMono-Regular.ttf", .name = "nerd-Regular.bin" },
    .{ .dependency = "noto_cjk_sc", .path = "NotoSansMonoCJKsc-Regular.otf", .name = "cjk-Regular.otf", .stored = true },
};

/// The tuppet root module with the pinned ghostty-vt dependency, shared by
/// the executable, the unit tests, and the release matrix.
fn tuppetModule(b: *std.Build, shared: Shared, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: ?bool) *std.Build.Module {
    // Pinned ghostty dependency; provides the "ghostty-vt" Zig module.
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    // build.zig.zon is the only place the version is written down.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption(Variant, "variant", shared.variant);
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vt", .module = ghostty.module("ghostty-vt") },
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "c", .module = c.createModule() },
        },
    });
    module.addAnonymousImport("emoji_atlas", .{ .root_source_file = b.path("assets/emoji/atlas.bin") });
    module.addAnonymousImport("marks", .{ .root_source_file = shared.marks });
    if (shared.unifont) |unifont| module.addAnonymousImport("unifont.bin", .{ .root_source_file = unifont });
    if (shared.variant != .lean) {
        // FreeType, compiled from source and linked statically, without
        // libpng: color emoji come from the atlas.
        if (ghostty.builder.lazyDependency("freetype", .{ .target = target, .optimize = optimize })) |ft|
            module.addImport("freetype", ft.module("freetype"));
        for (shared.fonts) |f| module.addAnonymousImport(f.name, .{ .root_source_file = f.file });
    }
    return module;
}

/// Pack the pinned Unifont with a host tool, or null while the lazy
/// dependency is not fetched yet.
fn packUnifont(b: *std.Build) ?std.Build.LazyPath {
    const dep = b.lazyDependency("unifont", .{}) orelse return null;
    const bitmap = b.createModule(.{
        .root_source_file = b.path("src/fonts/bitmap.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const packer = b.addExecutable(.{
        .name = "unifont-pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/unifont.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "bitmap", .module = bitmap }},
        }),
    });
    const run = b.addRunArtifact(packer);
    run.addFileArg(dep.path("font/precompiled/unifont-18.0.01.hex"));
    run.addFileArg(dep.path("font/precompiled/unifont_upper-18.0.01.hex"));
    return run.addOutputFileArg("unifont.bin");
}

/// Write the combining-mark tables from the Unicode data of the uucode
/// package Ghostty pins.
fn packMarks(b: *std.Build, ghostty: *std.Build.Dependency) std.Build.LazyPath {
    const uucode = ghostty.builder.dependency("uucode", .{});
    const tool = b.addExecutable(.{
        .name = "marks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/marks.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(uucode.path("ucd/UnicodeData.txt"));
    run.addFileArg(uucode.path("ucd/CompositionExclusions.txt"));
    run.addFileArg(uucode.path("ucd/DerivedCoreProperties.txt"));
    return run.addOutputFileArg("marks.zig");
}

/// Deflate the pinned font files with a host tool, except stored ones;
/// empty while a lazy dependency is not fetched yet.
fn packFonts(b: *std.Build, files: []const FontFile) []const Packed {
    var missing = false;
    for (files) |f| {
        if (b.lazyDependency(f.dependency, .{}) == null) missing = true;
    }
    if (missing) return &.{};
    const deflate = b.addExecutable(.{
        .name = "deflate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/deflate.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const out = b.allocator.alloc(Packed, files.len) catch @panic("OOM");
    for (out, files) |*o, f| {
        const file = b.lazyDependency(f.dependency, .{}).?.path(f.path);
        if (f.stored) {
            o.* = .{ .name = f.name, .file = file };
            continue;
        }
        const run = b.addRunArtifact(deflate);
        run.addFileArg(file);
        o.* = .{ .name = f.name, .file = run.addOutputFileArg(f.name) };
    }
    return out;
}

fn buildTuppet(b: *std.Build, shared: Shared, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: ?bool) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "tuppet",
        // Single static executable; macOS libc (libSystem) only
        // exists as a dynamic library, so darwin stays dynamic.
        .linkage = if (target.result.os.tag == .macos) null else .static,
        .root_module = tuppetModule(b, shared, target, optimize, strip),
    });
}

pub fn build(b: *std.Build) void {
    // The baseline CPU of the host's architecture, not the host's own CPU:
    // a binary built here must also run on older and virtualized processors,
    // such as VMs without AVX-512. -Dcpu=native opts back in.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const variant = b.option(Variant, "fonts", "Built-in fonts of `tuppet png`: lean, medium, or full (default: medium)") orelse .medium;
    const shared: Shared = .{
        .variant = variant,
        .unifont = packUnifont(b),
        .fonts = switch (variant) {
            .lean => &.{},
            .medium => packFonts(b, &medium_fonts),
            .full => packFonts(b, &full_fonts),
        },
        // The same arguments as tuppetModule's, so the same instance.
        .marks = packMarks(b, b.dependency("ghostty", .{ .target = target, .optimize = optimize })),
    };

    const exe = buildTuppet(b, shared, target, optimize, null);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run tuppet");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = tuppetModule(b, shared, target, optimize, null),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build matrix`: cross-compile the six release targets into
    // zig-out/matrix/<label>/tuppet[.exe], with a -lean or -full suffix on
    // <label> for those variants; `make dist` packages them.
    const matrix_step = b.step("matrix", "Build tuppet for all six release targets, in the -Dfonts variant");
    const suffix = switch (variant) {
        .lean => "-lean",
        .medium => "",
        .full => "-full",
    };
    inline for (matrix_targets) |mt| {
        const t = b.resolveTargetQuery(mt.query);
        // Release binaries keep the safety checks the tests run with.
        const m_exe = buildTuppet(b, shared, t, .ReleaseSafe, true);
        const install = b.addInstallArtifact(m_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("matrix/{s}{s}", .{ mt.label, suffix }) } },
        });
        matrix_step.dependOn(&install.step);
    }
}

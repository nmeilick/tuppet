const std = @import("std");

const MatrixTarget = struct {
    label: []const u8,
    query: std.Target.Query,
};

/// The six release targets: the three desktop platforms in both
/// mainstream architectures.
const matrix_targets = [_]MatrixTarget{
    .{ .label = "x86_64-linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
    .{ .label = "aarch64-linux", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
    .{ .label = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .label = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .label = "x86_64-windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
    .{ .label = "aarch64-windows", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
};

/// The tuppet root module with the pinned ghostty-vt dependency, shared by
/// the executable, the unit tests, and the release matrix.
fn tuppetModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: ?bool) *std.Build.Module {
    // Pinned ghostty dependency; provides the "ghostty-vt" Zig module.
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    // build.zig.zon is the only place the version is written down.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vt", .module = ghostty.module("ghostty-vt") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
}

fn buildTuppet(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: ?bool) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "tuppet",
        // Single static executable; macOS libc (libSystem) only
        // exists as a dynamic library, so darwin stays dynamic.
        .linkage = if (target.result.os.tag == .macos) null else .static,
        .root_module = tuppetModule(b, target, optimize, strip),
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = buildTuppet(b, target, optimize, null);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tuppet");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = tuppetModule(b, target, optimize, null),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build matrix`: cross-compile the six release targets into
    // zig-out/matrix/<label>/tuppet[.exe]; `make dist` packages them.
    const matrix_step = b.step("matrix", "Build tuppet for all six release targets");
    inline for (matrix_targets) |mt| {
        const t = b.resolveTargetQuery(mt.query);
        // Release binaries keep the safety checks the tests run with.
        const m_exe = buildTuppet(b, t, .ReleaseSafe, true);
        const install = b.addInstallArtifact(m_exe, .{
            .dest_dir = .{ .override = .{ .custom = "matrix/" ++ mt.label } },
        });
        matrix_step.dependOn(&install.step);
    }
}

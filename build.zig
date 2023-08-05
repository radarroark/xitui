const std = @import("std");
const libgit2 = @import("src/deps/libgit2.zig");
const zlib = @import("src/deps/zlib.zig");
const mbedtls = @import("src/deps/mbedtls.zig");
const libssh2 = @import("src/deps/libssh2.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z = zlib.create(b, target, optimize);
    const tls = mbedtls.create(b, target, optimize);
    const ssh2 = libssh2.create(b, target, optimize);
    tls.link(ssh2.step);

    const git2 = try libgit2.create(b, target, optimize);
    ssh2.link(git2.step);
    tls.link(git2.step);
    z.link(git2.step, .{});

    const exe = b.addExecutable(.{
        .name = "radargit",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.addIncludePath(.{ .path = "src/deps/libgit2/include" });
    exe.linkLibrary(git2.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();
    unit_tests.addIncludePath(.{ .path = "src/deps/libgit2/include" });
    unit_tests.linkLibrary(git2.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

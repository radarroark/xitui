const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xitui = b.addModule("xitui", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    // try
    {
        const exe = b.addExecutable(.{
            .name = "try",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/try.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("xitui", xitui);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("try", "Try the widgets");
        run_step.dependOn(&run_cmd.step);
    }

    // test
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("xitui", xitui);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}

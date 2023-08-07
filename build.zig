const std = @import("std");

pub fn build(b: *std.Build) !void {
    try create_exe(b, "kilo", "src/kilo.zig");
}

fn create_exe(b: *std.Build, name: []const u8, root_path: []const u8) !void {
    const options = b.addOptions();
    options.addOption([]const u8, "kilo_version", "0.1.0");
    options.addOption(usize, "kilo_tab_stop", 8);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = root_path },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    // add options as a module. @import("kilo_options") will give us a struct with all the options we provided
    const m = options.createModule();
    exe.addModule("kilo_options", m);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    var buf: [32]u8 = undefined;
    const run_name = try std.fmt.bufPrint(&buf, "run-{s}", .{name});
    const run_step = b.step(run_name, "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = root_path },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

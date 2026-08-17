const std = @import("std");

/// Targets that `zig build check` compiles, so a change to one backend cannot
/// silently break the others.
const check_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "x86_64-windows-gnu",
    "aarch64-macos",
    "x86_64-macos",
};

const examples = [_][]const u8{
    "basic",
    "rich",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("perch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `perch doctor`: reports the backend and session state on this machine.
    const exe = b.addExecutable(.{
        .name = "perch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "perch", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the perch doctor").dependOn(&run_cmd.step);

    // Tests.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // Examples: `zig build example-basic` builds and runs one.
    const examples_step = b.step("examples", "Build all examples");
    for (examples) |name| {
        const example = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "perch", .module = mod }},
            }),
        });
        examples_step.dependOn(&example.step);

        const run_example = b.addRunArtifact(example);
        b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("Run the {s} example", .{name}),
        ).dependOn(&run_example.step);
    }

    // Cross-compile every backend from one host, so a change to the macOS
    // backend fails fast on a Linux box. Built but not run.
    const check_step = b.step("check", "Compile-check the library for every supported target");
    for (check_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| {
            std.debug.panic("bad check target '{s}': {s}", .{ triple, @errorName(err) });
        };
        const compile = b.addTest(.{
            .name = b.fmt("check-{s}", .{triple}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .Debug,
            }),
        });
        check_step.dependOn(&compile.step);
    }
}

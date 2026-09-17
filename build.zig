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
    "behaviors",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const macos_sdk = b.option([]const u8, "macos-sdk", "Path to an Apple macOS SDK when cross-compiling") orelse
        if (b.graph.host.result.os.tag == .macos)
            std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \r\n")
        else
            null;

    const mod = b.addModule("perch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkPlatform(mod, macos_sdk);

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
        if (target.result.os.tag == .macos and std.mem.eql(u8, name, "rich")) {
            const bundle = b.step("macos-app", "Build zig-out/Perch.app for native macOS notifications");
            const plist = b.addWriteFiles().add("Perch-Info.plist",
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                \\<plist version="1.0"><dict>
                \\<key>CFBundleIdentifier</key><string>dev.perch.example.rich</string>
                \\<key>CFBundleExecutable</key><string>perch</string>
                \\<key>CFBundleName</key><string>Perch</string>
                \\<key>CFBundlePackageType</key><string>APPL</string>
                \\<key>CFBundleVersion</key><string>1</string>
                \\<key>CFBundleShortVersionString</key><string>0.0.0</string>
                \\<key>LSUIElement</key><true/>
                \\<key>NSHighResolutionCapable</key><true/>
                \\</dict></plist>
            );
            bundle.dependOn(&b.addInstallFile(plist, "Perch.app/Contents/Info.plist").step);
            bundle.dependOn(&b.addInstallArtifact(example, .{
                .dest_dir = .{ .override = .{ .custom = "Perch.app/Contents/MacOS" } },
                .dest_sub_path = "perch",
            }).step);
        }
        examples_step.dependOn(&example.step);

        const run_example = b.addRunArtifact(example);
        b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("Run the {s} example", .{name}),
        ).dependOn(&run_example.step);
    }

    // Integration tests drive the library through a mock StatusNotifierItem
    // host. They need a session bus of their own, since a real desktop already
    // owns the watcher name.
    if (target.result.os.tag == .linux) {
        const integration = b.addExecutable(.{
            .name = "integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "perch", .module = mod }},
            }),
        });
        const run_integration = b.addRunArtifact(integration);
        b.step(
            "integration",
            "Run the mock-host tests (use: dbus-run-session -- zig build integration)",
        ).dependOn(&run_integration.step);
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
        linkPlatform(compile.root_module, macos_sdk);
        // Depending on the emitted binary forces a link, which is what proves
        // the platform declarations resolve against the real import libraries.
        // Compiling alone would not catch a misspelled entry point.
        check_step.dependOn(&b.addInstallArtifact(compile, .{
            .dest_dir = .{ .override = .{ .custom = "check" } },
        }).step);
    }
}

fn linkPlatform(mod: *std.Build.Module, macos_sdk: ?[]const u8) void {
    if (mod.resolved_target.?.result.os.tag != .macos) return;
    mod.link_libc = true;
    mod.linkSystemLibrary("objc", .{});
    // Classes are looked up by name, so there may be no direct linker symbols.
    mod.linkFramework("AppKit", .{ .needed = true });
    mod.linkFramework("Foundation", .{ .needed = true });
    mod.linkFramework("UserNotifications", .{ .needed = true });
    mod.linkFramework("CoreGraphics", .{ .needed = true });
    if (macos_sdk) |sdk| {
        const b = mod.owner;
        mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    }
}

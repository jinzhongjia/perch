//! Exports SVG icons to a private icon theme directory, so the host renders
//! them at whatever size and scale the display needs.
//!
//! `StatusNotifierItem` has no way to carry vector art: the properties are a
//! themed name or raw ARGB pixmaps. Rasterising here would mean guessing a size
//! and going blurry on HiDPI. Instead perch writes the markup into a directory
//! and points `IconThemePath` at it, which is what libappindicator and
//! KStatusNotifierItem have always done for app-supplied icons.
//!
//! The directory lives under `XDG_RUNTIME_DIR` and is removed on `deinit`.

const std = @import("std");
const Dir = std.Io.Dir;

const IconExport = @This();

pub const Error = error{
    /// No writable directory to export into.
    NoRuntimeDir,
    WriteFailed,
    OutOfMemory,
};

gpa: std.mem.Allocator,
io: std.Io,
/// Absolute path handed to the host as `IconThemePath`.
root: []u8,
/// Whether we created `root` and may therefore delete it.
owns_root: bool,
/// Names already written, so `setIcon` can rotate without collisions.
counter: u32 = 0,

/// `runtime_dir` is `XDG_RUNTIME_DIR`; `override` short-circuits the whole
/// mechanism when the caller already has a theme directory of its own.
pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime_dir: ?[]const u8,
    override: ?[]const u8,
) Error!IconExport {
    if (override) |path| {
        return .{
            .gpa = gpa,
            .io = io,
            .root = try gpa.dupe(u8, path),
            .owns_root = false,
        };
    }

    const base = runtime_dir orelse return error.NoRuntimeDir;
    const root = try std.fmt.allocPrint(
        gpa,
        "{s}/perch-{d}",
        .{ base, std.os.linux.getpid() },
    );
    errdefer gpa.free(root);

    // A process killed by a signal never runs deinit, so tidy up after the
    // previous run before adding ours.
    removeStale(gpa, io, base);

    var self: IconExport = .{ .gpa = gpa, .io = io, .root = root, .owns_root = true };
    try self.writeThemeIndex();
    return self;
}

/// Deletes `perch-<pid>` directories whose process is gone.
fn removeStale(gpa: std.mem.Allocator, io: std.Io, base: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "perch-")) continue;

        const pid = std.fmt.parseInt(i32, entry.name["perch-".len..], 10) catch continue;
        if (pid == std.os.linux.getpid()) continue;
        if (processExists(io, pid)) continue;

        // The name has to be duplicated: deleting invalidates the iterator's
        // view of it.
        const name = gpa.dupe(u8, entry.name) catch return;
        defer gpa.free(name);
        dir.deleteTree(io, name) catch {};
    }
}

fn processExists(io: std.Io, pid: i32) bool {
    var buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid}) catch return true;
    // On the fence, keep the directory: deleting a live process's icons is worse
    // than leaving a stale one behind.
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn deinit(self: *IconExport) void {
    if (self.owns_root) {
        // Best effort: a leftover directory in the runtime dir is harmless and
        // goes away with the session.
        Dir.cwd().deleteTree(self.io, self.root) catch {};
    }
    self.gpa.free(self.root);
    self.* = undefined;
}

/// Hosts merge search paths per theme name, so the directory has to be called
/// `hicolor` — the fallback theme every lookup ends at — and carry an
/// `index.theme` for the hosts that insist on one.
const theme_index =
    \\[Icon Theme]
    \\Name=Hicolor
    \\Comment=perch runtime icons
    \\Directories=scalable/apps
    \\
    \\[scalable/apps]
    \\Size=48
    \\MinSize=8
    \\MaxSize=512
    \\Type=Scalable
    \\Context=Applications
    \\
;

fn writeThemeIndex(self: *IconExport) Error!void {
    const cwd = Dir.cwd();

    const theme_dir = try std.fmt.allocPrint(self.gpa, "{s}/hicolor/scalable/apps", .{self.root});
    defer self.gpa.free(theme_dir);
    cwd.createDirPath(self.io, theme_dir) catch return error.WriteFailed;

    const index_path = try std.fmt.allocPrint(self.gpa, "{s}/hicolor/index.theme", .{self.root});
    defer self.gpa.free(index_path);
    cwd.writeFile(self.io, .{ .sub_path = index_path, .data = theme_index }) catch
        return error.WriteFailed;
}

/// Writes `markup` and returns the themed name to publish as `IconName`. The
/// returned slice is owned by the caller.
///
/// `base_name` only shapes the file name; a counter keeps successive calls
/// distinct so hosts that cache by name still notice a change.
pub fn writeSvg(self: *IconExport, base_name: []const u8, markup: []const u8) Error![]u8 {
    self.counter += 1;

    var sanitised: std.ArrayList(u8) = .empty;
    defer sanitised.deinit(self.gpa);
    for (base_name) |c| {
        try sanitised.append(self.gpa, switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => c,
            else => '-',
        });
    }
    if (sanitised.items.len == 0) try sanitised.appendSlice(self.gpa, "perch");

    const name = try std.fmt.allocPrint(
        self.gpa,
        "{s}-{d}",
        .{ sanitised.items, self.counter },
    );
    errdefer self.gpa.free(name);

    const cwd = Dir.cwd();

    // The theme layout is what hosts are supposed to read...
    const themed = try std.fmt.allocPrint(
        self.gpa,
        "{s}/hicolor/scalable/apps/{s}.svg",
        .{ self.root, name },
    );
    defer self.gpa.free(themed);
    cwd.writeFile(self.io, .{ .sub_path = themed, .data = markup }) catch
        return error.WriteFailed;

    // ...and a flat copy covers the hosts that treat IconThemePath as a plain
    // directory of icon files instead.
    const flat = try std.fmt.allocPrint(self.gpa, "{s}/{s}.svg", .{ self.root, name });
    defer self.gpa.free(flat);
    cwd.writeFile(self.io, .{ .sub_path = flat, .data = markup }) catch {};

    return name;
}

test "an override path is used verbatim and never deleted" {
    const gpa = std.testing.allocator;

    var export_ = try IconExport.init(gpa, std.testing.io, null, "/some/theme/dir");
    defer export_.deinit();

    try std.testing.expectEqualStrings("/some/theme/dir", export_.root);
    try std.testing.expect(!export_.owns_root);
}

test "a missing runtime dir is reported, not guessed at" {
    try std.testing.expectError(
        error.NoRuntimeDir,
        IconExport.init(std.testing.allocator, std.testing.io, null, null),
    );
}

test "stale directories are removed, live ones are left alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const base = ".zig-cache/tmp/perch-stale-test";
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base);

    // Pid 1 always exists; this one never will.
    const dead = try std.fmt.allocPrint(gpa, "{s}/perch-4294967", .{base});
    defer gpa.free(dead);
    const live = try std.fmt.allocPrint(gpa, "{s}/perch-1", .{base});
    defer gpa.free(live);
    const unrelated = try std.fmt.allocPrint(gpa, "{s}/something-else", .{base});
    defer gpa.free(unrelated);
    for ([_][]const u8{ dead, live, unrelated }) |path| try cwd.createDirPath(io, path);

    removeStale(gpa, io, base);

    try std.testing.expectError(error.FileNotFound, cwd.access(io, dead, .{}));
    try cwd.access(io, live, .{});
    try cwd.access(io, unrelated, .{});
}

test "svg export writes both layouts and rotates names" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A relative base is fine: paths are resolved against the cwd, and the
    // exporter removes its own directory on deinit.
    var export_ = try IconExport.init(gpa, io, ".zig-cache/tmp", null);
    defer export_.deinit();

    const first = try export_.writeSvg("dev.perch.test", "<svg id=\"one\"/>");
    defer gpa.free(first);
    const second = try export_.writeSvg("dev.perch.test", "<svg id=\"two\"/>");
    defer gpa.free(second);

    // Dots are not valid in a themed icon name.
    try std.testing.expectEqualStrings("dev-perch-test-1", first);
    try std.testing.expectEqualStrings("dev-perch-test-2", second);

    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "hicolor/scalable/apps", "" }) |sub| {
        const path = if (sub.len == 0)
            try std.fmt.allocPrint(gpa, "{s}/{s}.svg", .{ export_.root, second })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}/{s}.svg", .{ export_.root, sub, second });
        defer gpa.free(path);

        const contents = try cwd.readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(contents);
        try std.testing.expectEqualStrings("<svg id=\"two\"/>", contents);
    }

    const index_path = try std.fmt.allocPrint(gpa, "{s}/hicolor/index.theme", .{export_.root});
    defer gpa.free(index_path);
    const index = try cwd.readFileAlloc(io, index_path, gpa, .unlimited);
    defer gpa.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "Name=Hicolor") != null);
}

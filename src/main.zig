//! `perch` — reports what the library can do on this machine. Useful when a tray
//! icon fails to appear and you need to know whether it is your code or the
//! desktop session.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const perch = @import("perch");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    var host_present = false;

    try out.print("perch {f}\n", .{perch.version});
    try out.print("  target   {t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag });
    try out.print("  backend  {s} (supported: {})\n", .{ perch.backend.name, perch.supported });

    if (builtin.os.tag == .linux) {
        const env = init.environ_map;
        try out.print("  session  desktop={s} dbus={}\n", .{
            env.get("XDG_CURRENT_DESKTOP") orelse "<unset>",
            env.get("DBUS_SESSION_BUS_ADDRESS") != null,
        });
        host_present = try reportHost(gpa, io, env, out);
    }

    var menu = perch.Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.addItem("Hello from perch");
    try menu.addSeparator();
    const quit = try menu.addItem("Quit");

    var doctor: Doctor = .{ .quit_id = quit };

    const tray = perch.Tray.create(gpa, .{
        .io = io,
        .app_id = "dev.perch.doctor",
        .title = "perch",
        .tooltip = "perch doctor",
        .icon = .{ .named = "applications-system" },
        .menu = &menu,
        .linux = .{ .environ = init.minimal.environ },
        .handler = .{ .ctx = &doctor, .on_activate = Doctor.onActivate },
    }) catch |err| {
        try out.print("\n  status   cannot create a tray: {t}\n", .{err});
        if (perch.backend.Impl.supported) {
            try out.print("           the {s} backend is still a stub; see docs/ROADMAP.md\n", .{perch.backend.name});
        }
        return;
    };
    defer tray.destroy();

    if (host_present) {
        try out.print(
            \\
            \\  status   the icon is live — look for it in your tray
            \\           choose Quit from its menu, or press Ctrl-C, to exit
            \\
        , .{});
    } else {
        try out.print(
            \\
            \\  status   the item is published and waiting for a host to appear
            \\           press Ctrl-C to exit
            \\
        , .{});
    }
    try out.flush();
    try tray.run();
}

/// Says whether anything is listening for tray icons — the usual reason an icon
/// never appears, and not something the tray API can report on its own.
fn reportHost(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
) !bool {
    const address = env.get("DBUS_SESSION_BUS_ADDRESS") orelse return false;

    const conn = perch.linux.Connection.create(gpa, io, address) catch |err| {
        try out.print("  host     cannot reach the session bus: {t}\n", .{err});
        return false;
    };
    defer conn.destroy();

    for (perch.linux.sni.watcher_names) |name| {
        if (conn.nameHasOwner(name) catch false) {
            try out.print("  host     {s} is running\n", .{name});
            return true;
        }
    }

    try out.print(
        \\  host     no status notifier watcher is running, so no icon can appear
        \\           GNOME needs the AppIndicator extension; bare X sessions need
        \\           a tray such as snixembed, which perch does not speak yet
        \\
    , .{});
    return false;
}

const Doctor = struct {
    quit_id: perch.MenuItem.Id,

    fn onActivate(ctx: ?*anyopaque, tray: *perch.Tray, id: perch.MenuItem.Id) void {
        const self: *Doctor = @ptrCast(@alignCast(ctx.?));
        if (id == self.quit_id) tray.stop();
    }
};

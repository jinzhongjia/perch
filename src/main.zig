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

    try out.print("perch {f}\n", .{perch.version});
    try out.print("  target   {t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag });
    try out.print("  backend  {s} (supported: {})\n", .{ perch.backend.name, perch.supported });

    if (builtin.os.tag == .linux) {
        const env = init.environ_map;
        try out.print("  session  desktop={s} dbus={}\n", .{
            env.get("XDG_CURRENT_DESKTOP") orelse "<unset>",
            env.get("DBUS_SESSION_BUS_ADDRESS") != null,
        });
    }

    var menu = perch.Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.addItem("Hello from perch");
    try menu.addSeparator();
    const quit = try menu.addItem("Quit");

    const tray = perch.Tray.create(gpa, .{
        .io = io,
        .app_id = "dev.perch.doctor",
        .title = "perch",
        .tooltip = "perch doctor",
        .menu = &menu,
    }) catch |err| {
        try out.print("\n  status   cannot create a tray: {t}\n", .{err});
        if (perch.backend.Impl.supported) {
            try out.print("           the {s} backend is still a stub; see docs/ROADMAP.md\n", .{perch.backend.name});
        }
        return;
    };
    defer tray.destroy();

    try out.print("\n  status   tray created; menu quit id = {d}\n", .{quit});
    try out.flush();
    try tray.run();
}

//! Minimal end-to-end use of perch: an icon, a menu with a checkbox and a
//! submenu, and a quit item that stops the loop.
//!
//!     zig build example-basic

const std = @import("std");
const perch = @import("perch");

const App = struct {
    verbose_id: perch.MenuItem.Id = 0,
    quit_id: perch.MenuItem.Id = 0,

    fn onReady(ctx: ?*anyopaque, tray: *perch.Tray) void {
        _ = ctx;
        tray.notify(.{
            .title = "perch",
            .body = "Sitting in the tray.",
        }) catch |err| std.log.warn("notification: {t}; {s}", .{ err, tray.lastDiagnostic() orelse "no platform diagnostic" });
    }

    fn onActivate(ctx: ?*anyopaque, tray: *perch.Tray, id: perch.MenuItem.Id) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (id == self.quit_id) {
            tray.stop();
        } else if (id == self.verbose_id) {
            const on = tray.menu.?.find(id).?.checked;
            std.log.info("verbose is now {}", .{on});
        }
    }

    fn onClick(ctx: ?*anyopaque, tray: *perch.Tray, event: perch.ClickEvent) void {
        _ = ctx;
        _ = tray;
        std.log.info("clicked with {t} at {?any}", .{ event.button, event.at });
    }

    fn onScroll(ctx: ?*anyopaque, tray: *perch.Tray, event: perch.ScrollEvent) void {
        _ = ctx;
        _ = tray;
        std.log.info("scrolled {t} by {d}", .{ event.axis, event.delta });
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var menu = perch.Menu.init(gpa);
    defer menu.deinit();

    var app: App = .{};
    app.verbose_id = try menu.addCheckbox("Verbose logging", false);

    const theme = try menu.addSubmenu("Theme");
    _ = try theme.addRadio("Light", 1, true);
    _ = try theme.addRadio("Dark", 1, false);

    try menu.addSeparator();
    app.quit_id = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });

    const tray = try perch.Tray.create(gpa, .{
        .io = init.io,
        .app_id = "dev.perch.example.basic",
        .title = "perch",
        .tooltip = "perch example",
        .icon = .{ .named = if (@import("builtin").os.tag == .macos) "gearshape" else "applications-system" },
        .menu = &menu,
        // Left click opens the menu; on_click then only sees the other buttons.
        // Set this to `.activate` to receive left clicks instead.
        .left_click = .show_menu,
        .handler = .{
            .ctx = &app,
            .on_ready = App.onReady,
            .on_activate = App.onActivate,
            .on_click = App.onClick,
            .on_scroll = App.onScroll,
        },
        // Linux needs DBUS_SESSION_BUS_ADDRESS, and library code cannot read
        // the environment on its own.
        .linux = .{ .environ = init.minimal.environ },
    });
    defer tray.destroy();

    try tray.run();
}

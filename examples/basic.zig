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
        }) catch {};
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

    fn onClick(ctx: ?*anyopaque, tray: *perch.Tray, button: perch.MouseButton, mods: perch.Modifiers) bool {
        _ = ctx;
        _ = tray;
        _ = mods;
        // Let the platform show the menu for every button but the middle one.
        return button == .middle;
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
        .icon = .{ .named = "applications-system" },
        .menu = &menu,
        // Linux needs DBUS_SESSION_BUS_ADDRESS, and library code cannot read
        // the environment on its own.
        .linux = .{ .environ = init.minimal.environ },
        .handler = .{
            .ctx = &app,
            .on_ready = App.onReady,
            .on_activate = App.onActivate,
            .on_click = App.onClick,
        },
    });
    defer tray.destroy();

    try tray.run();
}

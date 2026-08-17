//! The features beyond "an icon with a menu": an SVG icon the host renders at
//! any scale, notifications with buttons that can be replaced and closed, and
//! attention status.
//!
//!     zig build example-rich

const std = @import("std");
const perch = @import("perch");

/// Rendered by the desktop at whatever size the display scale asks for, so it
/// stays sharp where a fixed-size bitmap would not.
const icon_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
    \\  <circle cx="12" cy="12" r="10" fill="#4c8bf5"/>
    \\  <path d="M7 13l3 3 7-7" stroke="#fff" stroke-width="2.5" fill="none"
    \\        stroke-linecap="round" stroke-linejoin="round"/>
    \\</svg>
;

const attention_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
    \\  <circle cx="12" cy="12" r="10" fill="#e2574c"/>
    \\  <path d="M12 6v8M12 17v1" stroke="#fff" stroke-width="2.5"
    \\        stroke-linecap="round"/>
    \\</svg>
;

const App = struct {
    /// Tags name a notification without waiting for the daemon to answer.
    const download_tag: perch.Notification.Tag = 1;

    ids: struct {
        notify: perch.MenuItem.Id = 0,
        actions: perch.MenuItem.Id = 0,
        progress: perch.MenuItem.Id = 0,
        close: perch.MenuItem.Id = 0,
        attention: perch.MenuItem.Id = 0,
        quit: perch.MenuItem.Id = 0,
    } = .{},
    progress: u8 = 0,
    attention: bool = false,

    fn onActivate(ctx: ?*anyopaque, tray: *perch.Tray, id: perch.MenuItem.Id) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));

        if (id == self.ids.quit) {
            tray.stop();
        } else if (id == self.ids.notify) {
            tray.notify(.{
                .title = "perch",
                .body = "A plain notification.",
                .category = .transfer_complete,
            }) catch |err| std.log.err("notify: {t}", .{err});
        } else if (id == self.ids.actions) {
            tray.notify(.{
                .title = "Update available",
                .body = "perch 0.1 is ready to install.",
                .urgency = .critical,
                .resident = true,
                .actions = &.{
                    .{ .key = "install", .label = "Install now" },
                    .{ .key = "later", .label = "Remind me later" },
                },
            }) catch |err| std.log.err("notify: {t}", .{err});
        } else if (id == self.ids.progress) {
            self.progress = if (self.progress >= 100) 0 else self.progress + 25;
            // Same tag, so this replaces the previous popup instead of stacking.
            tray.notify(.{
                .title = "Downloading",
                .body = "Fetching a large file.",
                .tag = download_tag,
                .progress = self.progress,
                .transient = true,
                .suppress_sound = true,
            }) catch |err| std.log.err("notify: {t}", .{err});
        } else if (id == self.ids.close) {
            tray.closeNotification(download_tag) catch {};
        } else if (id == self.ids.attention) {
            self.attention = !self.attention;
            tray.setStatus(if (self.attention) .needs_attention else .active) catch {};
        }
    }

    fn onNotificationAction(
        ctx: ?*anyopaque,
        tray: *perch.Tray,
        tag: perch.Notification.Tag,
        action: []const u8,
    ) void {
        _ = ctx;
        _ = tray;
        std.log.info("notification {d}: pressed \"{s}\"", .{ tag, action });
    }

    fn onNotificationClosed(
        ctx: ?*anyopaque,
        tray: *perch.Tray,
        tag: perch.Notification.Tag,
        reason: perch.Notification.CloseReason,
    ) void {
        _ = ctx;
        _ = tray;
        std.log.info("notification {d} closed: {t}", .{ tag, reason });
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var menu = perch.Menu.init(gpa);
    defer menu.deinit();

    var app: App = .{};
    app.ids.notify = try menu.addItem("Post a notification");
    app.ids.actions = try menu.addItem("Post one with buttons");
    app.ids.progress = try menu.addItem("Advance a progress notification");
    app.ids.close = try menu.addItem("Close the progress notification");
    try menu.addSeparator();
    app.ids.attention = try menu.addCheckbox("Ask for attention", false);
    try menu.addSeparator();
    app.ids.quit = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });

    const tray = try perch.Tray.create(gpa, .{
        .io = init.io,
        .app_id = "dev.perch.example.rich",
        .title = "perch",
        .tooltip = "perch, richly",
        .icon = .{ .svg = icon_svg },
        .attention_icon = .{ .svg = attention_svg },
        .category = .application_status,
        .menu = &menu,
        .handler = .{
            .ctx = &app,
            .on_activate = App.onActivate,
            .on_notification_action = App.onNotificationAction,
            .on_notification_closed = App.onNotificationClosed,
        },
        .linux = .{ .environ = init.minimal.environ },
    });
    defer tray.destroy();

    try tray.run();
}

//! Interactive Linux host probes: zig build example-behaviors
//!
//! Use the gear's control menu to change the separate colored probe icon.
//! Keep this running while changing display scale or restarting AppIndicator.
//! Logs report requests and callbacks, NOT visual success. Check the desktop too.
//! Notification race probes deliberately do not pump between requests: duplicate
//! notifications or an immediate-close survivor are failures, not expected passes.

const std = @import("std");
const perch = @import("perch");

const blue_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#3584e4"/><path d="M7 12h10M12 7v10" stroke="white" stroke-width="2"/></svg>
;
const badge_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="17" cy="17" r="6" fill="#e01b24"/></svg>
;

// Opaque frames with contrasting centers make channel order and scaling visible.
fn pixels(comptime size: usize, comptime color: [3]u8) [size * size * 4]u8 {
    @setEvalBranchQuota(10_000);
    var out: [size * size * 4]u8 = undefined;
    for (0..size) |y| {
        for (0..size) |x| {
            const center = x >= size / 3 and x < size * 2 / 3 and y >= size / 3 and y < size * 2 / 3;
            out[(y * size + x) * 4 ..][0..4].* = if (center) .{ 255, 255, 255, 255 } else .{ color[0], color[1], color[2], 255 };
        }
    }
    return out;
}
const green = pixels(24, .{ 38, 162, 105 });
const orange = pixels(16, .{ 230, 120, 20 });
const purple = pixels(32, .{ 145, 65, 172 });
const frames = [_]perch.Icon{
    .{ .raw = .{ .width = 16, .height = 16, .pixels = &orange, .format = .rgba32 } },
    .{ .raw = .{ .width = 32, .height = 32, .pixels = &purple, .format = .rgba32 } },
};

const Command = enum {
    named,
    svg,
    png,
    raw,
    sizes,
    overlay,
    title,
    tooltip,
    passive,
    enabled,
    rename,
    append,
    attach,
    mode,
    show,
    replace,
    close,
    burst,
    immediate_close,
    image,
    quit,
};

const App = struct {
    ids: [std.meta.fields(Command).len]perch.MenuItem.Id = @splat(0),
    probe: *perch.Tray = undefined,
    menu: *perch.Menu,
    png: []const u8,
    sample: perch.MenuItem.Id,
    done: bool = false,
    overlay: bool = false,
    renamed: bool = false,
    alternate_title: bool = false,
    tooltip_present: bool = true,
    revision: u32 = 0,
    sequence: u32 = 0,
    // Borrowed menu labels stay valid until the entire example exits.
    labels: std.heap.ArenaAllocator,
    race_tag: perch.Notification.Tag = 100,

    fn add(self: *App, menu: *perch.Menu, command: Command, label: []const u8) !void {
        self.ids[@intFromEnum(command)] = try menu.addItem(label);
    }

    fn onControl(ctx: ?*anyopaque, _: *perch.Tray, id: perch.MenuItem.Id) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const index = std.mem.indexOfScalar(perch.MenuItem.Id, &self.ids, id) orelse return;
        const command: Command = @enumFromInt(index);
        std.log.info("request: {t}", .{command});
        self.execute(command) catch |err| std.log.err("{t}: {t}", .{ command, err });
    }

    fn execute(self: *App, command: Command) !void {
        switch (command) {
            .named => try self.probe.setIcon(.{ .named = "dialog-information" }),
            .svg => try self.probe.setIcon(.{ .svg = blue_svg }),
            .png => try self.probe.setIcon(.{ .bytes = self.png }),
            .raw => try self.probe.setIcon(.{ .raw = .{ .width = 24, .height = 24, .pixels = &green, .format = .rgba32 } }),
            .sizes => {
                try self.probe.setIcon(.{ .set = &frames });
                std.log.info("multi-size: 16px orange / 32px purple; host chooses a frame for its scale", .{});
            },
            .overlay => {
                const next = !self.overlay;
                try self.probe.setOverlayIcon(if (next) .{ .svg = badge_svg } else null);
                self.overlay = next;
                std.log.info("overlay={}; look for a red badge, then its removal", .{next});
            },
            .title => {
                self.alternate_title = !self.alternate_title;
                try self.probe.setTitle(if (self.alternate_title) "Probe title B" else "Probe title A");
            },
            .tooltip => {
                self.tooltip_present = !self.tooltip_present;
                try self.probe.setTooltip(if (self.tooltip_present) "Probe tooltip restored" else null);
                std.log.info("tooltip present={}; hover the probe (host may not display tooltips)", .{self.tooltip_present});
            },
            .passive => {
                const status: perch.Status = if (self.probe.options.status == .passive) .active else .passive;
                try self.probe.setStatus(status);
                std.log.info("probe status={t}; use this control again to restore it", .{status});
            },
            .enabled => {
                const next = !self.menu.find(self.sample).?.enabled;
                _ = self.menu.setEnabled(self.sample, next);
                try self.probe.refreshMenu();
                std.log.info("sample enabled={}; disabled rows must not activate from the UI", .{next});
            },
            .rename => {
                self.renamed = !self.renamed;
                _ = self.menu.setLabel(self.sample, if (self.renamed) "Renamed sample" else "Clickable sample");
                try self.probe.refreshMenu();
            },
            .append => {
                self.revision += 1;
                const label = try std.fmt.allocPrint(self.labels.allocator(), "Added item {d}", .{self.revision});
                const id = try self.menu.addItem(label);
                try self.probe.refreshMenu();
                std.log.info("added id={d}: {s}; open the probe menu and click it", .{ id, label });
            },
            .attach => {
                const menu: ?*perch.Menu = if (self.probe.menu == null) self.menu else null;
                try self.probe.setMenu(menu);
                std.log.info("menu attached={}; test click/double-click/middle-click/scroll", .{menu != null});
            },
            .mode => {
                // Left-click policy is a creation option, not a mutable setter.
                var options = self.probe.options;
                options.menu = self.probe.menu;
                options.left_click = if (options.leftClick() == .activate) .show_menu else .activate;
                const replacement = try perch.Tray.create(self.probe.gpa, options);
                self.probe.destroy();
                self.probe = replacement;
                std.log.info("recreated probe: left_click={t}, menu attached={}; host may override click policy", .{ options.leftClick(), options.menu != null });
            },
            .show => {
                try self.probe.showMenu();
                std.log.info("showMenu requested on probe; GNOME AppIndicator may ignore it", .{});
            },
            .replace => try self.post(1),
            .close => try self.probe.closeNotification(1),
            .burst => {
                const tag = self.nextRaceTag();
                for (0..3) |_| try self.post(tag);
                std.log.info("burst tag={d}: expect only the final revision, not three entries; inspect notification history", .{tag});
            },
            .immediate_close => {
                const tag = self.nextRaceTag();
                try self.post(tag);
                try self.probe.closeNotification(tag);
                std.log.info("immediate close tag={d}: no persistent notification should survive; inspect history", .{tag});
            },
            .image => try self.probe.notify(.{
                .tag = 2,
                .title = "Image and markup probe",
                .body = "<b>Bold</b> and <i>italic</i>; image hint is host-dependent.",
                .image = .{ .bytes = self.png },
                .suppress_sound = true,
            }),
            .quit => self.done = true,
        }
    }

    fn nextRaceTag(self: *App) perch.Notification.Tag {
        self.race_tag += 1;
        return self.race_tag;
    }

    fn post(self: *App, tag: perch.Notification.Tag) !void {
        self.sequence += 1;
        var body: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&body, "Tag {d}, revision {d}. Replacement must update this text.", .{ tag, self.sequence });
        // The Linux backend marshals these bytes during notify().
        try self.probe.notify(.{
            .tag = tag,
            .title = "perch behavior probe",
            .body = text,
            .timeout_ms = 0,
            .suppress_sound = true,
            .actions = &.{.{ .key = "ack", .label = "Acknowledge" }},
        });
        std.log.info("Notify tag={d} revision={d}", .{ tag, self.sequence });
    }

    fn onProbe(_: ?*anyopaque, tray: *perch.Tray, id: perch.MenuItem.Id) void {
        const item = tray.menu.?.find(id).?;
        std.log.info("probe menu callback: id={d} label={s} enabled={} checked={}", .{ id, item.label, item.enabled, item.checked });
    }

    fn onClick(_: ?*anyopaque, _: *perch.Tray, event: perch.ClickEvent) void {
        std.log.info("probe click: {t} at {?any}", .{ event.button, event.at });
    }

    fn onScroll(_: ?*anyopaque, _: *perch.Tray, event: perch.ScrollEvent) void {
        std.log.info("probe scroll: {t} delta={d}", .{ event.axis, event.delta });
    }

    fn onAction(_: ?*anyopaque, _: *perch.Tray, tag: perch.Notification.Tag, key: []const u8) void {
        std.log.info("notification action: tag={d} key={s}", .{ tag, key });
    }

    fn onClosed(_: ?*anyopaque, _: *perch.Tray, tag: perch.Notification.Tag, reason: perch.Notification.CloseReason) void {
        std.log.info("notification closed: tag={d} reason={t}", .{ tag, reason });
    }
};

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) {
        std.debug.print("This host-behavior probe requires a Linux desktop session.\n", .{});
        return;
    }
    const png = try perch.image.png.testImage(init.gpa, 24, 24, &green);
    defer init.gpa.free(png);
    var menu = perch.Menu.init(init.gpa);
    defer menu.deinit();
    const sample = try menu.addItem("Clickable sample");
    _ = try menu.add(.{ .label = "PNG menu icon", .icon = .{ .bytes = png } });
    _ = try menu.add(.{ .label = "Named menu icon", .icon = .{ .named = "dialog-information" } });
    const nested = try menu.addSubmenu("Nested");
    const deep = try nested.addSubmenu("One level deeper");
    _ = try deep.addCheckbox("Nested checkbox", false);

    var app: App = .{ .menu = &menu, .png = png, .sample = sample, .labels = .init(init.gpa) };
    defer app.labels.deinit();
    var controls = perch.Menu.init(init.gpa);
    defer controls.deinit();
    const icons = try controls.addSubmenu("Icons and appearance");
    try app.add(icons, .named, "Named icon");
    try app.add(icons, .svg, "SVG: blue plus");
    try app.add(icons, .png, "PNG: green with white center");
    try app.add(icons, .raw, "Raw RGBA: same green image");
    try app.add(icons, .sizes, "Multi-size: orange 16 / purple 32");
    try app.add(icons, .overlay, "Toggle red overlay");
    try app.add(icons, .title, "Toggle title A / B");
    try app.add(icons, .tooltip, "Remove / restore tooltip");
    try app.add(icons, .passive, "Toggle passive / active");
    const menus = try controls.addSubmenu("Menus and activation");
    try app.add(menus, .enabled, "Disable / enable sample");
    try app.add(menus, .rename, "Rename / restore sample");
    try app.add(menus, .append, "Append numbered menu item");
    try app.add(menus, .attach, "Detach / attach probe menu");
    try app.add(menus, .mode, "Recreate probe: switch left-click policy");
    try app.add(menus, .show, "Request probe showMenu (host-dependent)");
    const notifications = try controls.addSubmenu("Notifications and timing");
    try app.add(notifications, .replace, "Post / replace with next visible revision");
    try app.add(notifications, .close, "Close revision notification");
    try app.add(notifications, .burst, "Race: three immediate posts, same fresh tag");
    try app.add(notifications, .immediate_close, "Race: post then immediately close fresh tag");
    try app.add(notifications, .image, "Post image and markup hints");
    try controls.addSeparator();
    try app.add(&controls, .quit, "Quit both trays");

    app.probe = try perch.Tray.create(init.gpa, .{
        .io = init.io,
        .app_id = "dev.perch.example.behaviors.probe",
        .title = "Probe title A",
        .tooltip = "Probe tooltip",
        .icon = .{ .svg = blue_svg },
        .menu = &menu,
        .left_click = .activate,
        .linux = .{ .environ = init.minimal.environ },
        .handler = .{ .on_activate = App.onProbe, .on_click = App.onClick, .on_scroll = App.onScroll, .on_notification_action = App.onAction, .on_notification_closed = App.onClosed },
    });
    defer app.probe.destroy();
    const control = try perch.Tray.create(init.gpa, .{
        .io = init.io,
        .app_id = "dev.perch.example.behaviors.controls",
        .title = "perch behavior controls",
        .icon = .{ .named = "applications-system" },
        .menu = &controls,
        .linux = .{ .environ = init.minimal.environ },
        .handler = .{ .ctx = &app, .on_activate = App.onControl },
    });
    defer control.destroy();

    std.log.info("READY: gear = controls; blue plus = probe (initial left_click=activate)", .{});
    std.log.info("Use controls to restore a hidden or menu-less probe. Observe UI AND callback logs.", .{});
    std.log.info("Race cases may expose backend bugs; dismiss leftover test notifications manually. Quit both trays from controls.", .{});
    while (!app.done) {
        try control.pump();
        if (app.done) break;
        try app.probe.pump();
        try init.io.sleep(.fromMilliseconds(10), .awake);
    }
}

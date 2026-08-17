//! End-to-end tests against a mock StatusNotifierItem host on a private bus.
//!
//!     dbus-run-session -- zig build integration
//!
//! This is where host-behaviour differences get covered. Plasma, the GNOME
//! AppIndicator extension, waybar and snixembed each fetch icons and menus a
//! little differently, and only one of them is installed on any given machine.
//! Modelling the differences here means the matrix runs anywhere a session bus
//! can be started, CI included.

const std = @import("std");
const perch = @import("perch");

const MockHost = @import("MockHost.zig");

/// Both halves live in one thread, so every wait pumps the tray as well.
const Fixture = struct {
    host: *MockHost,
    tray: *perch.Tray,
    seen: *Seen,

    fn step(self: Fixture) anyerror!void {
        try self.tray.pump();
    }

    fn wait(self: Fixture, pending: MockHost.Pending) ![]const u8 {
        return self.host.awaitReply(pending, self, Fixture.step, 2000);
    }

    /// Pumps both sides for a while, for signals nobody replies to.
    fn settle(self: Fixture) !void {
        for (0..200) |_| {
            try self.tray.pump();
            try self.host.pump();
            try self.tray.options.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// What the tray's callbacks recorded.
const Seen = struct {
    activated: std.ArrayList(perch.MenuItem.Id) = .empty,
    clicks: std.ArrayList(perch.ClickEvent) = .empty,
    scrolls: std.ArrayList(perch.ScrollEvent) = .empty,
    actions: std.ArrayList(struct { tag: perch.Notification.Tag, key: []const u8 }) = .empty,
    closed: std.ArrayList(struct {
        tag: perch.Notification.Tag,
        reason: perch.Notification.CloseReason,
    }) = .empty,
    ready: bool = false,
    gpa: std.mem.Allocator,

    fn deinit(self: *Seen) void {
        self.activated.deinit(self.gpa);
        self.clicks.deinit(self.gpa);
        self.scrolls.deinit(self.gpa);
        for (self.actions.items) |action| self.gpa.free(action.key);
        self.actions.deinit(self.gpa);
        self.closed.deinit(self.gpa);
    }

    fn onReady(ctx: ?*anyopaque, tray: *perch.Tray) void {
        _ = tray;
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        self.ready = true;
    }

    fn onActivate(ctx: ?*anyopaque, tray: *perch.Tray, id: perch.MenuItem.Id) void {
        _ = tray;
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        self.activated.append(self.gpa, id) catch {};
    }

    fn onClick(ctx: ?*anyopaque, tray: *perch.Tray, event: perch.ClickEvent) void {
        _ = tray;
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        self.clicks.append(self.gpa, event) catch {};
    }

    fn onScroll(ctx: ?*anyopaque, tray: *perch.Tray, event: perch.ScrollEvent) void {
        _ = tray;
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        self.scrolls.append(self.gpa, event) catch {};
    }

    fn onAction(
        ctx: ?*anyopaque,
        tray: *perch.Tray,
        tag: perch.Notification.Tag,
        key: []const u8,
    ) void {
        _ = tray;
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        const owned = self.gpa.dupe(u8, key) catch return;
        self.actions.append(self.gpa, .{ .tag = tag, .key = owned }) catch {};
    }

    fn onClosed(
        ctx: ?*anyopaque,
        tray: *perch.Tray,
        tag: perch.Notification.Tag,
        reason: perch.Notification.CloseReason,
    ) void {
        _ = tray;
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        self.closed.append(self.gpa, .{ .tag = tag, .reason = reason }) catch {};
    }
};

var failures: usize = 0;
var checks: usize = 0;

fn check(condition: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (condition) return;
    failures += 1;
    std.debug.print("  FAIL " ++ what ++ "\n", args);
}

/// A 2x2 and a 4x4 PNG, so the multi-size path has something to publish.
fn twoSizeIcon(gpa: std.mem.Allocator) ![2][]u8 {
    const small = try perch.image.png.testImage(gpa, 2, 2, &@as([16]u8, @splat(0x40)));
    errdefer gpa.free(small);
    const large = try perch.image.png.testImage(gpa, 4, 4, &@as([64]u8, @splat(0x80)));
    return .{ small, large };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const address = init.environ_map.get("DBUS_SESSION_BUS_ADDRESS") orelse {
        std.debug.print(
            \\DBUS_SESSION_BUS_ADDRESS is unset.
            \\Run this under its own bus:  dbus-run-session -- zig build integration
            \\
        , .{});
        return 2;
    };

    // Taking the watcher name proves we are not on the developer's real session,
    // where kded6 or gnome-shell already owns it.
    const host = MockHost.create(gpa, init.io, address, perch.linux.sni.watcher_names[0]) catch |err| {
        std.debug.print(
            \\Cannot claim {s}: {t}
            \\A desktop session already owns it. Use a private bus:
            \\  dbus-run-session -- zig build integration
            \\
        , .{ perch.linux.sni.watcher_names[0], err });
        return 2;
    };
    defer host.destroy();

    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();

    const icons = try twoSizeIcon(gpa);
    defer gpa.free(icons[0]);
    defer gpa.free(icons[1]);
    const sizes = [_]perch.Icon{ .{ .bytes = icons[0] }, .{ .bytes = icons[1] } };

    var menu = perch.Menu.init(gpa);
    defer menu.deinit();
    const toggle = try menu.addCheckbox("Verbose", false);
    const submenu = try menu.addSubmenu("Theme");
    const light = try submenu.addRadio("Light", 1, true);
    const dark = try submenu.addRadio("Dark", 1, false);
    try menu.addSeparator();
    const quit = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });

    const tray = try perch.Tray.create(gpa, .{
        .io = init.io,
        .app_id = "dev.perch.integration",
        .title = "perch integration",
        .tooltip = "under test",
        .icon = .{ .set = &sizes },
        .menu = &menu,
        .left_click = .activate,
        .handler = .{
            .ctx = &seen,
            .on_ready = Seen.onReady,
            .on_activate = Seen.onActivate,
            .on_click = Seen.onClick,
            .on_scroll = Seen.onScroll,
            .on_notification_action = Seen.onAction,
            .on_notification_closed = Seen.onClosed,
        },
        .linux = .{ .environ = init.minimal.environ, .bus_address = address },
    });
    defer tray.destroy();

    const fixture: Fixture = .{ .host = host, .tray = tray, .seen = &seen };

    std.debug.print("registration\n", .{});
    try fixture.settle();
    check(host.items.items.len == 1, "the item registered with the watcher, got {d}", .{host.items.items.len});
    if (host.items.items.len == 0) {
        std.debug.print("nothing registered; the rest cannot run\n", .{});
        return 1;
    }

    try scenarioIconNameHost(fixture);
    try scenarioPixmapHost(fixture, sizes.len);
    try scenarioFullPropertyHost(fixture);
    try scenarioLayoutHost(fixture, .{ .toggle = toggle, .light = light, .dark = dark, .quit = quit });
    try scenarioIncrementalHost(fixture);
    try scenarioClicks(fixture);
    try scenarioNotifications(fixture);

    std.debug.print("\n{d} checks, {d} failed\n", .{ checks, failures });
    return if (failures == 0) 0 else 1;
}

/// A host that only reads `IconName` — older indicator implementations. Nothing
/// should crash, and the property must be answerable even though this icon is
/// bitmap-only.
fn scenarioIconNameHost(fixture: Fixture) !void {
    std.debug.print("host that reads IconName only\n", .{});

    const pending = try fixture.host.getProperty(perch.linux.sni.item_interface, "IconName");
    const body = try fixture.wait(pending);

    var r: perch.linux.wire.Reader = .init(body, .little);
    const signature = try r.variantBegin();
    check(std.mem.eql(u8, signature, "s"), "IconName is a string, got {s}", .{signature});
    // A bitmap icon has no themed name; empty is the correct answer, not an error.
    const name = try r.string();
    check(name.len == 0, "a bitmap icon reports no themed name, got \"{s}\"", .{name});
}

/// A host that renders from `IconPixmap`, like Plasma. Every size the icon
/// carries has to be on the wire, or HiDPI stretches one bitmap.
fn scenarioPixmapHost(fixture: Fixture, expected_sizes: usize) !void {
    std.debug.print("host that reads IconPixmap\n", .{});

    const pending = try fixture.host.getProperty(perch.linux.sni.item_interface, "IconPixmap");
    const body = try fixture.wait(pending);

    var r: perch.linux.wire.Reader = .init(body, .little);
    const signature = try r.variantBegin();
    check(std.mem.eql(u8, signature, "a(iiay)"), "IconPixmap signature is {s}", .{signature});

    const end = try r.arrayBegin("(iiay)");
    var count: usize = 0;
    var widths: [8]i32 = @splat(0);
    while (r.pos < end) {
        try r.structBegin();
        const width = try r.int(i32);
        const height = try r.int(i32);
        const pixels_end = try r.arrayBegin("y");
        const bytes = pixels_end - r.pos;
        r.pos = pixels_end;

        if (count < widths.len) widths[count] = width;
        check(
            bytes == @as(usize, @intCast(width * height * 4)),
            "pixmap {d} is {d}x{d} so it needs {d} bytes, got {d}",
            .{ count, width, height, width * height * 4, bytes },
        );
        count += 1;
    }
    check(count == expected_sizes, "all {d} sizes are published, got {d}", .{ expected_sizes, count });
    if (count >= 2) {
        check(widths[0] > widths[1], "sizes come largest first, got {d} then {d}", .{ widths[0], widths[1] });
    }
}

/// A host that asks for everything at once, which is what most do on first draw.
fn scenarioFullPropertyHost(fixture: Fixture) !void {
    std.debug.print("host that reads every property\n", .{});

    const pending = try fixture.host.getAllProperties(perch.linux.sni.item_interface);
    const body = try fixture.wait(pending);

    var r: perch.linux.wire.Reader = .init(body, .little);
    const end = try r.arrayBegin("{sv}");

    var found_id = false;
    var found_menu = false;
    var item_is_menu: ?bool = null;
    var category: []const u8 = "";
    var count: usize = 0;
    while (r.pos < end) {
        try r.dictEntryBegin();
        const key = try r.string();
        const signature = try r.variantBegin();
        if (std.mem.eql(u8, key, "Id")) {
            found_id = std.mem.eql(u8, try r.string(), "dev.perch.integration");
        } else if (std.mem.eql(u8, key, "Menu")) {
            found_menu = std.mem.eql(u8, try r.objectPath(), "/MenuBar");
        } else if (std.mem.eql(u8, key, "ItemIsMenu")) {
            item_is_menu = try r.boolean();
        } else if (std.mem.eql(u8, key, "Category")) {
            category = try r.string();
        } else {
            try r.skip(signature);
        }
        count += 1;
    }

    check(count >= 13, "GetAll returns the whole table, got {d} entries", .{count});
    check(found_id, "Id is the app id", .{});
    check(found_menu, "Menu points at /MenuBar", .{});
    // left_click is .activate here, so the host must not swallow left clicks.
    check(item_is_menu != null and !item_is_menu.?, "left_click .activate clears ItemIsMenu", .{});
    check(std.mem.eql(u8, category, "ApplicationStatus"), "Category is {s}", .{category});
}

/// A host that pulls the whole menu with a property filter, as most do.
fn scenarioLayoutHost(
    fixture: Fixture,
    ids: struct {
        toggle: perch.MenuItem.Id,
        light: perch.MenuItem.Id,
        dark: perch.MenuItem.Id,
        quit: perch.MenuItem.Id,
    },
) !void {
    std.debug.print("host that pulls the whole menu\n", .{});

    const pending = try fixture.host.getLayout(-1, &.{ "label", "type", "toggle-state", "children-display" });
    const body = try fixture.wait(pending);

    var r: perch.linux.wire.Reader = .init(body, .little);
    _ = try r.int(u32); // revision

    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(fixture.seen.gpa);
    var found_separator = false;
    var toggle_state: ?i32 = null;

    // Walks the (ia{sv}av) tree, collecting what a host would render.
    const Walk = struct {
        fn node(
            reader: *perch.linux.wire.Reader,
            out: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            separator: *bool,
            state: *?i32,
            wanted: perch.MenuItem.Id,
        ) !void {
            try reader.structBegin();
            const id = try reader.int(i32);

            const props_end = try reader.arrayBegin("{sv}");
            while (reader.pos < props_end) {
                try reader.dictEntryBegin();
                const key = try reader.string();
                const signature = try reader.variantBegin();
                if (std.mem.eql(u8, key, "label")) {
                    try out.append(gpa, try reader.string());
                } else if (std.mem.eql(u8, key, "type")) {
                    if (std.mem.eql(u8, try reader.string(), "separator")) separator.* = true;
                } else if (std.mem.eql(u8, key, "toggle-state")) {
                    const value = try reader.int(i32);
                    if (id == @as(i32, @intCast(wanted))) state.* = value;
                } else {
                    try reader.skip(signature);
                }
            }

            const children_end = try reader.arrayBegin("v");
            while (reader.pos < children_end) {
                _ = try reader.variantBegin();
                try node(reader, out, gpa, separator, state, wanted);
            }
        }
    };
    try Walk.node(&r, &labels, fixture.seen.gpa, &found_separator, &toggle_state, ids.toggle);

    check(labels.items.len == 5, "five labelled rows, got {d}", .{labels.items.len});
    check(found_separator, "the separator is typed as one", .{});
    check(toggle_state != null and toggle_state.? == 0, "the checkbox starts unchecked", .{});

    var has_quit = false;
    var has_dark = false;
    for (labels.items) |label| {
        if (std.mem.eql(u8, label, "Quit")) has_quit = true;
        if (std.mem.eql(u8, label, "Dark")) has_dark = true;
    }
    check(has_quit, "the top level is present", .{});
    check(has_dark, "submenu children are included at depth -1", .{});

    // A filtered fetch must not smuggle in properties nobody asked for.
    const filtered = try fixture.host.getLayout(1, &.{"label"});
    const filtered_body = try fixture.wait(filtered);
    var fr: perch.linux.wire.Reader = .init(filtered_body, .little);
    _ = try fr.int(u32);
    try fr.structBegin();
    _ = try fr.int(i32);
    const root_props_end = try fr.arrayBegin("{sv}");
    check(fr.pos == root_props_end, "a label-only filter drops children-display", .{});
    fr.pos = root_props_end;

    const depth_end = try fr.arrayBegin("v");
    var depth1_children: usize = 0;
    while (fr.pos < depth_end) {
        _ = try fr.variantBegin();
        try fr.structBegin();
        _ = try fr.int(i32);
        const props_end = try fr.arrayBegin("{sv}");
        fr.pos = props_end;
        const grandchildren_end = try fr.arrayBegin("v");
        check(fr.pos == grandchildren_end, "depth 1 stops before grandchildren", .{});
        fr.pos = grandchildren_end;
        depth1_children += 1;
    }
    check(depth1_children == 4, "depth 1 returns the four top rows, got {d}", .{depth1_children});

    _ = ids.light;
    _ = ids.dark;
    _ = ids.quit;
}

/// A host that asks for properties by id and calls `AboutToShow` first, the way
/// libdbusmenu-based ones do.
fn scenarioIncrementalHost(fixture: Fixture) !void {
    std.debug.print("host that fetches incrementally\n", .{});

    const about = try fixture.host.aboutToShow(0);
    const about_body = try fixture.wait(about);
    var ar: perch.linux.wire.Reader = .init(about_body, .little);
    const needs_update = try ar.boolean();
    check(!needs_update, "AboutToShow reports the layout is current", .{});

    // An empty id list means "everything", which is the form hosts use on first
    // draw and the one most likely to be mishandled.
    const pending = try fixture.host.getGroupProperties(&.{});
    const body = try fixture.wait(pending);

    var r: perch.linux.wire.Reader = .init(body, .little);
    const end = try r.arrayBegin("(ia{sv})");
    var rows: usize = 0;
    var saw_root = false;
    while (r.pos < end) {
        try r.structBegin();
        const id = try r.int(i32);
        if (id == 0) saw_root = true;
        const props_end = try r.arrayBegin("{sv}");
        r.pos = props_end;
        rows += 1;
    }
    // Root, five items, and one separator.
    check(rows == 7, "every row is described, got {d}", .{rows});
    check(saw_root, "the root is included", .{});
}

fn scenarioClicks(fixture: Fixture) !void {
    std.debug.print("clicks, scrolls and menu activation\n", .{});

    const before = fixture.seen.clicks.items.len;
    _ = try fixture.wait(try fixture.host.clickIcon("Activate", 12, 34));
    _ = try fixture.wait(try fixture.host.clickIcon("SecondaryActivate", 1, 2));
    _ = try fixture.wait(try fixture.host.clickIcon("ContextMenu", 5, 6));
    _ = try fixture.wait(try fixture.host.scrollIcon(-3, "vertical"));
    _ = try fixture.wait(try fixture.host.scrollIcon(7, "horizontal"));

    const clicks = fixture.seen.clicks.items[before..];
    check(clicks.len == 3, "three clicks arrived, got {d}", .{clicks.len});
    if (clicks.len == 3) {
        check(clicks[0].button == .left, "Activate is a left click", .{});
        check(clicks[1].button == .middle, "SecondaryActivate is a middle click", .{});
        check(clicks[2].button == .right, "ContextMenu is a right click", .{});
        check(
            clicks[0].at != null and clicks[0].at.?.x == 12 and clicks[0].at.?.y == 34,
            "the click position is passed through, got {?any}",
            .{clicks[0].at},
        );
    }

    const scrolls = fixture.seen.scrolls.items;
    check(scrolls.len == 2, "both scrolls arrived, got {d}", .{scrolls.len});
    if (scrolls.len == 2) {
        check(scrolls[0].axis == .vertical and scrolls[0].delta == -3, "vertical delta -3", .{});
        check(scrolls[1].axis == .horizontal and scrolls[1].delta == 7, "horizontal delta 7", .{});
    }

    // Clicking the checkbox toggles it in the model before the callback runs.
    const toggle_id: i32 = 1;
    _ = try fixture.wait(try fixture.host.clickMenuItem(toggle_id));
    check(fixture.seen.activated.items.len == 1, "the menu click was delivered", .{});
    const item = fixture.tray.menu.?.find(@intCast(toggle_id));
    check(item != null and item.?.checked, "the checkbox toggled", .{});
}

fn scenarioNotifications(fixture: Fixture) !void {
    std.debug.print("notifications, with buttons and replacement\n", .{});

    try fixture.tray.notify(.{
        .title = "Update available",
        .body = "perch 0.1 is ready.",
        .tag = 7,
        .urgency = .critical,
        .actions = &.{
            .{ .key = "install", .label = "Install now" },
            .{ .key = "later", .label = "Later" },
        },
    });
    try fixture.settle();

    const posted = fixture.host.latest();
    check(posted != null, "the daemon received a Notify", .{});
    if (posted == null) return;

    check(std.mem.eql(u8, posted.?.summary, "Update available"), "summary is {s}", .{posted.?.summary});
    check(posted.?.actions.items.len == 4, "two actions arrive as four strings, got {d}", .{posted.?.actions.items.len});
    if (posted.?.actions.items.len == 4) {
        check(std.mem.eql(u8, posted.?.actions.items[0], "install"), "the first action key", .{});
        check(std.mem.eql(u8, posted.?.actions.items[1], "Install now"), "the first action label", .{});
    }

    // The button press only reaches the app if the tag was mapped to the id the
    // daemon handed back.
    const id = posted.?.id;
    try fixture.host.invokeAction(id, "install");
    try fixture.settle();
    check(fixture.seen.actions.items.len == 1, "the action reached the app, got {d}", .{fixture.seen.actions.items.len});
    if (fixture.seen.actions.items.len == 1) {
        check(fixture.seen.actions.items[0].tag == 7, "the action carries our tag", .{});
        check(
            std.mem.eql(u8, fixture.seen.actions.items[0].key, "install"),
            "the action key is {s}",
            .{fixture.seen.actions.items[0].key},
        );
    }

    // Same tag: this must replace, not stack.
    const before = fixture.host.notifications.items.len;
    try fixture.tray.notify(.{
        .title = "Downloading",
        .body = "Halfway.",
        .tag = 7,
        .progress = 50,
    });
    try fixture.settle();
    check(
        fixture.host.notifications.items.len == before,
        "replacing does not add a notification, went from {d} to {d}",
        .{ before, fixture.host.notifications.items.len },
    );
    const replaced = fixture.host.find(id);
    check(replaced != null and replaced.?.replaces == id, "the replace carried the daemon's id", .{});
    check(replaced != null and replaced.?.progress != null and replaced.?.progress.? == 50, "the progress hint arrived", .{});

    // A dismissal from the user side.
    try fixture.host.closeNotification(id, 2);
    try fixture.settle();
    check(fixture.seen.closed.items.len == 1, "the close reached the app, got {d}", .{fixture.seen.closed.items.len});
    if (fixture.seen.closed.items.len == 1) {
        check(fixture.seen.closed.items[0].tag == 7, "the close carries our tag", .{});
        check(fixture.seen.closed.items[0].reason == .dismissed, "the reason is dismissed", .{});
    }

    // The tag is free again, so posting with it must create a new notification.
    try fixture.tray.notify(.{ .title = "Fresh", .tag = 7 });
    try fixture.settle();
    check(
        fixture.host.notifications.items.len == before + 1,
        "a closed tag starts a new notification, got {d}",
        .{fixture.host.notifications.items.len},
    );
}

//! End-to-end tests of the XEmbed fallback against a mock system tray.
//!
//!     dbus-run-session -- xvfb-run -a zig build xembed-integration
//!
//! The mock claims `_NET_SYSTEM_TRAY_S0` on a throwaway X server and embeds
//! whatever docks, like stalonetray would. The private bus has no
//! StatusNotifierWatcher, so the tray must pick the X path by itself. Clicks are
//! synthetic `SendEvent`s, which perch handles exactly like real ones.

const std = @import("std");
const perch = @import("perch");

const X11 = perch.linux.X11;
const XMenu = perch.linux.XMenu;

var failures: usize = 0;
var checks: usize = 0;

fn check(condition: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (condition) return;
    failures += 1;
    std.debug.print("  FAIL " ++ what ++ "\n", args);
}

const Seen = struct {
    activated: std.ArrayList(perch.MenuItem.Id) = .empty,
    clicks: std.ArrayList(perch.ClickEvent) = .empty,
    scrolls: std.ArrayList(perch.ScrollEvent) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *Seen) void {
        self.activated.deinit(self.gpa);
        self.clicks.deinit(self.gpa);
        self.scrolls.deinit(self.gpa);
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
};

const container_background = 0x00ff00;
const container_x = 50;
const container_y = 50;
const icon_size = 24;

/// The tray side: owns the selection and embeds icons into `container`.
const MockTray = struct {
    x: *X11,
    selection: X11.Atom,
    opcode: X11.Atom,
    manager_atom: X11.Atom,
    manager: X11.Window = 0,
    container: X11.Window,
    /// The last icon that asked to dock.
    docked: X11.Window = 0,

    fn create(gpa: std.mem.Allocator, io: std.Io, display: []const u8, authority: ?[]const u8) !MockTray {
        const x = try X11.connect(gpa, io, .{ .display = display, .authority_path = authority });
        var self: MockTray = .{
            .x = x,
            .selection = try x.internAtom("_NET_SYSTEM_TRAY_S0"),
            .opcode = try x.internAtom("_NET_SYSTEM_TRAY_OPCODE"),
            .manager_atom = try x.internAtom("MANAGER"),
            .container = x.generateId(),
        };
        try x.createWindow(.{
            .id = self.container,
            .parent = x.setup.root,
            .x = container_x,
            .y = container_y,
            .width = icon_size,
            .height = icon_size,
            .attributes = .{ .background_pixel = container_background, .override_redirect = true },
        });
        try x.mapWindow(self.container);
        try self.claim();
        return self;
    }

    /// Takes the selection with a fresh manager window and announces it.
    fn claim(self: *MockTray) !void {
        const x = self.x;
        self.manager = x.generateId();
        try x.createWindow(.{ .id = self.manager, .parent = x.setup.root, .x = -10, .y = -10, .width = 1, .height = 1 });
        try x.setSelectionOwner(self.manager, self.selection);
        try x.sendClientMessage(x.setup.root, X11.EventMask.structure_notify, x.setup.root, self.manager_atom, .{
            X11.current_time, self.selection, self.manager, 0, 0,
        });
        try x.sync();
    }

    /// A tray exiting: the manager window goes, and with it the selection.
    fn vanish(self: *MockTray) !void {
        try self.x.destroyWindow(self.manager);
        self.manager = 0;
        try self.x.sync();
    }

    fn pump(self: *MockTray) !void {
        while (try self.readable()) {
            const event = try self.x.nextEvent() orelse continue;
            switch (event) {
                .client_message => |message| {
                    if (message.type != self.opcode or message.data[1] != 0) continue;
                    const icon = message.data[2];
                    self.docked = icon;
                    try self.x.reparentWindow(icon, self.container, 0, 0);
                    try self.x.configureWindow(icon, .{ .x = 0, .y = 0, .width = icon_size, .height = icon_size });
                    try self.x.mapWindow(icon);
                    try self.x.flush();
                },
                else => {},
            }
        }
    }

    fn readable(self: *MockTray) !bool {
        if (self.x.pending()) return true;
        var fds = [_]std.posix.pollfd{.{ .fd = self.x.handle(), .events = std.posix.POLL.IN, .revents = 0 }};
        return try std.posix.poll(&fds, 0) > 0;
    }

    /// The pixel at (`px`, `py`) of `window`, as 0xRRGGBB.
    fn pixel(self: *MockTray, window: X11.Window, px: i16, py: i16) !u32 {
        const data = try self.x.getImage(window, .{ .x = px, .y = py, .width = 1, .height = 1 });
        return std.mem.readInt(u32, data[0..4], .little) & 0xffffff;
    }

    fn click(self: *MockTray, window: X11.Window, button: u8, x: i16, y: i16) !void {
        try self.x.sendEvent(window, 0, X11.pointerEvent(4, button, window, x, y, x, y));
        try self.x.sendEvent(window, 0, X11.pointerEvent(5, button, window, x, y, x, y));
        try self.x.flush();
    }

    fn hover(self: *MockTray, window: X11.Window, x: i16, y: i16) !void {
        try self.x.sendEvent(window, 0, X11.pointerEvent(6, 0, window, x, y, x, y));
        try self.x.flush();
    }

    /// Top-level windows that were not there in `before`: perch's popups.
    fn newWindows(self: *MockTray, gpa: std.mem.Allocator, before: []const X11.Window) ![]X11.Window {
        const now = try self.x.queryChildren(self.x.setup.root);
        defer gpa.free(now);
        var fresh: std.ArrayList(X11.Window) = .empty;
        for (now) |window| {
            if (std.mem.indexOfScalar(X11.Window, before, window) == null) try fresh.append(gpa, window);
        }
        return fresh.toOwnedSlice(gpa);
    }

    /// The metrics perch's menu will use, found the same way perch finds them.
    fn menuMetrics(self: *MockTray) !X11.FontMetrics {
        for (XMenu.font_names) |name| {
            const font = self.x.generateId();
            try self.x.openFont(font, name);
            if (self.x.queryFont(font)) |metrics| {
                try self.x.closeFont(font);
                return metrics;
            } else |_| {}
        }
        return XMenu.fallback_metrics;
    }
};

const Fixture = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mock: *MockTray,
    tray: *perch.Tray,

    fn settle(self: Fixture) !void {
        for (0..150) |_| {
            try self.tray.pump();
            try self.mock.pump();
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// 4x4: an opaque red 2x2 centre in a transparent frame, so both the icon and
/// the tray's background show at known places once scaled to 24x24.
fn centreIcon() [64]u8 {
    var pixels: [64]u8 = @splat(0);
    for ([_]usize{ 5, 6, 9, 10 }) |i| pixels[i * 4 ..][0..4].* = .{ 0xff, 0xff, 0x00, 0x00 };
    return pixels;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    const display = env.get("DISPLAY") orelse {
        std.debug.print("DISPLAY is unset. Run: dbus-run-session -- xvfb-run -a zig build xembed-integration\n", .{});
        return 2;
    };
    const address = env.get("DBUS_SESSION_BUS_ADDRESS") orelse {
        std.debug.print("DBUS_SESSION_BUS_ADDRESS is unset; run under dbus-run-session\n", .{});
        return 2;
    };

    var mock = try MockTray.create(gpa, io, display, env.get("XAUTHORITY"));
    defer mock.x.disconnect();

    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();

    var menu = perch.Menu.init(gpa);
    defer menu.deinit();
    const open = try menu.addItem("Open");
    _ = try menu.add(.{ .label = "Hidden", .visible = false });
    try menu.addSeparator();
    const verbose = try menu.addCheckbox("Verbose", false);
    const theme = try menu.addSubmenu("Theme");
    const light = try theme.addRadio("Light", 1, true);
    const dark = try theme.addRadio("Dark", 1, false);
    _ = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });

    const raw = centreIcon();
    const tray = try perch.Tray.create(gpa, .{
        .io = io,
        .app_id = "dev.perch.xembed",
        .icon = .{ .raw = .{ .width = 4, .height = 4, .pixels = &raw } },
        .menu = &menu,
        .handler = .{
            .ctx = &seen,
            .on_activate = Seen.onActivate,
            .on_click = Seen.onClick,
            .on_scroll = Seen.onScroll,
        },
        .linux = .{ .environ = init.minimal.environ, .bus_address = address },
    });
    var tray_alive = true;
    defer if (tray_alive) tray.destroy();

    const fixture: Fixture = .{ .gpa = gpa, .io = io, .mock = &mock, .tray = tray };

    std.debug.print("docking without a StatusNotifierWatcher\n", .{});
    try fixture.settle();
    check(mock.docked != 0, "the icon asked the tray to dock it", .{});
    if (mock.docked == 0) return finish();
    const icon = mock.docked;
    check((try mock.x.queryTree(icon)).parent == mock.container, "the icon was embedded in the tray", .{});

    std.debug.print("painting\n", .{});
    const centre = try mock.pixel(icon, icon_size / 2, icon_size / 2);
    check(centre == 0xff0000, "the icon's centre is red, got {x:0>6}", .{centre});
    const corner = try mock.pixel(icon, 1, 1);
    check(corner == container_background, "transparent pixels show the tray, got {x:0>6}", .{corner});

    std.debug.print("clicks and scrolls\n", .{});
    try mock.click(icon, 2, 5, 5);
    try mock.x.sendEvent(icon, 0, X11.pointerEvent(4, 4, icon, 5, 5, 55, 55));
    try mock.x.flush();
    try fixture.settle();
    check(seen.clicks.items.len == 1 and seen.clicks.items[0].button == .middle, "a middle click arrived", .{});
    check(
        seen.scrolls.items.len == 1 and seen.scrolls.items[0].axis == .vertical and seen.scrolls.items[0].delta == 1,
        "a wheel-up arrived as vertical +1",
        .{},
    );

    const metrics = try mock.menuMetrics();
    var root_layout = try XMenu.layout(gpa, &menu, metrics);
    defer root_layout.deinit(gpa);
    check(root_layout.rows.len == 6, "the hidden item takes no row, got {d} rows", .{root_layout.rows.len});

    const before = try mock.x.queryChildren(mock.x.setup.root);
    defer gpa.free(before);

    std.debug.print("menu: choose an item\n", .{});
    {
        const popup = try openMenu(fixture, icon, before) orelse return finish();
        try mock.click(popup, 1, 20, root_layout.centreOf(open).?);
        try fixture.settle();
        check(lastActivated(&seen) == open, "choosing Open activated it", .{});
        const after = try mock.newWindows(gpa, before);
        defer gpa.free(after);
        check(after.len == 0, "choosing closed the menu, {d} popups left", .{after.len});
    }

    std.debug.print("menu: toggle a checkbox\n", .{});
    {
        const popup = try openMenu(fixture, icon, before) orelse return finish();
        try mock.click(popup, 1, 20, root_layout.centreOf(verbose).?);
        try fixture.settle();
        check(lastActivated(&seen) == verbose, "the checkbox was activated", .{});
        check(menu.find(verbose).?.checked, "the checkbox is now checked", .{});
    }

    std.debug.print("menu: cascade into a submenu\n", .{});
    {
        const popup = try openMenu(fixture, icon, before) orelse return finish();
        const submenu_row = for (root_layout.rows) |row| {
            if (row.item.submenu == theme) break row;
        } else unreachable;
        try mock.hover(popup, 20, submenu_row.y + 2);
        try fixture.settle();
        const popups = try mock.newWindows(gpa, before);
        defer gpa.free(popups);
        check(popups.len == 2, "hovering the submenu row opened it, got {d} popups", .{popups.len});
        if (popups.len == 2) {
            const child = if (popups[0] == popup) popups[1] else popups[0];
            var child_layout = try XMenu.layout(gpa, theme, metrics);
            defer child_layout.deinit(gpa);
            try mock.click(child, 1, 20, child_layout.centreOf(dark).?);
            try fixture.settle();
            check(lastActivated(&seen) == dark, "choosing Dark activated it", .{});
            check(menu.find(dark).?.checked and !menu.find(light).?.checked, "the radio group moved to Dark", .{});
        }
    }

    std.debug.print("menu: a click outside dismisses it\n", .{});
    {
        const activations = seen.activated.items.len;
        const popup = try openMenu(fixture, icon, before) orelse return finish();
        try mock.click(popup, 1, -20, -20);
        try fixture.settle();
        const after = try mock.newWindows(gpa, before);
        defer gpa.free(after);
        check(after.len == 0, "the outside click closed the menu, {d} popups left", .{after.len});
        check(seen.activated.items.len == activations, "nothing was activated", .{});
    }

    std.debug.print("passive status hides the icon\n", .{});
    try tray.setStatus(.passive);
    try fixture.settle();
    check(isUnmapped(&mock, icon), "a passive icon is unmapped", .{});
    try tray.setStatus(.active);
    try fixture.settle();
    check(!isUnmapped(&mock, icon), "an active icon is mapped again", .{});

    std.debug.print("the tray restarts\n", .{});
    try mock.vanish();
    try fixture.settle();
    check(isGone(&mock, icon), "the icon was withdrawn with its tray", .{});
    mock.docked = 0;
    try mock.claim();
    try fixture.settle();
    check(mock.docked != 0 and mock.docked != icon, "the icon docked again in the new tray", .{});

    std.debug.print("destroying the tray removes the icon\n", .{});
    const last = mock.docked;
    tray.destroy();
    tray_alive = false;
    try mock.x.sync();
    check(last == 0 or isGone(&mock, last), "the icon window is gone", .{});

    return finish();
}

fn finish() u8 {
    std.debug.print("\n{d} checks, {d} failed\n", .{ checks, failures });
    return if (failures == 0) 0 else 1;
}

/// Right-clicks the icon and returns the popup that appeared.
fn openMenu(fixture: Fixture, icon: X11.Window, before: []const X11.Window) !?X11.Window {
    try fixture.mock.x.sendEvent(icon, 0, X11.pointerEvent(4, 3, icon, 5, 5, 60, 60));
    try fixture.mock.x.flush();
    try fixture.settle();
    const popups = try fixture.mock.newWindows(fixture.gpa, before);
    defer fixture.gpa.free(popups);
    check(popups.len == 1, "a right click opened one popup, got {d}", .{popups.len});
    if (popups.len == 0) return null;
    return popups[0];
}

fn lastActivated(seen: *const Seen) ?perch.MenuItem.Id {
    if (seen.activated.items.len == 0) return null;
    return seen.activated.items[seen.activated.items.len - 1];
}

/// GetImage fails on a window that is not viewable.
fn isUnmapped(mock: *MockTray, window: X11.Window) bool {
    _ = mock.x.getImage(window, .{ .x = 0, .y = 0, .width = 1, .height = 1 }) catch return true;
    return false;
}

fn isGone(mock: *MockTray, window: X11.Window) bool {
    _ = mock.x.queryTree(window) catch return true;
    return false;
}

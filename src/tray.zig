const std = @import("std");

const backend = @import("backend.zig");
const Icon = @import("icon.zig").Icon;
const Menu = @import("menu.zig").Menu;
const MenuItem = @import("menu.zig").MenuItem;
const Notification = @import("notification.zig").Notification;

/// Linux and BSD knobs, ignored elsewhere.
pub const LinuxOptions = struct {
    /// The process environment, needed to find `DBUS_SESSION_BUS_ADDRESS`. Zig
    /// 0.16 gives library code no other way to read the environment, so pass
    /// `init.minimal.environ` from `main`.
    environ: std.process.Environ = .empty,
    /// Session bus address, overriding whatever `environ` says.
    bus_address: ?[]const u8 = null,
    /// Directory of extra themed icons, exported as `IconThemePath` so hosts can
    /// resolve `Icon.named` values that are not in the system theme.
    icon_theme_path: ?[]const u8 = null,
};

pub const Error = error{
    /// No tray backend exists for this platform.
    Unsupported,
    /// Neither `LinuxOptions.bus_address` nor the environment told us where the
    /// session bus is.
    MissingBusAddress,
    /// The session bus refused the connection or the handshake.
    BusUnavailable,
    /// The backend exists but this entry point is still a stub.
    NotImplemented,
    /// No status-notifier host is running (e.g. a bare X session).
    NoTrayHost,
    /// The platform rejected the call; check `Tray.lastDiagnostic`.
    PlatformFailure,
    OutOfMemory,
};

pub const MouseButton = enum { left, right, middle };

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Command on macOS, Super/Windows elsewhere.
    super: bool = false,
};

pub const ScrollAxis = enum { vertical, horizontal };

/// Callbacks are invoked on the thread that called `Tray.run`.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    /// The icon is live and the platform is ready for updates.
    on_ready: ?*const fn (ctx: ?*anyopaque, tray: *Tray) void = null,
    /// A menu item was chosen. Checkboxes and radios are already toggled.
    on_activate: ?*const fn (ctx: ?*anyopaque, tray: *Tray, id: MenuItem.Id) void = null,
    /// The icon itself was clicked. Return `true` to suppress the default
    /// behaviour (showing the menu).
    on_click: ?*const fn (ctx: ?*anyopaque, tray: *Tray, button: MouseButton, mods: Modifiers) bool = null,
    on_scroll: ?*const fn (ctx: ?*anyopaque, tray: *Tray, axis: ScrollAxis, delta: i32) void = null,
    /// The session is ending; `run` returns right after this.
    on_quit: ?*const fn (ctx: ?*anyopaque, tray: *Tray) void = null,
};

pub const Options = struct {
    /// Backends need this for their platform I/O — the DBus socket on Linux,
    /// the message pump's waits elsewhere. `init.io` from `main` is the usual
    /// value; `std.testing.io` in tests.
    io: std.Io,
    /// Stable reverse-DNS identifier, e.g. `"dev.example.myapp"`. Used for the
    /// DBus service name on Linux, the bundle-ish toast id on Windows, and the
    /// notification authority on macOS.
    app_id: []const u8,
    /// Text shown next to the icon where the platform supports it.
    title: []const u8 = "",
    tooltip: ?[]const u8 = null,
    icon: ?Icon = null,
    /// Borrowed; must outlive the tray.
    menu: ?*Menu = null,
    handler: Handler = .{},
    linux: LinuxOptions = .{},
};

/// A live tray icon. Create with `Tray.create`, drive with `Tray.run`.
pub const Tray = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    menu: ?*Menu,
    handler: Handler,
    /// Last platform-specific error text, valid until the next failing call.
    last_diagnostic: ?[]const u8 = null,
    impl: backend.Impl,

    pub fn create(gpa: std.mem.Allocator, options: Options) Error!*Tray {
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .io = options.io,
            .options = options,
            .menu = options.menu,
            .handler = options.handler,
            .impl = undefined,
        };
        self.impl = try backend.Impl.init(self);
        return self;
    }

    pub fn destroy(self: *Tray) void {
        self.impl.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn setIcon(self: *Tray, icon: Icon) Error!void {
        self.options.icon = icon;
        return self.impl.setIcon(icon);
    }

    pub fn setTooltip(self: *Tray, tooltip: ?[]const u8) Error!void {
        self.options.tooltip = tooltip;
        return self.impl.setTooltip(tooltip);
    }

    pub fn setTitle(self: *Tray, title: []const u8) Error!void {
        self.options.title = title;
        return self.impl.setTitle(title);
    }

    /// Attaches (or replaces) the menu. Call after mutating a menu in place so
    /// the platform picks up the new state.
    pub fn setMenu(self: *Tray, menu: ?*Menu) Error!void {
        self.menu = menu;
        return self.impl.setMenu(menu);
    }

    /// Re-reads the currently attached menu.
    pub fn refreshMenu(self: *Tray) Error!void {
        return self.impl.setMenu(self.menu);
    }

    pub fn notify(self: *Tray, notification: Notification) Error!void {
        return self.impl.notify(notification);
    }

    /// Pops the menu up at the pointer, as if the icon had been clicked.
    pub fn showMenu(self: *Tray) Error!void {
        return self.impl.showMenu();
    }

    /// Runs the platform event loop until `stop` is called. Blocking.
    pub fn run(self: *Tray) Error!void {
        return self.impl.run();
    }

    /// Processes pending events and returns immediately. Use this when perch
    /// has to share a thread with another event loop.
    pub fn pump(self: *Tray) Error!void {
        return self.impl.pump();
    }

    /// Asks `run` to return. Safe to call from any thread.
    pub fn stop(self: *Tray) void {
        self.impl.stop();
    }

    pub fn lastDiagnostic(self: *const Tray) ?[]const u8 {
        return self.last_diagnostic;
    }

    /// Dispatch helper for backends: applies the toggle then fires the callback.
    pub fn dispatchActivate(self: *Tray, id: MenuItem.Id) void {
        if (self.menu) |menu| {
            if (menu.find(id)) |item| switch (item.kind) {
                .checkbox => _ = menu.setChecked(id, !item.checked),
                .radio => _ = menu.setChecked(id, true),
                else => {},
            };
        }
        if (self.handler.on_activate) |cb| cb(self.handler.ctx, self, id);
    }
};

test "dispatchActivate toggles a checkbox before notifying" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    const verbose = try menu.addCheckbox("Verbose", false);

    const Seen = struct {
        var id: MenuItem.Id = 0;
        fn onActivate(ctx: ?*anyopaque, tray: *Tray, activated: MenuItem.Id) void {
            _ = ctx;
            _ = tray;
            id = activated;
        }
    };

    // Exercise the dispatch logic without standing up a platform backend.
    var tray: Tray = .{
        .gpa = gpa,
        .io = std.testing.io,
        .options = .{ .io = std.testing.io, .app_id = "dev.perch.test" },
        .menu = &menu,
        .handler = .{ .on_activate = Seen.onActivate },
        .impl = undefined,
    };

    tray.dispatchActivate(verbose);
    try std.testing.expect(menu.find(verbose).?.checked);
    try std.testing.expectEqual(verbose, Seen.id);

    tray.dispatchActivate(verbose);
    try std.testing.expect(!menu.find(verbose).?.checked);
}

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

/// Screen coordinates, where the platform reports them.
pub const Point = struct { x: i32, y: i32 };

pub const ClickEvent = struct {
    button: MouseButton,
    /// Always empty on Linux: `StatusNotifierItem` does not report modifiers.
    mods: Modifiers = .{},
    /// Where the click landed, when the platform says.
    at: ?Point = null,
};

pub const ScrollEvent = struct {
    axis: ScrollAxis,
    delta: i32,
    mods: Modifiers = .{},
};

/// What a left click does. Platforms decide this up front rather than per click,
/// so it is a policy on the tray and not a return value from a callback.
pub const LeftClick = enum {
    /// Open the menu. The default whenever a menu is attached.
    show_menu,
    /// Call `Handler.on_click` instead, leaving the menu to the right button.
    activate,
};

/// How prominent the icon should be.
pub const Status = enum {
    /// Visible and idle.
    active,
    /// The host may hide the icon; on Linux it moves to the expander.
    passive,
    /// Ask for the user's attention, using `attention_icon` if one is set.
    needs_attention,

    /// The value `StatusNotifierItem.Status` expects.
    pub fn sniName(self: Status) []const u8 {
        return switch (self) {
            .active => "Active",
            .passive => "Passive",
            .needs_attention => "NeedsAttention",
        };
    }
};

/// Where the host should file the icon. Some hosts sort or group by this.
pub const Category = enum {
    application_status,
    communications,
    system_services,
    hardware,

    pub fn sniName(self: Category) []const u8 {
        return switch (self) {
            .application_status => "ApplicationStatus",
            .communications => "Communications",
            .system_services => "SystemServices",
            .hardware => "Hardware",
        };
    }
};

/// Callbacks are invoked on the thread that called `Tray.run`.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    /// The icon is live and the platform is ready for updates.
    on_ready: ?*const fn (ctx: ?*anyopaque, tray: *Tray) void = null,
    /// A menu item was chosen. Checkboxes and radios are already toggled.
    on_activate: ?*const fn (ctx: ?*anyopaque, tray: *Tray, id: MenuItem.Id) void = null,
    /// The icon itself was clicked. A left click only arrives when
    /// `Options.left_click` is `.activate`; a right click only when the host
    /// asks perch instead of opening the menu itself.
    on_click: ?*const fn (ctx: ?*anyopaque, tray: *Tray, event: ClickEvent) void = null,
    on_scroll: ?*const fn (ctx: ?*anyopaque, tray: *Tray, event: ScrollEvent) void = null,
    /// The user pressed a notification's action button.
    on_notification_action: ?*const fn (
        ctx: ?*anyopaque,
        tray: *Tray,
        tag: Notification.Tag,
        action: []const u8,
    ) void = null,
    /// A notification went away, whether dismissed, expired or closed by us.
    on_notification_closed: ?*const fn (
        ctx: ?*anyopaque,
        tray: *Tray,
        tag: Notification.Tag,
        reason: Notification.CloseReason,
    ) void = null,
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
    /// Shown instead of `icon` while the status is `.needs_attention`.
    attention_icon: ?Icon = null,
    /// Small badge drawn over `icon` where the platform supports it.
    overlay_icon: ?Icon = null,
    status: Status = .active,
    category: Category = .application_status,
    /// Defaults to `.show_menu` when a menu is attached, `.activate` otherwise.
    left_click: ?LeftClick = null,
    /// Borrowed; must outlive the tray.
    menu: ?*Menu = null,
    handler: Handler = .{},
    linux: LinuxOptions = .{},

    /// The effective left-click policy.
    pub fn leftClick(self: Options) LeftClick {
        return self.left_click orelse if (self.menu != null) .show_menu else .activate;
    }
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

    pub fn setAttentionIcon(self: *Tray, icon: ?Icon) Error!void {
        self.options.attention_icon = icon;
        return self.impl.setAttentionIcon(icon);
    }

    pub fn setOverlayIcon(self: *Tray, icon: ?Icon) Error!void {
        self.options.overlay_icon = icon;
        return self.impl.setOverlayIcon(icon);
    }

    pub fn setStatus(self: *Tray, status: Status) Error!void {
        self.options.status = status;
        return self.impl.setStatus(status);
    }

    /// Posts a notification. Give it a `tag` to be able to replace or close it.
    pub fn notify(self: *Tray, notification: Notification) Error!void {
        return self.impl.notify(notification);
    }

    /// Withdraws a notification posted with `tag`. Unknown tags are ignored,
    /// since a notification the user already dismissed is simply gone.
    pub fn closeNotification(self: *Tray, tag: Notification.Tag) Error!void {
        return self.impl.closeNotification(tag);
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

    /// Dispatch helper for backends.
    pub fn dispatchClick(self: *Tray, event: ClickEvent) void {
        if (self.handler.on_click) |cb| cb(self.handler.ctx, self, event);
    }

    pub fn dispatchScroll(self: *Tray, event: ScrollEvent) void {
        if (self.handler.on_scroll) |cb| cb(self.handler.ctx, self, event);
    }

    pub fn dispatchNotificationAction(
        self: *Tray,
        tag: Notification.Tag,
        action: []const u8,
    ) void {
        if (self.handler.on_notification_action) |cb| cb(self.handler.ctx, self, tag, action);
    }

    pub fn dispatchNotificationClosed(
        self: *Tray,
        tag: Notification.Tag,
        reason: Notification.CloseReason,
    ) void {
        if (self.handler.on_notification_closed) |cb| cb(self.handler.ctx, self, tag, reason);
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

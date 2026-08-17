//! Reference backend: the shape every platform backend must implement, and the
//! fallback used on targets perch has no tray for.

const Icon = @import("../icon.zig").Icon;
const Menu = @import("../menu.zig").Menu;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

pub const Backend = struct {
    pub const supported = false;

    owner: *Tray,

    pub fn init(owner: *Tray) Error!Backend {
        _ = owner;
        return error.Unsupported;
    }

    pub fn deinit(self: *Backend) void {
        self.* = undefined;
    }

    pub fn setIcon(self: *Backend, icon: Icon) Error!void {
        _ = self;
        _ = icon;
        return error.Unsupported;
    }

    pub fn setTooltip(self: *Backend, tooltip: ?[]const u8) Error!void {
        _ = self;
        _ = tooltip;
        return error.Unsupported;
    }

    pub fn setTitle(self: *Backend, title: []const u8) Error!void {
        _ = self;
        _ = title;
        return error.Unsupported;
    }

    pub fn setMenu(self: *Backend, menu: ?*Menu) Error!void {
        _ = self;
        _ = menu;
        return error.Unsupported;
    }

    pub fn notify(self: *Backend, notification: Notification) Error!void {
        _ = self;
        _ = notification;
        return error.Unsupported;
    }

    pub fn showMenu(self: *Backend) Error!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn run(self: *Backend) Error!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn pump(self: *Backend) Error!void {
        _ = self;
        return error.Unsupported;
    }

    pub fn stop(self: *Backend) void {
        _ = self;
    }
};

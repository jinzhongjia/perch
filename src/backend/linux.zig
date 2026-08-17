//! Linux/BSD backend: the freedesktop `StatusNotifierItem` protocol over DBus,
//! with `com.canonical.dbusmenu` for the menu and `org.freedesktop.Notifications`
//! for `notify`.
//!
//! Plumbing plan:
//!   1. Connect to the session bus (address from `DBUS_SESSION_BUS_ADDRESS`).
//!   2. Request the well-known name `org.kde.StatusNotifierItem-<pid>-<n>`.
//!   3. Export `/StatusNotifierItem` and `/MenuBar`, then call
//!      `RegisterStatusNotifierItem` on `org.kde.StatusNotifierWatcher`.
//!   4. Fall back to the XEmbed system tray spec when no watcher owns the name.
//!
//! Nothing here talks to DBus yet; every entry point reports `NotImplemented`
//! so callers can already compile and branch against the real API.

const std = @import("std");

const Icon = @import("../icon.zig").Icon;
const Menu = @import("../menu.zig").Menu;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

pub const Backend = struct {
    pub const supported = true;

    /// Which transport the item is published over.
    pub const Transport = enum { status_notifier_item, xembed };

    owner: *Tray,
    transport: Transport = .status_notifier_item,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(owner: *Tray) Error!Backend {
        owner.last_diagnostic = "linux: StatusNotifierItem backend is not wired up yet";
        return error.NotImplemented;
    }

    pub fn deinit(self: *Backend) void {
        self.* = undefined;
    }

    pub fn setIcon(self: *Backend, icon: Icon) Error!void {
        _ = self;
        _ = icon;
        return error.NotImplemented;
    }

    pub fn setTooltip(self: *Backend, tooltip: ?[]const u8) Error!void {
        _ = self;
        _ = tooltip;
        return error.NotImplemented;
    }

    pub fn setTitle(self: *Backend, title: []const u8) Error!void {
        _ = self;
        _ = title;
        return error.NotImplemented;
    }

    pub fn setMenu(self: *Backend, menu: ?*Menu) Error!void {
        _ = self;
        _ = menu;
        return error.NotImplemented;
    }

    pub fn notify(self: *Backend, notification: Notification) Error!void {
        _ = self;
        _ = notification;
        return error.NotImplemented;
    }

    pub fn showMenu(self: *Backend) Error!void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn run(self: *Backend) Error!void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn pump(self: *Backend) Error!void {
        _ = self;
        return error.NotImplemented;
    }

    pub fn stop(self: *Backend) void {
        self.running.store(false, .release);
    }
};

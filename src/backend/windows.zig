//! Windows backend: a hidden message-only window owning a `NOTIFYICONDATAW`
//! entry in the shell notification area, with a `HMENU` popup.
//!
//! Plumbing plan:
//!   1. `RegisterClassExW` + `CreateWindowExW(HWND_MESSAGE)` for the sink.
//!   2. `Shell_NotifyIconW(NIM_ADD)` with `uCallbackMessage` set, and
//!      `NIM_SETVERSION`/`NOTIFYICON_VERSION_4` for rich mouse events.
//!   3. Build the popup with `CreatePopupMenu`/`InsertMenuItemW`, show it via
//!      `TrackPopupMenuEx` after `SetForegroundWindow`.
//!   4. Re-add the icon on `TaskbarCreated` so it survives Explorer restarts.
//!   5. `notify` uses `NIF_INFO` balloons, or toasts when an AUMID is present.
//!
//! Nothing here calls Win32 yet; every entry point reports `NotImplemented`.

const std = @import("std");

const Icon = @import("../icon.zig").Icon;
const Menu = @import("../menu.zig").Menu;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

pub const Backend = struct {
    pub const supported = true;

    owner: *Tray,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(owner: *Tray) Error!Backend {
        owner.last_diagnostic = "windows: Shell_NotifyIcon backend is not wired up yet";
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

    /// The notification area has no text label; kept for API parity.
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

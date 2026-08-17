//! macOS backend: an `NSStatusItem` in the menu bar, driven through the
//! Objective-C runtime (`objc_msgSend`) so no Objective-C toolchain is needed.
//!
//! Plumbing plan:
//!   1. `NSApplication.sharedApplication`, activation policy `.accessory` so no
//!      Dock tile appears.
//!   2. `NSStatusBar.systemStatusBar.statusItemWithLength:` and configure
//!      `item.button` (image, `image.template = YES`, title, tooltip).
//!   3. Build the menu as `NSMenu`/`NSMenuItem`, routing actions to a
//!      dynamically registered `PerchTarget` class via `class_addMethod`.
//!   4. `run` is `[NSApp run]`; `pump` drains with
//!      `nextEventMatchingMask:untilDate:inMode:dequeue:`.
//!   5. `notify` goes through `UNUserNotificationCenter`.
//!
//! Nothing here touches the Objective-C runtime yet; every entry point reports
//! `NotImplemented`.

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
        owner.last_diagnostic = "macos: NSStatusItem backend is not wired up yet";
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

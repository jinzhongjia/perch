//! The Linux internals, exposed so tests — and callers that need to talk to the
//! session bus themselves — do not have to reimplement a DBus client.
//!
//! Nothing here is required to use a tray. The stable surface is `perch.Tray`.

pub const Connection = @import("linux/Connection.zig");
pub const DBusMenu = @import("linux/DBusMenu.zig");
pub const IconExport = @import("linux/IconExport.zig");
pub const Message = @import("linux/Message.zig");
pub const wire = @import("linux/wire.zig");

/// Names and paths the StatusNotifierItem protocol uses.
pub const sni = struct {
    pub const item_interface = "org.kde.StatusNotifierItem";
    pub const item_path = "/StatusNotifierItem";
    pub const watcher_interface = "org.kde.StatusNotifierWatcher";
    pub const watcher_path = "/StatusNotifierWatcher";
    /// Watcher names perch will register with, in order of preference. The KDE
    /// name is the de facto standard; the others are used by alternative
    /// implementations such as snixembed.
    pub const watcher_names = [_][]const u8{
        "org.kde.StatusNotifierWatcher",
        "org.freedesktop.StatusNotifierWatcher",
        "org.x.StatusNotifierWatcher",
    };
    pub const notifications_name = "org.freedesktop.Notifications";
    pub const notifications_path = "/org/freedesktop/Notifications";
    pub const notifications_interface = "org.freedesktop.Notifications";
};

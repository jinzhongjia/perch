const Icon = @import("icon.zig").Icon;

/// A desktop notification posted through the tray's identity.
///
/// Maps to `Shell_NotifyIcon`/toast on Windows, `UNUserNotificationCenter` on
/// macOS, and `org.freedesktop.Notifications` on Linux.
pub const Notification = struct {
    pub const Urgency = enum { low, normal, critical };

    title: []const u8,
    body: []const u8 = "",
    /// Defaults to the tray icon when null.
    icon: ?Icon = null,
    urgency: Urgency = .normal,
    /// Hint only; most platforms clamp or ignore it.
    timeout_ms: ?u32 = null,
};

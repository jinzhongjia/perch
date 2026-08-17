const std = @import("std");

const Icon = @import("icon.zig").Icon;

/// A desktop notification posted through the tray's identity.
///
/// Maps to `org.freedesktop.Notifications` on Linux, toasts on Windows and
/// `UNUserNotificationCenter` on macOS. Fields the platform cannot express are
/// dropped rather than approximated.
pub const Notification = struct {
    /// A caller-chosen handle. perch maps it to whatever id the platform hands
    /// back, so `Tray.closeNotification` and the notification callbacks can name
    /// a notification without waiting for a round trip. Reusing a tag replaces
    /// the notification that still holds it.
    pub const Tag = u32;

    pub const Urgency = enum { low, normal, critical };

    /// Why a notification disappeared.
    pub const CloseReason = enum {
        expired,
        dismissed,
        /// Closed by the application, i.e. `Tray.closeNotification`.
        closed,
        unknown,

        /// The reason codes `NotificationClosed` uses.
        pub fn fromCode(code: u32) CloseReason {
            return switch (code) {
                1 => .expired,
                2 => .dismissed,
                3 => .closed,
                else => .unknown,
            };
        }
    };

    /// A button on the notification. `key` comes back through
    /// `Handler.on_notification_action`.
    pub const Action = struct {
        key: []const u8,
        label: []const u8,
    };

    /// A hint at what the notification is about, so the host can style or route
    /// it. These are the freedesktop categories.
    pub const Category = enum {
        none,
        device,
        device_added,
        device_error,
        device_removed,
        email,
        email_arrived,
        email_bounced,
        im,
        im_error,
        im_received,
        network,
        network_connected,
        network_disconnected,
        network_error,
        presence,
        transfer,
        transfer_complete,
        transfer_error,

        /// The dotted name the specification uses.
        pub fn hintValue(self: Category) ?[]const u8 {
            return switch (self) {
                .none => null,
                .device => "device",
                .device_added => "device.added",
                .device_error => "device.error",
                .device_removed => "device.removed",
                .email => "email",
                .email_arrived => "email.arrived",
                .email_bounced => "email.bounced",
                .im => "im",
                .im_error => "im.error",
                .im_received => "im.received",
                .network => "network",
                .network_connected => "network.connected",
                .network_disconnected => "network.disconnected",
                .network_error => "network.error",
                .presence => "presence",
                .transfer => "transfer",
                .transfer_complete => "transfer.complete",
                .transfer_error => "transfer.error",
            };
        }
    };

    title: []const u8,
    /// May contain the small HTML subset hosts support: `<b>`, `<i>`, `<u>`,
    /// `<a href>` and `<img src>`.
    body: []const u8 = "",
    /// Shown beside the text. Defaults to the tray icon.
    icon: ?Icon = null,
    /// A larger picture shown in the notification body, where supported.
    image: ?Icon = null,
    urgency: Urgency = .normal,
    category: Category = .none,
    /// Buttons. Hosts that do not support actions ignore them, so never make an
    /// action the only way to reach a feature.
    actions: []const Action = &.{},
    /// Handle for closing or replacing this notification later. When two
    /// notifications share a tag, the second replaces the first.
    tag: ?Tag = null,
    /// Hint only; most platforms clamp or ignore it. Null means "let the host
    /// decide", 0 means "until dismissed" where that is allowed.
    timeout_ms: ?u32 = null,
    /// Skip the notification history and disappear with the popup.
    transient: bool = false,
    /// Stay on screen until acted on, rather than expiring.
    resident: bool = false,
    /// A 0..=100 progress reading shown as a bar, where supported.
    progress: ?u8 = null,
    /// A themed sound name, e.g. `"message-new-instant"`.
    sound_name: ?[]const u8 = null,
    /// Post without playing the host's sound.
    suppress_sound: bool = false,
};

test "close reasons map from the wire codes" {
    const R = Notification.CloseReason;
    try std.testing.expectEqual(R.expired, R.fromCode(1));
    try std.testing.expectEqual(R.dismissed, R.fromCode(2));
    try std.testing.expectEqual(R.closed, R.fromCode(3));
    try std.testing.expectEqual(R.unknown, R.fromCode(4));
    try std.testing.expectEqual(R.unknown, R.fromCode(0));
}

test "categories render as the specified dotted names" {
    const C = Notification.Category;
    try std.testing.expect(C.none.hintValue() == null);
    try std.testing.expectEqualStrings("im.received", C.im_received.hintValue().?);
    try std.testing.expectEqualStrings("transfer.complete", C.transfer_complete.hintValue().?);
    try std.testing.expectEqualStrings("device", C.device.hintValue().?);
}

//! perch — a cross-platform system tray library for Zig.
//!
//! One API, three native backends: Windows shell notification area,
//! macOS `NSStatusItem`, and the freedesktop `StatusNotifierItem` /
//! `XEmbed` fallback on Linux and the BSDs.

const std = @import("std");

pub const Tray = @import("tray.zig").Tray;
pub const Options = @import("tray.zig").Options;
pub const Handler = @import("tray.zig").Handler;
pub const Error = @import("tray.zig").Error;
pub const MouseButton = @import("tray.zig").MouseButton;
pub const Modifiers = @import("tray.zig").Modifiers;
pub const ScrollAxis = @import("tray.zig").ScrollAxis;
pub const ClickEvent = @import("tray.zig").ClickEvent;
pub const ScrollEvent = @import("tray.zig").ScrollEvent;
pub const Point = @import("tray.zig").Point;
pub const LeftClick = @import("tray.zig").LeftClick;
pub const Status = @import("tray.zig").Status;
pub const Category = @import("tray.zig").Category;
pub const LinuxOptions = @import("tray.zig").LinuxOptions;

pub const Menu = @import("menu.zig").Menu;
pub const MenuItem = @import("menu.zig").MenuItem;
pub const Icon = @import("icon.zig").Icon;
pub const Notification = @import("notification.zig").Notification;

/// Image decoding, exposed because callers sometimes want to inspect or
/// pre-decode icons themselves.
pub const image = @import("image.zig");
pub const PixelFormat = image.PixelFormat;

pub const backend = @import("backend.zig");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// Whether this build has a real tray backend for the target platform.
pub const supported = backend.Impl.supported;

test "public surface and the selected backend both compile" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(backend.Impl);
}

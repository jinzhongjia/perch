const builtin = @import("builtin");

/// The backend selected for the compilation target. Every backend exposes the
/// same surface; see `backend/unsupported.zig` for the canonical shape.
/// The BSDs run the same desktops and the same StatusNotifierItem hosts, but the
/// backend reaches for eventfd, /proc and `std.os.linux` directly, so it does not
/// build there yet. Claiming support perch cannot compile would be worse than
/// falling back.
pub const Impl = switch (builtin.os.tag) {
    .windows => @import("backend/windows.zig").Backend,
    .macos => @import("backend/macos.zig").Backend,
    .linux => @import("backend/linux.zig").Backend,
    else => @import("backend/unsupported.zig").Backend,
};

pub const name = switch (builtin.os.tag) {
    .windows => "shell-notifyicon",
    .macos => "nsstatusitem",
    .linux => "statusnotifieritem",
    else => "unsupported",
};

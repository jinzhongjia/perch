const builtin = @import("builtin");

/// The targets served by the freedesktop backend.
pub const freedesktop = switch (builtin.os.tag) {
    .linux => true,
    else => false,
};

/// The backend selected for the compilation target. Every backend exposes the
/// same surface; see `backend/unsupported.zig` for the canonical shape.
pub const Impl = switch (builtin.os.tag) {
    .windows => @import("backend/windows.zig").Backend,
    .macos => @import("backend/macos.zig").Backend,
    else => if (freedesktop) @import("backend/linux.zig").Backend else @import("backend/unsupported.zig").Backend,
};

pub const name = switch (builtin.os.tag) {
    .windows => "shell-notifyicon",
    .macos => "nsstatusitem",
    else => if (freedesktop) "statusnotifieritem" else "unsupported",
};

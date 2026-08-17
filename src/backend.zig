const builtin = @import("builtin");

/// The backend selected for the compilation target. Every backend exposes the
/// same surface; see `backend/unsupported.zig` for the canonical shape.
pub const Impl = switch (builtin.os.tag) {
    .windows => @import("backend/windows.zig").Backend,
    .macos => @import("backend/macos.zig").Backend,
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly => @import("backend/linux.zig").Backend,
    else => @import("backend/unsupported.zig").Backend,
};

pub const name = switch (builtin.os.tag) {
    .windows => "shell-notifyicon",
    .macos => "nsstatusitem",
    .linux, .freebsd, .netbsd, .openbsd, .dragonfly => "statusnotifieritem",
    else => "unsupported",
};

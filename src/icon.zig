const std = @import("std");

/// How a tray or menu icon is sourced. Backends pick the closest native
/// representation and scale to the platform's preferred size.
pub const Icon = union(enum) {
    /// Encoded image bytes, typically `@embedFile`d. PNG is understood
    /// everywhere; ICO is additionally accepted on Windows.
    bytes: []const u8,
    /// Path to an image on disk.
    path: []const u8,
    /// A themed icon name: a freedesktop icon-naming-spec name on Linux, an
    /// SF Symbol on macOS, a resource name on Windows.
    named: []const u8,
    /// A monochrome mask that adopts the system foreground colour. Maps to a
    /// macOS template image, a symbolic icon on Linux, and a plain icon on
    /// Windows.
    template: []const u8,

    pub fn format(self: Icon, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .bytes => |b| try writer.print("Icon.bytes({d} bytes)", .{b.len}),
            .path => |p| try writer.print("Icon.path({s})", .{p}),
            .named => |n| try writer.print("Icon.named({s})", .{n}),
            .template => |t| try writer.print("Icon.template({d} bytes)", .{t.len}),
        }
    }
};

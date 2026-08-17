const std = @import("std");

const image = @import("image.zig");

/// How a tray or menu icon is sourced. Backends pick the closest native
/// representation and scale to the platform's preferred size.
///
/// For crisp icons on HiDPI displays, prefer `named` or `svg` — the platform
/// then renders at exactly the size it needs — or hand over several sizes with
/// `set` (or a multi-frame `.ico`) and let the host choose.
pub const Icon = union(enum) {
    /// Encoded image bytes, typically `@embedFile`d. PNG, BMP and ICO are
    /// decoded by perch; a multi-frame ICO supplies every size at once.
    bytes: []const u8,
    /// Path to an image on disk. Read and decoded like `bytes` where the
    /// platform cannot resolve paths itself.
    path: []const u8,
    /// A themed icon name: a freedesktop icon-naming-spec name on Linux, an
    /// SF Symbol on macOS, a resource name on Windows. Scales perfectly,
    /// because the platform picks the size.
    named: []const u8,
    /// A monochrome mask that adopts the system foreground colour. Maps to a
    /// macOS template image, a symbolic icon on Linux, and a plain icon on
    /// Windows. Bytes are in the same formats as `bytes`.
    template: []const u8,
    /// SVG markup, rendered by the platform at the size it wants. perch does not
    /// rasterise it; on Linux the markup is exported to a private icon theme so
    /// the host renders it per display scale.
    svg: []const u8,
    /// Already-decoded pixels, skipping every decoder.
    raw: Raw,
    /// The same icon at several sizes, best first or in any order. Backends that
    /// can publish more than one size do; the others take the largest.
    /// Nesting a `set` inside a `set` is flattened one level and no further.
    set: []const Icon,

    pub const Raw = struct {
        width: u32,
        height: u32,
        /// Four bytes per pixel, `width * height * 4` long.
        pixels: []const u8,
        format: image.PixelFormat = .argb32,
    };

    /// The themed name a platform can resolve without decoding, if any.
    pub fn themedName(self: Icon) ?[]const u8 {
        return switch (self) {
            .named => |name| name,
            .set => |members| {
                for (members) |member| {
                    if (member.themedName()) |name| return name;
                }
                return null;
            },
            else => null,
        };
    }

    /// The SVG markup this icon carries, if any.
    pub fn svgMarkup(self: Icon) ?[]const u8 {
        return switch (self) {
            .svg => |markup| markup,
            .set => |members| {
                for (members) |member| {
                    if (member.svgMarkup()) |markup| return markup;
                }
                return null;
            },
            else => null,
        };
    }

    /// Encoded bytes suitable for handing to a platform that wants a file
    /// image (dbusmenu `icon-data` wants PNG, for instance).
    pub fn encodedBytes(self: Icon) ?[]const u8 {
        return switch (self) {
            .bytes, .template => |data| data,
            .set => |members| {
                for (members) |member| {
                    if (member.encodedBytes()) |data| return data;
                }
                return null;
            },
            else => null,
        };
    }

    pub fn format(self: Icon, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .bytes => |b| try writer.print("Icon.bytes({d} bytes)", .{b.len}),
            .path => |p| try writer.print("Icon.path({s})", .{p}),
            .named => |n| try writer.print("Icon.named({s})", .{n}),
            .template => |t| try writer.print("Icon.template({d} bytes)", .{t.len}),
            .svg => |s| try writer.print("Icon.svg({d} bytes)", .{s.len}),
            .raw => |r| try writer.print("Icon.raw({d}x{d})", .{ r.width, r.height }),
            .set => |members| try writer.print("Icon.set({d} sources)", .{members.len}),
        }
    }
};

/// Decodes every bitmap an icon carries, largest first. Themed names and SVG
/// yield nothing, since those are the platform's job to render.
///
/// The caller owns the result; free it with `image.freeAll`.
pub fn decodeAll(gpa: std.mem.Allocator, icon: Icon) image.Error![]image.Image {
    var out: std.ArrayList(image.Image) = .empty;
    errdefer {
        for (out.items) |*decoded| decoded.deinit(gpa);
        out.deinit(gpa);
    }

    try collect(gpa, icon, &out, 0);
    const images = try out.toOwnedSlice(gpa);
    std.mem.sort(image.Image, images, {}, image.byDescendingSize);
    return images;
}

/// `depth` guards against a `set` that points at itself.
fn collect(
    gpa: std.mem.Allocator,
    icon: Icon,
    out: *std.ArrayList(image.Image),
    depth: usize,
) image.Error!void {
    switch (icon) {
        .bytes, .template => |data| {
            const frames = try image.decodeAll(gpa, data);
            defer gpa.free(frames);
            errdefer for (frames) |*frame| frame.deinit(gpa);
            try out.appendSlice(gpa, frames);
        },
        .raw => |raw| {
            var decoded = try image.Image.fromPixels(
                gpa,
                raw.width,
                raw.height,
                raw.pixels,
                raw.format,
            );
            errdefer decoded.deinit(gpa);
            try out.append(gpa, decoded);
        },
        .set => |members| {
            if (depth > 0) return;
            for (members) |member| {
                // One bad size should not lose the others.
                collect(gpa, member, out, depth + 1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
            }
        },
        // Nothing to decode: the platform resolves these itself. `path` is read
        // by the backend, which owns filesystem access.
        .named, .svg, .path => {},
    }
}

test "themedName and svgMarkup look through a set" {
    const members = [_]Icon{
        .{ .bytes = "png bytes" },
        .{ .named = "applications-system" },
        .{ .svg = "<svg/>" },
    };
    const set: Icon = .{ .set = &members };

    try std.testing.expectEqualStrings("applications-system", set.themedName().?);
    try std.testing.expectEqualStrings("<svg/>", set.svgMarkup().?);
    try std.testing.expectEqualStrings("png bytes", set.encodedBytes().?);

    const plain: Icon = .{ .bytes = "x" };
    try std.testing.expect(plain.themedName() == null);
    try std.testing.expect(plain.svgMarkup() == null);
}

test "decodeAll returns every size, largest first" {
    const gpa = std.testing.allocator;

    const small = try image.png.testImage(gpa, 2, 2, &@as([16]u8, @splat(0x22)));
    defer gpa.free(small);
    const large = try image.png.testImage(gpa, 8, 8, &@as([256]u8, @splat(0x33)));
    defer gpa.free(large);

    const members = [_]Icon{ .{ .bytes = small }, .{ .bytes = large } };
    const frames = try decodeAll(gpa, .{ .set = &members });
    defer image.freeAll(gpa, frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(@as(u32, 8), frames[0].width);
    try std.testing.expectEqual(@as(u32, 2), frames[1].width);
}

test "raw pixels need no decoder" {
    const gpa = std.testing.allocator;

    const pixels = [_]u8{ 1, 2, 3, 4 };
    const frames = try decodeAll(gpa, .{ .raw = .{
        .width = 1,
        .height = 1,
        .pixels = &pixels,
        .format = .rgba32,
    } });
    defer image.freeAll(gpa, frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualSlices(u8, &.{ 4, 1, 2, 3 }, frames[0].argb);
}

test "names and SVG decode to nothing, and a bad member is skipped" {
    const gpa = std.testing.allocator;

    for ([_]Icon{ .{ .named = "x" }, .{ .svg = "<svg/>" }, .{ .path = "/tmp/x.png" } }) |icon| {
        const frames = try decodeAll(gpa, icon);
        defer image.freeAll(gpa, frames);
        try std.testing.expectEqual(@as(usize, 0), frames.len);
    }

    const good = try image.png.testImage(gpa, 1, 1, &.{ 9, 9, 9, 9 });
    defer gpa.free(good);
    const members = [_]Icon{ .{ .bytes = "not an image" }, .{ .bytes = good } };
    const frames = try decodeAll(gpa, .{ .set = &members });
    defer image.freeAll(gpa, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
}

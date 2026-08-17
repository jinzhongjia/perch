//! Decoding tray and menu icons into pixels every backend can consume.
//!
//! Everything lands in ARGB32 with the alpha byte first, which is what
//! `StatusNotifierItem.IconPixmap` wants on the wire and what Windows `HICON`
//! and macOS `NSBitmapImageRep` are cheapest to build from.
//!
//! SVG is deliberately absent: it is handed to the platform to render at the
//! size it actually needs, rather than rasterised here at a guessed size.

const std = @import("std");

pub const png = @import("image/png.zig");
pub const bmp = @import("image/bmp.zig");
pub const ico = @import("image/ico.zig");

pub const Error = error{
    /// The bytes do not start with any magic number we recognise.
    UnknownFormat,
    /// A well-formed image using a feature this decoder does not implement.
    Unsupported,
    Corrupt,
    OutOfMemory,
};

/// Byte order of caller-supplied pixels.
pub const PixelFormat = enum {
    /// A, R, G, B — what backends want, and what decoders produce.
    argb32,
    /// R, G, B, A — the common in-memory layout elsewhere.
    rgba32,
    /// B, G, R, A — little-endian 0xAARRGGBB, as Windows and Cairo store it.
    bgra32,
};

/// Decoded pixels, four bytes each, alpha first.
pub const Image = struct {
    width: u32,
    height: u32,
    /// Owned by whoever allocated the image.
    argb: []u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.argb);
        self.* = undefined;
    }

    /// The longer edge, which is what hosts sort candidate sizes by.
    pub fn extent(self: Image) u32 {
        return @max(self.width, self.height);
    }

    /// Copies caller-supplied pixels, converting to ARGB32.
    pub fn fromPixels(
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
        pixels: []const u8,
        format: PixelFormat,
    ) Error!Image {
        const count = std.math.mul(usize, width, height) catch return error.Corrupt;
        if (count == 0 or pixels.len < count * 4) return error.Corrupt;

        const argb = try gpa.alloc(u8, count * 4);
        errdefer gpa.free(argb);

        for (0..count) |i| {
            const in = pixels[i * 4 ..][0..4];
            const out = argb[i * 4 ..][0..4];
            switch (format) {
                .argb32 => out.* = in.*,
                .rgba32 => out.* = .{ in[3], in[0], in[1], in[2] },
                .bgra32 => out.* = .{ in[3], in[2], in[1], in[0] },
            }
        }
        return .{ .width = width, .height = height, .argb = argb };
    }
};

pub const Format = enum { png, bmp, ico, svg, unknown };

/// Identifies a format from its leading bytes. SVG is matched loosely, since it
/// is text and may start with a comment, a doctype or the XML declaration.
pub fn sniff(bytes: []const u8) Format {
    if (std.mem.startsWith(u8, bytes, &png.signature)) return .png;
    if (std.mem.startsWith(u8, bytes, "BM")) return .bmp;
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], &[_]u8{ 0, 0, 1, 0 })) return .ico;

    const head = bytes[0..@min(bytes.len, 512)];
    const trimmed = std.mem.trimStart(u8, head, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "<?xml") or
        std.mem.startsWith(u8, trimmed, "<svg") or
        std.mem.startsWith(u8, trimmed, "<!--") or
        std.mem.startsWith(u8, trimmed, "<!DOCTYPE svg"))
    {
        if (std.mem.indexOf(u8, head, "<svg") != null) return .svg;
    }
    return .unknown;
}

/// Decodes a single image, picking the largest frame when the format is a
/// container.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
    return switch (sniff(bytes)) {
        .png => png.decode(gpa, bytes),
        .bmp => bmp.decode(gpa, bytes),
        .ico => ico.decodeLargest(gpa, bytes),
        // Rasterising SVG at a size nobody asked for is worse than refusing.
        .svg => error.Unsupported,
        .unknown => error.UnknownFormat,
    };
}

/// Decodes every frame the bytes carry, largest first, so a single `.ico` gives
/// a host all the sizes it needs for HiDPI. Single-frame formats yield one
/// image. The caller owns both the slice and the images.
pub fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8) Error![]Image {
    if (sniff(bytes) == .ico) return ico.decodeAll(gpa, bytes);

    var image = try decode(gpa, bytes);
    errdefer image.deinit(gpa);

    const out = try gpa.alloc(Image, 1);
    out[0] = image;
    return out;
}

/// Frees a list from `decodeAll`.
pub fn freeAll(gpa: std.mem.Allocator, images: []Image) void {
    for (images) |*image| image.deinit(gpa);
    gpa.free(images);
}

/// Orders images largest first, which is the order hosts prefer to receive.
pub fn byDescendingSize(_: void, a: Image, b: Image) bool {
    return a.extent() > b.extent();
}

test "sniff recognises the formats we decode" {
    try std.testing.expectEqual(Format.png, sniff(&png.signature));
    try std.testing.expectEqual(Format.bmp, sniff("BM\x00\x00"));
    try std.testing.expectEqual(Format.ico, sniff(&[_]u8{ 0, 0, 1, 0, 1, 0 }));
    try std.testing.expectEqual(Format.svg, sniff("<svg xmlns=\"http://www.w3.org/2000/svg\"/>"));
    try std.testing.expectEqual(
        Format.svg,
        sniff("<?xml version=\"1.0\"?>\n<svg width=\"16\" height=\"16\"></svg>"),
    );
    try std.testing.expectEqual(Format.unknown, sniff("GIF89a"));
    try std.testing.expectEqual(Format.unknown, sniff(""));
    // XML that is not SVG must not be mistaken for one.
    try std.testing.expectEqual(Format.unknown, sniff("<?xml version=\"1.0\"?><rss></rss>"));
}

test "fromPixels converts the common layouts" {
    const gpa = std.testing.allocator;

    var argb = try Image.fromPixels(gpa, 1, 1, &.{ 1, 2, 3, 4 }, .argb32);
    defer argb.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, argb.argb);

    var rgba = try Image.fromPixels(gpa, 1, 1, &.{ 1, 2, 3, 4 }, .rgba32);
    defer rgba.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 4, 1, 2, 3 }, rgba.argb);

    var bgra = try Image.fromPixels(gpa, 1, 1, &.{ 1, 2, 3, 4 }, .bgra32);
    defer bgra.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, bgra.argb);

    try std.testing.expectError(
        error.Corrupt,
        Image.fromPixels(gpa, 2, 2, &.{ 1, 2, 3, 4 }, .argb32),
    );
}

test "decodeAll yields one frame for single-frame formats" {
    const gpa = std.testing.allocator;

    const data = try png.testImage(gpa, 2, 1, &.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    defer gpa.free(data);

    const frames = try decodeAll(gpa, data);
    defer freeAll(gpa, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqual(@as(u32, 2), frames[0].width);
}

test "unknown and SVG bytes are refused with distinct errors" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownFormat, decode(gpa, "not an image"));
    try std.testing.expectError(error.Unsupported, decode(gpa, "<svg/>"));
}

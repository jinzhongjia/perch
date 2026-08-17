//! PNG decoding.
//!
//! Supported: 8- and 16-bit depths, greyscale, RGB, palette and alpha variants,
//! non-interlaced. Adam7 interlacing is rejected rather than guessed at.

const std = @import("std");
const flate = std.compress.flate;

const image = @import("../image.zig");
const Error = image.Error;
const Image = image.Image;

pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

const ColorType = enum(u8) {
    grey = 0,
    rgb = 2,
    palette = 3,
    grey_alpha = 4,
    rgba = 6,

    fn channels(self: ColorType) u8 {
        return switch (self) {
            .grey, .palette => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: ColorType,
    interlaced: bool,

    /// Bytes per pixel in the filtered scanline data, rounded up.
    fn bytesPerPixel(self: Header) usize {
        const bits = @as(usize, self.color.channels()) * self.depth;
        return (bits + 7) / 8;
    }

    fn bytesPerRow(self: Header) usize {
        const bits = @as(usize, self.color.channels()) * self.depth * self.width;
        return (bits + 7) / 8;
    }
};

/// Decodes `data` into ARGB32. The caller owns the returned image.
pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Image {
    if (data.len < signature.len or !std.mem.eql(u8, data[0..signature.len], &signature)) {
        return error.UnknownFormat;
    }

    var header: ?Header = null;
    var palette: []const u8 = &.{};
    var palette_alpha: []const u8 = &.{};

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var pos: usize = signature.len;
    while (pos + 8 <= data.len) {
        const length = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 ..][0..4];
        const body_start = pos + 8;
        if (length > data.len or body_start + length + 4 > data.len) return error.Corrupt;
        const body = data[body_start..][0..length];

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (length < 13) return error.Corrupt;
            const color_raw = body[9];
            const color = std.enums.fromInt(ColorType, color_raw) orelse return error.Corrupt;
            const depth = body[8];
            switch (depth) {
                1, 2, 4 => if (color != .palette) return error.Unsupported,
                8, 16 => {},
                else => return error.Corrupt,
            }
            if (body[10] != 0 or body[11] != 0) return error.Unsupported; // compression, filter method
            header = .{
                .width = std.mem.readInt(u32, body[0..4], .big),
                .height = std.mem.readInt(u32, body[4..8], .big),
                .depth = depth,
                .color = color,
                .interlaced = body[12] != 0,
            };
            if (header.?.width == 0 or header.?.height == 0) return error.Corrupt;
            if (header.?.interlaced) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = body;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            palette_alpha = body;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }

        pos = body_start + length + 4; // skip the CRC
    }

    const ihdr = header orelse return error.Corrupt;
    if (idat.items.len == 0) return error.Corrupt;
    if (ihdr.color == .palette and palette.len == 0) return error.Corrupt;
    // Guard against a header that claims an implausible allocation.
    const pixels = std.math.mul(u64, ihdr.width, ihdr.height) catch return error.Corrupt;
    if (pixels > 64 * 1024 * 1024) return error.Unsupported;

    const raw = try inflate(gpa, idat.items, ihdr);
    defer gpa.free(raw);

    try unfilter(raw, ihdr);
    return convert(gpa, raw, ihdr, palette, palette_alpha);
}

/// Inflates the concatenated IDAT stream into exactly the expected size:
/// one filter byte plus one row of samples, per row.
fn inflate(gpa: std.mem.Allocator, compressed: []const u8, header: Header) Error![]u8 {
    const row_len = header.bytesPerRow() + 1;
    const total = std.math.mul(usize, row_len, header.height) catch return error.Corrupt;

    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);

    var input: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &window);
    decompress.reader.readSliceAll(out) catch return error.Corrupt;
    return out;
}

/// Reverses the per-scanline filters in place.
fn unfilter(raw: []u8, header: Header) Error!void {
    const bpp = header.bytesPerPixel();
    const row_len = header.bytesPerRow();
    const stride = row_len + 1;

    var row: usize = 0;
    while (row < header.height) : (row += 1) {
        const filter = raw[row * stride];
        const line = raw[row * stride + 1 ..][0..row_len];
        const previous: ?[]const u8 = if (row == 0) null else raw[(row - 1) * stride + 1 ..][0..row_len];

        switch (filter) {
            0 => {},
            1 => for (bpp..row_len) |i| {
                line[i] = line[i] +% line[i - bpp];
            },
            2 => if (previous) |up| {
                for (0..row_len) |i| line[i] = line[i] +% up[i];
            },
            3 => for (0..row_len) |i| {
                const left: u32 = if (i >= bpp) line[i - bpp] else 0;
                const up: u32 = if (previous) |p| p[i] else 0;
                line[i] = line[i] +% @as(u8, @truncate((left + up) / 2));
            },
            4 => for (0..row_len) |i| {
                const left: i32 = if (i >= bpp) line[i - bpp] else 0;
                const up: i32 = if (previous) |p| p[i] else 0;
                const up_left: i32 = if (previous != null and i >= bpp) previous.?[i - bpp] else 0;
                line[i] = line[i] +% @as(u8, @intCast(paeth(left, up, up_left)));
            },
            else => return error.Corrupt,
        }
    }
}

fn paeth(left: i32, up: i32, up_left: i32) i32 {
    const estimate = left + up - up_left;
    const d_left = @abs(estimate - left);
    const d_up = @abs(estimate - up);
    const d_up_left = @abs(estimate - up_left);
    if (d_left <= d_up and d_left <= d_up_left) return left;
    if (d_up <= d_up_left) return up;
    return up_left;
}

fn convert(
    gpa: std.mem.Allocator,
    raw: []const u8,
    header: Header,
    palette: []const u8,
    palette_alpha: []const u8,
) Error!Image {
    const out = try gpa.alloc(u8, @as(usize, header.width) * header.height * 4);
    errdefer gpa.free(out);

    const stride = header.bytesPerRow() + 1;
    // 16-bit samples are truncated to their high byte; the tray is 22 px wide.
    const sample_step: usize = if (header.depth == 16) 2 else 1;

    var row: usize = 0;
    while (row < header.height) : (row += 1) {
        const line = raw[row * stride + 1 ..][0..header.bytesPerRow()];
        var column: usize = 0;
        while (column < header.width) : (column += 1) {
            const out_at = (row * header.width + column) * 4;
            var a: u8 = 0xff;
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;

            switch (header.color) {
                .palette => {
                    const index = paletteIndex(line, column, header.depth);
                    const at = @as(usize, index) * 3;
                    if (at + 2 >= palette.len) return error.Corrupt;
                    r = palette[at];
                    g = palette[at + 1];
                    b = palette[at + 2];
                    if (index < palette_alpha.len) a = palette_alpha[index];
                },
                .grey => {
                    const at = column * sample_step;
                    r = line[at];
                    g = r;
                    b = r;
                },
                .grey_alpha => {
                    const at = column * 2 * sample_step;
                    r = line[at];
                    g = r;
                    b = r;
                    a = line[at + sample_step];
                },
                .rgb => {
                    const at = column * 3 * sample_step;
                    r = line[at];
                    g = line[at + sample_step];
                    b = line[at + 2 * sample_step];
                },
                .rgba => {
                    const at = column * 4 * sample_step;
                    r = line[at];
                    g = line[at + sample_step];
                    b = line[at + 2 * sample_step];
                    a = line[at + 3 * sample_step];
                },
            }

            // Network byte order: the alpha byte comes first.
            out[out_at] = a;
            out[out_at + 1] = r;
            out[out_at + 2] = g;
            out[out_at + 3] = b;
        }
    }

    return .{ .width = header.width, .height = header.height, .argb = out };
}

/// Palette images pack 1, 2, 4 or 8 bit indices, most significant bits first.
fn paletteIndex(line: []const u8, column: usize, depth: u8) u8 {
    return switch (depth) {
        8 => line[column],
        4 => if (column % 2 == 0) line[column / 2] >> 4 else line[column / 2] & 0x0f,
        2 => @truncate((line[column / 4] >> @intCast(6 - 2 * (column % 4))) & 0x03),
        1 => @truncate((line[column / 8] >> @intCast(7 - (column % 8))) & 0x01),
        else => unreachable,
    };
}

// -- tests ------------------------------------------------------------------

/// Builds an RGBA8 PNG from raw pixels, for tests elsewhere in the tree that
/// need a valid image without carrying a fixture file.
pub fn testImage(
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    rgba: []const u8,
) ![]u8 {
    const row_len = width * 4;
    std.debug.assert(rgba.len == row_len * height);

    var scanlines: std.ArrayList(u8) = .empty;
    defer scanlines.deinit(gpa);
    for (0..height) |row| {
        try scanlines.append(gpa, 0); // filter: none
        try scanlines.appendSlice(gpa, rgba[row * row_len ..][0..row_len]);
    }
    return buildPng(gpa, width, height, .rgba, 8, scanlines.items, &.{});
}

/// Builds a PNG in memory so the tests do not need fixture files.
fn buildPng(
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    color: ColorType,
    depth: u8,
    scanlines: []const u8,
    extra_chunks: []const struct { kind: *const [4]u8, body: []const u8 },
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = depth;
    ihdr[9] = @intFromEnum(color);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &out, "IHDR", &ihdr);

    for (extra_chunks) |chunk| try appendChunk(gpa, &out, chunk.kind, chunk.body);

    // zlib-wrapped stored deflate blocks, so the test needs no compressor.
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    try idat.appendSlice(gpa, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < scanlines.len) {
        const chunk_len: u16 = @intCast(@min(scanlines.len - offset, 0xffff));
        const final: u8 = if (offset + chunk_len >= scanlines.len) 1 else 0;
        try idat.append(gpa, final);
        try idat.append(gpa, @truncate(chunk_len));
        try idat.append(gpa, @truncate(chunk_len >> 8));
        try idat.append(gpa, @truncate(~chunk_len));
        try idat.append(gpa, @truncate(~chunk_len >> 8));
        try idat.appendSlice(gpa, scanlines[offset..][0..chunk_len]);
        offset += chunk_len;
    }
    const adler = std.hash.Adler32.hash(scanlines);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler, .big);
    try idat.appendSlice(gpa, &adler_bytes);

    try appendChunk(gpa, &out, "IDAT", idat.items);
    try appendChunk(gpa, &out, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn appendChunk(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: *const [4]u8,
    body: []const u8,
) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(body.len), .big);
    try out.appendSlice(gpa, &length);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

test "rgba decodes to ARGB in network order" {
    const gpa = std.testing.allocator;

    // 2x1, filter 0, then two RGBA pixels.
    const scanlines = [_]u8{ 0, 0x11, 0x22, 0x33, 0x44, 0xaa, 0xbb, 0xcc, 0xdd };
    const data = try buildPng(gpa, 2, 1, .rgba, 8, &scanlines, &.{});
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqualSlices(u8, &.{
        0x44, 0x11, 0x22, 0x33,
        0xdd, 0xaa, 0xbb, 0xcc,
    }, decoded.argb);
}

test "rgb gets an opaque alpha channel" {
    const gpa = std.testing.allocator;

    const scanlines = [_]u8{ 0, 1, 2, 3 };
    const data = try buildPng(gpa, 1, 1, .rgb, 8, &scanlines, &.{});
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 1, 2, 3 }, decoded.argb);
}

test "the Sub filter is reversed" {
    const gpa = std.testing.allocator;

    // Filter 1 (Sub) on a 3-pixel RGB row: each pixel adds the one to its left.
    const scanlines = [_]u8{ 1, 10, 20, 30, 1, 1, 1, 2, 2, 2 };
    const data = try buildPng(gpa, 3, 1, .rgb, 8, &scanlines, &.{});
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 10, 20, 30,
        0xff, 11, 21, 31,
        0xff, 13, 23, 33,
    }, decoded.argb);
}

test "the Up filter reads the previous row" {
    const gpa = std.testing.allocator;

    const scanlines = [_]u8{
        0, 5, 5, 5, // row 0, no filter
        2, 10, 10, 10, // row 1, Up
    };
    const data = try buildPng(gpa, 1, 2, .rgb, 8, &scanlines, &.{});
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 5,  5,  5,
        0xff, 15, 15, 15,
    }, decoded.argb);
}

test "palette images resolve through PLTE and tRNS" {
    const gpa = std.testing.allocator;

    const palette = [_]u8{ 255, 0, 0, 0, 255, 0 };
    const alpha = [_]u8{ 0x80, 0xff };
    const scanlines = [_]u8{ 0, 0, 1 };
    const data = try buildPng(gpa, 2, 1, .palette, 8, &scanlines, &.{
        .{ .kind = "PLTE", .body = &palette },
        .{ .kind = "tRNS", .body = &alpha },
    });
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{
        0x80, 255, 0,   0,
        0xff, 0,   255, 0,
    }, decoded.argb);
}

test "16-bit samples are truncated to 8" {
    const gpa = std.testing.allocator;

    // One 16-bit RGB pixel: 0x1234, 0x5678, 0x9abc.
    const scanlines = [_]u8{ 0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc };
    const data = try buildPng(gpa, 1, 1, .rgb, 16, &scanlines, &.{});
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x12, 0x56, 0x9a }, decoded.argb);
}

test "non-PNG input and interlacing are rejected" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.UnknownFormat, decode(gpa, "not a png at all"));
    try std.testing.expectError(error.UnknownFormat, decode(gpa, ""));

    const scanlines = [_]u8{ 0, 1, 2, 3 };
    const data = try buildPng(gpa, 1, 1, .rgb, 8, &scanlines, &.{});
    defer gpa.free(data);

    // Flip the interlace byte, the last of IHDR's 13 bytes.
    const interlace_at = signature.len + 8 + 12;
    data[interlace_at] = 1;
    try std.testing.expectError(error.Unsupported, decode(gpa, data));
}

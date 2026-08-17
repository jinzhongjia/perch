//! BMP/DIB decoding, both as standalone `.bmp` files and as the frames inside
//! an `.ico`.
//!
//! Supported: `BITMAPINFOHEADER` and later, 1/4/8-bit palette, 16-bit, 24-bit
//! and 32-bit, `BI_RGB` and `BI_BITFIELDS`, top-down and bottom-up. Not
//! supported: RLE compression, and the OS/2 `BITMAPCOREHEADER`.

const std = @import("std");

const image = @import("../image.zig");
const Error = image.Error;
const Image = image.Image;

/// `BITMAPFILEHEADER` is 14 bytes; everything after it is the DIB.
const file_header_len = 14;

const Compression = enum(u32) {
    rgb = 0,
    rle8 = 1,
    rle4 = 2,
    bitfields = 3,
    _,
};

const Info = struct {
    width: u32,
    height: u32,
    /// True when row 0 is the top row, which is how ICO frames are never stored
    /// but standalone BMPs sometimes are.
    top_down: bool,
    bpp: u16,
    compression: Compression,
    /// Palette entry count; 0 means "the maximum for this depth".
    palette_len: u32,
    header_len: u32,
    masks: ?Masks,

    /// Bytes per row, padded to a 4-byte boundary.
    fn stride(self: Info) usize {
        const bits = @as(usize, self.width) * self.bpp;
        return ((bits + 31) / 32) * 4;
    }

    fn paletteEntries(self: Info) u32 {
        if (self.palette_len != 0) return self.palette_len;
        return switch (self.bpp) {
            1 => 2,
            4 => 16,
            8 => 256,
            else => 0,
        };
    }
};

/// `BI_BITFIELDS` channel masks.
const Masks = struct { r: u32, g: u32, b: u32, a: u32 };

/// Decodes a standalone BMP file.
pub fn decode(gpa: std.mem.Allocator, data: []const u8) Error!Image {
    if (data.len < file_header_len + 4 or !std.mem.startsWith(u8, data, "BM")) {
        return error.UnknownFormat;
    }
    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const dib = data[file_header_len..];

    const info = try readInfo(dib);
    const palette = try readPalette(dib, info);

    // The file header says where the pixels start; trust it when it is sane.
    const pixels = if (pixel_offset >= file_header_len and pixel_offset < data.len)
        data[pixel_offset..]
    else
        dib[info.header_len + palette.len ..];

    return decodePixels(gpa, info, palette, pixels, null);
}

/// Decodes an ICO frame: a DIB with no file header, whose declared height covers
/// the colour rows and then a 1-bit AND mask.
pub fn decodeIcoFrame(gpa: std.mem.Allocator, dib: []const u8) Error!Image {
    var info = try readInfo(dib);
    // The stored height is doubled to account for the mask.
    if (info.height % 2 != 0) return error.Corrupt;
    info.height /= 2;
    if (info.height == 0) return error.Corrupt;

    const palette = try readPalette(dib, info);
    const body = dib[info.header_len + palette.len ..];

    const colour_len = info.stride() * info.height;
    if (body.len < colour_len) return error.Corrupt;

    // A 32-bit frame carries its own alpha, so the mask is redundant and often
    // wrong; only consult it for the shallower depths.
    const mask: ?[]const u8 = if (info.bpp == 32) null else mask: {
        const mask_stride = ((@as(usize, info.width) + 31) / 32) * 4;
        const needed = mask_stride * info.height;
        if (body.len < colour_len + needed) break :mask null;
        break :mask body[colour_len..][0..needed];
    };

    return decodePixels(gpa, info, palette, body[0..colour_len], mask);
}

fn readInfo(dib: []const u8) Error!Info {
    if (dib.len < 4) return error.Corrupt;
    const header_len = std.mem.readInt(u32, dib[0..4], .little);
    // 12 is BITMAPCOREHEADER, which uses a different layout entirely.
    if (header_len < 40 or header_len > dib.len) return error.Unsupported;

    const width_raw = std.mem.readInt(i32, dib[4..8], .little);
    const height_raw = std.mem.readInt(i32, dib[8..12], .little);
    if (width_raw <= 0 or height_raw == 0) return error.Corrupt;

    const bpp = std.mem.readInt(u16, dib[14..16], .little);
    switch (bpp) {
        1, 4, 8, 16, 24, 32 => {},
        else => return error.Unsupported,
    }

    const compression: Compression = @enumFromInt(std.mem.readInt(u32, dib[16..20], .little));
    switch (compression) {
        .rgb, .bitfields => {},
        else => return error.Unsupported,
    }

    var masks: ?Masks = null;
    if (compression == .bitfields) {
        // The masks always follow the 40-byte core of the header, whether the
        // header stops there or continues as V4/V5.
        const at: usize = 40;
        if (dib.len < at + 12) return error.Corrupt;
        masks = .{
            .r = std.mem.readInt(u32, dib[at..][0..4], .little),
            .g = std.mem.readInt(u32, dib[at + 4 ..][0..4], .little),
            .b = std.mem.readInt(u32, dib[at + 8 ..][0..4], .little),
            .a = if (header_len >= 56 and dib.len >= at + 16)
                std.mem.readInt(u32, dib[at + 12 ..][0..4], .little)
            else
                0,
        };
    }

    return .{
        .width = @intCast(width_raw),
        .height = @abs(height_raw),
        .top_down = height_raw < 0,
        .bpp = bpp,
        .compression = compression,
        .palette_len = std.mem.readInt(u32, dib[32..36], .little),
        .header_len = header_len,
        .masks = masks,
    };
}

/// The palette is BGRX quads directly after the header.
fn readPalette(dib: []const u8, info: Info) Error![]const u8 {
    const entries = info.paletteEntries();
    if (entries == 0) return &.{};
    const len = @as(usize, entries) * 4;
    if (dib.len < info.header_len + len) return error.Corrupt;
    return dib[info.header_len..][0..len];
}

fn decodePixels(
    gpa: std.mem.Allocator,
    info: Info,
    palette: []const u8,
    pixels: []const u8,
    and_mask: ?[]const u8,
) Error!Image {
    const count = std.math.mul(usize, info.width, info.height) catch return error.Corrupt;
    if (count > 64 * 1024 * 1024) return error.Unsupported;

    const stride = info.stride();
    if (pixels.len < stride * info.height) return error.Corrupt;

    const out = try gpa.alloc(u8, count * 4);
    errdefer gpa.free(out);

    const mask_stride = ((@as(usize, info.width) + 31) / 32) * 4;

    for (0..info.height) |row| {
        // Bottom-up rows are stored last-first.
        const source_row = if (info.top_down) row else info.height - 1 - row;
        const line = pixels[source_row * stride ..][0..stride];

        for (0..info.width) |column| {
            var a: u8 = 0xff;
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;

            switch (info.bpp) {
                1, 4, 8 => {
                    const index = paletteIndex(line, column, info.bpp);
                    const at = @as(usize, index) * 4;
                    if (at + 2 >= palette.len) return error.Corrupt;
                    b = palette[at];
                    g = palette[at + 1];
                    r = palette[at + 2];
                },
                16 => {
                    const value = std.mem.readInt(u16, line[column * 2 ..][0..2], .little);
                    if (info.masks) |m| {
                        r = extractChannel(value, m.r);
                        g = extractChannel(value, m.g);
                        b = extractChannel(value, m.b);
                        if (m.a != 0) a = extractChannel(value, m.a);
                    } else {
                        // Default 16-bit layout is X1R5G5B5.
                        r = expand5(@truncate((value >> 10) & 0x1f));
                        g = expand5(@truncate((value >> 5) & 0x1f));
                        b = expand5(@truncate(value & 0x1f));
                    }
                },
                24 => {
                    const at = column * 3;
                    b = line[at];
                    g = line[at + 1];
                    r = line[at + 2];
                },
                32 => {
                    const at = column * 4;
                    if (info.masks) |m| {
                        const value = std.mem.readInt(u32, line[at..][0..4], .little);
                        r = extractChannel(value, m.r);
                        g = extractChannel(value, m.g);
                        b = extractChannel(value, m.b);
                        a = if (m.a != 0) extractChannel(value, m.a) else 0xff;
                    } else {
                        b = line[at];
                        g = line[at + 1];
                        r = line[at + 2];
                        a = line[at + 3];
                    }
                },
                else => unreachable,
            }

            // A set mask bit means "transparent here".
            if (and_mask) |mask| {
                const bit_at = source_row * mask_stride + column / 8;
                if (bit_at < mask.len) {
                    const bit = (mask[bit_at] >> @intCast(7 - (column % 8))) & 1;
                    if (bit == 1) a = 0;
                }
            }

            const out_at = (row * info.width + column) * 4;
            out[out_at] = a;
            out[out_at + 1] = r;
            out[out_at + 2] = g;
            out[out_at + 3] = b;
        }
    }

    return .{ .width = info.width, .height = info.height, .argb = out };
}

/// Scales a masked channel up to eight bits.
fn extractChannel(value: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift = @ctz(mask);
    const width = @popCount(mask);
    const raw = (value & mask) >> @intCast(shift);
    if (width >= 8) return @truncate(raw >> @intCast(width - 8));
    // Replicate the high bits so full-scale input stays full-scale output.
    const max = (@as(u32, 1) << @intCast(width)) - 1;
    return @intCast(raw * 255 / max);
}

fn expand5(value: u5) u8 {
    return @intCast(@as(u32, value) * 255 / 31);
}

/// Palette indices are packed most significant bits first.
fn paletteIndex(line: []const u8, column: usize, bpp: u16) u8 {
    return switch (bpp) {
        8 => line[column],
        4 => if (column % 2 == 0) line[column / 2] >> 4 else line[column / 2] & 0x0f,
        1 => @truncate((line[column / 8] >> @intCast(7 - (column % 8))) & 1),
        else => unreachable,
    };
}

// -- tests ------------------------------------------------------------------

/// Assembles a BMP with a 40-byte header, for tests.
pub fn testImage(
    gpa: std.mem.Allocator,
    width: i32,
    height: i32,
    bpp: u16,
    palette: []const u8,
    rows: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const pixel_offset: u32 = @intCast(file_header_len + 40 + palette.len);
    try out.appendSlice(gpa, "BM");
    try appendInt(gpa, &out, u32, @intCast(pixel_offset + rows.len));
    try appendInt(gpa, &out, u32, 0); // reserved
    try appendInt(gpa, &out, u32, pixel_offset);

    try appendInt(gpa, &out, u32, 40);
    try appendInt(gpa, &out, i32, width);
    try appendInt(gpa, &out, i32, height);
    try appendInt(gpa, &out, u16, 1); // planes
    try appendInt(gpa, &out, u16, bpp);
    try appendInt(gpa, &out, u32, 0); // BI_RGB
    try appendInt(gpa, &out, u32, @intCast(rows.len));
    try appendInt(gpa, &out, u32, 0); // x pixels per metre
    try appendInt(gpa, &out, u32, 0); // y pixels per metre
    try appendInt(gpa, &out, u32, @intCast(palette.len / 4));
    try appendInt(gpa, &out, u32, 0); // important colours

    try out.appendSlice(gpa, palette);
    try out.appendSlice(gpa, rows);
    return out.toOwnedSlice(gpa);
}

fn appendInt(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime T: type,
    value: T,
) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try out.appendSlice(gpa, &buffer);
}

test "24-bit bottom-up rows are flipped" {
    const gpa = std.testing.allocator;

    // Two rows of one pixel, each padded to four bytes. Stored bottom-up, so
    // the first row in the file is the bottom of the picture.
    const rows = [_]u8{
        1, 2, 3, 0, // BGR = blue 1, green 2, red 3
        4, 5, 6, 0,
    };
    const data = try testImage(gpa, 1, 2, 24, &.{}, &rows);
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 1), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 6, 5, 4, // top row comes from the last stored row
        0xff, 3, 2, 1,
    }, decoded.argb);
}

test "top-down rows are kept in order" {
    const gpa = std.testing.allocator;

    const rows = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
    const data = try testImage(gpa, 1, -2, 24, &.{}, &rows);
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 3, 2, 1, 0xff, 6, 5, 4 }, decoded.argb);
}

test "32-bit keeps its alpha channel" {
    const gpa = std.testing.allocator;

    const rows = [_]u8{ 10, 20, 30, 40 }; // BGRA
    const data = try testImage(gpa, 1, 1, 32, &.{}, &rows);
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 40, 30, 20, 10 }, decoded.argb);
}

test "8-bit palette entries resolve" {
    const gpa = std.testing.allocator;

    // Two BGRX palette entries.
    const palette = [_]u8{ 255, 0, 0, 0, 0, 255, 0, 0 };
    const rows = [_]u8{ 0, 1, 0, 0 }; // two pixels, padded to four bytes
    const data = try testImage(gpa, 2, 1, 8, &palette, &rows);
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{
        0xff, 0, 0,   255,
        0xff, 0, 255, 0,
    }, decoded.argb);
}

test "1-bit and 4-bit indices unpack" {
    const gpa = std.testing.allocator;

    const palette = [_]u8{ 0, 0, 0, 0, 255, 255, 255, 0 };
    // 1bpp: bits 1,0,1,0 in the high nibble of the first byte.
    const one_bit = [_]u8{ 0b1010_0000, 0, 0, 0 };
    const data = try testImage(gpa, 4, 1, 1, &palette, &one_bit);
    defer gpa.free(data);

    var decoded = try decode(gpa, data);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 255), decoded.argb[1]); // index 1 = white
    try std.testing.expectEqual(@as(u8, 0), decoded.argb[5]); // index 0 = black

    const four_bit = [_]u8{ 0x10, 0, 0, 0 };
    const data4 = try testImage(gpa, 2, 1, 4, &palette, &four_bit);
    defer gpa.free(data4);

    var decoded4 = try decode(gpa, data4);
    defer decoded4.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 255), decoded4.argb[1]);
    try std.testing.expectEqual(@as(u8, 0), decoded4.argb[5]);
}

test "channel extraction scales to full range" {
    // A 5-bit channel at full scale must reach 255, not 248.
    try std.testing.expectEqual(@as(u8, 255), extractChannel(0x1f, 0x1f));
    try std.testing.expectEqual(@as(u8, 0), extractChannel(0, 0x1f));
    try std.testing.expectEqual(@as(u8, 255), extractChannel(0x00ff0000, 0x00ff0000));
    try std.testing.expectEqual(@as(u8, 0x12), extractChannel(0x12000000, 0xff000000));
}

test "unsupported compression and headers are rejected" {
    const gpa = std.testing.allocator;

    const rows = [_]u8{ 1, 2, 3, 0 };
    const data = try testImage(gpa, 1, 1, 24, &.{}, &rows);
    defer gpa.free(data);

    // Flip BI_RGB to BI_RLE8, at offset 14 + 16.
    data[file_header_len + 16] = 1;
    try std.testing.expectError(error.Unsupported, decode(gpa, data));

    try std.testing.expectError(error.UnknownFormat, decode(gpa, "not a bmp"));
}

//! ICO/CUR containers.
//!
//! An icon file holds several frames at different sizes, which is exactly what a
//! tray needs: hand every frame to the host and let it pick per display scale.
//! Each frame is either a PNG or a headerless DIB.

const std = @import("std");

const image = @import("../image.zig");
const bmp = @import("bmp.zig");
const png = @import("png.zig");
const Error = image.Error;
const Image = image.Image;

const dir_header_len = 6;
const dir_entry_len = 16;

/// The `ICONDIR` type field.
pub const Kind = enum(u16) { icon = 1, cursor = 2, _ };

pub const Entry = struct {
    /// 0 in the file means 256.
    width: u32,
    height: u32,
    offset: usize,
    len: usize,
};

/// Reads the directory without decoding any pixels.
pub fn entries(gpa: std.mem.Allocator, data: []const u8) Error![]Entry {
    if (data.len < dir_header_len) return error.UnknownFormat;
    if (std.mem.readInt(u16, data[0..2], .little) != 0) return error.UnknownFormat;
    const kind = std.mem.readInt(u16, data[2..4], .little);
    if (kind != @intFromEnum(Kind.icon) and kind != @intFromEnum(Kind.cursor)) {
        return error.UnknownFormat;
    }

    const count = std.mem.readInt(u16, data[4..6], .little);
    if (count == 0) return error.Corrupt;
    if (data.len < dir_header_len + @as(usize, count) * dir_entry_len) return error.Corrupt;

    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);

    for (0..count) |i| {
        const at = dir_header_len + i * dir_entry_len;
        const entry = data[at..][0..dir_entry_len];
        const offset = std.mem.readInt(u32, entry[12..16], .little);
        const len = std.mem.readInt(u32, entry[8..12], .little);
        // A frame pointing outside the file is a broken frame, not a broken
        // file: skip it and keep the rest.
        if (offset < dir_header_len or len == 0) continue;
        if (@as(usize, offset) + len > data.len) continue;

        try out.append(gpa, .{
            .width = if (entry[0] == 0) 256 else entry[0],
            .height = if (entry[1] == 0) 256 else entry[1],
            .offset = offset,
            .len = len,
        });
    }

    if (out.items.len == 0) return error.Corrupt;
    return out.toOwnedSlice(gpa);
}

/// Decodes one frame's bytes, which may be a PNG or a DIB.
pub fn decodeFrame(gpa: std.mem.Allocator, frame: []const u8) Error!Image {
    if (std.mem.startsWith(u8, frame, &png.signature)) return png.decode(gpa, frame);
    return bmp.decodeIcoFrame(gpa, frame);
}

/// Decodes every frame, largest first. Frames that fail to decode are skipped as
/// long as at least one succeeds, so one odd frame does not lose the icon.
pub fn decodeAll(gpa: std.mem.Allocator, data: []const u8) Error![]Image {
    const dir = try entries(gpa, data);
    defer gpa.free(dir);

    var out: std.ArrayList(Image) = .empty;
    errdefer {
        for (out.items) |*decoded| decoded.deinit(gpa);
        out.deinit(gpa);
    }

    for (dir) |entry| {
        var decoded = decodeFrame(gpa, data[entry.offset..][0..entry.len]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        errdefer decoded.deinit(gpa);
        try out.append(gpa, decoded);
    }

    if (out.items.len == 0) return error.Corrupt;
    const images = try out.toOwnedSlice(gpa);
    std.mem.sort(Image, images, {}, image.byDescendingSize);
    return images;
}

/// Decodes only the largest frame.
pub fn decodeLargest(gpa: std.mem.Allocator, data: []const u8) Error!Image {
    const dir = try entries(gpa, data);
    defer gpa.free(dir);

    // Try the biggest declared frame first, then fall back through the rest.
    const order = try gpa.dupe(Entry, dir);
    defer gpa.free(order);
    std.mem.sort(Entry, order, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return @max(a.width, a.height) > @max(b.width, b.height);
        }
    }.lessThan);

    for (order) |entry| {
        return decodeFrame(gpa, data[entry.offset..][0..entry.len]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
    }
    return error.Corrupt;
}

// -- tests ------------------------------------------------------------------

/// Assembles an ICO from already-encoded frames, for tests.
pub fn testImage(
    gpa: std.mem.Allocator,
    frames: []const struct { width: u8, height: u8, bytes: []const u8 },
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &.{ 0, 0, 1, 0 });
    try out.append(gpa, @intCast(frames.len));
    try out.append(gpa, 0);

    var offset: u32 = @intCast(dir_header_len + frames.len * dir_entry_len);
    for (frames) |frame| {
        var entry: [dir_entry_len]u8 = @splat(0);
        entry[0] = frame.width;
        entry[1] = frame.height;
        std.mem.writeInt(u32, entry[8..12], @intCast(frame.bytes.len), .little);
        std.mem.writeInt(u32, entry[12..16], offset, .little);
        try out.appendSlice(gpa, &entry);
        offset += @intCast(frame.bytes.len);
    }
    for (frames) |frame| try out.appendSlice(gpa, frame.bytes);
    return out.toOwnedSlice(gpa);
}

test "every PNG frame decodes, largest first" {
    const gpa = std.testing.allocator;

    const small = try png.testImage(gpa, 2, 2, &@as([16]u8, @splat(0x40)));
    defer gpa.free(small);
    const large = try png.testImage(gpa, 4, 4, &@as([64]u8, @splat(0x80)));
    defer gpa.free(large);

    // Deliberately out of order in the file.
    const data = try testImage(gpa, &.{
        .{ .width = 2, .height = 2, .bytes = small },
        .{ .width = 4, .height = 4, .bytes = large },
    });
    defer gpa.free(data);

    const frames = try decodeAll(gpa, data);
    defer image.freeAll(gpa, frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(@as(u32, 4), frames[0].width);
    try std.testing.expectEqual(@as(u32, 2), frames[1].width);

    var largest = try decodeLargest(gpa, data);
    defer largest.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4), largest.width);
}

test "a DIB frame uses its AND mask for transparency" {
    const gpa = std.testing.allocator;

    // A 2x2 24-bit frame: height is doubled to cover the mask.
    var dib: std.ArrayList(u8) = .empty;
    defer dib.deinit(gpa);
    try appendInt(gpa, &dib, u32, 40);
    try appendInt(gpa, &dib, i32, 2);
    try appendInt(gpa, &dib, i32, 4); // 2 colour rows + 2 mask rows
    try appendInt(gpa, &dib, u16, 1);
    try appendInt(gpa, &dib, u16, 24);
    try appendInt(gpa, &dib, u32, 0);
    try appendInt(gpa, &dib, u32, 0);
    try appendInt(gpa, &dib, u32, 0);
    try appendInt(gpa, &dib, u32, 0);
    try appendInt(gpa, &dib, u32, 0);
    try appendInt(gpa, &dib, u32, 0);

    // Colour rows, bottom-up, padded to four bytes.
    try dib.appendSlice(gpa, &.{ 1, 1, 1, 2, 2, 2, 0, 0 }); // bottom row
    try dib.appendSlice(gpa, &.{ 3, 3, 3, 4, 4, 4, 0, 0 }); // top row
    // Mask rows: the top-left pixel is transparent.
    try dib.appendSlice(gpa, &.{ 0b0000_0000, 0, 0, 0 }); // bottom row opaque
    try dib.appendSlice(gpa, &.{ 0b1000_0000, 0, 0, 0 }); // top row, first bit set

    const data = try testImage(gpa, &.{.{ .width = 2, .height = 2, .bytes = dib.items }});
    defer gpa.free(data);

    const frames = try decodeAll(gpa, data);
    defer image.freeAll(gpa, frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqual(@as(u32, 2), frames[0].width);
    try std.testing.expectEqual(@as(u32, 2), frames[0].height);
    // Top-left is masked out; its neighbour is not.
    try std.testing.expectEqual(@as(u8, 0), frames[0].argb[0]);
    try std.testing.expectEqual(@as(u8, 0xff), frames[0].argb[4]);
    try std.testing.expectEqual(@as(u8, 4), frames[0].argb[5]);
}

test "a broken frame does not lose the good ones" {
    const gpa = std.testing.allocator;

    const good = try png.testImage(gpa, 2, 2, &@as([16]u8, @splat(0x11)));
    defer gpa.free(good);

    const data = try testImage(gpa, &.{
        .{ .width = 8, .height = 8, .bytes = "garbage frame bytes" },
        .{ .width = 2, .height = 2, .bytes = good },
    });
    defer gpa.free(data);

    const frames = try decodeAll(gpa, data);
    defer image.freeAll(gpa, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqual(@as(u32, 2), frames[0].width);

    // The largest declared frame is the broken one, so this must fall back.
    var largest = try decodeLargest(gpa, data);
    defer largest.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), largest.width);
}

test "malformed containers are rejected" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.UnknownFormat, entries(gpa, "no"));
    try std.testing.expectError(error.UnknownFormat, entries(gpa, &.{ 0, 0, 9, 0, 1, 0 }));
    // Zero frames.
    try std.testing.expectError(error.Corrupt, entries(gpa, &.{ 0, 0, 1, 0, 0, 0 }));
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

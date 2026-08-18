//! Turning decoded pixels into `HICON`s.
//!
//! The shell wants one icon at the size the current DPI asks for, not a ladder
//! of sizes the way StatusNotifierItem does, so the closest frame is picked and
//! converted. Re-picking on a DPI change is why the icon is rebuilt whenever the
//! taskbar is.

const std = @import("std");

const image = @import("../image.zig");
const win32 = @import("win32.zig");

/// Picks the frame closest to `wanted`, preferring one at least that big so the
/// shell downscales instead of blowing a small icon up.
pub fn pickBest(images: []const image.Image, wanted: u32) ?image.Image {
    if (images.len == 0) return null;

    var best: ?image.Image = null;
    var best_score: u64 = std.math.maxInt(u64);
    for (images) |candidate| {
        const extent = candidate.extent();
        // Upscaling looks worse than downscaling, so it costs more.
        const score: u64 = if (extent >= wanted)
            @as(u64, extent - wanted)
        else
            @as(u64, wanted - extent) * 4;
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
    }
    return best;
}

/// Builds an `HICON` from ARGB32 pixels. The caller owns it and must call
/// `win32.DestroyIcon`.
pub fn create(frame: image.Image) ?win32.HICON {
    const width: i32 = @intCast(frame.width);
    const height: i32 = @intCast(frame.height);

    const info: win32.BITMAPINFO = .{
        .bmiHeader = .{
            .biSize = @sizeOf(win32.BITMAPINFOHEADER),
            .biWidth = width,
            // Negative height means the rows are stored top-down, matching how
            // every decoder here produces them.
            .biHeight = -height,
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = win32.BI_RGB,
            .biSizeImage = 0,
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        },
        .bmiColors = .{0},
    };

    var bits: ?*anyopaque = null;
    const colour = win32.CreateDIBSection(null, &info, win32.DIB_RGB_COLORS, &bits, null, 0) orelse
        return null;
    defer _ = win32.DeleteObject(colour);

    const pixels: [*]u8 = @ptrCast(bits orelse return null);
    const count = frame.width * frame.height;
    for (0..count) |i| {
        const argb = frame.argb[i * 4 ..][0..4];
        const out = pixels[i * 4 ..][0..4];
        // A 32-bit DIB is BGRA in memory, and icons take straight alpha.
        out[0] = argb[3]; // B
        out[1] = argb[2]; // G
        out[2] = argb[1]; // R
        out[3] = argb[0]; // A
    }

    // The mask is unused for a 32-bit icon but must exist. All-zero means
    // "opaque everywhere", leaving transparency to the alpha channel.
    const mask_stride = ((frame.width + 15) / 16) * 2;
    const mask_bytes = mask_stride * frame.height;
    const mask_data = std.heap.page_allocator.alloc(u8, mask_bytes) catch return null;
    defer std.heap.page_allocator.free(mask_data);
    @memset(mask_data, 0);

    const mask = win32.CreateBitmap(width, height, 1, 1, mask_data.ptr) orelse return null;
    defer _ = win32.DeleteObject(mask);

    var icon_info: win32.ICONINFO = .{
        .fIcon = win32.BOOL.TRUE,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask,
        .hbmColor = colour,
    };
    return win32.CreateIconIndirect(&icon_info);
}

test "pickBest prefers the smallest frame that is big enough" {
    const gpa = std.testing.allocator;

    var frames: [3]image.Image = undefined;
    const sizes = [_]u32{ 32, 16, 64 };
    for (&frames, sizes) |*frame, size| {
        frame.* = .{
            .width = size,
            .height = size,
            .argb = try gpa.alloc(u8, size * size * 4),
        };
    }
    defer for (&frames) |*frame| frame.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 16), pickBest(&frames, 16).?.width);
    try std.testing.expectEqual(@as(u32, 32), pickBest(&frames, 20).?.width);
    try std.testing.expectEqual(@as(u32, 32), pickBest(&frames, 32).?.width);
    try std.testing.expectEqual(@as(u32, 64), pickBest(&frames, 48).?.width);
    // Nothing is big enough, so the largest wins.
    try std.testing.expectEqual(@as(u32, 64), pickBest(&frames, 256).?.width);
    try std.testing.expect(pickBest(&.{}, 16) == null);
}

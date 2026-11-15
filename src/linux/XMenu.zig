//! The popup menu for the XEmbed fallback. The system tray protocol has no
//! menu of its own, so perch draws one: an override-redirect window per level,
//! a monospace core font, and pointer handling for hover, cascade and choose.
//!
//! Layout is a pure function of the menu and the font metrics, so tests and
//! the drawing code agree on where every row is.

const std = @import("std");

const menu_mod = @import("../menu.zig");
const Menu = menu_mod.Menu;
const MenuItem = menu_mod.MenuItem;
const X11 = @import("X11.zig");

/// Tried in order; the first that opens is used. The ISO 10646 encodings give
/// labels the whole BMP, `fixed` is the alias every server ships.
pub const font_names = [_][]const u8{
    "-misc-fixed-medium-r-semicondensed--13-*-*-*-*-*-iso10646-1",
    "-misc-fixed-medium-r-normal--13-*-*-*-*-*-iso10646-1",
    "fixed",
};

/// Metrics for a missing font: rows keep a usable height, and text is skipped.
pub const fallback_metrics: X11.FontMetrics = .{ .ascent = 10, .descent = 3, .char_width = 6 };

pub const check_column = 22;
pub const arrow_column = 18;
pub const text_padding = 8;
pub const accelerator_gap = 24;
pub const separator_height = 7;
pub const min_width = 120;
/// Longer labels are cut, since `ImageText16` draws at most 255 characters.
pub const max_label_chars = 80;

pub const Row = struct {
    item: *MenuItem,
    y: i16,
    height: u16,

    /// Whether choosing this row should activate it.
    pub fn actionable(self: Row) bool {
        return self.item.enabled and switch (self.item.kind) {
            .separator, .submenu => false,
            else => true,
        };
    }

    pub fn contains(self: Row, y: i32) bool {
        return y >= self.y and y < @as(i32, self.y) + self.height;
    }
};

pub const Layout = struct {
    rows: []Row,
    width: u16,
    height: u16,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.rows);
        self.* = undefined;
    }

    /// The row under a point in window coordinates.
    pub fn rowAt(self: Layout, x: i32, y: i32) ?usize {
        if (x < 0 or x >= self.width) return null;
        for (self.rows, 0..) |row, i| {
            if (row.contains(y)) return i;
        }
        return null;
    }

    /// The vertical centre of the row showing `id`, for tests that click it.
    pub fn centreOf(self: Layout, id: MenuItem.Id) ?i16 {
        for (self.rows) |row| {
            if (row.item.id == id) return row.y + @as(i16, @intCast(row.height / 2));
        }
        return null;
    }
};

pub fn itemHeight(metrics: X11.FontMetrics) u16 {
    return @intCast(@max(20, metrics.ascent + metrics.descent + 8));
}

/// Rows for the visible items of `menu`, top to bottom. Hidden items take no
/// space, and separators next to nothing are kept: the menu is the caller's.
pub fn layout(gpa: std.mem.Allocator, menu: *Menu, metrics: X11.FontMetrics) std.mem.Allocator.Error!Layout {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);

    const char_width: u32 = @intCast(@max(1, metrics.char_width));
    var label_chars: usize = 0;
    var accelerator_chars: usize = 0;
    var y: i16 = 2;
    for (menu.items.items) |*item| {
        if (!item.visible) continue;
        const height: u16 = if (item.kind == .separator) separator_height else itemHeight(metrics);
        try rows.append(gpa, .{ .item = item, .y = y, .height = height });
        y += @intCast(height);
        label_chars = @max(label_chars, @min(X11.charCount(item.label), max_label_chars));
        if (item.accelerator) |accelerator| accelerator_chars = @max(accelerator_chars, X11.charCount(accelerator));
    }

    var width: u32 = check_column + text_padding + @as(u32, @intCast(label_chars)) * char_width + arrow_column;
    if (accelerator_chars > 0) width += accelerator_gap + @as(u32, @intCast(accelerator_chars)) * char_width;
    return .{
        .rows = try rows.toOwnedSlice(gpa),
        .width = @intCast(@min(@max(width, min_width), std.math.maxInt(i16))),
        .height = @intCast(@max(y + 2, 8)),
    };
}

/// Where a popup of `size` goes so it stays on a `screen_w` by `screen_h`
/// screen: at the anchor if it fits, otherwise flipped or pushed back inside.
/// `flip_x` is where it lands when flipped horizontally (a submenu opens to the
/// left of its parent).
pub fn place(anchor_x: i32, anchor_y: i32, flip_x: i32, width: u16, height: u16, screen_w: u16, screen_h: u16) [2]i16 {
    var x = anchor_x;
    var y = anchor_y;
    if (x + width > screen_w) x = flip_x - width;
    if (y + height > screen_h) y = anchor_y - height;
    x = std.math.clamp(x, 0, @max(0, @as(i32, screen_w) - width));
    y = std.math.clamp(y, 0, @max(0, @as(i32, screen_h) - height));
    return .{ @intCast(x), @intCast(y) };
}

pub const Palette = struct {
    background: u32,
    text: u32,
    disabled: u32,
    highlight: u32,
    highlight_text: u32,
    separator: u32,

    pub fn forVisual(rgb: bool, white: u32, black: u32) Palette {
        if (rgb) return .{
            .background = 0xf4f4f4,
            .text = 0x1e1e1e,
            .disabled = 0x9a9a9a,
            .highlight = 0x3d6fc9,
            .highlight_text = 0xffffff,
            .separator = 0xc8c8c8,
        };
        // An indexed or odd visual: only black and white are safe to assume.
        return .{
            .background = white,
            .text = black,
            .disabled = black,
            .highlight = black,
            .highlight_text = white,
            .separator = black,
        };
    }
};

/// Paints a whole popup. `gc` must carry the font when `has_font` is set.
pub fn draw(
    x: *X11,
    window: X11.Window,
    gc: u32,
    menu_layout: Layout,
    highlighted: ?usize,
    metrics: X11.FontMetrics,
    has_font: bool,
    palette: Palette,
) X11.Error!void {
    try x.changeGc(gc, .{ .foreground = palette.background });
    try x.fillRectangles(window, gc, &.{.{ .x = 0, .y = 0, .width = menu_layout.width, .height = menu_layout.height }});
    // A one-pixel frame, so the popup reads against any wallpaper.
    try x.changeGc(gc, .{ .foreground = palette.separator });
    try x.fillRectangles(window, gc, &.{
        .{ .x = 0, .y = 0, .width = menu_layout.width, .height = 1 },
        .{ .x = 0, .y = @intCast(menu_layout.height - 1), .width = menu_layout.width, .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = menu_layout.height },
        .{ .x = @intCast(menu_layout.width - 1), .y = 0, .width = 1, .height = menu_layout.height },
    });

    for (menu_layout.rows, 0..) |row, i| {
        try drawRow(x, window, gc, menu_layout, row, highlighted == i, metrics, has_font, palette);
    }
}

fn drawRow(
    x: *X11,
    window: X11.Window,
    gc: u32,
    menu_layout: Layout,
    row: Row,
    lit: bool,
    metrics: X11.FontMetrics,
    has_font: bool,
    palette: Palette,
) X11.Error!void {
    const item = row.item;
    const inner_width = menu_layout.width - 2;
    if (item.kind == .separator) {
        try x.changeGc(gc, .{ .foreground = palette.separator });
        try x.fillRectangles(window, gc, &.{.{ .x = 6, .y = row.y + separator_height / 2, .width = inner_width - 10, .height = 1 }});
        return;
    }

    const lit_row = lit and item.enabled;
    const background = if (lit_row) palette.highlight else palette.background;
    const foreground = if (!item.enabled) palette.disabled else if (lit_row) palette.highlight_text else palette.text;
    try x.changeGc(gc, .{ .foreground = background });
    try x.fillRectangles(window, gc, &.{.{ .x = 1, .y = row.y, .width = inner_width, .height = row.height }});

    const centre: i16 = row.y + @as(i16, @intCast(row.height / 2));
    try x.changeGc(gc, .{ .foreground = foreground });
    // Marks are drawn as shapes, so they do not depend on the font's coverage.
    if ((item.kind == .checkbox or item.kind == .radio) and item.checked) {
        const marks: []const X11.Rectangle = if (item.kind == .checkbox) &.{
            .{ .x = 7, .y = centre - 1, .width = 3, .height = 3 },
            .{ .x = 9, .y = centre + 1, .width = 3, .height = 2 },
            .{ .x = 11, .y = centre - 1, .width = 2, .height = 2 },
            .{ .x = 12, .y = centre - 3, .width = 2, .height = 2 },
            .{ .x = 13, .y = centre - 5, .width = 2, .height = 2 },
        } else &.{
            .{ .x = 9, .y = centre - 3, .width = 4, .height = 6 },
            .{ .x = 8, .y = centre - 2, .width = 6, .height = 4 },
        };
        try x.fillRectangles(window, gc, marks);
    } else if (item.kind == .checkbox or item.kind == .radio) {
        // An empty box or ring hints that the row toggles.
        try x.fillRectangles(window, gc, &.{
            .{ .x = 7, .y = centre - 4, .width = 8, .height = 1 },
            .{ .x = 7, .y = centre + 3, .width = 8, .height = 1 },
            .{ .x = 7, .y = centre - 4, .width = 1, .height = 8 },
            .{ .x = 14, .y = centre - 4, .width = 1, .height = 8 },
        });
    }
    if (item.kind == .submenu) {
        const tip: i16 = @intCast(menu_layout.width - 8);
        var step: i16 = 0;
        while (step < 4) : (step += 1) {
            try x.fillRectangles(window, gc, &.{.{ .x = tip - 4 + step, .y = centre - 3 + step, .width = 1, .height = @intCast(7 - step * 2) }});
        }
    }

    if (!has_font) return;
    try x.changeGc(gc, .{ .foreground = foreground, .background = background });
    const baseline: i16 = centre + @divTrunc(metrics.ascent - metrics.descent, 2);
    const label = item.label[0..labelPrefix(item.label, max_label_chars)];
    try x.imageText(window, gc, check_column + text_padding, baseline, label);
    if (item.accelerator) |accelerator| {
        const chars: i16 = @intCast(X11.charCount(accelerator));
        const right: i16 = @intCast(menu_layout.width - arrow_column);
        try x.imageText(window, gc, right - chars * metrics.char_width, baseline, accelerator);
    }
}

/// Byte length of the first `max_chars` UTF-8 characters of `text`.
fn labelPrefix(text: []const u8, max_chars: usize) usize {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < text.len and chars < max_chars) : (chars += 1) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i = @min(text.len, i + len);
    }
    return i;
}

test "layout skips hidden items and sizes rows by kind" {
    const gpa = std.testing.allocator;
    var menu = Menu.init(gpa);
    defer menu.deinit();
    const open = try menu.addItem("Open");
    _ = try menu.add(.{ .label = "Hidden", .visible = false });
    try menu.addSeparator();
    const quit = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });

    const metrics: X11.FontMetrics = .{ .ascent = 11, .descent = 2, .char_width = 6 };
    var result = try layout(gpa, &menu, metrics);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
    try std.testing.expectEqual(open, result.rows[0].item.id);
    try std.testing.expectEqual(@as(u16, 21), result.rows[0].height);
    try std.testing.expectEqual(@as(u16, separator_height), result.rows[1].height);
    try std.testing.expectEqual(quit, result.rows[2].item.id);
    try std.testing.expectEqual(@as(u16, 2 + 21 + 7 + 21 + 2), result.height);
    try std.testing.expect(result.width >= min_width);

    try std.testing.expectEqual(@as(?usize, 0), result.rowAt(10, 3));
    try std.testing.expectEqual(@as(?usize, 2), result.rowAt(10, 2 + 21 + 7 + 5));
    try std.testing.expect(result.rowAt(-1, 3) == null);
    try std.testing.expect(result.rowAt(10, 200) == null);
    try std.testing.expectEqual(@as(?i16, 2 + 10), result.centreOf(open));

    try std.testing.expect(result.rows[0].actionable());
    try std.testing.expect(!result.rows[1].actionable());
}

test "a long accelerator widens the menu" {
    const gpa = std.testing.allocator;
    var menu = Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.add(.{ .label = "A label of a fair length", .accelerator = "Ctrl+Shift+Alt+F12" });
    const metrics: X11.FontMetrics = .{ .ascent = 11, .descent = 2, .char_width = 6 };
    var result = try layout(gpa, &menu, metrics);
    defer result.deinit(gpa);
    const expected = check_column + text_padding + 24 * 6 + arrow_column + accelerator_gap + 18 * 6;
    try std.testing.expectEqual(@as(u16, expected), result.width);
}

test "place keeps popups on screen" {
    // Fits as asked.
    try std.testing.expectEqual([2]i16{ 100, 100 }, place(100, 100, 100, 50, 40, 800, 600));
    // Off the right edge: flips to the left of flip_x.
    try std.testing.expectEqual([2]i16{ 650, 100 }, place(780, 100, 700, 50, 40, 800, 600));
    // Off the bottom: opens upwards from the anchor.
    try std.testing.expectEqual([2]i16{ 100, 550 }, place(100, 590, 100, 50, 40, 800, 600));
    // Larger than the screen: pinned to the origin.
    try std.testing.expectEqual([2]i16{ 0, 0 }, place(10, 10, 10, 900, 700, 800, 600));
}

test "labelPrefix counts characters, not bytes" {
    try std.testing.expectEqual(@as(usize, 2), labelPrefix("abc", 2));
    try std.testing.expectEqual(@as(usize, 6), labelPrefix("启用x", 2));
    try std.testing.expectEqual(@as(usize, 3), labelPrefix("abc", 10));
}

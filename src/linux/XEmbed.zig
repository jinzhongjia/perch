//! The XEmbed system tray fallback, for sessions with an X tray but no
//! StatusNotifierHost: bare window managers, trayer, stalonetray and friends.
//!
//! The icon is a small window handed to the `_NET_SYSTEM_TRAY_S<n>` selection
//! owner, which reparents it into the tray. perch paints the pixels itself and
//! draws its own popup menu (see `XMenu.zig`), since the protocol has none.
//! When the tray goes away the icon is withdrawn, and it docks again as soon as
//! a new tray announces itself with a `MANAGER` message.

const std = @import("std");

const image = @import("../image.zig");
const icon_mod = @import("../icon.zig");
const menu_mod = @import("../menu.zig");
const Menu = menu_mod.Menu;
const tray_mod = @import("../tray.zig");
const Tray = tray_mod.Tray;
const X11 = @import("X11.zig");
const XMenu = @import("XMenu.zig");

const XEmbed = @This();

const log = std.log.scoped(.perch);

/// Images for one icon slot, borrowed from the backend. `name` is tried in
/// the icon theme when there are no decoded pixels (a `named` icon or SVG).
pub const Source = struct {
    images: []const image.Image = &.{},
    name: ?[]const u8 = null,
};

pub const Sources = struct {
    icon: Source = .{},
    attention: Source = .{},
    overlay: Source = .{},
};

/// The first size a tray sees before it configures the icon.
pub const initial_size = 22;
/// Larger trays are rare, and a bigger icon would not fit one request anyway.
pub const max_size = 128;

const Atoms = struct {
    selection: X11.Atom,
    opcode: X11.Atom,
    visual: X11.Atom,
    manager: X11.Atom,
    xembed_info: X11.Atom,
    net_wm_name: X11.Atom,
    utf8_string: X11.Atom,
};

const wm_class: X11.Atom = 67;
const string_type: X11.Atom = 31;
const request_dock = 0;
const xembed_mapped = 1;

const Popup = struct {
    window: X11.Window,
    menu: *Menu,
    layout: XMenu.Layout,
    x: i16,
    y: i16,
    highlighted: ?usize = null,
};

gpa: std.mem.Allocator,
io: std.Io,
owner: *Tray,
x: *X11,
atoms: Atoms,
sources: Sources = .{},
/// Theme lookups, keyed by name, so a named icon is read from disk once.
themed: std.StringHashMapUnmanaged([]image.Image) = .empty,
theme_dirs: []const []const u8,

/// The tray's selection owner, or 0 while there is none.
manager: X11.Window = 0,
icon_window: X11.Window = 0,
icon_gc: u32 = 0,
colormap: u32 = 0,
/// Depth of `icon_window`: 32 with the tray's ARGB visual, else the root's.
icon_depth: u8 = 0,
argb: bool = false,
width: u16 = initial_size,
height: u16 = initial_size,
/// Mapped by the tray. Drawing before that is pointless, and reading the
/// background of an unmapped window is an error.
viewable: bool = false,

menu_gc: u32 = 0,
font: u32 = 0,
has_font: bool = false,
metrics: X11.FontMetrics = XMenu.fallback_metrics,
palette: XMenu.Palette,
popups: std.ArrayList(Popup) = .empty,
/// Set once the pointer has done something inside the menu, so the release
/// of the click that opened it does not choose whatever lies beneath.
armed: bool = false,
grabbed: bool = false,

pub const Options = struct {
    display: []const u8,
    authority_path: ?[]const u8 = null,
    /// Icon theme base directories, most specific first, each holding themes
    /// such as `hicolor/`. Borrowed for the lifetime of the XEmbed.
    theme_dirs: []const []const u8 = &.{},
};

pub fn create(gpa: std.mem.Allocator, io: std.Io, owner: *Tray, options: Options) (X11.Error || error{UnsupportedVisual})!*XEmbed {
    const x = try X11.connect(gpa, io, .{ .display = options.display, .authority_path = options.authority_path });
    errdefer x.disconnect();

    const root_visual = x.visual(x.setup.root_visual) orelse return error.UnsupportedVisual;
    if (x.setup.root_depth != 24 or x.setup.bpp_depth24 != 32) return error.UnsupportedVisual;

    var name_buffer: [32]u8 = undefined;
    const selection_name = std.fmt.bufPrint(&name_buffer, "_NET_SYSTEM_TRAY_S{d}", .{0}) catch unreachable;
    const atoms: Atoms = .{
        .selection = try x.internAtom(selection_name),
        .opcode = try x.internAtom("_NET_SYSTEM_TRAY_OPCODE"),
        .visual = try x.internAtom("_NET_SYSTEM_TRAY_VISUAL"),
        .manager = try x.internAtom("MANAGER"),
        .xembed_info = try x.internAtom("_XEMBED_INFO"),
        .net_wm_name = try x.internAtom("_NET_WM_NAME"),
        .utf8_string = try x.internAtom("UTF8_STRING"),
    };

    const self = try gpa.create(XEmbed);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .owner = owner,
        .x = x,
        .atoms = atoms,
        .theme_dirs = options.theme_dirs,
        .palette = .forVisual(root_visual.isRgb888(), x.setup.white_pixel, x.setup.black_pixel),
    };

    // A new tray announces itself to the root window with MANAGER.
    try x.changeWindowAttributes(x.setup.root, .{ .event_mask = X11.EventMask.structure_notify });
    try self.dock();
    try x.flush();
    return self;
}

pub fn destroy(self: *XEmbed) void {
    self.closeMenu();
    self.withdraw();
    if (self.menu_gc != 0) self.x.freeGc(self.menu_gc) catch {};
    if (self.font != 0) self.x.closeFont(self.font) catch {};
    self.x.flush() catch {};
    self.popups.deinit(self.gpa);
    var it = self.themed.iterator();
    while (it.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        image.freeAll(self.gpa, entry.value_ptr.*);
    }
    self.themed.deinit(self.gpa);
    self.x.disconnect();
    const gpa = self.gpa;
    gpa.destroy(self);
}

pub fn handle(self: *const XEmbed) @import("sys.zig").fd_t {
    return self.x.handle();
}

pub fn pending(self: *const XEmbed) bool {
    return self.x.pending();
}

/// Whether a tray currently holds the icon.
pub fn docked(self: *const XEmbed) bool {
    return self.icon_window != 0;
}

// -- the icon ---------------------------------------------------------------

/// Hands a fresh icon window to the current tray, if there is one.
fn dock(self: *XEmbed) X11.Error!void {
    const x = self.x;
    self.withdraw();
    self.manager = try x.getSelectionOwner(self.atoms.selection);
    if (self.manager == 0) return;

    // Learn when the tray goes away, so the icon is not left on the root.
    try x.changeWindowAttributes(self.manager, .{ .event_mask = X11.EventMask.structure_notify });

    // An ARGB visual lets a compositing tray blend the icon itself.
    const tray_visual = x.getPropertyWord(self.manager, self.atoms.visual) catch null;
    const argb_visual: ?X11.Visual = if (tray_visual) |id| blk: {
        const v = x.visual(id) orelse break :blk null;
        break :blk if (v.depth == 32 and v.isRgb888() and x.setup.bpp_depth32 == 32) v else null;
    } else null;

    self.icon_window = x.generateId();
    self.icon_gc = x.generateId();
    const events = X11.EventMask.exposure | X11.EventMask.button_press |
        X11.EventMask.button_release | X11.EventMask.structure_notify;
    if (argb_visual) |v| {
        self.colormap = x.generateId();
        try x.createColormap(self.colormap, x.setup.root, v.id);
        try x.createWindow(.{
            .id = self.icon_window,
            .parent = x.setup.root,
            .width = initial_size,
            .height = initial_size,
            .depth = 32,
            .visual = v.id,
            // A different depth from the parent needs its own border and map.
            .attributes = .{ .background_pixel = 0, .border_pixel = 0, .event_mask = events, .colormap = self.colormap },
        });
        self.icon_depth = 32;
        self.argb = true;
    } else {
        try x.createWindow(.{
            .id = self.icon_window,
            .parent = x.setup.root,
            .width = initial_size,
            .height = initial_size,
            .attributes = .{ .background_pixmap = X11.WindowAttributes.parent_relative, .event_mask = events },
        });
        self.icon_depth = x.setup.root_depth;
        self.argb = false;
    }
    self.width = initial_size;
    self.height = initial_size;
    try x.createGc(self.icon_gc, self.icon_window, .{ .graphics_exposures = false });

    const app_id = self.owner.options.app_id;
    var class: [256]u8 = undefined;
    if (app_id.len * 2 + 2 <= class.len) {
        // WM_CLASS is instance, then class, each nul-terminated.
        @memcpy(class[0..app_id.len], app_id);
        class[app_id.len] = 0;
        @memcpy(class[app_id.len + 1 ..][0..app_id.len], app_id);
        class[app_id.len * 2 + 1] = 0;
        try x.changeProperty(self.icon_window, wm_class, string_type, 8, class[0 .. app_id.len * 2 + 2]);
    }
    const title = if (self.owner.options.title.len > 0) self.owner.options.title else app_id;
    try x.changeProperty(self.icon_window, self.atoms.net_wm_name, self.atoms.utf8_string, 8, title);
    try self.writeXEmbedInfo();

    try x.sendClientMessage(self.manager, 0, self.manager, self.atoms.opcode, .{
        X11.current_time, request_dock, self.icon_window, 0, 0,
    });
}

/// Destroys the icon window, which takes it out of the tray.
fn withdraw(self: *XEmbed) void {
    const x = self.x;
    if (self.icon_window != 0) {
        x.freeGc(self.icon_gc) catch {};
        x.destroyWindow(self.icon_window) catch {};
        self.icon_window = 0;
        self.icon_gc = 0;
    }
    self.viewable = false;
    if (self.colormap != 0) {
        x.freeColormap(self.colormap) catch {};
        self.colormap = 0;
    }
}

fn wantsMapped(self: *const XEmbed) bool {
    return self.owner.options.status != .passive;
}

/// `_XEMBED_INFO`: protocol version 0, and whether the tray should show us.
fn writeXEmbedInfo(self: *XEmbed) X11.Error!void {
    var info: [8]u8 = undefined;
    std.mem.writeInt(u32, info[0..4], 0, .little);
    std.mem.writeInt(u32, info[4..8], if (self.wantsMapped()) xembed_mapped else 0, .little);
    try self.x.changeProperty(self.icon_window, self.atoms.xembed_info, self.atoms.xembed_info, 32, &info);
}

pub fn setSources(self: *XEmbed, sources: Sources) void {
    self.sources = sources;
    self.redraw() catch |err| log.warn("perch: cannot draw the XEmbed icon: {t}", .{err});
}

/// Applies `.passive` (hidden) or visible, and redraws for attention.
pub fn applyStatus(self: *XEmbed) void {
    if (self.icon_window == 0) return;
    self.writeXEmbedInfo() catch {};
    // Trays watch _XEMBED_INFO; mapping directly covers the ones that do not.
    if (self.wantsMapped()) self.x.mapWindow(self.icon_window) catch {} else self.x.unmapWindow(self.icon_window) catch {};
    self.redraw() catch {};
    self.x.flush() catch {};
}

/// Repaints the icon at the tray's current size.
pub fn redraw(self: *XEmbed) !void {
    if (self.icon_window == 0 or !self.viewable) return;
    const width = @min(self.width, max_size);
    const height = @min(self.height, max_size);
    const pixels = try self.gpa.alloc(u32, @as(usize, width) * height);
    defer self.gpa.free(pixels);
    @memset(pixels, 0);

    const attention = self.owner.options.status == .needs_attention;
    const main = self.resolve(if (attention and self.hasSource(self.sources.attention)) self.sources.attention else self.sources.icon);
    const side = @min(width, height);
    const left: u16 = (width - side) / 2;
    const top: u16 = (height - side) / 2;
    if (pickFrame(main, side)) |frame| {
        compose(pixels, width, frame, left, top, side);
    } else {
        drawPlaceholder(pixels, width, left, top, side);
    }
    if (pickFrame(self.resolve(self.sources.overlay), side / 2)) |badge| {
        compose(pixels, width, badge, left + side - side / 2, top + side - side / 2, side / 2);
    }

    const bytes = std.mem.sliceAsBytes(pixels);
    if (self.argb) {
        // Already premultiplied, which is what a compositing tray expects.
    } else {
        // Blend over whatever the tray paints behind us.
        try self.x.clearArea(self.icon_window, .{ .x = 0, .y = 0, .width = width, .height = height });
        const background = try self.x.getImage(self.icon_window, .{ .x = 0, .y = 0, .width = width, .height = height });
        if (background.len >= bytes.len) blendOver(pixels, background);
    }
    try self.x.putImage(self.icon_window, self.icon_gc, self.icon_depth, width, height, 0, 0, bytes);
    try self.x.flush();
}

fn hasSource(self: *XEmbed, source: Source) bool {
    return self.resolve(source).len > 0;
}

/// Decoded pixels for `source`, looking its name up in the icon theme when it
/// has none of its own.
fn resolve(self: *XEmbed, source: Source) []const image.Image {
    if (source.images.len > 0) return source.images;
    const name = source.name orelse return &.{};
    if (self.themed.get(name)) |found| return found;

    // Only memory can run out here; a miss is an empty slice, cached too.
    const found = findThemed(self.gpa, self.io, self.theme_dirs, name) catch return &.{};
    const key = self.gpa.dupe(u8, name) catch {
        image.freeAll(self.gpa, found);
        return &.{};
    };
    self.themed.put(self.gpa, key, found) catch {
        self.gpa.free(key);
        image.freeAll(self.gpa, found);
        return &.{};
    };
    return found;
}

/// The smallest frame at least `side` pixels, else the largest.
pub fn pickFrame(frames: []const image.Image, side: u16) ?image.Image {
    var best: ?image.Image = null;
    for (frames) |frame| {
        const extent = frame.extent();
        const current = best orelse {
            best = frame;
            continue;
        };
        const current_extent = current.extent();
        if (current_extent < side) {
            if (extent > current_extent) best = frame;
        } else if (extent >= side and extent < current_extent) {
            best = frame;
        }
    }
    return best;
}

/// Scales `frame` into a `side`-square at (`left`, `top`) of `out`, area-averaged
/// when shrinking, and composites it over what is there. Pixels are
/// premultiplied 0xAARRGGBB.
pub fn compose(out: []u32, stride: u16, frame: image.Image, left: u16, top: u16, side: u16) void {
    if (side == 0 or frame.width == 0 or frame.height == 0) return;
    // Keep the aspect ratio inside the square.
    const scale_w: u32 = if (frame.width >= frame.height) side else @max(1, side * frame.width / frame.height);
    const scale_h: u32 = if (frame.height >= frame.width) side else @max(1, side * frame.height / frame.width);
    const off_x = left + (side - scale_w) / 2;
    const off_y = top + (side - scale_h) / 2;

    for (0..scale_h) |dy| {
        const sy0 = dy * frame.height / scale_h;
        const sy1 = @max(sy0 + 1, (dy + 1) * frame.height / scale_h);
        for (0..scale_w) |dx| {
            const sx0 = dx * frame.width / scale_w;
            const sx1 = @max(sx0 + 1, (dx + 1) * frame.width / scale_w);
            var sum: [4]u32 = .{ 0, 0, 0, 0 };
            for (sy0..sy1) |sy| {
                for (sx0..sx1) |sx| {
                    const p = frame.argb[(sy * frame.width + sx) * 4 ..][0..4];
                    const a: u32 = p[0];
                    sum[0] += a;
                    sum[1] += p[1] * a / 255;
                    sum[2] += p[2] * a / 255;
                    sum[3] += p[3] * a / 255;
                }
            }
            const n: u32 = @intCast((sy1 - sy0) * (sx1 - sx0));
            const src: [4]u32 = .{ sum[0] / n, sum[1] / n, sum[2] / n, sum[3] / n };
            const index = (off_y + dy) * stride + off_x + dx;
            out[index] = over(src, out[index]);
        }
    }
}

/// Premultiplied source-over.
fn over(src: [4]u32, dst: u32) u32 {
    const inverse = 255 - src[0];
    var result: u32 = 0;
    inline for (0..4) |channel| {
        const shift: u5 = @intCast(24 - channel * 8);
        const d = (dst >> shift) & 0xff;
        result |= @as(u32, @min(255, src[channel] + d * inverse / 255)) << shift;
    }
    return result;
}

/// Composites premultiplied `pixels` over an opaque 0x00RRGGBB `background`,
/// in place, for a tray without an ARGB visual.
pub fn blendOver(pixels: []u32, background: []const u8) void {
    for (pixels, 0..) |*pixel, i| {
        const bg = std.mem.readInt(u32, background[i * 4 ..][0..4], .little) | 0xff000000;
        const a = pixel.* >> 24;
        pixel.* = over(.{ a, (pixel.* >> 16) & 0xff, (pixel.* >> 8) & 0xff, pixel.* & 0xff }, bg) & 0x00ffffff;
    }
}

/// A neutral rounded square, so an icon perch cannot decode is still clickable.
fn drawPlaceholder(out: []u32, stride: u16, left: u16, top: u16, side: u16) void {
    const inset = side / 6;
    var y: u16 = inset;
    while (y < side - inset) : (y += 1) {
        var x: u16 = inset;
        while (x < side - inset) : (x += 1) {
            const corner = (y == inset or y == side - inset - 1) and (x == inset or x == side - inset - 1);
            if (!corner) out[(top + y) * stride + left + x] = 0xff8a8a8a;
        }
    }
}

// -- events -----------------------------------------------------------------

/// Handles one event from the X server. Callbacks run from here.
pub fn dispatchOne(self: *XEmbed) X11.Error!void {
    const event = try self.x.nextEvent() orelse return;
    switch (event) {
        .client_message => |message| {
            // A tray (re)started: MANAGER names the selection it now owns.
            if (message.type == self.atoms.manager and message.data[1] == self.atoms.selection) {
                try self.dock();
                self.redraw() catch {};
            }
        },
        .destroy => |destroyed| {
            if (destroyed.window == self.manager and self.manager != 0) {
                self.closeMenu();
                self.withdraw();
                self.manager = 0;
                // Another tray may already hold the selection.
                try self.dock();
            } else if (destroyed.window == self.icon_window) {
                self.icon_window = 0;
                self.icon_gc = 0;
                self.viewable = false;
            }
        },
        .configure => |configure| {
            if (configure.window != self.icon_window) return;
            if (configure.width != self.width or configure.height != self.height) {
                self.width = configure.width;
                self.height = configure.height;
                self.redraw() catch {};
            }
        },
        .map => |mapped| {
            if (mapped.window != self.icon_window) return;
            self.viewable = true;
            self.redraw() catch {};
        },
        .unmap => |unmapped| {
            if (unmapped.window == self.icon_window) self.viewable = false;
        },
        .reparent => |reparent| {
            // Embedded: honour the status we were asked to show.
            if (reparent.window == self.icon_window and reparent.parent != self.x.setup.root and self.wantsMapped()) {
                try self.x.mapWindow(self.icon_window);
            }
        },
        .expose => |expose| {
            if (expose.count != 0) return;
            if (expose.window == self.icon_window) {
                self.redraw() catch {};
            } else if (self.popupIndex(expose.window)) |i| {
                try self.drawPopup(i);
            }
        },
        .button_press => |input| try self.handlePress(input),
        .button_release => |input| try self.handleRelease(input),
        .motion => |input| try self.handleMotion(input),
        .leave => |input| {
            if (self.popupIndex(input.window)) |i| {
                // Keep the highlight on a row whose submenu is open.
                if (i + 1 == self.popups.items.len and self.popups.items[i].highlighted != null) {
                    self.popups.items[i].highlighted = null;
                    try self.drawPopup(i);
                }
            }
        },
        .key_press => |input| {
            // Escape on every evdev keymap; anything fancier needs the keymap.
            if (input.detail == 9 and self.popups.items.len > 0) self.closeMenu();
        },
        else => {},
    }
    try self.x.flush();
}

fn modifiers(state: u16) tray_mod.Modifiers {
    return .{
        .shift = state & 0x1 != 0,
        .ctrl = state & 0x4 != 0,
        .alt = state & 0x8 != 0,
        .super = state & 0x40 != 0,
    };
}

fn handlePress(self: *XEmbed, input: X11.Event.Input) X11.Error!void {
    if (self.popups.items.len > 0) {
        if (self.hit(input) != null) {
            self.armed = true;
        } else {
            self.closeMenu();
        }
        return;
    }
    if (input.window != self.icon_window) return;

    const at: tray_mod.Point = .{ .x = input.root_x, .y = input.root_y };
    const mods = modifiers(input.state);
    const owner = self.owner;
    switch (input.detail) {
        1 => {
            if (owner.options.leftClick() == .show_menu and owner.menu != null) {
                try self.openMenu(input.root_x, input.root_y);
            } else {
                owner.dispatchClick(.{ .button = .left, .mods = mods, .at = at });
            }
        },
        2 => owner.dispatchClick(.{ .button = .middle, .mods = mods, .at = at }),
        3 => {
            owner.dispatchClick(.{ .button = .right, .mods = mods, .at = at });
            // The callback may have stopped or replaced things; re-read state.
            if (self.owner.menu != null and self.icon_window != 0) try self.openMenu(input.root_x, input.root_y);
        },
        4, 5, 6, 7 => owner.dispatchScroll(.{
            .axis = if (input.detail <= 5) .vertical else .horizontal,
            .delta = if (input.detail == 4 or input.detail == 7) 1 else -1,
            .mods = mods,
        }),
        else => {},
    }
}

fn handleRelease(self: *XEmbed, input: X11.Event.Input) X11.Error!void {
    if (self.popups.items.len == 0) return;
    const target = self.hit(input) orelse return;
    if (!self.armed) return;
    const popup = self.popups.items[target.popup];
    const row = popup.layout.rows[target.row];
    if (!row.actionable()) return;
    const id = row.item.id;
    self.closeMenu();
    // Last: the callback may destroy the tray, and with it this XEmbed.
    self.owner.dispatchActivate(id);
}

fn handleMotion(self: *XEmbed, input: X11.Event.Input) X11.Error!void {
    const target = self.hit(input) orelse return;
    const popup = &self.popups.items[target.popup];
    if (popup.highlighted != target.row) {
        popup.highlighted = target.row;
        self.armed = true;
        try self.drawPopup(target.popup);
    }
    const row = popup.layout.rows[target.row];
    const open_child = target.popup + 1 < self.popups.items.len and
        self.popups.items[target.popup + 1].menu == row.item.submenu;
    if (open_child) return;
    self.closeFrom(target.popup + 1);
    if (row.item.kind == .submenu and row.item.enabled) {
        if (row.item.submenu) |child| {
            const parent = self.popups.items[target.popup];
            try self.openPopup(
                child,
                parent.x + @as(i16, @intCast(parent.layout.width)) - 2,
                parent.y + row.y - 2,
                parent.x + 2,
            );
        }
    }
}

const Hit = struct { popup: usize, row: usize };

/// The popup row under the pointer. With the grab's owner_events, events over
/// our popups arrive relative to them; anything else is outside.
fn hit(self: *XEmbed, input: X11.Event.Input) ?Hit {
    var i = self.popups.items.len;
    while (i > 0) {
        i -= 1;
        const popup = self.popups.items[i];
        const local_x: i32 = input.root_x - popup.x;
        const local_y: i32 = input.root_y - popup.y;
        const inside = if (input.window == popup.window)
            popup.layout.rowAt(input.x, input.y)
        else
            popup.layout.rowAt(local_x, local_y);
        if (inside) |row| return .{ .popup = i, .row = row };
    }
    return null;
}

fn popupIndex(self: *XEmbed, window: X11.Window) ?usize {
    for (self.popups.items, 0..) |popup, i| {
        if (popup.window == window) return i;
    }
    return null;
}

// -- the menu ---------------------------------------------------------------

/// Pops the menu up at the pointer, as `Tray.showMenu` asks.
pub fn showMenu(self: *XEmbed) X11.Error!void {
    if (self.owner.menu == null) return;
    const pointer = try self.x.queryPointer(self.x.setup.root);
    try self.openMenu(pointer.root_x, pointer.root_y);
    try self.x.flush();
}

fn openMenu(self: *XEmbed, root_x: i16, root_y: i16) X11.Error!void {
    self.closeMenu();
    const menu = self.owner.menu orelse return;
    try self.ensureMenuResources();
    self.armed = false;
    try self.openPopup(menu, root_x, root_y, root_x);
    if (self.popups.items.len == 0) return;
    const first = self.popups.items[0].window;
    const mask = X11.EventMask.button_press | X11.EventMask.button_release |
        X11.EventMask.pointer_motion | X11.EventMask.leave_window;
    self.grabbed = self.x.grabPointer(first, @intCast(mask)) catch false;
    _ = self.x.grabKeyboard(first) catch false;
}

fn openPopup(self: *XEmbed, menu: *Menu, anchor_x: i32, anchor_y: i32, flip_x: i32) X11.Error!void {
    var popup_layout = try XMenu.layout(self.gpa, menu, self.metrics);
    errdefer popup_layout.deinit(self.gpa);
    if (popup_layout.rows.len == 0) {
        popup_layout.deinit(self.gpa);
        return;
    }
    const x = self.x;
    const at = XMenu.place(anchor_x, anchor_y, flip_x, popup_layout.width, popup_layout.height, x.setup.width, x.setup.height);
    const window = x.generateId();
    try x.createWindow(.{
        .id = window,
        .parent = x.setup.root,
        .x = at[0],
        .y = at[1],
        .width = popup_layout.width,
        .height = popup_layout.height,
        .attributes = .{
            .background_pixel = self.palette.background,
            .override_redirect = true,
            .event_mask = X11.EventMask.exposure | X11.EventMask.button_press |
                X11.EventMask.button_release | X11.EventMask.pointer_motion |
                X11.EventMask.leave_window | X11.EventMask.key_press,
        },
    });
    try x.mapWindow(window);
    try self.popups.append(self.gpa, .{
        .window = window,
        .menu = menu,
        .layout = popup_layout,
        .x = at[0],
        .y = at[1],
    });
}

/// Closes popups from `index` down the cascade.
fn closeFrom(self: *XEmbed, index: usize) void {
    while (self.popups.items.len > index) {
        var popup = self.popups.pop().?;
        self.x.destroyWindow(popup.window) catch {};
        popup.layout.deinit(self.gpa);
    }
}

pub fn closeMenu(self: *XEmbed) void {
    if (self.popups.items.len == 0) return;
    self.closeFrom(0);
    if (self.grabbed) self.x.ungrabPointer() catch {};
    self.x.ungrabKeyboard() catch {};
    self.grabbed = false;
    self.armed = false;
    self.x.flush() catch {};
}

fn drawPopup(self: *XEmbed, index: usize) X11.Error!void {
    const popup = self.popups.items[index];
    try XMenu.draw(self.x, popup.window, self.menu_gc, popup.layout, popup.highlighted, self.metrics, self.has_font, self.palette);
}

/// Opens the font and the GC on first use. A server without the core fonts
/// still gets a menu, drawn without labels.
fn ensureMenuResources(self: *XEmbed) X11.Error!void {
    if (self.menu_gc != 0) return;
    const x = self.x;
    for (XMenu.font_names) |name| {
        const font = x.generateId();
        try x.openFont(font, name);
        if (x.queryFont(font)) |metrics| {
            self.font = font;
            self.metrics = metrics;
            self.has_font = true;
            break;
        } else |err| switch (err) {
            error.RequestFailed => continue,
            else => return err,
        }
    }
    if (!self.has_font) log.warn("perch: no X core font is available; menu labels will be blank", .{});
    self.menu_gc = x.generateId();
    try x.createGc(self.menu_gc, x.setup.root, .{
        .foreground = self.palette.text,
        .background = self.palette.background,
        .font = if (self.has_font) self.font else null,
        .graphics_exposures = false,
    });
}

/// The XMenu font metrics in use, for tests that click rows by position.
pub fn menuMetrics(self: *const XEmbed) X11.FontMetrics {
    return self.metrics;
}

// -- icon themes --------------------------------------------------------------

const theme_names = [_][]const u8{ "hicolor", "Adwaita", "breeze" };
const theme_sizes = [_][]const u8{ "16x16", "22x22", "24x24", "32x32", "48x48", "64x64", "128x128" };
const theme_contexts = [_][]const u8{ "apps", "status", "devices", "places", "actions", "categories", "legacy" };

/// PNGs named `name` in the given base directories' themes, one per size, plus
/// `<base>/../pixmaps`. SVG-only icons are not found: perch does not rasterise.
pub fn findThemed(
    gpa: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    name: []const u8,
) std.mem.Allocator.Error![]image.Image {
    var found: std.ArrayList(image.Image) = .empty;
    errdefer {
        for (found.items) |*frame| frame.deinit(gpa);
        found.deinit(gpa);
    }
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (theme_sizes) |size| {
        sizes: for (dirs) |dir| {
            for (theme_names) |theme| {
                for (theme_contexts) |context| {
                    const candidate = std.fmt.bufPrint(&path, "{s}/{s}/{s}/{s}/{s}.png", .{ dir, theme, size, context, name }) catch continue;
                    if (try loadPng(gpa, io, candidate)) |frame| {
                        try found.append(gpa, frame);
                        break :sizes;
                    }
                }
            }
        }
    }
    if (found.items.len == 0) {
        for (dirs) |dir| {
            const candidate = std.fmt.bufPrint(&path, "{s}/../pixmaps/{s}.png", .{ dir, name }) catch continue;
            if (try loadPng(gpa, io, candidate)) |frame| {
                try found.append(gpa, frame);
                break;
            }
        }
    }
    return found.toOwnedSlice(gpa);
}

fn loadPng(gpa: std.mem.Allocator, io: std.Io, path: []const u8) std.mem.Allocator.Error!?image.Image {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(bytes);
    return image.decode(gpa, bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

test "pickFrame prefers the smallest frame that covers the size" {
    const frames = [_]image.Image{
        .{ .width = 16, .height = 16, .argb = &.{} },
        .{ .width = 32, .height = 32, .argb = &.{} },
        .{ .width = 64, .height = 64, .argb = &.{} },
    };
    try std.testing.expectEqual(@as(u32, 32), pickFrame(&frames, 22).?.width);
    try std.testing.expectEqual(@as(u32, 16), pickFrame(&frames, 16).?.width);
    try std.testing.expectEqual(@as(u32, 64), pickFrame(&frames, 100).?.width);
    try std.testing.expect(pickFrame(&.{}, 22) == null);
}

test "compose scales, centres and premultiplies" {
    // 2x2: opaque red, transparent, half-transparent white, opaque blue.
    var argb = [_]u8{
        0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x80, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0xff,
    };
    const frame: image.Image = .{ .width = 2, .height = 2, .argb = &argb };

    // Upscaled to 4x4: each source pixel becomes a 2x2 block.
    var out: [16]u32 = @splat(0);
    compose(&out, 4, frame, 0, 0, 4);
    try std.testing.expectEqual(@as(u32, 0xffff0000), out[0]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), out[5]);
    try std.testing.expectEqual(@as(u32, 0), out[2]);
    try std.testing.expectEqual(@as(u32, 0x80808080), out[8]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), out[15]);

    // Downscaled to 1x1: the premultiplied average of all four.
    var one: [1]u32 = .{0};
    compose(&one, 1, frame, 0, 0, 1);
    try std.testing.expectEqual(@as(u32, 0x9f5f205f), one[0]);
}

test "compose keeps the aspect ratio inside the square" {
    var argb: [8]u8 = .{ 0xff, 0, 0xff, 0, 0xff, 0, 0xff, 0 };
    const wide: image.Image = .{ .width = 2, .height = 1, .argb = &argb };
    var out: [16]u32 = @splat(0);
    compose(&out, 4, wide, 0, 0, 4);
    // 4x2, centred vertically: rows 1 and 2.
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), out[4]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), out[11]);
    try std.testing.expectEqual(@as(u32, 0), out[12]);
}

test "blendOver mixes premultiplied pixels into the background" {
    var pixels = [_]u32{ 0xffff0000, 0x00000000, 0x80800000 };
    var background: [12]u8 = undefined;
    for (0..3) |i| std.mem.writeInt(u32, background[i * 4 ..][0..4], 0x0000ff00, .little);
    blendOver(&pixels, &background);
    try std.testing.expectEqual(@as(u32, 0x00ff0000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x0000ff00), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0x00807f00), pixels[2]);
}

test "findThemed reads sized PNGs from a theme directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const base = ".zig-cache/tmp/perch-theme-test";
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    const png = try image.png.testImage(gpa, 2, 2, &@as([16]u8, @splat(0xff)));
    defer gpa.free(png);
    try cwd.createDirPath(io, base ++ "/icons/hicolor/16x16/apps");
    try cwd.createDirPath(io, base ++ "/icons/Adwaita/32x32/legacy");
    try cwd.writeFile(io, .{ .sub_path = base ++ "/icons/hicolor/16x16/apps/probe.png", .data = png });
    try cwd.writeFile(io, .{ .sub_path = base ++ "/icons/Adwaita/32x32/legacy/probe.png", .data = png });

    const frames = try findThemed(gpa, io, &.{base ++ "/icons"}, "probe");
    defer image.freeAll(gpa, frames);
    try std.testing.expectEqual(@as(usize, 2), frames.len);

    const missing = try findThemed(gpa, io, &.{base ++ "/icons"}, "absent");
    defer image.freeAll(gpa, missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}

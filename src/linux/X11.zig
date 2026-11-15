//! A minimal X11 client: the core-protocol requests an XEmbed tray icon and its
//! popup menu need, spoken directly over the display's unix socket.
//!
//! No Xlib, no XCB, no extensions. Requests are buffered and sent on `flush`
//! (or implicitly before waiting for a reply); events that arrive while a reply
//! is awaited are queued, so the caller never loses one.

const std = @import("std");
const net = std.Io.net;

const sys = @import("sys.zig");

const X11 = @This();

const log = std.log.scoped(.perch);

pub const Error = error{
    /// `DISPLAY` is unset, or names a TCP display perch does not speak to.
    DisplayUnsupported,
    ConnectFailed,
    /// The server refused the connection setup, usually over authorization.
    SetupRefused,
    /// The peer closed the socket, or the socket errored.
    Disconnected,
    WriteFailed,
    /// A packet did not follow the protocol.
    Malformed,
    /// The server answered a request with an error.
    RequestFailed,
    OutOfMemory,
};

pub const Window = u32;
pub const Atom = u32;
pub const VisualId = u32;
pub const none: u32 = 0;
pub const current_time: u32 = 0;

/// The pieces of the connection setup reply perch uses.
pub const Setup = struct {
    resource_id_base: u32,
    resource_id_mask: u32,
    /// In four-byte units.
    max_request_len: u16,
    root: Window,
    root_depth: u8,
    root_visual: VisualId,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    width: u16,
    height: u16,
    /// Bits per pixel for 24- and 32-bit depths, which is all perch draws in.
    bpp_depth24: u8 = 0,
    bpp_depth32: u8 = 0,
    visuals: []Visual = &.{},
};

pub const Visual = struct {
    id: VisualId,
    depth: u8,
    class: u8,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,

    pub const true_color = 4;

    /// The 0xRRGGBB layout every perch drawing routine assumes.
    pub fn isRgb888(self: Visual) bool {
        return self.class == true_color and self.red_mask == 0xff0000 and
            self.green_mask == 0x00ff00 and self.blue_mask == 0x0000ff;
    }
};

pub const EventMask = struct {
    pub const key_press: u32 = 0x1;
    pub const button_press: u32 = 0x4;
    pub const button_release: u32 = 0x8;
    pub const enter_window: u32 = 0x10;
    pub const leave_window: u32 = 0x20;
    pub const pointer_motion: u32 = 0x40;
    pub const exposure: u32 = 0x8000;
    pub const structure_notify: u32 = 0x20000;
    pub const substructure_notify: u32 = 0x80000;
    pub const property_change: u32 = 0x400000;
};

/// `CreateWindow` / `ChangeWindowAttributes` values, in mask-bit order.
pub const WindowAttributes = struct {
    background_pixmap: ?u32 = null,
    background_pixel: ?u32 = null,
    border_pixel: ?u32 = null,
    override_redirect: ?bool = null,
    event_mask: ?u32 = null,
    colormap: ?u32 = null,

    /// `ParentRelative` for `background_pixmap`: show the parent through.
    pub const parent_relative: u32 = 1;

    fn mask(self: WindowAttributes) u32 {
        var m: u32 = 0;
        if (self.background_pixmap != null) m |= 0x1;
        if (self.background_pixel != null) m |= 0x2;
        if (self.border_pixel != null) m |= 0x8;
        if (self.override_redirect != null) m |= 0x200;
        if (self.event_mask != null) m |= 0x800;
        if (self.colormap != null) m |= 0x2000;
        return m;
    }

    fn count(self: WindowAttributes) u16 {
        return @popCount(self.mask());
    }

    fn write(self: WindowAttributes, w: *std.Io.Writer) !void {
        if (self.background_pixmap) |v| try w.writeInt(u32, v, .little);
        if (self.background_pixel) |v| try w.writeInt(u32, v, .little);
        if (self.border_pixel) |v| try w.writeInt(u32, v, .little);
        if (self.override_redirect) |v| try w.writeInt(u32, @intFromBool(v), .little);
        if (self.event_mask) |v| try w.writeInt(u32, v, .little);
        if (self.colormap) |v| try w.writeInt(u32, v, .little);
    }
};

/// `CreateGC` / `ChangeGC` values, in mask-bit order.
pub const GcValues = struct {
    foreground: ?u32 = null,
    background: ?u32 = null,
    font: ?u32 = null,
    graphics_exposures: ?bool = null,

    fn mask(self: GcValues) u32 {
        var m: u32 = 0;
        if (self.foreground != null) m |= 0x4;
        if (self.background != null) m |= 0x8;
        if (self.font != null) m |= 0x4000;
        if (self.graphics_exposures != null) m |= 0x10000;
        return m;
    }

    fn count(self: GcValues) u16 {
        return @popCount(self.mask());
    }

    fn write(self: GcValues, w: *std.Io.Writer) !void {
        if (self.foreground) |v| try w.writeInt(u32, v, .little);
        if (self.background) |v| try w.writeInt(u32, v, .little);
        if (self.font) |v| try w.writeInt(u32, v, .little);
        if (self.graphics_exposures) |v| try w.writeInt(u32, @intFromBool(v), .little);
    }
};

pub const Rectangle = struct { x: i16, y: i16, width: u16, height: u16 };

/// The events perch acts on, decoded from their 32-byte wire form.
pub const Event = union(enum) {
    key_press: Input,
    button_press: Input,
    button_release: Input,
    motion: Input,
    leave: Input,
    expose: struct { window: Window, count: u16 },
    destroy: struct { window: Window },
    unmap: struct { window: Window },
    map: struct { window: Window },
    reparent: struct { window: Window, parent: Window },
    configure: struct { window: Window, x: i16, y: i16, width: u16, height: u16 },
    client_message: struct { window: Window, type: Atom, format: u8, data: [5]u32 },
    property: struct { window: Window, atom: Atom },
    other: u8,

    /// Pointer and key events share one layout.
    pub const Input = struct {
        /// Button number or keycode.
        detail: u8,
        time: u32,
        root: Window,
        window: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        x: i16,
        y: i16,
        state: u16,
    };

    pub fn decode(raw: *const [32]u8) Event {
        const code = raw[0] & 0x7f;
        const u32At = struct {
            fn at(bytes: *const [32]u8, offset: usize) u32 {
                return std.mem.readInt(u32, bytes[offset..][0..4], .little);
            }
        }.at;
        const i16At = struct {
            fn at(bytes: *const [32]u8, offset: usize) i16 {
                return std.mem.readInt(i16, bytes[offset..][0..2], .little);
            }
        }.at;
        const u16At = struct {
            fn at(bytes: *const [32]u8, offset: usize) u16 {
                return std.mem.readInt(u16, bytes[offset..][0..2], .little);
            }
        }.at;
        const input: Input = .{
            .detail = raw[1],
            .time = u32At(raw, 4),
            .root = u32At(raw, 8),
            .window = u32At(raw, 12),
            .child = u32At(raw, 16),
            .root_x = i16At(raw, 20),
            .root_y = i16At(raw, 22),
            .x = i16At(raw, 24),
            .y = i16At(raw, 26),
            .state = u16At(raw, 28),
        };
        return switch (code) {
            2 => .{ .key_press = input },
            4 => .{ .button_press = input },
            5 => .{ .button_release = input },
            6 => .{ .motion = input },
            8 => .{ .leave = input },
            12 => .{ .expose = .{ .window = u32At(raw, 4), .count = u16At(raw, 16) } },
            17 => .{ .destroy = .{ .window = u32At(raw, 8) } },
            18 => .{ .unmap = .{ .window = u32At(raw, 8) } },
            19 => .{ .map = .{ .window = u32At(raw, 8) } },
            21 => .{ .reparent = .{ .window = u32At(raw, 8), .parent = u32At(raw, 12) } },
            22 => .{ .configure = .{
                .window = u32At(raw, 8),
                .x = i16At(raw, 16),
                .y = i16At(raw, 18),
                .width = u16At(raw, 20),
                .height = u16At(raw, 22),
            } },
            28 => .{ .property = .{ .window = u32At(raw, 4), .atom = u32At(raw, 8) } },
            33 => blk: {
                var data: [5]u32 = undefined;
                for (&data, 0..) |*word, i| word.* = u32At(raw, 12 + i * 4);
                break :blk .{ .client_message = .{
                    .window = u32At(raw, 4),
                    .type = u32At(raw, 8),
                    .format = raw[1],
                    .data = data,
                } };
            },
            else => .{ .other = code },
        };
    }
};

gpa: std.mem.Allocator,
io: std.Io,
stream: net.Stream,
reader: net.Stream.Reader,
writer: net.Stream.Writer,
read_buffer: []u8,
write_buffer: []u8,
setup: Setup,
next_resource: u32 = 0,
/// Sequence number of the last request written, as the server counts them.
sequence: u16 = 0,
/// Events read while waiting for a reply, oldest first.
queued: std.ArrayList([32]u8) = .empty,
/// Holds the most recent reply returned by `awaitReply`.
reply_buffer: std.ArrayList(u8) = .empty,

pub const ConnectOptions = struct {
    /// The `DISPLAY` value, e.g. `":0"` or `"unix:1.0"`.
    display: []const u8,
    /// Path of the authority file: `XAUTHORITY`, else `$HOME/.Xauthority`.
    authority_path: ?[]const u8 = null,
};

/// Connects to the display and completes the setup handshake.
pub fn connect(gpa: std.mem.Allocator, io: std.Io, options: ConnectOptions) Error!*X11 {
    const display = try parseDisplay(options.display);

    var path_buffer: [net.UnixAddress.max_len]u8 = undefined;
    const stream = openSocket(io, display.number, &path_buffer) orelse return error.ConnectFailed;
    errdefer stream.close(io);

    const self = try gpa.create(X11);
    errdefer gpa.destroy(self);
    const read_buffer = try gpa.alloc(u8, 64 * 1024);
    errdefer gpa.free(read_buffer);
    const write_buffer = try gpa.alloc(u8, 64 * 1024);
    errdefer gpa.free(write_buffer);

    self.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .setup = undefined,
    };
    // Both hold an `interface` found via @fieldParentPtr, so they must live at
    // their final address.
    self.reader = stream.reader(io, read_buffer);
    self.writer = stream.writer(io, write_buffer);

    var cookie_buffer: [256]u8 = undefined;
    const cookie = if (options.authority_path) |path|
        readCookie(gpa, io, path, display.number, &cookie_buffer)
    else
        null;
    try self.handshake(cookie);
    return self;
}

pub fn disconnect(self: *X11) void {
    const gpa = self.gpa;
    self.stream.close(self.io);
    gpa.free(self.setup.visuals);
    self.queued.deinit(gpa);
    self.reply_buffer.deinit(gpa);
    gpa.free(self.read_buffer);
    gpa.free(self.write_buffer);
    gpa.destroy(self);
}

/// The socket, for polling alongside other descriptors.
pub fn handle(self: *const X11) sys.fd_t {
    return self.stream.socket.handle;
}

/// Whether events are ready without reading the socket.
pub fn pending(self: *const X11) bool {
    return self.queued.items.len > 0 or self.reader.interface.bufferedLen() >= 32;
}

pub fn generateId(self: *X11) u32 {
    const id = self.setup.resource_id_base | (self.next_resource & self.setup.resource_id_mask);
    self.next_resource += 1;
    return id;
}

/// The visual with `id`, if the setup listed it.
pub fn visual(self: *const X11, id: VisualId) ?Visual {
    for (self.setup.visuals) |v| {
        if (v.id == id) return v;
    }
    return null;
}

pub fn flush(self: *X11) Error!void {
    self.writer.interface.flush() catch return error.WriteFailed;
}

// -- connection setup -------------------------------------------------------

pub const Display = struct { number: u32, screen: u32 };

/// `[unix]:<display>[.<screen>]`. TCP displays are refused: perch only speaks
/// to the local socket.
pub fn parseDisplay(value: []const u8) Error!Display {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.DisplayUnsupported;
    const host = value[0..colon];
    if (host.len != 0 and !std.mem.eql(u8, host, "unix")) return error.DisplayUnsupported;

    const rest = value[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const number_text = if (dot) |d| rest[0..d] else rest;
    const screen_text = if (dot) |d| rest[d + 1 ..] else "0";
    return .{
        .number = std.fmt.parseInt(u32, number_text, 10) catch return error.DisplayUnsupported,
        .screen = std.fmt.parseInt(u32, screen_text, 10) catch return error.DisplayUnsupported,
    };
}

fn openSocket(io: std.Io, number: u32, buffer: *[net.UnixAddress.max_len]u8) ?net.Stream {
    // Linux servers also listen on an abstract socket, which survives a wiped
    // /tmp; the filesystem socket works everywhere.
    const candidates = [_][]const u8{ "\x00/tmp/.X11-unix/X{d}", "/tmp/.X11-unix/X{d}" };
    inline for (candidates, 0..) |pattern, i| {
        if (i == 0 and @import("builtin").os.tag != .linux) continue;
        const path = std.fmt.bufPrint(buffer, pattern, .{number}) catch return null;
        if (net.UnixAddress.init(path)) |address| {
            if (address.connect(io)) |stream| return stream else |_| {}
        } else |_| {}
    }
    return null;
}

/// The `MIT-MAGIC-COOKIE-1` for local display `number`, if the authority file
/// has one. A missing file is normal: many servers accept local connections
/// without a cookie.
fn readCookie(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    number: u32,
    out: *[256]u8,
) ?[]const u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(contents);
    const cookie = findCookie(contents, number) orelse return null;
    if (cookie.len > out.len) return null;
    @memcpy(out[0..cookie.len], cookie);
    return out[0..cookie.len];
}

pub const cookie_name = "MIT-MAGIC-COOKIE-1";

/// Scans an `.Xauthority` file. Records are big-endian length-prefixed fields:
/// family, address, display number, auth name, auth data. Local (256) and wild
/// (65535) families apply to unix sockets; hostnames are not compared, since a
/// renamed host must not lock the user out of their own display.
pub fn findCookie(contents: []const u8, number: u32) ?[]const u8 {
    var number_text: [10]u8 = undefined;
    const wanted = std.fmt.bufPrint(&number_text, "{d}", .{number}) catch return null;

    var pos: usize = 0;
    while (pos + 2 <= contents.len) {
        const family = std.mem.readInt(u16, contents[pos..][0..2], .big);
        pos += 2;
        var fields: [4][]const u8 = undefined;
        for (&fields) |*field| {
            if (pos + 2 > contents.len) return null;
            const len = std.mem.readInt(u16, contents[pos..][0..2], .big);
            pos += 2;
            if (pos + len > contents.len) return null;
            field.* = contents[pos..][0..len];
            pos += len;
        }
        const local = family == 256 or family == 65535;
        const display_matches = fields[1].len == 0 or std.mem.eql(u8, fields[1], wanted);
        if (local and display_matches and std.mem.eql(u8, fields[2], cookie_name)) return fields[3];
    }
    return null;
}

fn handshake(self: *X11, cookie: ?[]const u8) Error!void {
    const w = &self.writer.interface;
    const name: []const u8 = if (cookie != null) cookie_name else "";
    const data: []const u8 = cookie orelse "";
    writeSetupRequest(w, name, data) catch return error.WriteFailed;
    try self.flush();

    const r = &self.reader.interface;
    const head = r.takeArray(8) catch return error.Disconnected;
    const extra_len = @as(usize, std.mem.readInt(u16, head[6..8], .little)) * 4;
    const body = r.take(extra_len) catch return error.Disconnected;
    if (head[0] != 1) {
        const reason_len = @min(head[1], body.len);
        log.warn("perch: the X server refused the connection: {s}", .{body[0..reason_len]});
        return error.SetupRefused;
    }
    self.setup = try parseSetup(self.gpa, body);
}

fn writeSetupRequest(w: *std.Io.Writer, name: []const u8, data: []const u8) !void {
    try w.writeAll(&.{ 'l', 0 });
    try w.writeInt(u16, 11, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, @intCast(data.len), .little);
    try w.writeAll(&.{ 0, 0 });
    try w.writeAll(name);
    try writePad(w, name.len);
    try w.writeAll(data);
    try writePad(w, data.len);
}

/// Parses the setup reply after its 8-byte header. Only the first screen is
/// read: multi-screen (Zaphod) setups are long gone.
pub fn parseSetup(gpa: std.mem.Allocator, body: []const u8) Error!Setup {
    if (body.len < 32) return error.Malformed;
    const vendor_len = std.mem.readInt(u16, body[16..18], .little);
    const screen_count = body[20];
    const format_count = body[21];
    if (screen_count == 0) return error.Malformed;

    var setup: Setup = .{
        .resource_id_base = std.mem.readInt(u32, body[4..8], .little),
        .resource_id_mask = std.mem.readInt(u32, body[8..12], .little),
        .max_request_len = std.mem.readInt(u16, body[18..20], .little),
        .root = undefined,
        .root_depth = undefined,
        .root_visual = undefined,
        .default_colormap = undefined,
        .white_pixel = undefined,
        .black_pixel = undefined,
        .width = undefined,
        .height = undefined,
    };

    var pos: usize = 32 + vendor_len + padLen(vendor_len);
    for (0..format_count) |_| {
        if (pos + 8 > body.len) return error.Malformed;
        const depth = body[pos];
        const bpp = body[pos + 1];
        if (depth == 24) setup.bpp_depth24 = bpp;
        if (depth == 32) setup.bpp_depth32 = bpp;
        pos += 8;
    }

    if (pos + 40 > body.len) return error.Malformed;
    const screen = body[pos..];
    setup.root = std.mem.readInt(u32, screen[0..4], .little);
    setup.default_colormap = std.mem.readInt(u32, screen[4..8], .little);
    setup.white_pixel = std.mem.readInt(u32, screen[8..12], .little);
    setup.black_pixel = std.mem.readInt(u32, screen[12..16], .little);
    setup.width = std.mem.readInt(u16, screen[20..22], .little);
    setup.height = std.mem.readInt(u16, screen[22..24], .little);
    setup.root_visual = std.mem.readInt(u32, screen[32..36], .little);
    setup.root_depth = screen[38];
    const depth_count = screen[39];
    pos += 40;

    var visuals: std.ArrayList(Visual) = .empty;
    errdefer visuals.deinit(gpa);
    for (0..depth_count) |_| {
        if (pos + 8 > body.len) return error.Malformed;
        const depth = body[pos];
        const visual_count = std.mem.readInt(u16, body[pos + 2 ..][0..2], .little);
        pos += 8;
        for (0..visual_count) |_| {
            if (pos + 24 > body.len) return error.Malformed;
            const v = body[pos..][0..24];
            try visuals.append(gpa, .{
                .id = std.mem.readInt(u32, v[0..4], .little),
                .depth = depth,
                .class = v[4],
                .red_mask = std.mem.readInt(u32, v[8..12], .little),
                .green_mask = std.mem.readInt(u32, v[12..16], .little),
                .blue_mask = std.mem.readInt(u32, v[16..20], .little),
            });
            pos += 24;
        }
    }
    setup.visuals = try visuals.toOwnedSlice(gpa);
    return setup;
}

fn padLen(len: usize) usize {
    return (4 - len % 4) % 4;
}

fn writePad(w: *std.Io.Writer, len: usize) !void {
    const zeros = [_]u8{ 0, 0, 0 };
    try w.writeAll(zeros[0..padLen(len)]);
}

// -- packets ------------------------------------------------------------------

/// Reads the next packet. Events are queued; errors are logged, or returned
/// when they answer `wanted`; a reply to `wanted` is returned.
fn readPacket(self: *X11, wanted: ?u16) Error!?[]const u8 {
    const r = &self.reader.interface;
    const head = r.takeArray(32) catch return error.Disconnected;
    const sequence = std.mem.readInt(u16, head[2..4], .little);
    switch (head[0]) {
        0 => {
            if (wanted != null and sequence == wanted.?) return error.RequestFailed;
            log.debug("perch: X error {d} for request {d} (seq {d})", .{ head[1], head[10], sequence });
            return null;
        },
        1 => {
            const extra = @as(usize, std.mem.readInt(u32, head[4..8], .little)) * 4;
            self.reply_buffer.clearRetainingCapacity();
            try self.reply_buffer.appendSlice(self.gpa, head);
            try self.reply_buffer.resize(self.gpa, 32 + extra);
            r.readSliceAll(self.reply_buffer.items[32..]) catch return error.Disconnected;
            if (wanted != null and sequence == wanted.?) return self.reply_buffer.items;
            return null;
        },
        else => {
            try self.queued.append(self.gpa, head.*);
            return null;
        },
    }
}

/// Waits for the reply to request `sequence`. The slice, including its 32-byte
/// header, is valid until the next read.
pub fn awaitReply(self: *X11, sequence: u16) Error![]const u8 {
    try self.flush();
    while (true) {
        if (try self.readPacket(sequence)) |reply| return reply;
    }
}

/// The next event, reading the socket only if nothing is queued. Blocks when
/// the socket is empty, so poll first.
pub fn nextEvent(self: *X11) Error!?Event {
    while (self.queued.items.len == 0) {
        _ = try self.readPacket(null);
        // An error or a stray reply consumed the read; let the caller poll again.
        if (self.queued.items.len == 0 and self.reader.interface.bufferedLen() < 32) return null;
    }
    const raw = self.queued.orderedRemove(0);
    return Event.decode(&raw);
}

// -- requests -----------------------------------------------------------------

/// Starts a request of `words` four-byte units and returns its sequence.
fn begin(self: *X11, opcode: u8, data: u8, words: usize) Error!u16 {
    if (words > self.setup.max_request_len) return error.RequestFailed;
    const w = &self.writer.interface;
    w.writeAll(&.{ opcode, data }) catch return error.WriteFailed;
    w.writeInt(u16, @intCast(words), .little) catch return error.WriteFailed;
    self.sequence +%= 1;
    return self.sequence;
}

fn put32(self: *X11, value: u32) Error!void {
    self.writer.interface.writeInt(u32, value, .little) catch return error.WriteFailed;
}

fn put16(self: *X11, value: u16) Error!void {
    self.writer.interface.writeInt(u16, value, .little) catch return error.WriteFailed;
}

fn putI16(self: *X11, value: i16) Error!void {
    self.writer.interface.writeInt(i16, value, .little) catch return error.WriteFailed;
}

fn putBytes(self: *X11, bytes: []const u8) Error!void {
    self.writer.interface.writeAll(bytes) catch return error.WriteFailed;
    writePad(&self.writer.interface, bytes.len) catch return error.WriteFailed;
}

pub const CreateWindowArgs = struct {
    id: Window,
    parent: Window,
    x: i16 = 0,
    y: i16 = 0,
    width: u16,
    height: u16,
    /// 0 copies the parent's.
    depth: u8 = 0,
    /// 0 copies the parent's.
    visual: VisualId = 0,
    attributes: WindowAttributes = .{},
};

pub fn createWindow(self: *X11, args: CreateWindowArgs) Error!void {
    _ = try self.begin(1, args.depth, 8 + @as(usize, args.attributes.count()));
    try self.put32(args.id);
    try self.put32(args.parent);
    try self.putI16(args.x);
    try self.putI16(args.y);
    try self.put16(@max(args.width, 1));
    try self.put16(@max(args.height, 1));
    try self.put16(0); // border width
    try self.put16(1); // InputOutput
    try self.put32(args.visual);
    try self.put32(args.attributes.mask());
    args.attributes.write(&self.writer.interface) catch return error.WriteFailed;
}

pub fn changeWindowAttributes(self: *X11, window: Window, attributes: WindowAttributes) Error!void {
    _ = try self.begin(2, 0, 3 + @as(usize, attributes.count()));
    try self.put32(window);
    try self.put32(attributes.mask());
    attributes.write(&self.writer.interface) catch return error.WriteFailed;
}

pub fn destroyWindow(self: *X11, window: Window) Error!void {
    _ = try self.begin(4, 0, 2);
    try self.put32(window);
}

pub fn reparentWindow(self: *X11, window: Window, parent: Window, x: i16, y: i16) Error!void {
    _ = try self.begin(7, 0, 4);
    try self.put32(window);
    try self.put32(parent);
    try self.putI16(x);
    try self.putI16(y);
}

pub fn mapWindow(self: *X11, window: Window) Error!void {
    _ = try self.begin(8, 0, 2);
    try self.put32(window);
}

pub fn unmapWindow(self: *X11, window: Window) Error!void {
    _ = try self.begin(10, 0, 2);
    try self.put32(window);
}

/// Moves and resizes; also raises, since popups must land on top.
pub fn configureWindow(self: *X11, window: Window, rect: Rectangle) Error!void {
    _ = try self.begin(12, 0, 8);
    try self.put32(window);
    try self.put16(0x1 | 0x2 | 0x4 | 0x8 | 0x40);
    try self.put16(0);
    try self.put32(@bitCast(@as(i32, rect.x)));
    try self.put32(@bitCast(@as(i32, rect.y)));
    try self.put32(@max(rect.width, 1));
    try self.put32(@max(rect.height, 1));
    try self.put32(0); // Above
}

pub const Tree = struct { root: Window, parent: Window };

pub fn queryTree(self: *X11, window: Window) Error!Tree {
    const seq = try self.begin(15, 0, 2);
    try self.put32(window);
    const reply = try self.awaitReply(seq);
    return .{
        .root = std.mem.readInt(u32, reply[8..12], .little),
        .parent = std.mem.readInt(u32, reply[12..16], .little),
    };
}

/// The children of `window`, bottom to top. Owned by the caller.
pub fn queryChildren(self: *X11, window: Window) Error![]Window {
    const seq = try self.begin(15, 0, 2);
    try self.put32(window);
    const reply = try self.awaitReply(seq);
    const count = std.mem.readInt(u16, reply[16..18], .little);
    if (reply.len < 32 + @as(usize, count) * 4) return error.Malformed;
    const children = try self.gpa.alloc(Window, count);
    for (children, 0..) |*child, i| {
        child.* = std.mem.readInt(u32, reply[32 + i * 4 ..][0..4], .little);
    }
    return children;
}

pub fn internAtom(self: *X11, name: []const u8) Error!Atom {
    const seq = try self.begin(16, 0, 2 + (name.len + padLen(name.len)) / 4);
    try self.put16(@intCast(name.len));
    try self.put16(0);
    try self.putBytes(name);
    const reply = try self.awaitReply(seq);
    return std.mem.readInt(u32, reply[8..12], .little);
}

/// Replaces a property with `data`, `format` bits per element.
pub fn changeProperty(
    self: *X11,
    window: Window,
    property: Atom,
    @"type": Atom,
    format: u8,
    data: []const u8,
) Error!void {
    _ = try self.begin(18, 0, 6 + (data.len + padLen(data.len)) / 4);
    try self.put32(window);
    try self.put32(property);
    try self.put32(@"type");
    self.writer.interface.writeAll(&.{ format, 0, 0, 0 }) catch return error.WriteFailed;
    try self.put32(@intCast(data.len / (format / 8)));
    try self.putBytes(data);
}

/// The first 32-bit value of `property`, if it is set with that format.
pub fn getPropertyWord(self: *X11, window: Window, property: Atom) Error!?u32 {
    const seq = try self.begin(20, 0, 6);
    try self.put32(window);
    try self.put32(property);
    try self.put32(0); // AnyPropertyType
    try self.put32(0); // offset
    try self.put32(1); // length, in words
    const reply = try self.awaitReply(seq);
    const format = reply[1];
    const count = std.mem.readInt(u32, reply[16..20], .little);
    if (format != 32 or count == 0 or reply.len < 36) return null;
    return std.mem.readInt(u32, reply[32..36], .little);
}

pub fn setSelectionOwner(self: *X11, owner: Window, selection: Atom) Error!void {
    _ = try self.begin(22, 0, 4);
    try self.put32(owner);
    try self.put32(selection);
    try self.put32(current_time);
}

pub fn getSelectionOwner(self: *X11, selection: Atom) Error!Window {
    const seq = try self.begin(23, 0, 2);
    try self.put32(selection);
    const reply = try self.awaitReply(seq);
    return std.mem.readInt(u32, reply[8..12], .little);
}

/// Sends a 32-bit-format ClientMessage to `destination`.
pub fn sendClientMessage(
    self: *X11,
    destination: Window,
    event_mask: u32,
    window: Window,
    @"type": Atom,
    data: [5]u32,
) Error!void {
    var event: [32]u8 = @splat(0);
    event[0] = 33;
    event[1] = 32;
    std.mem.writeInt(u32, event[4..8], window, .little);
    std.mem.writeInt(u32, event[8..12], @"type", .little);
    for (data, 0..) |word, i| std.mem.writeInt(u32, event[12 + i * 4 ..][0..4], word, .little);
    try self.sendEvent(destination, event_mask, event);
}

pub fn sendEvent(self: *X11, destination: Window, event_mask: u32, event: [32]u8) Error!void {
    _ = try self.begin(25, 0, 11);
    try self.put32(destination);
    try self.put32(event_mask);
    self.writer.interface.writeAll(&event) catch return error.WriteFailed;
}

/// Builds a synthetic pointer event, as a test or a nested toolkit would.
pub fn pointerEvent(code: u8, button: u8, window: Window, x: i16, y: i16, root_x: i16, root_y: i16) [32]u8 {
    var event: [32]u8 = @splat(0);
    event[0] = code;
    event[1] = button;
    std.mem.writeInt(u32, event[12..16], window, .little);
    std.mem.writeInt(i16, event[20..22], root_x, .little);
    std.mem.writeInt(i16, event[22..24], root_y, .little);
    std.mem.writeInt(i16, event[24..26], x, .little);
    std.mem.writeInt(i16, event[26..28], y, .little);
    event[30] = 1; // same screen
    return event;
}

/// Grabs the pointer for a popup. Returns whether the grab took.
pub fn grabPointer(self: *X11, window: Window, event_mask: u16) Error!bool {
    const seq = try self.begin(26, 1, 6); // owner_events: report inside our windows normally
    try self.put32(window);
    try self.put16(event_mask);
    self.writer.interface.writeAll(&.{ 1, 1 }) catch return error.WriteFailed; // async, async
    try self.put32(none); // confine_to
    try self.put32(none); // cursor
    try self.put32(current_time);
    const reply = try self.awaitReply(seq);
    return reply[1] == 0;
}

pub fn ungrabPointer(self: *X11) Error!void {
    _ = try self.begin(27, 0, 2);
    try self.put32(current_time);
}

pub fn grabKeyboard(self: *X11, window: Window) Error!bool {
    const seq = try self.begin(31, 1, 4);
    try self.put32(window);
    try self.put32(current_time);
    self.writer.interface.writeAll(&.{ 1, 1, 0, 0 }) catch return error.WriteFailed;
    const reply = try self.awaitReply(seq);
    return reply[1] == 0;
}

pub fn ungrabKeyboard(self: *X11) Error!void {
    _ = try self.begin(32, 0, 2);
    try self.put32(current_time);
}

pub const Pointer = struct { root_x: i16, root_y: i16 };

pub fn queryPointer(self: *X11, window: Window) Error!Pointer {
    const seq = try self.begin(38, 0, 2);
    try self.put32(window);
    const reply = try self.awaitReply(seq);
    return .{
        .root_x = std.mem.readInt(i16, reply[16..18], .little),
        .root_y = std.mem.readInt(i16, reply[18..20], .little),
    };
}

pub fn openFont(self: *X11, id: u32, name: []const u8) Error!void {
    _ = try self.begin(45, 0, 3 + (name.len + padLen(name.len)) / 4);
    try self.put32(id);
    try self.put16(@intCast(name.len));
    try self.put16(0);
    try self.putBytes(name);
}

pub fn closeFont(self: *X11, id: u32) Error!void {
    _ = try self.begin(46, 0, 2);
    try self.put32(id);
}

pub const FontMetrics = struct { ascent: i16, descent: i16, char_width: i16 };

/// Fails when `font` was never opened, which is how a missing font shows up.
pub fn queryFont(self: *X11, font: u32) Error!FontMetrics {
    const seq = try self.begin(47, 0, 2);
    try self.put32(font);
    const reply = try self.awaitReply(seq);
    if (reply.len < 60) return error.Malformed;
    return .{
        .char_width = std.mem.readInt(i16, reply[28..30], .little),
        .ascent = std.mem.readInt(i16, reply[52..54], .little),
        .descent = std.mem.readInt(i16, reply[54..56], .little),
    };
}

pub fn createGc(self: *X11, id: u32, drawable: u32, values: GcValues) Error!void {
    _ = try self.begin(55, 0, 4 + @as(usize, values.count()));
    try self.put32(id);
    try self.put32(drawable);
    try self.put32(values.mask());
    values.write(&self.writer.interface) catch return error.WriteFailed;
}

pub fn changeGc(self: *X11, gc: u32, values: GcValues) Error!void {
    _ = try self.begin(56, 0, 3 + @as(usize, values.count()));
    try self.put32(gc);
    try self.put32(values.mask());
    values.write(&self.writer.interface) catch return error.WriteFailed;
}

pub fn freeGc(self: *X11, gc: u32) Error!void {
    _ = try self.begin(60, 0, 2);
    try self.put32(gc);
}

pub fn clearArea(self: *X11, window: Window, rect: Rectangle) Error!void {
    _ = try self.begin(61, 0, 4);
    try self.put32(window);
    try self.putI16(rect.x);
    try self.putI16(rect.y);
    try self.put16(rect.width);
    try self.put16(rect.height);
}

pub fn fillRectangles(self: *X11, drawable: u32, gc: u32, rects: []const Rectangle) Error!void {
    _ = try self.begin(70, 0, 3 + rects.len * 2);
    try self.put32(drawable);
    try self.put32(gc);
    for (rects) |rect| {
        try self.putI16(rect.x);
        try self.putI16(rect.y);
        try self.put16(rect.width);
        try self.put16(rect.height);
    }
}

/// ZPixmap upload. `pixels` holds 32-bit little-endian values, `width * height`
/// of them, in the drawable's pixel layout.
pub fn putImage(
    self: *X11,
    drawable: u32,
    gc: u32,
    depth: u8,
    width: u16,
    height: u16,
    x: i16,
    y: i16,
    pixels: []const u8,
) Error!void {
    _ = try self.begin(72, 2, 6 + pixels.len / 4);
    try self.put32(drawable);
    try self.put32(gc);
    try self.put16(width);
    try self.put16(height);
    try self.putI16(x);
    try self.putI16(y);
    self.writer.interface.writeAll(&.{ 0, depth, 0, 0 }) catch return error.WriteFailed;
    try self.putBytes(pixels);
}

/// ZPixmap download. The slice is valid until the next read.
pub fn getImage(self: *X11, drawable: u32, rect: Rectangle) Error![]const u8 {
    const seq = try self.begin(73, 2, 5);
    try self.put32(drawable);
    try self.putI16(rect.x);
    try self.putI16(rect.y);
    try self.put16(rect.width);
    try self.put16(rect.height);
    try self.put32(0xffffffff);
    const reply = try self.awaitReply(seq);
    return reply[32..];
}

/// Draws up to 255 UCS-2 characters with the GC's font, foreground and
/// background. `text` is UTF-8; characters outside the BMP become '?'.
pub fn imageText(self: *X11, drawable: u32, gc: u32, x: i16, y: i16, text: []const u8) Error!void {
    var chars: [255]u16 = undefined;
    const count = toChar2b(text, &chars);
    if (count == 0) return;
    _ = try self.begin(77, @intCast(count), 4 + (count * 2 + padLen(count * 2)) / 4);
    try self.put32(drawable);
    try self.put32(gc);
    try self.putI16(x);
    try self.putI16(y);
    for (chars[0..count]) |c| {
        self.writer.interface.writeInt(u16, c, .big) catch return error.WriteFailed;
    }
    writePad(&self.writer.interface, count * 2) catch return error.WriteFailed;
}

/// UTF-8 to big-endian-ready UCS-2, truncating at `out.len`. Invalid bytes and
/// characters beyond the BMP become '?'.
pub fn toChar2b(text: []const u8, out: []u16) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < out.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            out[count] = '?';
            count += 1;
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            out[count] = '?';
            count += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch '?';
        out[count] = if (cp > 0xffff) '?' else @intCast(cp);
        count += 1;
        i += len;
    }
    return count;
}

/// The number of characters `toChar2b` produces, for layout.
pub fn charCount(text: []const u8) usize {
    var chars: [255]u16 = undefined;
    return toChar2b(text, &chars);
}

pub fn createColormap(self: *X11, id: u32, window: Window, visual_id: VisualId) Error!void {
    _ = try self.begin(78, 0, 4);
    try self.put32(id);
    try self.put32(window);
    try self.put32(visual_id);
}

pub fn freeColormap(self: *X11, id: u32) Error!void {
    _ = try self.begin(79, 0, 2);
    try self.put32(id);
}

/// Round-trips to the server, so every earlier request has been processed.
pub fn sync(self: *X11) Error!void {
    // GetInputFocus is the conventional no-op with a reply.
    const seq = try self.begin(43, 0, 1);
    _ = try self.awaitReply(seq);
}

test "parseDisplay accepts local forms and refuses TCP" {
    try std.testing.expectEqual(Display{ .number = 0, .screen = 0 }, try parseDisplay(":0"));
    try std.testing.expectEqual(Display{ .number = 1, .screen = 2 }, try parseDisplay(":1.2"));
    try std.testing.expectEqual(Display{ .number = 10, .screen = 0 }, try parseDisplay("unix:10"));
    try std.testing.expectError(error.DisplayUnsupported, parseDisplay("localhost:0"));
    try std.testing.expectError(error.DisplayUnsupported, parseDisplay(""));
    try std.testing.expectError(error.DisplayUnsupported, parseDisplay(":x"));
}

fn testAuthRecord(out: *std.ArrayList(u8), family: u16, number: []const u8, name: []const u8, data: []const u8) !void {
    const gpa = std.testing.allocator;
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, family, .big);
    try out.appendSlice(gpa, &len);
    for ([_][]const u8{ "host", number, name, data }) |field| {
        std.mem.writeInt(u16, &len, @intCast(field.len), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, field);
    }
}

test "findCookie picks the local MIT cookie for the display" {
    const gpa = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try testAuthRecord(&file, 0, "0", cookie_name, "internet"); // a TCP record
    try testAuthRecord(&file, 256, "1", cookie_name, "display1");
    try testAuthRecord(&file, 256, "0", "XDM-AUTHORIZATION-1", "other-scheme");
    try testAuthRecord(&file, 256, "0", cookie_name, "display0");

    try std.testing.expectEqualStrings("display0", findCookie(file.items, 0).?);
    try std.testing.expectEqualStrings("display1", findCookie(file.items, 1).?);
    try std.testing.expect(findCookie(file.items, 2) == null);
    // Truncated files stop the scan instead of reading past the end.
    try std.testing.expect(findCookie(file.items[0 .. file.items.len - 3], 0) == null);
}

test "parseSetup reads the first screen and its visuals" {
    const gpa = std.testing.allocator;
    var body: [32 + 4 + 16 + 40 + 8 + 24 + 8 + 24]u8 = @splat(0);
    std.mem.writeInt(u32, body[4..8], 0x0400000, .little); // id base
    std.mem.writeInt(u32, body[8..12], 0x01fffff, .little); // id mask
    std.mem.writeInt(u16, body[16..18], 4, .little); // vendor length
    std.mem.writeInt(u16, body[18..20], 65535, .little);
    body[20] = 1; // screens
    body[21] = 2; // formats
    @memcpy(body[32..36], "Test");
    body[36] = 24;
    body[37] = 32;
    body[44] = 32;
    body[45] = 32;
    const screen = body[52..];
    std.mem.writeInt(u32, screen[0..4], 0x123, .little); // root
    std.mem.writeInt(u16, screen[20..22], 1920, .little);
    std.mem.writeInt(u16, screen[22..24], 1080, .little);
    std.mem.writeInt(u32, screen[32..36], 0x21, .little); // root visual
    screen[38] = 24;
    screen[39] = 2; // depths
    const d24 = body[92..];
    d24[0] = 24;
    std.mem.writeInt(u16, d24[2..4], 1, .little);
    std.mem.writeInt(u32, d24[8..12], 0x21, .little);
    d24[12] = Visual.true_color;
    std.mem.writeInt(u32, d24[16..20], 0xff0000, .little);
    std.mem.writeInt(u32, d24[20..24], 0x00ff00, .little);
    std.mem.writeInt(u32, d24[24..28], 0x0000ff, .little);
    const d32 = body[124..];
    d32[0] = 32;
    std.mem.writeInt(u16, d32[2..4], 1, .little);
    std.mem.writeInt(u32, d32[8..12], 0x55, .little);
    d32[12] = Visual.true_color;

    const setup = try parseSetup(gpa, &body);
    defer gpa.free(setup.visuals);
    try std.testing.expectEqual(@as(u32, 0x123), setup.root);
    try std.testing.expectEqual(@as(u8, 24), setup.root_depth);
    try std.testing.expectEqual(@as(u8, 32), setup.bpp_depth24);
    try std.testing.expectEqual(@as(u16, 1920), setup.width);
    try std.testing.expectEqual(@as(usize, 2), setup.visuals.len);
    try std.testing.expect(setup.visuals[0].isRgb888());
    try std.testing.expectEqual(@as(u8, 32), setup.visuals[1].depth);
    try std.testing.expectError(error.Malformed, parseSetup(gpa, body[0..60]));
}

test "events decode from their wire layout" {
    var raw: [32]u8 = @splat(0);
    raw[0] = 4 | 0x80; // a synthetic ButtonPress
    raw[1] = 3;
    std.mem.writeInt(u32, raw[12..16], 0x77, .little);
    std.mem.writeInt(i16, raw[20..22], -5, .little);
    std.mem.writeInt(i16, raw[26..28], 9, .little);
    std.mem.writeInt(u16, raw[28..30], 0x5, .little);
    const press = Event.decode(&raw).button_press;
    try std.testing.expectEqual(@as(u8, 3), press.detail);
    try std.testing.expectEqual(@as(u32, 0x77), press.window);
    try std.testing.expectEqual(@as(i16, -5), press.root_x);
    try std.testing.expectEqual(@as(i16, 9), press.y);
    try std.testing.expectEqual(@as(u16, 0x5), press.state);

    raw = @splat(0);
    raw[0] = 22;
    std.mem.writeInt(u32, raw[8..12], 0x99, .little);
    std.mem.writeInt(u16, raw[20..22], 24, .little);
    std.mem.writeInt(u16, raw[22..24], 22, .little);
    const configure = Event.decode(&raw).configure;
    try std.testing.expectEqual(@as(u32, 0x99), configure.window);
    try std.testing.expectEqual(@as(u16, 24), configure.width);

    raw = @splat(0);
    raw[0] = 33;
    raw[1] = 32;
    std.mem.writeInt(u32, raw[8..12], 0x42, .little);
    std.mem.writeInt(u32, raw[16..20], 7, .little);
    const message = Event.decode(&raw).client_message;
    try std.testing.expectEqual(@as(u32, 0x42), message.type);
    try std.testing.expectEqual(@as(u32, 7), message.data[1]);
}

test "toChar2b maps the BMP and replaces the rest" {
    var out: [8]u16 = undefined;
    const n = toChar2b("a启😀\xff", &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u16, 'a'), out[0]);
    try std.testing.expectEqual(@as(u16, 0x542f), out[1]);
    try std.testing.expectEqual(@as(u16, '?'), out[2]);
    try std.testing.expectEqual(@as(u16, '?'), out[3]);
    // Truncation stops at the buffer.
    try std.testing.expectEqual(@as(usize, 2), toChar2b("abc", out[0..2]));
}

test "pointerEvent round-trips through decode" {
    const raw = pointerEvent(5, 1, 0x10, 3, 4, 100, 200);
    const release = Event.decode(&raw).button_release;
    try std.testing.expectEqual(@as(u8, 1), release.detail);
    try std.testing.expectEqual(@as(u32, 0x10), release.window);
    try std.testing.expectEqual(@as(i16, 4), release.y);
    try std.testing.expectEqual(@as(i16, 200), release.root_y);
}

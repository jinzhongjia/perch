//! A D-Bus message: the fixed header, the header field array, and the body.

const std = @import("std");
const wire = @import("wire.zig");

const Message = @This();

pub const Type = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
    _,
};

pub const Flags = packed struct(u8) {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _reserved: u5 = 0,
};

/// Header field codes from the specification.
pub const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
    _,
};

/// Everything before the header field array: 12 bytes plus the array's own
/// length word.
pub const fixed_header_len = 16;
pub const protocol_version = 1;

/// Ceiling from the specification; also our read guard.
pub const max_message_len = 134217728;

type: Type,
flags: Flags = .{},
serial: u32,
endian: std.builtin.Endian = .little,

path: ?[]const u8 = null,
interface: ?[]const u8 = null,
member: ?[]const u8 = null,
error_name: ?[]const u8 = null,
reply_serial: ?u32 = null,
destination: ?[]const u8 = null,
sender: ?[]const u8 = null,
signature: ?[]const u8 = null,

/// Points into the buffer the message was parsed from, or into the caller's
/// marshalled body when sending.
body: []const u8 = &.{},

pub const ParseError = error{Malformed};

/// Total length of the message whose first `fixed_header_len` bytes are `prefix`.
pub fn totalLen(prefix: *const [fixed_header_len]u8) ParseError!usize {
    const endian: std.builtin.Endian = switch (prefix[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.Malformed,
    };
    if (prefix[3] != protocol_version) return error.Malformed;
    const body_len = std.mem.readInt(u32, prefix[4..8], endian);
    const fields_len = std.mem.readInt(u32, prefix[12..16], endian);
    const unpadded = fixed_header_len + @as(usize, fields_len);
    const total = std.mem.alignForward(usize, unpadded, 8) + body_len;
    if (total > max_message_len) return error.Malformed;
    return total;
}

/// Parses a complete message. Returned slices borrow from `buffer`.
pub fn parse(buffer: []const u8) ParseError!Message {
    if (buffer.len < fixed_header_len) return error.Malformed;
    const prefix = buffer[0..fixed_header_len];
    if (try totalLen(prefix) != buffer.len) return error.Malformed;

    const endian: std.builtin.Endian = if (prefix[0] == 'l') .little else .big;
    var self: Message = .{
        .type = @enumFromInt(prefix[1]),
        .flags = @bitCast(prefix[2]),
        .serial = std.mem.readInt(u32, prefix[8..12], endian),
        .endian = endian,
    };
    if (self.serial == 0) return error.Malformed;

    // The field array starts at offset 12, so its length word is already read.
    var r: wire.Reader = .init(buffer, endian);
    r.pos = 12;
    const fields_end = try r.arrayBegin("(yv)");
    while (r.pos < fields_end) {
        try r.structBegin();
        const code: Field = @enumFromInt(try r.byte());
        const value_sig = try r.variantBegin();
        switch (code) {
            .path => self.path = try expectAndRead(&r, value_sig, "o"),
            .interface => self.interface = try expectAndRead(&r, value_sig, "s"),
            .member => self.member = try expectAndRead(&r, value_sig, "s"),
            .error_name => self.error_name = try expectAndRead(&r, value_sig, "s"),
            .destination => self.destination = try expectAndRead(&r, value_sig, "s"),
            .sender => self.sender = try expectAndRead(&r, value_sig, "s"),
            .signature => {
                if (!std.mem.eql(u8, value_sig, "g")) return error.Malformed;
                self.signature = try r.signature();
            },
            .reply_serial => {
                if (!std.mem.eql(u8, value_sig, "u")) return error.Malformed;
                self.reply_serial = try r.int(u32);
            },
            // UNIX_FDS and anything the specification adds later.
            else => try r.skip(value_sig),
        }
    }
    if (r.pos != fields_end) return error.Malformed;

    try r.pad(8);
    self.body = buffer[r.pos..];
    return self;
}

fn expectAndRead(r: *wire.Reader, actual_sig: []const u8, expected_sig: []const u8) ParseError![]const u8 {
    if (!std.mem.eql(u8, actual_sig, expected_sig)) return error.Malformed;
    return r.string();
}

/// Marshals the message into `out`, header first. `body` must already be
/// marshalled; its signature has to match `signature`.
pub fn writeTo(self: Message, out: *wire.Writer) wire.Writer.Error!void {
    try out.byte('l');
    try out.byte(@intFromEnum(self.type));
    try out.byte(@bitCast(self.flags));
    try out.byte(protocol_version);
    try out.int(u32, @intCast(self.body.len));
    try out.int(u32, self.serial);

    const fields = try out.arrayBegin("(yv)");
    if (self.path) |v| try writeStringField(out, .path, "o", v);
    if (self.interface) |v| try writeStringField(out, .interface, "s", v);
    if (self.member) |v| try writeStringField(out, .member, "s", v);
    if (self.error_name) |v| try writeStringField(out, .error_name, "s", v);
    if (self.reply_serial) |v| {
        try out.structBegin();
        try out.byte(@intFromEnum(Field.reply_serial));
        try out.variantUint32(v);
    }
    if (self.destination) |v| try writeStringField(out, .destination, "s", v);
    if (self.sender) |v| try writeStringField(out, .sender, "s", v);
    if (self.signature) |v| {
        try out.structBegin();
        try out.byte(@intFromEnum(Field.signature));
        try out.variantBegin("g");
        try out.signature(v);
    }
    out.arrayEnd(fields);

    try out.pad(8);
    try out.raw(self.body);
}

fn writeStringField(
    out: *wire.Writer,
    code: Field,
    value_sig: []const u8,
    value: []const u8,
) wire.Writer.Error!void {
    try out.structBegin();
    try out.byte(@intFromEnum(code));
    try out.variantBegin(value_sig);
    try out.string(value);
}

/// True when this is a method call for `interface.member`.
pub fn isCall(self: Message, interface: []const u8, member: []const u8) bool {
    if (self.type != .method_call) return false;
    const m = self.member orelse return false;
    if (!std.mem.eql(u8, m, member)) return false;
    // Some peers omit the interface on calls; accept that.
    const i = self.interface orelse return true;
    return std.mem.eql(u8, i, interface);
}

pub fn isSignal(self: Message, interface: []const u8, member: []const u8) bool {
    if (self.type != .signal) return false;
    const i = self.interface orelse return false;
    const m = self.member orelse return false;
    return std.mem.eql(u8, i, interface) and std.mem.eql(u8, m, member);
}

test "header round-trips through parse" {
    const gpa = std.testing.allocator;

    var body: wire.Writer = .init(gpa);
    defer body.deinit();
    try body.string("org.kde.StatusNotifierItem-1234-1");

    var out: wire.Writer = .init(gpa);
    defer out.deinit();

    const sent: Message = .{
        .type = .method_call,
        .serial = 3,
        .path = "/StatusNotifierWatcher",
        .interface = "org.kde.StatusNotifierWatcher",
        .member = "RegisterStatusNotifierItem",
        .destination = "org.kde.StatusNotifierWatcher",
        .signature = "s",
        .body = body.bytes(),
    };
    try sent.writeTo(&out);

    // The body must start on an 8-byte boundary.
    try std.testing.expectEqual(@as(usize, 0), (out.len() - body.len()) % 8);

    const got = try parse(out.bytes());
    try std.testing.expectEqual(Type.method_call, got.type);
    try std.testing.expectEqual(@as(u32, 3), got.serial);
    try std.testing.expectEqualStrings("/StatusNotifierWatcher", got.path.?);
    try std.testing.expectEqualStrings("RegisterStatusNotifierItem", got.member.?);
    try std.testing.expectEqualStrings("s", got.signature.?);
    try std.testing.expect(got.reply_serial == null);

    var r: wire.Reader = .init(got.body, got.endian);
    try std.testing.expectEqualStrings("org.kde.StatusNotifierItem-1234-1", try r.string());
}

test "totalLen agrees with the marshalled size" {
    const gpa = std.testing.allocator;
    var out: wire.Writer = .init(gpa);
    defer out.deinit();

    const sent: Message = .{
        .type = .signal,
        .serial = 9,
        .path = "/StatusNotifierItem",
        .interface = "org.kde.StatusNotifierItem",
        .member = "NewIcon",
    };
    try sent.writeTo(&out);
    try std.testing.expectEqual(out.len(), try totalLen(out.bytes()[0..fixed_header_len]));
}

test "a reply carries its serial back" {
    const gpa = std.testing.allocator;
    var out: wire.Writer = .init(gpa);
    defer out.deinit();

    const sent: Message = .{ .type = .method_return, .serial = 12, .reply_serial = 7, .destination = ":1.42" };
    try sent.writeTo(&out);

    const got = try parse(out.bytes());
    try std.testing.expectEqual(@as(u32, 7), got.reply_serial.?);
    try std.testing.expectEqualStrings(":1.42", got.destination.?);
}

test "malformed messages are rejected" {
    try std.testing.expectError(error.Malformed, parse("short"));

    var prefix: [fixed_header_len]u8 = @splat(0);
    prefix[0] = 'x'; // bad endianness marker
    try std.testing.expectError(error.Malformed, totalLen(&prefix));

    prefix[0] = 'l';
    prefix[3] = 9; // bad protocol version
    try std.testing.expectError(error.Malformed, totalLen(&prefix));
}

//! A D-Bus session bus connection: transport, SASL handshake, and message I/O.
//!
//! Only what a tray needs — no object manager, no signal-match bookkeeping
//! beyond `addMatch`, no threading. The caller owns the event loop and decides
//! what to do with each inbound message.

const std = @import("std");
const linux = std.os.linux;
const net = std.Io.net;

const Message = @import("Message.zig");
const wire = @import("wire.zig");

const Connection = @This();

pub const Error = error{
    /// `DBUS_SESSION_BUS_ADDRESS` is missing, or names a transport we do not speak.
    AddressUnsupported,
    ConnectFailed,
    AuthFailed,
    /// The peer closed the socket, or the socket errored.
    Disconnected,
    WriteFailed,
    /// A message did not follow the wire format.
    Malformed,
    /// The bus answered a method call with an error.
    CallFailed,
    OutOfMemory,
};

pub const bus_name = "org.freedesktop.DBus";
pub const bus_path = "/org/freedesktop/DBus";
pub const bus_interface = "org.freedesktop.DBus";
pub const properties_interface = "org.freedesktop.DBus.Properties";
pub const introspectable_interface = "org.freedesktop.DBus.Introspectable";
pub const peer_interface = "org.freedesktop.DBus.Peer";

/// `RequestName` flags.
pub const request_name_replace_existing = 0x2;
pub const request_name_do_not_queue = 0x4;

gpa: std.mem.Allocator,
io: std.Io,
stream: net.Stream,
reader: net.Stream.Reader,
writer: net.Stream.Writer,
read_buffer: []u8,
write_buffer: []u8,

/// Scratch for marshalling outbound messages; reused across sends.
out: wire.Writer,
/// Holds the message returned by the most recent `readMessage`.
inbound: std.ArrayList(u8) = .empty,
/// Name the bus assigned us, e.g. `":1.42"`.
unique_name: []u8 = &.{},
serial: u32 = 0,

/// Reads `DBUS_SESSION_BUS_ADDRESS` and connects, authenticating as the current
/// uid and sending `Hello`.
pub fn create(gpa: std.mem.Allocator, io: std.Io, address: []const u8) Error!*Connection {
    var path_buffer: [net.UnixAddress.max_len]u8 = undefined;
    const path = try parseUnixPath(address, &path_buffer);
    const unix_address = net.UnixAddress.init(path) catch return error.AddressUnsupported;

    const self = try gpa.create(Connection);
    errdefer gpa.destroy(self);

    const read_buffer = try gpa.alloc(u8, 64 * 1024);
    errdefer gpa.free(read_buffer);
    const write_buffer = try gpa.alloc(u8, 16 * 1024);
    errdefer gpa.free(write_buffer);

    const stream = unix_address.connect(io) catch return error.ConnectFailed;
    errdefer stream.close(io);

    self.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .out = .init(gpa),
    };
    // Both hold an `interface` that is located via @fieldParentPtr, so they must
    // live at the final address — hence the in-place initialisation.
    self.reader = stream.reader(io, read_buffer);
    self.writer = stream.writer(io, write_buffer);

    errdefer {
        self.out.deinit();
        self.inbound.deinit(gpa);
    }
    try self.authenticate();
    try self.hello();
    return self;
}

pub fn destroy(self: *Connection) void {
    const gpa = self.gpa;
    self.stream.close(self.io);
    self.out.deinit();
    self.inbound.deinit(gpa);
    gpa.free(self.unique_name);
    gpa.free(self.read_buffer);
    gpa.free(self.write_buffer);
    gpa.destroy(self);
}

/// The socket, for polling alongside other descriptors.
pub fn handle(self: *const Connection) linux.fd_t {
    return self.stream.socket.handle;
}

/// Picks the unix socket out of a bus address list such as
/// `unix:path=/run/user/1000/bus` or `unix:abstract=/tmp/dbus-XXXX,guid=...`.
fn parseUnixPath(address: []const u8, buffer: []u8) Error![]const u8 {
    var candidates = std.mem.splitScalar(u8, address, ';');
    while (candidates.next()) |candidate| {
        if (!std.mem.startsWith(u8, candidate, "unix:")) continue;
        var pairs = std.mem.splitScalar(u8, candidate["unix:".len..], ',');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "path")) {
                if (value.len > buffer.len) return error.AddressUnsupported;
                @memcpy(buffer[0..value.len], value);
                return buffer[0..value.len];
            }
            if (std.mem.eql(u8, key, "abstract")) {
                // Abstract sockets live in their own namespace, marked by a
                // leading nul byte rather than a filesystem path.
                if (value.len + 1 > buffer.len) return error.AddressUnsupported;
                buffer[0] = 0;
                @memcpy(buffer[1..][0..value.len], value);
                return buffer[0 .. value.len + 1];
            }
        }
    }
    return error.AddressUnsupported;
}

/// `AUTH EXTERNAL`, where the credential is the hex-encoded decimal uid.
fn authenticate(self: *Connection) Error!void {
    const w = &self.writer.interface;

    var uid_text: [16]u8 = undefined;
    const uid = std.fmt.bufPrint(&uid_text, "{d}", .{linux.getuid()}) catch unreachable;

    // The leading nul byte is part of the transport, not the SASL exchange.
    w.writeAll("\x00AUTH EXTERNAL ") catch return error.WriteFailed;
    for (uid) |c| w.print("{x:0>2}", .{c}) catch return error.WriteFailed;
    w.writeAll("\r\n") catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;

    const greeting = try self.readLine();
    if (!std.mem.startsWith(u8, greeting, "OK")) return error.AuthFailed;

    w.writeAll("BEGIN\r\n") catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;
}

fn readLine(self: *Connection) Error![]const u8 {
    // Inclusive, so the delimiter is consumed rather than left for the first
    // message read.
    const line = self.reader.interface.takeDelimiterInclusive('\n') catch return error.Disconnected;
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn hello(self: *Connection) Error!void {
    const serial = try self.call(.{
        .destination = bus_name,
        .path = bus_path,
        .interface = bus_interface,
        .member = "Hello",
    });
    const response = try self.awaitReply(serial);
    var r: wire.Reader = .init(response.body, response.endian);
    const name = r.string() catch return error.Malformed;
    self.unique_name = try self.gpa.dupe(u8, name);
}

/// Claims a well-known name. Returns the bus's reply code, where 1 means we are
/// the primary owner.
pub fn requestName(self: *Connection, name: []const u8, flags: u32) Error!u32 {
    var body: wire.Writer = .init(self.gpa);
    defer body.deinit();
    try body.string(name);
    try body.int(u32, flags);

    const serial = try self.call(.{
        .destination = bus_name,
        .path = bus_path,
        .interface = bus_interface,
        .member = "RequestName",
        .signature = "su",
        .body = body.bytes(),
    });
    const response = try self.awaitReply(serial);
    var r: wire.Reader = .init(response.body, response.endian);
    return r.int(u32) catch error.Malformed;
}

/// Subscribes to signals. `rule` is a match rule as in the specification.
pub fn addMatch(self: *Connection, rule: []const u8) Error!void {
    var body: wire.Writer = .init(self.gpa);
    defer body.deinit();
    try body.string(rule);

    const serial = try self.call(.{
        .destination = bus_name,
        .path = bus_path,
        .interface = bus_interface,
        .member = "AddMatch",
        .signature = "s",
        .body = body.bytes(),
    });
    _ = try self.awaitReply(serial);
}

/// Whether anyone currently owns `name`.
pub fn nameHasOwner(self: *Connection, name: []const u8) Error!bool {
    var body: wire.Writer = .init(self.gpa);
    defer body.deinit();
    try body.string(name);

    const serial = try self.call(.{
        .destination = bus_name,
        .path = bus_path,
        .interface = bus_interface,
        .member = "NameHasOwner",
        .signature = "s",
        .body = body.bytes(),
    });
    const response = try self.awaitReply(serial);
    var r: wire.Reader = .init(response.body, response.endian);
    return r.boolean() catch error.Malformed;
}

pub fn nextSerial(self: *Connection) u32 {
    self.serial += 1;
    return self.serial;
}

pub fn send(self: *Connection, message: Message) Error!void {
    self.out.clearRetainingCapacity();
    try message.writeTo(&self.out);
    const w = &self.writer.interface;
    w.writeAll(self.out.bytes()) catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;
}

pub const CallArgs = struct {
    destination: ?[]const u8 = null,
    path: []const u8,
    interface: ?[]const u8 = null,
    member: []const u8,
    signature: ?[]const u8 = null,
    body: []const u8 = &.{},
    no_reply: bool = false,
};

/// Sends a method call and returns its serial, for matching the reply.
pub fn call(self: *Connection, args: CallArgs) Error!u32 {
    const serial = self.nextSerial();
    try self.send(.{
        .type = .method_call,
        .flags = .{ .no_reply_expected = args.no_reply },
        .serial = serial,
        .destination = args.destination,
        .path = args.path,
        .interface = args.interface,
        .member = args.member,
        .signature = args.signature,
        .body = args.body,
    });
    return serial;
}

pub const SignalArgs = struct {
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    signature: ?[]const u8 = null,
    body: []const u8 = &.{},
};

pub fn emit(self: *Connection, args: SignalArgs) Error!void {
    try self.send(.{
        .type = .signal,
        .serial = self.nextSerial(),
        .path = args.path,
        .interface = args.interface,
        .member = args.member,
        .signature = args.signature,
        .body = args.body,
    });
}

pub fn reply(self: *Connection, to: Message, signature: ?[]const u8, body: []const u8) Error!void {
    try self.send(.{
        .type = .method_return,
        .serial = self.nextSerial(),
        .reply_serial = to.serial,
        .destination = to.sender,
        .signature = signature,
        .body = body,
    });
}

pub fn replyError(self: *Connection, to: Message, name: []const u8, text: []const u8) Error!void {
    var body: wire.Writer = .init(self.gpa);
    defer body.deinit();
    try body.string(text);

    try self.send(.{
        .type = .error_reply,
        .serial = self.nextSerial(),
        .reply_serial = to.serial,
        .destination = to.sender,
        .error_name = name,
        .signature = "s",
        .body = body.bytes(),
    });
}

/// Reads the next message. The result borrows this connection's inbound buffer
/// and is invalidated by the following read.
pub fn readMessage(self: *Connection) Error!Message {
    const r = &self.reader.interface;
    const prefix = r.peekArray(Message.fixed_header_len) catch return error.Disconnected;
    const total = try Message.totalLen(prefix);
    try self.inbound.resize(self.gpa, total);
    r.readSliceAll(self.inbound.items) catch return error.Disconnected;
    return Message.parse(self.inbound.items);
}

/// Bytes already read from the socket but not yet parsed.
pub fn buffered(self: *const Connection) usize {
    return self.reader.interface.bufferedLen();
}

/// Reads until the reply to `serial` arrives, discarding anything else. Only
/// safe during setup, before the tray is serving requests.
fn awaitReply(self: *Connection, serial: u32) Error!Message {
    while (true) {
        const message = try self.readMessage();
        if (message.reply_serial != serial) continue;
        if (message.type == .error_reply) return error.CallFailed;
        if (message.type != .method_return) return error.Malformed;
        return message;
    }
}

test "parseUnixPath handles paths, abstract sockets and lists" {
    var buffer: [net.UnixAddress.max_len]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/run/user/1000/bus",
        try parseUnixPath("unix:path=/run/user/1000/bus", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/run/user/1000/bus",
        try parseUnixPath("unix:path=/run/user/1000/bus,guid=abc123", &buffer),
    );
    try std.testing.expectEqualStrings(
        "\x00/tmp/dbus-Ab12Cd",
        try parseUnixPath("tcp:host=localhost,port=1;unix:abstract=/tmp/dbus-Ab12Cd,guid=x", &buffer),
    );
    try std.testing.expectError(
        error.AddressUnsupported,
        parseUnixPath("tcp:host=localhost,port=1234", &buffer),
    );
    try std.testing.expectError(error.AddressUnsupported, parseUnixPath("", &buffer));
}

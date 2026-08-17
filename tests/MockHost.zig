//! A fake StatusNotifierItem host and notification daemon, for testing perch
//! without a desktop.
//!
//! Real hosts differ in ways that break trays: some read `IconName` and ignore
//! pixmaps, some fetch the menu with a property filter, some pull it one level at
//! a time, some call `AboutToShow` first. Installing four desktops to find that
//! out is not practical, so the differences are modelled here instead and the
//! whole matrix runs on a private bus in CI.
//!
//! Must run on its own bus — `dbus-run-session` — because a real session already
//! owns these names.

const std = @import("std");
const perch = @import("perch");

const Connection = perch.linux.Connection;
const Message = perch.linux.Message;
const sni = perch.linux.sni;
const wire = perch.linux.wire;

const MockHost = @This();

pub const Error = Connection.Error || error{NameTaken};

/// One registered item.
pub const Item = struct {
    service: []u8,

    fn deinit(self: *Item, gpa: std.mem.Allocator) void {
        gpa.free(self.service);
    }
};

/// A notification the daemon side has accepted.
pub const Posted = struct {
    id: u32,
    app_name: []u8,
    summary: []u8,
    body: []u8,
    actions: std.ArrayList([]u8) = .empty,
    /// The `value` hint, when present.
    progress: ?i32 = null,
    replaces: u32,
    closed: bool = false,

    fn deinit(self: *Posted, gpa: std.mem.Allocator) void {
        gpa.free(self.app_name);
        gpa.free(self.summary);
        gpa.free(self.body);
        for (self.actions.items) |action| gpa.free(action);
        self.actions.deinit(gpa);
    }
};

gpa: std.mem.Allocator,
conn: *Connection,
/// Which watcher name we took, so tests can check the fallback order.
watcher_name: []const u8,
items: std.ArrayList(Item) = .empty,
notifications: std.ArrayList(Posted) = .empty,
next_notification_id: u32 = 100,
body: wire.Writer,

/// Claims `watcher_name` plus the notification daemon name.
pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    watcher_name: []const u8,
) Error!*MockHost {
    const conn = try Connection.create(gpa, io, address);
    errdefer conn.destroy();

    if (try conn.requestName(watcher_name, Connection.request_name_do_not_queue) != 1) {
        return error.NameTaken;
    }
    if (try conn.requestName(sni.notifications_name, Connection.request_name_do_not_queue) != 1) {
        return error.NameTaken;
    }

    const self = try gpa.create(MockHost);
    self.* = .{
        .gpa = gpa,
        .conn = conn,
        .watcher_name = watcher_name,
        .body = .init(gpa),
    };
    return self;
}

pub fn destroy(self: *MockHost) void {
    const gpa = self.gpa;
    for (self.items.items) |*item| item.deinit(gpa);
    self.items.deinit(gpa);
    for (self.notifications.items) |*posted| posted.deinit(gpa);
    self.notifications.deinit(gpa);
    self.body.deinit();
    self.conn.destroy();
    gpa.destroy(self);
}

/// Handles whatever has arrived, without blocking.
pub fn pump(self: *MockHost) !void {
    while (try self.readable()) {
        const message = try self.conn.readMessage();
        try self.handle(message);
    }
}

fn readable(self: *MockHost) !bool {
    if (self.conn.buffered() > 0) return true;
    var fds = [_]std.os.linux.pollfd{
        .{ .fd = self.conn.handle(), .events = std.os.linux.POLL.IN, .revents = 0 },
    };
    const n = try std.posix.poll(&fds, 0);
    return n > 0;
}

fn handle(self: *MockHost, message: Message) !void {
    if (message.type != .method_call) return;
    const member = message.member orelse return;

    if (std.mem.eql(u8, member, "RegisterStatusNotifierItem")) {
        var r: wire.Reader = .init(message.body, message.endian);
        const service = try r.string();
        try self.items.append(self.gpa, .{ .service = try self.gpa.dupe(u8, service) });
        return self.conn.reply(message, null, &.{});
    }

    if (std.mem.eql(u8, member, "Notify")) return self.handleNotify(message);

    if (std.mem.eql(u8, member, "CloseNotification")) {
        var r: wire.Reader = .init(message.body, message.endian);
        const id = try r.int(u32);
        try self.conn.reply(message, null, &.{});
        // Real daemons confirm with reason 3, "closed by the application".
        return self.closeNotification(id, 3);
    }

    if (std.mem.eql(u8, member, "GetAll")) {
        // Watcher properties, for a tray that checks whether a host is present.
        self.body.clearRetainingCapacity();
        const array = try self.body.arrayBegin("{sv}");
        try self.body.dictStringVariantBool("IsStatusNotifierHostRegistered", true);
        self.body.arrayEnd(array);
        return self.conn.reply(message, "a{sv}", self.body.bytes());
    }

    try self.conn.replyError(
        message,
        "org.freedesktop.DBus.Error.UnknownMethod",
        "the mock host does not implement this",
    );
}

fn handleNotify(self: *MockHost, message: Message) !void {
    var r: wire.Reader = .init(message.body, message.endian);
    const app_name = try r.string();
    const replaces = try r.int(u32);
    _ = try r.string(); // app icon
    const summary = try r.string();
    const body_text = try r.string();

    var actions: std.ArrayList([]u8) = .empty;
    errdefer {
        for (actions.items) |action| self.gpa.free(action);
        actions.deinit(self.gpa);
    }
    const actions_end = try r.arrayBegin("s");
    while (r.pos < actions_end) {
        try actions.append(self.gpa, try self.gpa.dupe(u8, try r.string()));
    }

    var progress: ?i32 = null;
    const hints_end = try r.arrayBegin("{sv}");
    while (r.pos < hints_end) {
        try r.dictEntryBegin();
        const key = try r.string();
        const sig = try r.variantBegin();
        if (std.mem.eql(u8, key, "value") and std.mem.eql(u8, sig, "i")) {
            progress = try r.int(i32);
        } else {
            try r.skip(sig);
        }
    }
    _ = try r.int(i32); // timeout

    // Replacing keeps the id, which is how the caller's tag stays stable.
    const id = if (replaces != 0) replaces else id: {
        self.next_notification_id += 1;
        break :id self.next_notification_id;
    };

    if (self.find(id)) |existing| {
        existing.deinit(self.gpa);
        existing.* = .{
            .id = id,
            .app_name = try self.gpa.dupe(u8, app_name),
            .summary = try self.gpa.dupe(u8, summary),
            .body = try self.gpa.dupe(u8, body_text),
            .actions = actions,
            .progress = progress,
            .replaces = replaces,
        };
    } else {
        try self.notifications.append(self.gpa, .{
            .id = id,
            .app_name = try self.gpa.dupe(u8, app_name),
            .summary = try self.gpa.dupe(u8, summary),
            .body = try self.gpa.dupe(u8, body_text),
            .actions = actions,
            .progress = progress,
            .replaces = replaces,
        });
    }

    self.body.clearRetainingCapacity();
    try self.body.int(u32, id);
    try self.conn.reply(message, "u", self.body.bytes());
}

pub fn find(self: *MockHost, id: u32) ?*Posted {
    for (self.notifications.items) |*posted| {
        if (posted.id == id) return posted;
    }
    return null;
}

/// The most recent notification, which is what tests usually mean.
pub fn latest(self: *MockHost) ?*Posted {
    if (self.notifications.items.len == 0) return null;
    return &self.notifications.items[self.notifications.items.len - 1];
}

/// Pretends the user pressed a button.
pub fn invokeAction(self: *MockHost, id: u32, action: []const u8) !void {
    self.body.clearRetainingCapacity();
    try self.body.int(u32, id);
    try self.body.string(action);
    try self.conn.emit(.{
        .path = sni.notifications_path,
        .interface = sni.notifications_interface,
        .member = "ActionInvoked",
        .signature = "us",
        .body = self.body.bytes(),
    });
}

/// Pretends the notification went away. Reason 2 is "dismissed by the user".
pub fn closeNotification(self: *MockHost, id: u32, reason: u32) !void {
    if (self.find(id)) |posted| posted.closed = true;

    self.body.clearRetainingCapacity();
    try self.body.int(u32, id);
    try self.body.int(u32, reason);
    try self.conn.emit(.{
        .path = sni.notifications_path,
        .interface = sni.notifications_interface,
        .member = "NotificationClosed",
        .signature = "uu",
        .body = self.body.bytes(),
    });
}

// -- the client half: fetching from a registered item -----------------------

/// Serial of a call whose reply the caller will wait for.
pub const Pending = u32;

pub fn getProperty(self: *MockHost, interface: []const u8, name: []const u8) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.string(interface);
    try self.body.string(name);
    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = sni.item_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .signature = "ss",
        .body = self.body.bytes(),
    });
}

pub fn getAllProperties(self: *MockHost, interface: []const u8) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.string(interface);
    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = sni.item_path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "GetAll",
        .signature = "s",
        .body = self.body.bytes(),
    });
}

/// `GetLayout`, with the depth and property filter a host would use.
pub fn getLayout(self: *MockHost, depth: i32, properties: []const []const u8) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.int(i32, 0);
    try self.body.int(i32, depth);
    const array = try self.body.arrayBegin("s");
    for (properties) |name| try self.body.string(name);
    self.body.arrayEnd(array);

    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = perch.linux.DBusMenu.object_path,
        .interface = perch.linux.DBusMenu.interface,
        .member = "GetLayout",
        .signature = "iias",
        .body = self.body.bytes(),
    });
}

pub fn getGroupProperties(self: *MockHost, ids: []const i32) !Pending {
    self.body.clearRetainingCapacity();
    const id_array = try self.body.arrayBegin("i");
    for (ids) |id| try self.body.int(i32, id);
    self.body.arrayEnd(id_array);
    const names = try self.body.arrayBegin("s");
    self.body.arrayEnd(names);

    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = perch.linux.DBusMenu.object_path,
        .interface = perch.linux.DBusMenu.interface,
        .member = "GetGroupProperties",
        .signature = "aias",
        .body = self.body.bytes(),
    });
}

pub fn aboutToShow(self: *MockHost, id: i32) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.int(i32, id);
    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = perch.linux.DBusMenu.object_path,
        .interface = perch.linux.DBusMenu.interface,
        .member = "AboutToShow",
        .signature = "i",
        .body = self.body.bytes(),
    });
}

/// Clicks a menu row, as a host does when the user picks it.
pub fn clickMenuItem(self: *MockHost, id: i32) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.int(i32, id);
    try self.body.string("clicked");
    try self.body.variantString("");
    try self.body.int(u32, 0);
    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = perch.linux.DBusMenu.object_path,
        .interface = perch.linux.DBusMenu.interface,
        .member = "Event",
        .signature = "isvu",
        .body = self.body.bytes(),
    });
}

/// One of `Activate`, `SecondaryActivate`, `ContextMenu`.
pub fn clickIcon(self: *MockHost, member: []const u8, x: i32, y: i32) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.int(i32, x);
    try self.body.int(i32, y);
    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = sni.item_path,
        .interface = sni.item_interface,
        .member = member,
        .signature = "ii",
        .body = self.body.bytes(),
    });
}

pub fn scrollIcon(self: *MockHost, delta: i32, orientation: []const u8) !Pending {
    self.body.clearRetainingCapacity();
    try self.body.int(i32, delta);
    try self.body.string(orientation);
    return self.conn.call(.{
        .destination = self.items.items[0].service,
        .path = sni.item_path,
        .interface = sni.item_interface,
        .member = "Scroll",
        .signature = "is",
        .body = self.body.bytes(),
    });
}

/// Reads messages until the reply to `pending` arrives, returning its body.
/// The slice is valid until the next read.
///
/// `step` is called between reads so the caller can pump the tray, since both
/// sides live in one thread.
pub fn awaitReply(
    self: *MockHost,
    pending: Pending,
    context: anytype,
    comptime step: fn (@TypeOf(context)) anyerror!void,
    deadline_ms: u32,
) ![]const u8 {
    var waited: u32 = 0;
    while (waited < deadline_ms) {
        try step(context);
        if (try self.readable()) {
            const message = try self.conn.readMessage();
            if (message.reply_serial == pending) {
                if (message.type == .error_reply) {
                    std.debug.print("mock host: call failed: {?s}\n", .{message.error_name});
                    return error.CallFailed;
                }
                return message.body;
            }
            try self.handle(message);
            continue;
        }
        self.conn.io.sleep(.fromMilliseconds(1), .awake) catch {};
        waited += 1;
    }
    return error.Timeout;
}

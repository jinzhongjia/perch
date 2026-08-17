//! Linux/BSD backend: the freedesktop `StatusNotifierItem` protocol over DBus,
//! with `com.canonical.dbusmenu` for the menu and `org.freedesktop.Notifications`
//! for `notify`.
//!
//! The item is published on our own bus name, then handed to
//! `org.kde.StatusNotifierWatcher`. If no watcher is running yet we stay
//! registered-pending and retry when one appears, so starting before the shell
//! is not an error.

const std = @import("std");
const linux = std.os.linux;

const Connection = @import("../linux/Connection.zig");
const DBusMenu = @import("../linux/DBusMenu.zig");
const Message = @import("../linux/Message.zig");
const png = @import("../linux/png.zig");
const wire = @import("../linux/wire.zig");

const Icon = @import("../icon.zig").Icon;
const Menu = @import("../menu.zig").Menu;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

const log = std.log.scoped(.perch);

pub const item_interface = "org.kde.StatusNotifierItem";
pub const item_path = "/StatusNotifierItem";
pub const watcher_name = "org.kde.StatusNotifierWatcher";
pub const watcher_path = "/StatusNotifierWatcher";
pub const watcher_interface = "org.kde.StatusNotifierWatcher";
pub const notifications_name = "org.freedesktop.Notifications";
pub const notifications_path = "/org/freedesktop/Notifications";
pub const notifications_interface = "org.freedesktop.Notifications";

pub const Backend = struct {
    pub const supported = true;

    owner: *Tray,
    gpa: std.mem.Allocator,
    conn: *Connection,

    /// `org.kde.StatusNotifierItem-<pid>-<n>`, owned.
    service_name: []u8,
    /// Whether a watcher has accepted our item.
    registered: bool = false,

    /// Set by `stop`, read by `run`.
    stopping: std.atomic.Value(bool) = .init(false),
    /// eventfd that `stop` writes to so a blocked `run` wakes immediately.
    wakeup: linux.fd_t,

    /// Bumped whenever the menu changes; hosts refetch when it moves.
    menu_revision: u32 = 1,

    /// Decoded from `Icon.bytes`/`Icon.path` for `IconPixmap`. Owned.
    icon_pixmap: ?png.Image = null,
    /// Scratch for marshalling reply bodies; reused.
    body: wire.Writer,

    pub fn init(owner: *Tray) Error!Backend {
        const gpa = owner.gpa;
        const options = owner.options;

        const address = options.linux.bus_address orelse
            (options.linux.environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse {
                owner.last_diagnostic = "DBUS_SESSION_BUS_ADDRESS is unset; pass Options.linux.environ or .bus_address";
                return error.MissingBusAddress;
            });

        const conn = Connection.create(gpa, options.io, address) catch |err| {
            owner.last_diagnostic = switch (err) {
                error.AddressUnsupported => "session bus address names a transport perch cannot speak",
                error.AuthFailed => "the session bus rejected EXTERNAL authentication",
                error.OutOfMemory => "out of memory connecting to the session bus",
                else => "cannot connect to the session bus",
            };
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.AddressUnsupported => error.MissingBusAddress,
                else => error.BusUnavailable,
            };
        };
        errdefer conn.destroy();

        // The name has to be unique per item in the process, and the convention
        // is to derive it from the pid.
        const service_name = try std.fmt.allocPrint(
            gpa,
            "org.kde.StatusNotifierItem-{d}-{d}",
            .{ linux.getpid(), nextItemNumber() },
        );
        errdefer gpa.free(service_name);

        const rc = conn.requestName(service_name, Connection.request_name_do_not_queue) catch {
            owner.last_diagnostic = "the session bus refused our StatusNotifierItem name";
            return error.PlatformFailure;
        };
        if (rc != 1) {
            owner.last_diagnostic = "another process already owns our StatusNotifierItem name";
            return error.PlatformFailure;
        }

        const wakeup_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wakeup_rc) != .SUCCESS) {
            owner.last_diagnostic = "cannot create the wakeup eventfd";
            return error.PlatformFailure;
        }

        var self: Backend = .{
            .owner = owner,
            .gpa = gpa,
            .conn = conn,
            .service_name = service_name,
            .wakeup = @intCast(wakeup_rc),
            .body = .init(gpa),
        };
        errdefer self.body.deinit();

        // Watch the watcher, so a shell restart re-registers us instead of
        // silently losing the icon.
        conn.addMatch(
            "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus'," ++
                "member='NameOwnerChanged',arg0='" ++ watcher_name ++ "'",
        ) catch {};

        try self.loadIconPixmap(options.icon);

        // Starting before the desktop shell is normal, so an absent watcher is
        // not an error: NameOwnerChanged brings us back.
        if (conn.nameHasOwner(watcher_name) catch false) {
            self.registerWithWatcher();
        } else {
            log.info("perch: no status notifier host yet, waiting for one to appear", .{});
        }
        return self;
    }

    /// Per-process counter, so two trays in one process get distinct names.
    var item_counter: std.atomic.Value(u32) = .init(0);

    fn nextItemNumber() u32 {
        return item_counter.fetchAdd(1, .monotonic) + 1;
    }

    pub fn deinit(self: *Backend) void {
        if (self.icon_pixmap) |*image| image.deinit(self.gpa);
        self.body.deinit();
        self.conn.destroy();
        self.gpa.free(self.service_name);
        _ = linux.close(self.wakeup);
        self.* = undefined;
    }

    // -- perch API ----------------------------------------------------------

    pub fn setIcon(self: *Backend, icon: Icon) Error!void {
        try self.loadIconPixmap(icon);
        self.emitItemSignal("NewIcon");
        return;
    }

    /// The new value is already in `owner.options`, which is where the property
    /// handler reads it from; the signal just tells the host to refetch.
    pub fn setTooltip(self: *Backend, tooltip: ?[]const u8) Error!void {
        _ = tooltip;
        self.emitItemSignal("NewToolTip");
        return;
    }

    pub fn setTitle(self: *Backend, title: []const u8) Error!void {
        _ = title;
        self.emitItemSignal("NewTitle");
        return;
    }

    pub fn setMenu(self: *Backend, menu: ?*Menu) Error!void {
        // Likewise: `owner.menu` is already updated, so a revision bump plus
        // LayoutUpdated is all the host needs.
        _ = menu;
        self.menu_revision += 1;

        self.body.clearRetainingCapacity();
        self.body.int(u32, self.menu_revision) catch return error.OutOfMemory;
        self.body.int(i32, DBusMenu.root_id) catch return error.OutOfMemory;
        self.conn.emit(.{
            .path = DBusMenu.object_path,
            .interface = DBusMenu.interface,
            .member = "LayoutUpdated",
            .signature = "ui",
            .body = self.body.bytes(),
        }) catch |err| return mapSendError(err);
    }

    pub fn notify(self: *Backend, notification: Notification) Error!void {
        const options = self.owner.options;

        self.body.clearRetainingCapacity();
        const b = &self.body;
        b.string(options.app_id) catch return error.OutOfMemory;
        b.int(u32, 0) catch return error.OutOfMemory; // replaces_id
        b.string(iconName(notification.icon orelse options.icon)) catch return error.OutOfMemory;
        b.string(notification.title) catch return error.OutOfMemory;
        b.string(notification.body) catch return error.OutOfMemory;

        const actions = b.arrayBegin("s") catch return error.OutOfMemory;
        b.arrayEnd(actions);

        const hints = b.arrayBegin("{sv}") catch return error.OutOfMemory;
        b.dictEntryBegin() catch return error.OutOfMemory;
        b.string("urgency") catch return error.OutOfMemory;
        b.variantBegin("y") catch return error.OutOfMemory;
        b.byte(switch (notification.urgency) {
            .low => 0,
            .normal => 1,
            .critical => 2,
        }) catch return error.OutOfMemory;
        b.dictStringVariantString("desktop-entry", options.app_id) catch return error.OutOfMemory;
        b.arrayEnd(hints);

        const timeout: i32 = if (notification.timeout_ms) |ms| @intCast(ms) else -1;
        b.int(i32, timeout) catch return error.OutOfMemory;

        _ = self.conn.call(.{
            .destination = notifications_name,
            .path = notifications_path,
            .interface = notifications_interface,
            .member = "Notify",
            .signature = "susssasa{sv}i",
            .body = b.bytes(),
            // The reply is just the notification id, which we do not track, but
            // asking for one means a rejection reaches our log.
        }) catch |err| return mapSendError(err);
    }

    /// Hosts own the menu popup, so all we can do is ask for it.
    pub fn showMenu(self: *Backend) Error!void {
        self.body.clearRetainingCapacity();
        self.body.int(i32, DBusMenu.root_id) catch return error.OutOfMemory;
        self.body.int(u32, 0) catch return error.OutOfMemory; // timestamp
        self.conn.emit(.{
            .path = DBusMenu.object_path,
            .interface = DBusMenu.interface,
            .member = "ItemActivationRequested",
            .signature = "iu",
            .body = self.body.bytes(),
        }) catch |err| return mapSendError(err);
    }

    pub fn run(self: *Backend) Error!void {
        if (self.owner.handler.on_ready) |cb| cb(self.owner.handler.ctx, self.owner);

        while (!self.stopping.load(.acquire)) {
            // Anything already buffered is a message we have not parsed yet, so
            // do not go to sleep on the socket first.
            if (self.conn.buffered() == 0) {
                const ready = self.wait(-1) catch return error.PlatformFailure;
                if (!ready) continue;
            }
            try self.dispatchOne();
        }

        if (self.owner.handler.on_quit) |cb| cb(self.owner.handler.ctx, self.owner);
    }

    pub fn pump(self: *Backend) Error!void {
        while (!self.stopping.load(.acquire)) {
            if (self.conn.buffered() == 0) {
                const ready = self.wait(0) catch return error.PlatformFailure;
                if (!ready) return;
            }
            try self.dispatchOne();
        }
    }

    pub fn stop(self: *Backend) void {
        self.stopping.store(true, .release);
        // Nudge the poll in `run`; the value is irrelevant.
        const one: u64 = 1;
        _ = linux.write(self.wakeup, std.mem.asBytes(&one), @sizeOf(u64));
    }

    // -- event loop ---------------------------------------------------------

    /// Waits for the bus socket or the wakeup fd. Returns true when there is a
    /// message to read.
    fn wait(self: *Backend, timeout_ms: i32) !bool {
        var fds = [_]linux.pollfd{
            .{ .fd = self.conn.handle(), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.wakeup, .events = linux.POLL.IN, .revents = 0 },
        };
        const n = try std.posix.poll(&fds, timeout_ms);
        if (n == 0) return false;

        if (fds[1].revents & linux.POLL.IN != 0) {
            var drain: u64 = undefined;
            _ = linux.read(self.wakeup, std.mem.asBytes(&drain), @sizeOf(u64));
        }
        return fds[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0;
    }

    fn dispatchOne(self: *Backend) Error!void {
        const message = self.conn.readMessage() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Either the bus hung up or the stream desynchronised; both leave
            // the connection unusable, so end the loop rather than spin.
            else => {
                self.owner.last_diagnostic = switch (err) {
                    error.Disconnected => "the session bus closed the connection",
                    else => "malformed message on the session bus",
                };
                self.stopping.store(true, .release);
                return error.PlatformFailure;
            },
        };
        self.handle(message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Failing to answer one call is not worth tearing the tray down.
                log.warn("perch: could not answer {?s}.{?s}: {t}", .{
                    message.interface, message.member, err,
                });
            },
        };
    }

    fn handle(self: *Backend, message: Message) Connection.Error!void {
        switch (message.type) {
            .signal => {
                if (message.isSignal(Connection.bus_interface, "NameOwnerChanged")) {
                    try self.handleNameOwnerChanged(message);
                }
                return;
            },
            .method_call => {},
            .error_reply => {
                // A call of ours was rejected. Nothing to retry, but staying
                // quiet here makes marshalling bugs invisible.
                log.warn("perch: the bus rejected a call: {?s}", .{message.error_name});
                return;
            },
            // Replies to calls whose results we do not need.
            else => return,
        }

        const path = message.path orelse return;

        if (std.mem.eql(u8, path, DBusMenu.object_path)) {
            return self.handleMenuCall(message);
        }
        if (std.mem.eql(u8, path, item_path)) {
            return self.handleItemCall(message);
        }
        try self.conn.replyError(message, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
    }

    fn handleNameOwnerChanged(self: *Backend, message: Message) Connection.Error!void {
        var r: wire.Reader = .init(message.body, message.endian);
        const name = r.string() catch return error.Malformed;
        _ = r.string() catch return error.Malformed; // old owner
        const new_owner = r.string() catch return error.Malformed;
        if (!std.mem.eql(u8, name, watcher_name)) return;

        if (new_owner.len == 0) {
            self.registered = false;
            return;
        }
        // A new watcher took over — hand it our item.
        self.registerWithWatcher();
    }

    // -- StatusNotifierItem -------------------------------------------------

    /// Sends our name to the watcher. The caller must already know a watcher is
    /// running: probing for one blocks on a reply, which is not safe once the
    /// event loop is serving requests.
    fn registerWithWatcher(self: *Backend) void {
        self.body.clearRetainingCapacity();
        self.body.string(self.service_name) catch return;
        _ = self.conn.call(.{
            .destination = watcher_name,
            .path = watcher_path,
            .interface = watcher_interface,
            .member = "RegisterStatusNotifierItem",
            .signature = "s",
            .body = self.body.bytes(),
            .no_reply = true,
        }) catch |err| {
            log.warn("perch: cannot reach the status notifier watcher: {t}", .{err});
            return;
        };
        self.registered = true;
    }

    fn emitItemSignal(self: *Backend, member: []const u8) void {
        self.conn.emit(.{
            .path = item_path,
            .interface = item_interface,
            .member = member,
        }) catch |err| log.warn("perch: cannot emit {s}: {t}", .{ member, err });
    }

    fn handleItemCall(self: *Backend, message: Message) Connection.Error!void {
        const member = message.member orelse return;

        if (message.isCall(Connection.properties_interface, "Get")) {
            var r: wire.Reader = .init(message.body, message.endian);
            _ = r.string() catch return error.Malformed;
            const name = r.string() catch return error.Malformed;

            self.body.clearRetainingCapacity();
            if (!try self.writeItemProperty(&self.body, name)) {
                return self.conn.replyError(
                    message,
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "no such property",
                );
            }
            return self.conn.reply(message, "v", self.body.bytes());
        }

        if (message.isCall(Connection.properties_interface, "GetAll")) {
            self.body.clearRetainingCapacity();
            const array = try self.body.arrayBegin("{sv}");
            for (item_property_names) |name| {
                try self.body.dictEntryBegin();
                try self.body.string(name);
                _ = try self.writeItemProperty(&self.body, name);
            }
            self.body.arrayEnd(array);
            return self.conn.reply(message, "a{sv}", self.body.bytes());
        }

        if (message.isCall(Connection.properties_interface, "Set")) {
            return self.conn.replyError(
                message,
                "org.freedesktop.DBus.Error.PropertyReadOnly",
                "StatusNotifierItem properties are read-only",
            );
        }

        if (message.isCall(Connection.introspectable_interface, "Introspect")) {
            self.body.clearRetainingCapacity();
            try self.body.string(item_introspection);
            return self.conn.reply(message, "s", self.body.bytes());
        }

        if (message.isCall(Connection.peer_interface, "Ping")) {
            return self.conn.reply(message, null, &.{});
        }

        // org.kde.StatusNotifierItem methods. All of them reply with nothing.
        if (std.mem.eql(u8, member, "Activate")) {
            self.deliverClick(.left, message);
            return self.conn.reply(message, null, &.{});
        }
        if (std.mem.eql(u8, member, "SecondaryActivate")) {
            self.deliverClick(.middle, message);
            return self.conn.reply(message, null, &.{});
        }
        if (std.mem.eql(u8, member, "ContextMenu")) {
            self.deliverClick(.right, message);
            return self.conn.reply(message, null, &.{});
        }
        if (std.mem.eql(u8, member, "Scroll")) {
            var r: wire.Reader = .init(message.body, message.endian);
            const delta = r.int(i32) catch return error.Malformed;
            const orientation = r.string() catch return error.Malformed;
            if (self.owner.handler.on_scroll) |cb| {
                const axis: tray_mod.ScrollAxis =
                    if (std.ascii.eqlIgnoreCase(orientation, "horizontal")) .horizontal else .vertical;
                cb(self.owner.handler.ctx, self.owner, axis, delta);
            }
            return self.conn.reply(message, null, &.{});
        }

        try self.conn.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    }

    fn deliverClick(self: *Backend, button: tray_mod.MouseButton, message: Message) void {
        _ = message;
        if (self.owner.handler.on_click) |cb| {
            _ = cb(self.owner.handler.ctx, self.owner, button, .{});
        }
    }

    const item_property_names = [_][]const u8{
        "Category",
        "Id",
        "Title",
        "Status",
        "WindowId",
        "IconName",
        "IconPixmap",
        "IconThemePath",
        "OverlayIconName",
        "AttentionIconName",
        "ToolTip",
        "ItemIsMenu",
        "Menu",
    };

    /// Writes the property as a variant. Returns false for unknown names.
    fn writeItemProperty(self: *Backend, w: *wire.Writer, name: []const u8) wire.Writer.Error!bool {
        const options = self.owner.options;
        const table = .{
            .{ "Category", "ApplicationStatus" },
            .{ "Status", "Active" },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, name, entry[0])) {
                try w.variantString(entry[1]);
                return true;
            }
        }

        if (std.mem.eql(u8, name, "Id")) {
            try w.variantString(options.app_id);
        } else if (std.mem.eql(u8, name, "Title")) {
            try w.variantString(if (options.title.len > 0) options.title else options.app_id);
        } else if (std.mem.eql(u8, name, "WindowId")) {
            try w.variantInt32(0);
        } else if (std.mem.eql(u8, name, "IconName")) {
            try w.variantString(iconName(options.icon));
        } else if (std.mem.eql(u8, name, "IconThemePath")) {
            try w.variantString(options.linux.icon_theme_path orelse "");
        } else if (std.mem.eql(u8, name, "OverlayIconName") or
            std.mem.eql(u8, name, "AttentionIconName"))
        {
            try w.variantString("");
        } else if (std.mem.eql(u8, name, "IconPixmap")) {
            try w.variantBegin("a(iiay)");
            try self.writePixmaps(w);
        } else if (std.mem.eql(u8, name, "ToolTip")) {
            // (icon name, icon pixmaps, title, description)
            try w.variantBegin("(sa(iiay)ss)");
            try w.structBegin();
            try w.string("");
            const pixmaps = try w.arrayBegin("(iiay)");
            w.arrayEnd(pixmaps);
            try w.string(options.tooltip orelse options.title);
            try w.string("");
        } else if (std.mem.eql(u8, name, "ItemIsMenu")) {
            // True asks the host to open the menu on left click and never call
            // Activate, which is what we want unless the caller wants clicks.
            try w.variantBool(self.owner.handler.on_click == null and self.owner.menu != null);
        } else if (std.mem.eql(u8, name, "Menu")) {
            try w.variantObjectPath(DBusMenu.object_path);
        } else {
            return false;
        }
        return true;
    }

    fn writePixmaps(self: *Backend, w: *wire.Writer) wire.Writer.Error!void {
        const array = try w.arrayBegin("(iiay)");
        if (self.icon_pixmap) |image| {
            try w.structBegin();
            try w.int(i32, @intCast(image.width));
            try w.int(i32, @intCast(image.height));
            const pixels = try w.arrayBegin("y");
            try w.raw(image.argb);
            w.arrayEnd(pixels);
        }
        w.arrayEnd(array);
    }

    /// Decodes `icon` into ARGB32 for `IconPixmap`, if it carries bytes.
    fn loadIconPixmap(self: *Backend, icon: ?Icon) Error!void {
        if (self.icon_pixmap) |*old| {
            old.deinit(self.gpa);
            self.icon_pixmap = null;
        }
        const source = icon orelse return;
        const bytes = switch (source) {
            .bytes, .template => |data| data,
            // A themed name needs no decoding, and a path is left to the host.
            .named, .path => return,
        };
        self.icon_pixmap = png.decodeArgb32(self.gpa, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("perch: cannot decode the tray icon: {t}", .{err});
                return;
            },
        };
    }

    // -- com.canonical.dbusmenu ---------------------------------------------

    fn handleMenuCall(self: *Backend, message: Message) Connection.Error!void {
        if (message.isCall(Connection.properties_interface, "Get")) {
            var r: wire.Reader = .init(message.body, message.endian);
            _ = r.string() catch return error.Malformed;
            const name = r.string() catch return error.Malformed;

            self.body.clearRetainingCapacity();
            if (!try writeMenuProperty(&self.body, name)) {
                return self.conn.replyError(
                    message,
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "no such property",
                );
            }
            return self.conn.reply(message, "v", self.body.bytes());
        }

        if (message.isCall(Connection.properties_interface, "GetAll")) {
            self.body.clearRetainingCapacity();
            const array = try self.body.arrayBegin("{sv}");
            for (menu_property_names) |name| {
                try self.body.dictEntryBegin();
                try self.body.string(name);
                _ = try writeMenuProperty(&self.body, name);
            }
            self.body.arrayEnd(array);
            return self.conn.reply(message, "a{sv}", self.body.bytes());
        }

        if (message.isCall(Connection.introspectable_interface, "Introspect")) {
            self.body.clearRetainingCapacity();
            try self.body.string(menu_introspection);
            return self.conn.reply(message, "s", self.body.bytes());
        }

        if (message.isCall(DBusMenu.interface, "GetLayout")) {
            var r: wire.Reader = .init(message.body, message.endian);
            const parent_id = r.int(i32) catch return error.Malformed;
            const depth = r.int(i32) catch return error.Malformed;
            // The property filter is advisory; we honour it to keep replies small.
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.gpa);
            const end = r.arrayBegin("s") catch return error.Malformed;
            while (r.pos < end) {
                try names.append(self.gpa, r.string() catch return error.Malformed);
            }

            const menu = self.owner.menu orelse {
                return self.conn.replyError(
                    message,
                    "org.freedesktop.DBus.Error.Failed",
                    "no menu attached",
                );
            };
            const node = DBusMenu.findNode(menu, parent_id) orelse {
                return self.conn.replyError(
                    message,
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "no such menu item",
                );
            };

            self.body.clearRetainingCapacity();
            try self.body.int(u32, self.menu_revision);
            try DBusMenu.writeNode(&self.body, node, depth, .{ .names = names.items });
            return self.conn.reply(message, DBusMenu.get_layout_signature, self.body.bytes());
        }

        if (message.isCall(DBusMenu.interface, "GetGroupProperties")) {
            var r: wire.Reader = .init(message.body, message.endian);
            var ids: std.ArrayList(i32) = .empty;
            defer ids.deinit(self.gpa);
            const ids_end = r.arrayBegin("i") catch return error.Malformed;
            while (r.pos < ids_end) {
                try ids.append(self.gpa, r.int(i32) catch return error.Malformed);
            }
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.gpa);
            const names_end = r.arrayBegin("s") catch return error.Malformed;
            while (r.pos < names_end) {
                try names.append(self.gpa, r.string() catch return error.Malformed);
            }

            const menu = self.owner.menu orelse {
                return self.conn.replyError(
                    message,
                    "org.freedesktop.DBus.Error.Failed",
                    "no menu attached",
                );
            };

            self.body.clearRetainingCapacity();
            // An empty id list means "every item", which hosts use on first draw.
            if (ids.items.len == 0) {
                try collectIds(self.gpa, menu, &ids);
            }
            try DBusMenu.writeGroupProperties(&self.body, menu, ids.items, .{ .names = names.items });
            return self.conn.reply(message, "a(ia{sv})", self.body.bytes());
        }

        if (message.isCall(DBusMenu.interface, "GetProperty")) {
            var r: wire.Reader = .init(message.body, message.endian);
            const id = r.int(i32) catch return error.Malformed;
            const name = r.string() catch return error.Malformed;

            const menu = self.owner.menu orelse return self.conn.replyError(
                message,
                "org.freedesktop.DBus.Error.Failed",
                "no menu attached",
            );
            const node = DBusMenu.findNode(menu, id) orelse return self.conn.replyError(
                message,
                "org.freedesktop.DBus.Error.InvalidArgs",
                "no such menu item",
            );

            // Marshalled from offset 0: a variant lifted out of a larger buffer
            // would carry the wrong alignment.
            self.body.clearRetainingCapacity();
            if (!try DBusMenu.writeNodeProperty(&self.body, node, name)) {
                return self.conn.replyError(
                    message,
                    "org.freedesktop.DBus.Error.InvalidArgs",
                    "no such property",
                );
            }
            return self.conn.reply(message, "v", self.body.bytes());
        }

        if (message.isCall(DBusMenu.interface, "Event")) {
            var r: wire.Reader = .init(message.body, message.endian);
            const id = r.int(i32) catch return error.Malformed;
            const event_name = r.string() catch return error.Malformed;
            // The data variant is event-specific and unused by every event we act on.
            const data_sig = r.variantBegin() catch return error.Malformed;
            r.skip(data_sig) catch return error.Malformed;

            if (DBusMenu.Event.parse(event_name) == .clicked and id > 0) {
                self.owner.dispatchActivate(@intCast(id));
                // The toggle happened in the menu model; tell the host to refetch.
                self.notifyItemChanged(@intCast(id)) catch {};
            }
            return self.conn.reply(message, null, &.{});
        }

        if (message.isCall(DBusMenu.interface, "EventGroup")) {
            var r: wire.Reader = .init(message.body, message.endian);
            const end = r.arrayBegin("(isvu)") catch return error.Malformed;
            while (r.pos < end) {
                r.structBegin() catch return error.Malformed;
                const id = r.int(i32) catch return error.Malformed;
                const event_name = r.string() catch return error.Malformed;
                const data_sig = r.variantBegin() catch return error.Malformed;
                r.skip(data_sig) catch return error.Malformed;
                _ = r.int(u32) catch return error.Malformed;
                if (DBusMenu.Event.parse(event_name) == .clicked and id > 0) {
                    self.owner.dispatchActivate(@intCast(id));
                    self.notifyItemChanged(@intCast(id)) catch {};
                }
            }
            self.body.clearRetainingCapacity();
            const errors = try self.body.arrayBegin("i");
            self.body.arrayEnd(errors);
            return self.conn.reply(message, "ai", self.body.bytes());
        }

        if (message.isCall(DBusMenu.interface, "AboutToShow")) {
            self.body.clearRetainingCapacity();
            // The layout is always current, so nothing to refetch.
            try self.body.boolean(false);
            return self.conn.reply(message, "b", self.body.bytes());
        }

        if (message.isCall(DBusMenu.interface, "AboutToShowGroup")) {
            self.body.clearRetainingCapacity();
            const updates = try self.body.arrayBegin("i");
            self.body.arrayEnd(updates);
            const errors = try self.body.arrayBegin("i");
            self.body.arrayEnd(errors);
            return self.conn.reply(message, "aiai", self.body.bytes());
        }

        try self.conn.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    }

    /// Tells hosts that one item's properties moved, without a full relayout.
    fn notifyItemChanged(self: *Backend, id: u32) Connection.Error!void {
        const menu = self.owner.menu orelse return;
        const node = DBusMenu.findNode(menu, @intCast(id)) orelse return;

        self.body.clearRetainingCapacity();
        const updated = try self.body.arrayBegin("(ia{sv})");
        try self.body.structBegin();
        try self.body.int(i32, node.id());
        const properties = try self.body.arrayBegin("{sv}");
        try DBusMenu.writeNodeProperties(&self.body, node, .all);
        self.body.arrayEnd(properties);
        self.body.arrayEnd(updated);

        const removed = try self.body.arrayBegin("(ias)");
        self.body.arrayEnd(removed);

        try self.conn.emit(.{
            .path = DBusMenu.object_path,
            .interface = DBusMenu.interface,
            .member = "ItemsPropertiesUpdated",
            .signature = "a(ia{sv})a(ias)",
            .body = self.body.bytes(),
        });
    }

    const menu_property_names = [_][]const u8{ "Version", "TextDirection", "Status", "IconThemePath" };

    fn writeMenuProperty(w: *wire.Writer, name: []const u8) wire.Writer.Error!bool {
        if (std.mem.eql(u8, name, "Version")) {
            try w.variantUint32(DBusMenu.version);
        } else if (std.mem.eql(u8, name, "TextDirection")) {
            try w.variantString("ltr");
        } else if (std.mem.eql(u8, name, "Status")) {
            try w.variantString("normal");
        } else if (std.mem.eql(u8, name, "IconThemePath")) {
            try w.variantBegin("as");
            const array = try w.arrayBegin("s");
            w.arrayEnd(array);
        } else {
            return false;
        }
        return true;
    }
};

/// Every id in the tree, for the "give me everything" form of
/// `GetGroupProperties`.
fn collectIds(gpa: std.mem.Allocator, menu: *Menu, out: *std.ArrayList(i32)) std.mem.Allocator.Error!void {
    try out.append(gpa, DBusMenu.root_id);
    try collectChildIds(gpa, menu, out);
}

fn collectChildIds(gpa: std.mem.Allocator, menu: *Menu, out: *std.ArrayList(i32)) std.mem.Allocator.Error!void {
    for (menu.items.items) |*item| {
        try out.append(gpa, @intCast(item.id));
        if (item.submenu) |sub| try collectChildIds(gpa, sub, out);
    }
}

fn iconName(icon: ?Icon) []const u8 {
    const source = icon orelse return "";
    return switch (source) {
        .named => |name| name,
        // Hosts that support absolute paths will take this; the pixmap covers
        // the rest.
        .path => |path| path,
        .bytes, .template => "",
    };
}

fn mapSendError(err: Connection.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Disconnected, error.WriteFailed => error.PlatformFailure,
        else => error.PlatformFailure,
    };
}

const item_introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.freedesktop.DBus.Introspectable">
    \\  <method name="Introspect"><arg type="s" name="xml_data" direction="out"/></method>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="s" name="property_name" direction="in"/>
    \\   <arg type="v" name="value" direction="out"/>
    \\  </method>
    \\  <method name="GetAll">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="a{sv}" name="properties" direction="out"/>
    \\  </method>
    \\ </interface>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="WindowId" type="i" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="IconThemePath" type="s" access="read"/>
    \\  <property name="OverlayIconName" type="s" access="read"/>
    \\  <property name="AttentionIconName" type="s" access="read"/>
    \\  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <method name="Activate">
    \\   <arg type="i" name="x" direction="in"/>
    \\   <arg type="i" name="y" direction="in"/>
    \\  </method>
    \\  <method name="SecondaryActivate">
    \\   <arg type="i" name="x" direction="in"/>
    \\   <arg type="i" name="y" direction="in"/>
    \\  </method>
    \\  <method name="ContextMenu">
    \\   <arg type="i" name="x" direction="in"/>
    \\   <arg type="i" name="y" direction="in"/>
    \\  </method>
    \\  <method name="Scroll">
    \\   <arg type="i" name="delta" direction="in"/>
    \\   <arg type="s" name="orientation" direction="in"/>
    \\  </method>
    \\  <signal name="NewTitle"/>
    \\  <signal name="NewIcon"/>
    \\  <signal name="NewToolTip"/>
    \\  <signal name="NewStatus"><arg type="s" name="status"/></signal>
    \\ </interface>
    \\</node>
;

const menu_introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="s" name="property_name" direction="in"/>
    \\   <arg type="v" name="value" direction="out"/>
    \\  </method>
    \\  <method name="GetAll">
    \\   <arg type="s" name="interface_name" direction="in"/>
    \\   <arg type="a{sv}" name="properties" direction="out"/>
    \\  </method>
    \\ </interface>
    \\ <interface name="com.canonical.dbusmenu">
    \\  <property name="Version" type="u" access="read"/>
    \\  <property name="TextDirection" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconThemePath" type="as" access="read"/>
    \\  <method name="GetLayout">
    \\   <arg type="i" name="parentId" direction="in"/>
    \\   <arg type="i" name="recursionDepth" direction="in"/>
    \\   <arg type="as" name="propertyNames" direction="in"/>
    \\   <arg type="u" name="revision" direction="out"/>
    \\   <arg type="(ia{sv}av)" name="layout" direction="out"/>
    \\  </method>
    \\  <method name="GetGroupProperties">
    \\   <arg type="ai" name="ids" direction="in"/>
    \\   <arg type="as" name="propertyNames" direction="in"/>
    \\   <arg type="a(ia{sv})" name="properties" direction="out"/>
    \\  </method>
    \\  <method name="GetProperty">
    \\   <arg type="i" name="id" direction="in"/>
    \\   <arg type="s" name="name" direction="in"/>
    \\   <arg type="v" name="value" direction="out"/>
    \\  </method>
    \\  <method name="Event">
    \\   <arg type="i" name="id" direction="in"/>
    \\   <arg type="s" name="eventId" direction="in"/>
    \\   <arg type="v" name="data" direction="in"/>
    \\   <arg type="u" name="timestamp" direction="in"/>
    \\  </method>
    \\  <method name="EventGroup">
    \\   <arg type="a(isvu)" name="events" direction="in"/>
    \\   <arg type="ai" name="idErrors" direction="out"/>
    \\  </method>
    \\  <method name="AboutToShow">
    \\   <arg type="i" name="id" direction="in"/>
    \\   <arg type="b" name="needUpdate" direction="out"/>
    \\  </method>
    \\  <method name="AboutToShowGroup">
    \\   <arg type="ai" name="ids" direction="in"/>
    \\   <arg type="ai" name="updatesNeeded" direction="out"/>
    \\   <arg type="ai" name="idErrors" direction="out"/>
    \\  </method>
    \\  <signal name="ItemsPropertiesUpdated">
    \\   <arg type="a(ia{sv})" name="updatedProps"/>
    \\   <arg type="a(ias)" name="removedProps"/>
    \\  </signal>
    \\  <signal name="LayoutUpdated">
    \\   <arg type="u" name="revision"/>
    \\   <arg type="i" name="parent"/>
    \\  </signal>
    \\  <signal name="ItemActivationRequested">
    \\   <arg type="i" name="id"/>
    \\   <arg type="u" name="timestamp"/>
    \\  </signal>
    \\ </interface>
    \\</node>
;

test "collectIds walks the whole tree" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.addItem("One");
    const sub = try menu.addSubmenu("More");
    _ = try sub.addItem("Two");

    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(gpa);
    try collectIds(gpa, &menu, &ids);

    // Root, One, More, Two.
    try std.testing.expectEqual(@as(usize, 4), ids.items.len);
    try std.testing.expectEqual(DBusMenu.root_id, ids.items[0]);
}

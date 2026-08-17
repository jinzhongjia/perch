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
const IconExport = @import("../linux/IconExport.zig");
const Message = @import("../linux/Message.zig");
const wire = @import("../linux/wire.zig");

const image = @import("../image.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const Menu = @import("../menu.zig").Menu;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

const log = std.log.scoped(.perch);

const sni = @import("../linux.zig").sni;

pub const item_interface = sni.item_interface;
pub const item_path = sni.item_path;
pub const watcher_path = sni.watcher_path;
pub const watcher_interface = sni.watcher_interface;
/// The KDE name is the one nearly every host uses; the alternatives cover
/// implementations like snixembed that picked a different bus name.
pub const watcher_names = sni.watcher_names;
pub const watcher_name = watcher_names[0];
pub const notifications_name = sni.notifications_name;
pub const notifications_path = sni.notifications_path;
pub const notifications_interface = sni.notifications_interface;

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

    /// The three icon slots `StatusNotifierItem` defines.
    icon: Slot = .{},
    attention: Slot = .{},
    overlay: Slot = .{},

    /// Where SVG icons are exported for the host to render. Only set up when an
    /// icon actually carries markup.
    icon_export: ?IconExport = null,

    /// Notifications we have posted, so tags can be mapped to server ids.
    notifications: std.ArrayList(Posted) = .empty,

    /// Scratch for marshalling reply bodies; reused.
    body: wire.Writer,

    /// One icon slot: every decoded size, largest first, plus the themed name of
    /// an exported SVG if the icon carried markup. Publishing all the sizes lets
    /// the host pick per display scale instead of stretching one.
    const Slot = struct {
        images: []image.Image = &.{},
        exported_name: ?[]u8 = null,

        fn deinit(self: *Slot, gpa: std.mem.Allocator) void {
            image.freeAll(gpa, self.images);
            if (self.exported_name) |name| gpa.free(name);
            self.* = .{};
        }
    };

    /// A notification in flight. `id` stays null until the daemon answers, which
    /// is why callers address notifications by their own `tag`.
    const Posted = struct {
        tag: Notification.Tag,
        /// Serial of the `Notify` call, for matching the reply.
        serial: u32,
        id: ?u32 = null,
    };

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

        // Watch every watcher name, so a shell restart — or a host that uses one
        // of the alternative names — re-registers us instead of silently losing
        // the icon.
        inline for (watcher_names) |name| {
            conn.addMatch(
                "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus'," ++
                    "member='NameOwnerChanged',arg0='" ++ name ++ "'",
            ) catch {};
        }

        // Action buttons and dismissals come back as signals from the daemon.
        conn.addMatch(
            "type='signal',sender='" ++ notifications_name ++ "'," ++
                "interface='" ++ notifications_interface ++ "'",
        ) catch {};

        try self.loadIcons();

        // Starting before the desktop shell is normal, so an absent watcher is
        // not an error: NameOwnerChanged brings us back.
        if (self.findWatcher()) |name| {
            self.registerWithWatcher(name);
        } else {
            log.info(
                "perch: no status notifier host yet, waiting for one to appear " ++
                    "(GNOME needs the AppIndicator extension)",
                .{},
            );
        }
        return self;
    }

    /// Per-process counter, so two trays in one process get distinct names.
    var item_counter: std.atomic.Value(u32) = .init(0);

    fn nextItemNumber() u32 {
        return item_counter.fetchAdd(1, .monotonic) + 1;
    }

    pub fn deinit(self: *Backend) void {
        self.icon.deinit(self.gpa);
        self.attention.deinit(self.gpa);
        self.overlay.deinit(self.gpa);
        if (self.icon_export) |*exporter| exporter.deinit();
        self.notifications.deinit(self.gpa);
        self.body.deinit();
        self.conn.destroy();
        self.gpa.free(self.service_name);
        _ = linux.close(self.wakeup);
        self.* = undefined;
    }

    // -- perch API ----------------------------------------------------------

    pub fn setIcon(self: *Backend, icon: Icon) Error!void {
        _ = icon;
        try self.loadIcons();
        self.emitItemSignal("NewIcon");
        return;
    }

    pub fn setAttentionIcon(self: *Backend, icon: ?Icon) Error!void {
        _ = icon;
        try self.loadIcons();
        self.emitItemSignal("NewAttentionIcon");
        return;
    }

    pub fn setOverlayIcon(self: *Backend, icon: ?Icon) Error!void {
        _ = icon;
        try self.loadIcons();
        self.emitItemSignal("NewOverlayIcon");
        return;
    }

    pub fn setStatus(self: *Backend, status: tray_mod.Status) Error!void {
        self.body.clearRetainingCapacity();
        self.body.string(status.sniName()) catch return error.OutOfMemory;
        self.conn.emit(.{
            .path = item_path,
            .interface = item_interface,
            .member = "NewStatus",
            .signature = "s",
            .body = self.body.bytes(),
        }) catch |err| return mapSendError(err);
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

        // Reusing a tag replaces the notification still holding it.
        const replaces: u32 = replaces: {
            const tag = notification.tag orelse break :replaces 0;
            const existing = self.findPosted(tag) orelse break :replaces 0;
            break :replaces existing.id orelse 0;
        };

        self.body.clearRetainingCapacity();
        const b = &self.body;
        try b.string(options.app_id);
        try b.int(u32, replaces);
        try b.string(themedName(notification.icon) orelse themedName(options.icon) orelse "");
        try b.string(notification.title);
        try b.string(notification.body);

        // Actions alternate key, label — the key comes back in ActionInvoked.
        const actions = try b.arrayBegin("s");
        for (notification.actions) |action| {
            try b.string(action.key);
            try b.string(action.label);
        }
        b.arrayEnd(actions);

        const hints = try b.arrayBegin("{sv}");
        try b.dictEntryBegin();
        try b.string("urgency");
        try b.variantBegin("y");
        try b.byte(switch (notification.urgency) {
            .low => 0,
            .normal => 1,
            .critical => 2,
        });
        try b.dictStringVariantString("desktop-entry", options.app_id);
        if (notification.category.hintValue()) |category| {
            try b.dictStringVariantString("category", category);
        }
        if (notification.transient) try b.dictStringVariantBool("transient", true);
        if (notification.resident) try b.dictStringVariantBool("resident", true);
        if (notification.suppress_sound) try b.dictStringVariantBool("suppress-sound", true);
        if (notification.sound_name) |sound| {
            try b.dictStringVariantString("sound-name", sound);
        }
        if (notification.progress) |percent| {
            try b.dictStringVariantInt32("value", @min(percent, 100));
        }
        if (notification.image) |picture| try self.writeImageHint(b, picture);
        b.arrayEnd(hints);

        const timeout: i32 = if (notification.timeout_ms) |ms| @intCast(ms) else -1;
        try b.int(i32, timeout);

        const serial = self.conn.call(.{
            .destination = notifications_name,
            .path = notifications_path,
            .interface = notifications_interface,
            .member = "Notify",
            .signature = "susssasa{sv}i",
            .body = b.bytes(),
        }) catch |err| return mapSendError(err);

        // Remember the call so the reply can attach the daemon's id to our tag.
        if (notification.tag) |tag| {
            if (self.findPosted(tag)) |existing| {
                existing.serial = serial;
                existing.id = null;
            } else {
                try self.notifications.append(self.gpa, .{ .tag = tag, .serial = serial });
            }
        }
    }

    pub fn closeNotification(self: *Backend, tag: Notification.Tag) Error!void {
        const posted = self.findPosted(tag) orelse return;
        // Nothing to close yet if the daemon has not answered; dropping the
        // record keeps the tag reusable.
        const id = posted.id orelse {
            self.forgetPosted(tag);
            return;
        };

        self.body.clearRetainingCapacity();
        try self.body.int(u32, id);
        _ = self.conn.call(.{
            .destination = notifications_name,
            .path = notifications_path,
            .interface = notifications_interface,
            .member = "CloseNotification",
            .signature = "u",
            .body = self.body.bytes(),
            .no_reply = true,
        }) catch |err| return mapSendError(err);
    }

    /// The `image-data` hint: `(iiibiiay)` — width, height, rowstride, alpha,
    /// bits per sample, channels, pixels. Note that unlike `IconPixmap` this one
    /// wants RGBA, not ARGB.
    fn writeImageHint(self: *Backend, b: *wire.Writer, picture: Icon) wire.Writer.Error!void {
        const frames = icon_mod.decodeAll(self.gpa, picture) catch return;
        defer image.freeAll(self.gpa, frames);
        if (frames.len == 0) return;
        const frame = frames[0];

        try b.dictEntryBegin();
        try b.string("image-data");
        try b.variantBegin("(iiibiiay)");
        try b.structBegin();
        try b.int(i32, @intCast(frame.width));
        try b.int(i32, @intCast(frame.height));
        try b.int(i32, @intCast(frame.width * 4)); // rowstride
        try b.boolean(true); // has alpha
        try b.int(i32, 8); // bits per sample
        try b.int(i32, 4); // channels
        const pixels = try b.arrayBegin("y");
        var i: usize = 0;
        while (i < frame.argb.len) : (i += 4) {
            const argb = frame.argb[i..][0..4];
            try b.byte(argb[1]);
            try b.byte(argb[2]);
            try b.byte(argb[3]);
            try b.byte(argb[0]);
        }
        b.arrayEnd(pixels);
    }

    fn findPosted(self: *Backend, tag: Notification.Tag) ?*Posted {
        for (self.notifications.items) |*posted| {
            if (posted.tag == tag) return posted;
        }
        return null;
    }

    fn forgetPosted(self: *Backend, tag: Notification.Tag) void {
        for (self.notifications.items, 0..) |posted, i| {
            if (posted.tag == tag) {
                _ = self.notifications.swapRemove(i);
                return;
            }
        }
    }

    fn postedById(self: *Backend, id: u32) ?*Posted {
        for (self.notifications.items) |*posted| {
            if (posted.id == id) return posted;
        }
        return null;
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
                } else if (message.isSignal(notifications_interface, "ActionInvoked")) {
                    try self.handleNotificationAction(message);
                } else if (message.isSignal(notifications_interface, "NotificationClosed")) {
                    try self.handleNotificationClosed(message);
                }
                return;
            },
            .method_return => {
                // The only replies we wait for are notification ids.
                self.adoptNotificationId(message);
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

    /// Attaches the daemon's notification id to the tag that asked for it.
    fn adoptNotificationId(self: *Backend, message: Message) void {
        const reply_serial = message.reply_serial orelse return;
        for (self.notifications.items) |*posted| {
            if (posted.serial != reply_serial) continue;
            var r: wire.Reader = .init(message.body, message.endian);
            posted.id = r.int(u32) catch return;
            return;
        }
    }

    fn handleNotificationAction(self: *Backend, message: Message) Connection.Error!void {
        var r: wire.Reader = .init(message.body, message.endian);
        const id = r.int(u32) catch return error.Malformed;
        const action = r.string() catch return error.Malformed;

        const posted = self.postedById(id) orelse return;
        self.owner.dispatchNotificationAction(posted.tag, action);
    }

    fn handleNotificationClosed(self: *Backend, message: Message) Connection.Error!void {
        var r: wire.Reader = .init(message.body, message.endian);
        const id = r.int(u32) catch return error.Malformed;
        const code = r.int(u32) catch return error.Malformed;

        const posted = self.postedById(id) orelse return;
        const tag = posted.tag;
        self.forgetPosted(tag);
        self.owner.dispatchNotificationClosed(tag, .fromCode(code));
    }

    fn handleNameOwnerChanged(self: *Backend, message: Message) Connection.Error!void {
        var r: wire.Reader = .init(message.body, message.endian);
        const name = r.string() catch return error.Malformed;
        _ = r.string() catch return error.Malformed; // old owner
        const new_owner = r.string() catch return error.Malformed;

        var is_watcher = false;
        for (watcher_names) |candidate| {
            if (std.mem.eql(u8, name, candidate)) is_watcher = true;
        }
        if (!is_watcher) return;

        if (new_owner.len == 0) {
            self.registered = false;
            return;
        }
        // A watcher appeared or took over — hand it our item.
        self.registerWithWatcher(name);
    }

    // -- StatusNotifierItem -------------------------------------------------

    /// The first watcher name with an owner, if any. Blocks on a reply, so it is
    /// only safe during setup — inside the event loop, NameOwnerChanged already
    /// says which name appeared.
    fn findWatcher(self: *Backend) ?[]const u8 {
        for (watcher_names) |name| {
            if (self.conn.nameHasOwner(name) catch false) return name;
        }
        return null;
    }

    /// Sends our name to `watcher`, which the caller must already know is
    /// running.
    fn registerWithWatcher(self: *Backend, watcher: []const u8) void {
        self.body.clearRetainingCapacity();
        self.body.string(self.service_name) catch return;
        _ = self.conn.call(.{
            .destination = watcher,
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
            self.owner.dispatchScroll(.{
                .axis = if (std.ascii.eqlIgnoreCase(orientation, "horizontal"))
                    .horizontal
                else
                    .vertical,
                .delta = delta,
            });
            return self.conn.reply(message, null, &.{});
        }

        try self.conn.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    }

    /// All three click methods carry the pointer position, which the API passes
    /// through. Modifiers are not part of the protocol, so they stay empty.
    fn deliverClick(self: *Backend, button: tray_mod.MouseButton, message: Message) void {
        var at: ?tray_mod.Point = null;
        var r: wire.Reader = .init(message.body, message.endian);
        if (r.int(i32) catch null) |x| {
            if (r.int(i32) catch null) |y| at = .{ .x = x, .y = y };
        }
        self.owner.dispatchClick(.{ .button = button, .at = at });
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
        "OverlayIconPixmap",
        "AttentionIconName",
        "AttentionIconPixmap",
        "ToolTip",
        "ItemIsMenu",
        "Menu",
    };

    /// Writes the property as a variant. Returns false for unknown names.
    fn writeItemProperty(self: *Backend, w: *wire.Writer, name: []const u8) wire.Writer.Error!bool {
        const options = self.owner.options;

        if (std.mem.eql(u8, name, "Category")) {
            try w.variantString(options.category.sniName());
        } else if (std.mem.eql(u8, name, "Status")) {
            try w.variantString(options.status.sniName());
        } else if (std.mem.eql(u8, name, "Id")) {
            try w.variantString(options.app_id);
        } else if (std.mem.eql(u8, name, "Title")) {
            try w.variantString(if (options.title.len > 0) options.title else options.app_id);
        } else if (std.mem.eql(u8, name, "WindowId")) {
            try w.variantInt32(0);
        } else if (std.mem.eql(u8, name, "IconName")) {
            try w.variantString(slotName(self.icon, options.icon));
        } else if (std.mem.eql(u8, name, "AttentionIconName")) {
            try w.variantString(slotName(self.attention, options.attention_icon));
        } else if (std.mem.eql(u8, name, "OverlayIconName")) {
            try w.variantString(slotName(self.overlay, options.overlay_icon));
        } else if (std.mem.eql(u8, name, "IconThemePath")) {
            try w.variantString(self.themePath());
        } else if (std.mem.eql(u8, name, "IconPixmap")) {
            try w.variantBegin("a(iiay)");
            try writePixmaps(w, self.icon.images);
        } else if (std.mem.eql(u8, name, "AttentionIconPixmap")) {
            try w.variantBegin("a(iiay)");
            try writePixmaps(w, self.attention.images);
        } else if (std.mem.eql(u8, name, "OverlayIconPixmap")) {
            try w.variantBegin("a(iiay)");
            try writePixmaps(w, self.overlay.images);
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
            // True tells the host to open the menu on left click and never call
            // Activate. The caller decides through Options.left_click, because
            // the host commits to one behaviour up front.
            try w.variantBool(options.leftClick() == .show_menu and self.owner.menu != null);
        } else if (std.mem.eql(u8, name, "Menu")) {
            try w.variantObjectPath(DBusMenu.object_path);
        } else {
            return false;
        }
        return true;
    }

    /// An exported SVG wins over a themed name: the host renders it per display
    /// scale, which no pixmap can match.
    fn slotName(slot: Slot, icon: ?Icon) []const u8 {
        if (slot.exported_name) |exported| return exported;
        return themedName(icon) orelse "";
    }

    /// The directory hosts should add to their icon theme search path.
    fn themePath(self: *const Backend) []const u8 {
        if (self.icon_export) |exporter| return exporter.root;
        return self.owner.options.linux.icon_theme_path orelse "";
    }

    /// `a(iiay)` — one entry per size. Hosts pick the closest to what the current
    /// display scale needs, which is how HiDPI stays sharp.
    fn writePixmaps(w: *wire.Writer, images: []const image.Image) wire.Writer.Error!void {
        const array = try w.arrayBegin("(iiay)");
        for (images) |frame| {
            try w.structBegin();
            try w.int(i32, @intCast(frame.width));
            try w.int(i32, @intCast(frame.height));
            const pixels = try w.arrayBegin("y");
            try w.raw(frame.argb);
            w.arrayEnd(pixels);
        }
        w.arrayEnd(array);
    }

    /// Decodes all three icon slots and exports any SVG markup they carry.
    fn loadIcons(self: *Backend) Error!void {
        const options = self.owner.options;
        try self.loadSlot(&self.icon, options.icon, "icon");
        try self.loadSlot(&self.attention, options.attention_icon, "attention");
        try self.loadSlot(&self.overlay, options.overlay_icon, "overlay");
    }

    /// `suffix` keeps the three slots' exported file names apart.
    fn loadSlot(self: *Backend, slot: *Slot, icon: ?Icon, suffix: []const u8) Error!void {
        slot.deinit(self.gpa);
        const source = icon orelse return;

        slot.images = icon_mod.decodeAll(self.gpa, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                log.warn("perch: cannot decode a tray icon: {t}", .{err});
                break :blk &.{};
            },
        };

        if (source.svgMarkup()) |markup| {
            slot.exported_name = try self.exportSvg(markup, suffix);
        }
    }

    /// Writes SVG markup where the host can find it and returns the themed name
    /// to publish. A failure is not fatal: pixmaps or a themed name still cover
    /// the icon, so it warns and gives up rather than refusing to start.
    fn exportSvg(self: *Backend, markup: []const u8, suffix: []const u8) Error!?[]u8 {
        if (self.icon_export == null) {
            const options = self.owner.options;
            self.icon_export = IconExport.init(
                self.gpa,
                options.io,
                options.linux.environ.getPosix("XDG_RUNTIME_DIR"),
                options.linux.icon_theme_path,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("perch: cannot export an SVG icon: {t}", .{err});
                    return null;
                },
            };
        }

        const base = try std.fmt.allocPrint(
            self.gpa,
            "{s}-{s}",
            .{ self.owner.options.app_id, suffix },
        );
        defer self.gpa.free(base);

        return self.icon_export.?.writeSvg(base, markup) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("perch: cannot write an SVG icon: {t}", .{err});
                return null;
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

/// The name a host can resolve on its own, if the icon offers one. A path counts:
/// hosts that accept absolute paths will take it, and the pixmaps cover the rest.
fn themedName(icon: ?Icon) ?[]const u8 {
    const source = icon orelse return null;
    if (source.themedName()) |name| return name;
    return switch (source) {
        .path => |path| path,
        else => null,
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

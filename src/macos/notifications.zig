//! UserNotifications owns asynchronous blocks, never a movable Center or a Tray.
//! Notification authority is exclusive for the lifetime of the first notifying tray.
//! Requires a real main .app bundle (APPL), matching app_id, and macOS 11 or newer.
const std = @import("std");
const objc = @import("objc.zig");
const images = @import("image.zig");
const tray = @import("../tray.zig");
const Tray = tray.Tray;
const Error = tray.Error;
const Notification = @import("../notification.zig").Notification;
const gpa = std.heap.c_allocator;
const Id = objc.Id;
const log = std.log.scoped(.perch_macos_notifications);

const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Lock) void {
        while (self.held.swap(true, .acquire)) {
            while (self.held.load(.monotonic)) std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *Lock) void {
        self.held.store(false, .release);
    }
};
var authority_lock: Lock = .{};
var authority: ?*State = null;
var delegate_class: ?objc.Class = null;

const Record = struct {
    sequence: u64,
    tag: ?Notification.Tag,
    identifier: Id,
    request: Id,
    category: Id,
    submitted: bool = false,

    fn deinit(self: Record) void {
        objc.release(self.identifier);
        objc.release(self.request);
        objc.release(self.category);
    }
};
const Event = struct {
    next: ?*Event = null,
    kind: enum { authorization, categories, submission, response, closed },
    identifier: Id = null,
    value: Id = null,
    granted: bool = false,
    sequence: u64 = 0,

    fn destroy(self: *Event) void {
        objc.release(self.identifier);
        objc.release(self.value);
        gpa.destroy(self);
    }
};
const State = struct {
    refs: std.atomic.Value(usize) = .init(1),
    lock: Lock = .{},
    // Queue and owner lifetime are guarded by lock. Other fields are tray-thread-only.
    owner: ?*Tray,
    first: ?*Event = null,
    last: ?*Event = null,
    queue_failed: bool = false,
    delivery_failed: bool = false,
    center: Id = null,
    delegate: Id = null,
    baseline_categories: Id = null,
    session: Id = null,
    authorization: enum { pending, granted, denied } = .pending,
    records: std.ArrayList(Record) = .empty,
    next_sequence: u64 = 0,
    diagnostic: [1024]u8 = undefined,

    fn retain(self: *State) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        objc.release(self.center);
        objc.release(self.baseline_categories);
        objc.release(self.session);
        gpa.destroy(self);
    }
    fn fail(self: *State, message: []const u8, native: Id) void {
        const detail = if (native != null) objc.utf8(objc.send(Id, native, "localizedDescription", .{})) else "";
        const text = std.fmt.bufPrint(&self.diagnostic, "{s}{s}{s}", .{ message, if (detail.len != 0) ": " else "", detail }) catch self.diagnostic[0..self.diagnostic.len];
        if (self.owner) |owner| owner.last_diagnostic = text;
        log.err("{s}", .{text});
    }
    fn enqueue(self: *State, event: Event) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.owner == null) return false;
        const node = gpa.create(Event) catch {
            self.queue_failed = true;
            return false;
        };
        node.* = event;
        node.identifier = objc.retain(event.identifier);
        node.value = objc.retain(event.value);
        if (self.last) |last| last.next = node else self.first = node;
        self.last = node;
        return true;
    }
    fn removeNative(self: *State, identifier: Id) void {
        const identifiers = objc.send(Id, objc.class("NSArray"), "arrayWithObject:", .{identifier});
        objc.send(void, self.center, "removePendingNotificationRequestsWithIdentifiers:", .{identifiers});
        objc.send(void, self.center, "removeDeliveredNotificationsWithIdentifiers:", .{identifiers});
    }
    fn findSequence(self: *State, sequence: u64) ?usize {
        for (self.records.items, 0..) |record, index| if (record.sequence == sequence) return index;
        return null;
    }
    fn findIdentifier(self: *State, identifier: Id) ?usize {
        for (self.records.items, 0..) |record, index| {
            if (objc.send(objc.BOOL, record.identifier, "isEqualToString:", .{identifier}) != 0) return index;
        }
        return null;
    }
    fn categories(self: *State) void {
        if (self.baseline_categories == null or objc.send(Id, self.center, "delegate", .{}) != self.delegate) return;
        const merged = objc.send(Id, self.baseline_categories, "mutableCopy", .{});
        defer objc.release(merged);
        for (self.records.items) |record| objc.send(void, merged, "addObject:", .{record.category});
        objc.send(void, self.center, "setNotificationCategories:", .{merged});
    }
    fn submit(self: *State) void {
        if (self.delivery_failed or self.authorization != .granted or self.baseline_categories == null) return;
        if (objc.send(Id, self.center, "delegate", .{}) != self.delegate) {
            self.fail("Notification delegate changed while perch owned notification authority; submissions stopped", null);
            return;
        }
        self.categories();
        for (self.records.items) |*record| {
            if (record.submitted) continue;
            record.submitted = true;
            var block = Block.init(self, &submissionComplete);
            block.sequence = record.sequence;
            block.identifier = record.identifier;
            objc.send(void, self.center, "addNotificationRequest:withCompletionHandler:", .{ record.request, &block });
        }
    }
};

pub const Center = struct {
    state: *State,

    pub fn init(owner: *Tray) Error!Center {
        const state = try gpa.create(State);
        state.* = .{ .owner = owner };
        return .{ .state = state };
    }

    pub fn deinit(self: *Center) void {
        const pool = objc.pool();
        defer objc.release(pool);
        const state = self.state;
        state.lock.lock();
        state.owner = null;
        var event = state.first;
        state.first = null;
        state.last = null;
        state.lock.unlock();
        while (event) |node| {
            event = node.next;
            node.destroy();
        }
        authority_lock.lock();
        if (authority == state) {
            if (objc.send(Id, state.center, "delegate", .{}) == state.delegate) {
                objc.send(void, state.center, "setDelegate:", .{@as(Id, null)});
                if (state.baseline_categories != null) objc.send(void, state.center, "setNotificationCategories:", .{state.baseline_categories});
            }
            authority = null;
        }
        authority_lock.unlock();
        for (state.records.items) |record| {
            state.removeNative(record.identifier);
            record.deinit();
        }
        state.records.deinit(gpa);
        objc.release(state.delegate);
        state.delegate = null;
        state.release();
    }

    fn start(self: *Center) Error!void {
        const state = self.state;
        const owner = state.owner orelse return error.PlatformFailure;
        if (state.center != null) {
            if (objc.send(Id, state.center, "delegate", .{}) != state.delegate) {
                state.fail("Host replaced perch's notification delegate; notification authority is no longer available", null);
                return error.PlatformFailure;
            }
            return;
        }
        const bundle = objc.send(Id, objc.class("NSBundle"), "mainBundle", .{});
        const identifier = objc.send(Id, bundle, "bundleIdentifier", .{});
        const package = objc.send(Id, bundle, "objectForInfoDictionaryKey:", .{objc.string("CFBundlePackageType")});
        const url = objc.send(Id, bundle, "bundleURL", .{});
        const extension = objc.send(Id, url, "pathExtension", .{});
        if (identifier == null or !std.mem.eql(u8, objc.utf8(package), "APPL") or
            !std.mem.eql(u8, objc.utf8(extension), "app") or
            !std.mem.eql(u8, objc.utf8(identifier), owner.options.app_id))
        {
            state.fail("macOS notifications require a real .app main bundle with CFBundlePackageType=APPL and CFBundleIdentifier matching Tray.options.app_id; bare executables are not supported", null);
            return error.PlatformFailure;
        }
        const Version = extern struct { major: isize, minor: isize, patch: isize };
        const process = objc.send(Id, objc.class("NSProcessInfo"), "processInfo", .{});
        if (objc.send(objc.BOOL, process, "isOperatingSystemAtLeastVersion:", .{Version{ .major = 11, .minor = 0, .patch = 0 }}) == 0) {
            state.fail("perch notifications require macOS 11 or newer", null);
            return error.Unsupported;
        }
        authority_lock.lock();
        defer authority_lock.unlock();
        if (authority != null) {
            state.fail("Another perch tray owns this application's notification authority", null);
            return error.PlatformFailure;
        }
        const center = objc.send(Id, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
        if (center == null or objc.send(Id, center, "delegate", .{}) != null) {
            state.fail("The application already has a UNUserNotificationCenter delegate; perch will not replace its notification authority", null);
            return error.PlatformFailure;
        }
        const cls = try delegateClass();
        const delegate = objc.send(Id, objc.send(Id, cls, "alloc", .{}), "init", .{}) orelse return error.OutOfMemory;
        state.retain(); // Released by delegate dealloc, not when its weak center link is cleared.
        _ = objc.object_setInstanceVariable(delegate, "perchState", state);
        state.center = objc.retain(center);
        state.delegate = delegate;
        state.session = objc.retain(objc.send(Id, objc.send(Id, objc.class("NSUUID"), "UUID", .{}), "UUIDString", .{}));
        authority = state;
        objc.send(void, center, "setDelegate:", .{delegate});
        var categories_block = Block.init(state, &categoriesComplete);
        objc.send(void, center, "getNotificationCategoriesWithCompletionHandler:", .{&categories_block});
        var authorization_block = Block.init(state, &authorizationComplete);
        objc.send(void, center, "requestAuthorizationWithOptions:completionHandler:", .{ @as(usize, 6), &authorization_block });
    }

    pub fn notify(self: *Center, notification: Notification) Error!void {
        const pool = objc.pool();
        defer objc.release(pool);
        try self.start();
        const state = self.state;
        if (state.delivery_failed) {
            state.fail("Notification callback queue failed; recreate the tray before posting more notifications", null);
            return error.PlatformFailure;
        }
        if (state.authorization == .denied) {
            state.fail("Notification authorization was denied; enable notifications in System Settings and recreate the tray", null);
            return error.PlatformFailure;
        }
        const owner = state.owner orelse return error.PlatformFailure;
        if (state.next_sequence == std.math.maxInt(u64)) return error.PlatformFailure;
        state.next_sequence += 1;
        var identifier_buffer: [96]u8 = undefined;
        const identifier_text = std.fmt.bufPrint(&identifier_buffer, "perch.{s}.{d}", .{ objc.utf8(state.session), state.next_sequence }) catch return error.PlatformFailure;
        const identifier = objc.string(identifier_text);
        const content = objc.send(Id, objc.send(Id, objc.class("UNMutableNotificationContent"), "alloc", .{}), "init", .{});
        defer objc.release(content);
        objc.send(void, content, "setTitle:", .{objc.string(notification.title)});
        objc.send(void, content, "setBody:", .{objc.string(notification.body)});
        if (!notification.suppress_sound) {
            const sound = if (notification.sound_name) |name|
                objc.send(Id, objc.class("UNNotificationSound"), "soundNamed:", .{objc.string(name)})
            else
                objc.send(Id, objc.class("UNNotificationSound"), "defaultSound", .{});
            objc.send(void, content, "setSound:", .{sound});
        }
        if (notification.image) |icon| {
            const attachment = try makeAttachment(state, owner, icon);
            const attachments = objc.send(Id, objc.class("NSArray"), "arrayWithObject:", .{attachment});
            objc.send(void, content, "setAttachments:", .{attachments});
        }
        const actions = objc.send(Id, objc.class("NSMutableArray"), "array", .{});
        for (notification.actions, 0..) |action, index| {
            if (action.key.len == 0 or std.mem.eql(u8, action.key, "com.apple.UNNotificationDefaultActionIdentifier") or
                std.mem.eql(u8, action.key, "com.apple.UNNotificationDismissActionIdentifier"))
            {
                state.fail("Notification action keys must be nonempty and cannot use Apple's reserved identifiers", null);
                return error.PlatformFailure;
            }
            for (notification.actions[0..index]) |previous| {
                if (std.mem.eql(u8, previous.key, action.key)) {
                    state.fail("Notification action keys must be unique within a notification", null);
                    return error.PlatformFailure;
                }
            }
            const native = objc.send(Id, objc.class("UNNotificationAction"), "actionWithIdentifier:title:options:", .{ objc.string(action.key), objc.string(action.label), @as(usize, 4) });
            objc.send(void, actions, "addObject:", .{native});
        }
        const category = objc.send(Id, objc.class("UNNotificationCategory"), "categoryWithIdentifier:actions:intentIdentifiers:options:", .{
            identifier, actions, objc.send(Id, objc.class("NSArray"), "array", .{}), @as(usize, 1),
        });
        objc.send(void, content, "setCategoryIdentifier:", .{identifier});
        const request = objc.send(Id, objc.class("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", .{ identifier, content, @as(Id, null) });
        if (request == null or category == null) {
            state.fail("UserNotifications failed to construct the notification request", null);
            return error.PlatformFailure;
        }
        try state.records.ensureUnusedCapacity(gpa, 1);
        // Build the replacement fully before withdrawing the existing notification.
        if (notification.tag) |tag| {
            for (state.records.items, 0..) |record, index| {
                if (record.tag == tag) {
                    state.removeNative(record.identifier);
                    state.records.orderedRemove(index).deinit();
                    break;
                }
            }
        }
        state.records.appendAssumeCapacity(.{
            .sequence = state.next_sequence,
            .tag = notification.tag,
            .identifier = objc.retain(identifier),
            .request = objc.retain(request),
            .category = objc.retain(category),
        });
        state.submit();
    }

    pub fn close(self: *Center, tag: Notification.Tag) Error!void {
        const pool = objc.pool();
        defer objc.release(pool);
        const state = self.state;
        for (state.records.items, 0..) |record, index| {
            if (record.tag != tag) continue;
            state.removeNative(record.identifier);
            state.records.orderedRemove(index).deinit();
            state.categories();
            if (!state.enqueue(.{ .kind = .closed, .sequence = tag })) return error.OutOfMemory;
            return;
        }
    }

    pub fn pump(self: *Center) void {
        const state = self.state;
        state.retain();
        defer state.release();
        const pool = objc.pool();
        defer objc.release(pool);
        state.lock.lock();
        var event = state.first;
        state.first = null;
        state.last = null;
        const queue_failed = state.queue_failed;
        state.queue_failed = false;
        state.lock.unlock();
        if (queue_failed) {
            state.delivery_failed = true;
            state.fail("Out of memory receiving notification results; outstanding notifications were withdrawn and this center is disabled", null);
            for (state.records.items) |record| {
                state.removeNative(record.identifier);
                record.deinit();
            }
            state.records.clearRetainingCapacity();
            state.categories();
        }
        while (event) |node| {
            event = node.next;
            defer node.destroy();
            if (state.owner == null) continue;
            switch (node.kind) {
                .authorization => {
                    state.authorization = if (node.granted and node.value == null) .granted else .denied;
                    if (state.authorization == .denied) {
                        state.fail("Notification authorization failed or was denied; enable notifications in System Settings", node.value);
                        for (state.records.items) |record| record.deinit();
                        state.records.clearRetainingCapacity();
                    }
                },
                .categories => {
                    objc.release(state.baseline_categories);
                    state.baseline_categories = objc.retain(node.value);
                },
                .submission => {
                    if (state.findSequence(node.sequence)) |index| {
                        if (node.value != null) {
                            state.fail("UserNotifications rejected the notification submission", node.value);
                            state.records.orderedRemove(index).deinit();
                            state.categories();
                        }
                    } else state.removeNative(node.identifier); // Closed/replaced during asynchronous submission.
                },
                .response => {
                    if (state.findIdentifier(node.identifier)) |index| {
                        const record = state.records.orderedRemove(index);
                        const tag = record.tag;
                        state.removeNative(record.identifier);
                        record.deinit();
                        state.categories();
                        if (tag) |value| {
                            const action = objc.utf8(node.value);
                            const dismissed = std.mem.eql(u8, action, "com.apple.UNNotificationDismissActionIdentifier");
                            if (!dismissed) {
                                const key = if (std.mem.eql(u8, action, "com.apple.UNNotificationDefaultActionIdentifier")) "default" else action;
                                if (state.owner) |owner| owner.dispatchNotificationAction(value, key);
                            }
                            if (state.owner) |owner| owner.dispatchNotificationClosed(value, .dismissed);
                        }
                    }
                },
                .closed => {
                    if (state.owner) |owner| owner.dispatchNotificationClosed(@intCast(node.sequence), .closed);
                },
            }
        }
        if (state.owner != null) state.submit();
    }
};

// Clang's Blocks ABI: pointer-sized reserved/size in the descriptor, int flags,
// copy/dispose helpers, and signature present when BLOCK_HAS_SIGNATURE is set.
extern var _NSConcreteStackBlock: [32]usize;
const Descriptor = extern struct {
    reserved: usize = 0,
    size: usize = @sizeOf(Block),
    copy: *const fn (*Block, *const Block) callconv(.c) void = &copyBlock,
    dispose: *const fn (*Block) callconv(.c) void = &disposeBlock,
    signature: [*:0]const u8,
};
const Block = extern struct {
    isa: *anyopaque,
    flags: i32 = (1 << 25) | (1 << 30),
    reserved: i32 = 0,
    invoke: *const anyopaque,
    descriptor: *const Descriptor,
    state: *State,
    identifier: Id = null,
    sequence: u64 = 0,

    fn init(state: *State, comptime callback: anytype) Block {
        const descriptor = &struct {
            const value: Descriptor = .{ .signature = if (@TypeOf(callback) == @TypeOf(&authorizationComplete))
                (if (@import("builtin").cpu.arch == .aarch64) "v24@?0B8@16" else "v24@?0c8@16")
            else
                "v16@?0@8" };
        }.value;
        return .{ .isa = @ptrCast(&_NSConcreteStackBlock), .invoke = @ptrCast(callback), .descriptor = descriptor, .state = state };
    }
};
fn copyBlock(destination: *Block, source: *const Block) callconv(.c) void {
    source.state.retain();
    destination.identifier = objc.retain(source.identifier);
}
fn disposeBlock(block: *Block) callconv(.c) void {
    objc.release(block.identifier);
    block.state.release();
}
fn authorizationComplete(block: *Block, granted: objc.BOOL, native_error: Id) callconv(.c) void {
    _ = block.state.enqueue(.{ .kind = .authorization, .granted = granted != 0, .value = native_error });
}
fn categoriesComplete(block: *Block, categories: Id) callconv(.c) void {
    _ = block.state.enqueue(.{ .kind = .categories, .value = categories });
}
fn submissionComplete(block: *Block, native_error: Id) callconv(.c) void {
    const state = block.state;
    // A late add, including a result lost to allocation failure, must not
    // resurrect a notification after its tray has been destroyed.
    if (!state.enqueue(.{ .kind = .submission, .identifier = block.identifier, .sequence = block.sequence, .value = native_error })) {
        const pool = objc.pool();
        defer objc.release(pool);
        state.removeNative(block.identifier);
    }
}

extern fn objc_disposeClassPair(objc.Class) void;
fn delegateClass() Error!objc.Class {
    if (delegate_class) |cls| return cls;
    const cls = objc.objc_allocateClassPair(objc.class("NSObject"), "PerchNotificationDelegate", 0) orelse return error.PlatformFailure;
    errdefer objc_disposeClassPair(cls);
    if (!objc.class_addIvar(cls, "perchState", @sizeOf(?*State), @intCast(@ctz(@as(usize, @alignOf(?*State)))), "^v") or
        !objc.addMethod(cls, "dealloc", &delegateDealloc, "v@:") or
        !objc.addMethod(cls, "userNotificationCenter:willPresentNotification:withCompletionHandler:", &willPresent, "v@:@@@?") or
        !objc.addMethod(cls, "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", &didRespond, "v@:@@@?")) return error.PlatformFailure;
    objc.objc_registerClassPair(cls);
    delegate_class = cls;
    return cls;
}
fn delegateState(receiver: Id) ?*State {
    var pointer: ?*anyopaque = null;
    _ = objc.object_getInstanceVariable(receiver, "perchState", &pointer);
    return @ptrCast(@alignCast(pointer));
}
const Super = extern struct { receiver: Id, super_class: objc.Class };
extern fn objc_msgSendSuper(*Super, objc.Sel) callconv(.c) void;
fn delegateDealloc(receiver: Id, _: objc.Sel) callconv(.c) void {
    if (delegateState(receiver)) |state| state.release();
    var super = Super{ .receiver = receiver, .super_class = objc.class("NSObject") };
    objc_msgSendSuper(&super, objc.sel("dealloc"));
}
const Completion = extern struct { isa: *anyopaque, flags: i32, reserved: i32, invoke: *const anyopaque };
fn willPresent(_: Id, _: objc.Sel, _: Id, _: Id, completion: *Completion) callconv(.c) void {
    const invoke: *const fn (*Completion, usize) callconv(.c) void = @ptrCast(@alignCast(completion.invoke));
    invoke(completion, (1 << 1) | (1 << 3) | (1 << 4));
}
fn didRespond(receiver: Id, _: objc.Sel, _: Id, response: Id, completion: *Completion) callconv(.c) void {
    if (delegateState(receiver)) |state| {
        const notification = objc.send(Id, response, "notification", .{});
        const request = objc.send(Id, notification, "request", .{});
        _ = state.enqueue(.{
            .kind = .response,
            .identifier = objc.send(Id, request, "identifier", .{}),
            .value = objc.send(Id, response, "actionIdentifier", .{}),
        });
    }
    const invoke: *const fn (*Completion) callconv(.c) void = @ptrCast(@alignCast(completion.invoke));
    invoke(completion);
}

extern fn NSTemporaryDirectory() Id;
extern fn mkdtemp([*:0]u8) ?[*:0]u8;
fn makeAttachment(state: *State, owner: *Tray, icon: @import("../icon.zig").Icon) Error!Id {
    const image = try images.load(owner, icon, 512);
    defer objc.release(image);
    const tiff = objc.send(Id, image, "TIFFRepresentation", .{});
    const bitmap = objc.send(Id, objc.send(Id, objc.class("NSBitmapImageRep"), "alloc", .{}), "initWithData:", .{tiff});
    defer objc.release(bitmap);
    const properties = objc.send(Id, objc.class("NSDictionary"), "dictionary", .{});
    const png = objc.send(Id, bitmap, "representationUsingType:properties:", .{ @as(usize, 4), properties });
    if (png == null) {
        state.fail("Unable to encode notification image as PNG", null);
        return error.PlatformFailure;
    }
    var directory_buffer: [4096]u8 = undefined;
    const directory = std.fmt.bufPrintZ(&directory_buffer, "{s}perch-notification-XXXXXX", .{objc.utf8(NSTemporaryDirectory())}) catch return error.PlatformFailure;
    if (mkdtemp(directory.ptr) == null) {
        state.fail("Unable to create private notification attachment directory", null);
        return error.PlatformFailure;
    }
    const directory_string = objc.string(directory);
    const manager = objc.send(Id, objc.class("NSFileManager"), "defaultManager", .{});
    defer _ = objc.send(objc.BOOL, manager, "removeItemAtPath:error:", .{ directory_string, @as(?*Id, null) });
    const path = objc.send(Id, directory_string, "stringByAppendingPathComponent:", .{objc.string("image.png")});
    if (objc.send(objc.BOOL, png, "writeToFile:atomically:", .{ path, @as(objc.BOOL, 1) }) == 0) {
        state.fail("Unable to write notification attachment image", null);
        return error.PlatformFailure;
    }
    const url = objc.send(Id, objc.class("NSURL"), "fileURLWithPath:", .{path});
    var native_error: Id = null;
    const attachment = objc.send(Id, objc.class("UNNotificationAttachment"), "attachmentWithIdentifier:URL:options:error:", .{ objc.string("image"), url, @as(Id, null), &native_error });
    if (attachment == null) {
        state.fail("UserNotifications rejected the image attachment", native_error);
        return error.PlatformFailure;
    }
    // UNNotificationAttachment moves the source into its managed attachment store.
    return attachment;
}

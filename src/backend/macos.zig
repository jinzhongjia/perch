//! AppKit status items, menus and event delivery through the Objective-C runtime.
//! Every operation except stop (including destruction) belongs on the main thread.
const std = @import("std");
const objc = @import("../macos/objc.zig");
const images = @import("../macos/image.zig");
const Center = @import("../macos/notifications.zig").Center;
const Icon = @import("../icon.zig").Icon;
const Menu = @import("../menu.zig").Menu;
const MenuItem = @import("../menu.zig").MenuItem;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

extern "c" fn pthread_main_np() c_int;
extern "c" var NSApp: objc.Id;
extern "c" var NSDefaultRunLoopMode: objc.Id;
extern "c" var NSRunLoopCommonModes: objc.Id;
extern "c" var NSApplicationWillTerminateNotification: objc.Id;

const yes: objc.BOOL = 1;
const no: objc.BOOL = 0;
const shift_mask: usize = 1 << 17;
const control_mask: usize = 1 << 18;
const option_mask: usize = 1 << 19;
const command_mask: usize = 1 << 20;
const icon_size: f64 = 18;

pub const Backend = struct {
    pub const supported = true;

    owner: *Tray,
    app: objc.Id,
    item: objc.Id,
    button: objc.Id,
    target: objc.Id,
    view: objc.Id,
    timer: objc.Id = null,
    native_menu: objc.Id = null,
    pending_menu: objc.Id = null,
    menu_pending: bool = false,
    tracking: bool = false,
    icon: objc.Id = null,
    attention: objc.Id = null,
    overlay: objc.Id = null,
    notifications: Center,
    stopping: std.atomic.Value(bool) = .init(false),
    running: bool = false,
    ready: bool = false,
    quit: bool = false,
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,

    pub fn init(owner: *Tray) Error!Backend {
        try mainThread(owner);
        const pool = objc.pool();
        defer objc.release(pool);
        const new_app = NSApp == null;
        const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
        if (app == null) return fail(owner, "macos: cannot create NSApplication");
        // Never change the policy or delegate of an embedding application.
        if (new_app) {
            // LSUIElement bundles already launch as accessory applications;
            // AppKit may return NO for a policy change that is unnecessary.
            if (objc.send(isize, app, "activationPolicy", .{}) != 1 and
                objc.send(objc.BOOL, app, "setActivationPolicy:", .{@as(isize, 1)}) == 0 and
                objc.send(isize, app, "activationPolicy", .{}) != 1)
                return fail(owner, "macos: AppKit rejected accessory activation policy; a GUI login session is required");
            objc.send(void, app, "finishLaunching", .{});
        }
        const target_class = try targetClass(owner);
        const view_class = try viewClass(owner);
        const target = objc.send(objc.Id, objc.send(objc.Id, target_class, "alloc", .{}), "init", .{});
        if (target == null) return error.OutOfMemory;
        errdefer objc.release(target);
        const bar = objc.send(objc.Id, objc.class("NSStatusBar"), "systemStatusBar", .{});
        const item = objc.retain(objc.send(objc.Id, bar, "statusItemWithLength:", .{@as(f64, -1)}));
        if (item == null) return fail(owner, "macos: no status bar item is available in this GUI session");
        errdefer {
            objc.send(void, bar, "removeStatusItem:", .{item});
            objc.release(item);
        }
        const button = objc.send(objc.Id, item, "button", .{});
        if (button == null) return fail(owner, "macos: NSStatusItem has no button");
        const bounds = objc.send(objc.Rect, button, "bounds", .{});
        const view = objc.send(objc.Id, objc.send(objc.Id, view_class, "alloc", .{}), "initWithFrame:", .{bounds});
        if (view == null) return error.OutOfMemory;
        errdefer objc.release(view);
        objc.send(void, view, "setAutoresizingMask:", .{@as(usize, 2 | 16)});
        objc.send(void, button, "addSubview:", .{view});
        errdefer objc.send(void, view, "removeFromSuperview", .{});
        var self: Backend = .{
            .owner = owner,
            .app = app,
            .item = item,
            .button = button,
            .target = target,
            .view = view,
            .notifications = try Center.init(owner),
        };
        errdefer self.notifications.deinit();
        errdefer {
            objc.release(self.icon);
            objc.release(self.attention);
            objc.release(self.overlay);
            objc.release(self.native_menu);
        }
        if (owner.options.icon) |icon| self.icon = try images.load(owner, icon, icon_size);
        if (owner.options.attention_icon) |icon| self.attention = try images.load(owner, icon, icon_size);
        if (owner.options.overlay_icon) |icon| self.overlay = try images.load(owner, icon, icon_size);
        try self.refreshIcon();
        try self.setTitle(owner.options.title);
        try self.setTooltip(owner.options.tooltip);
        try self.setMenu(owner.menu);
        objc.send(void, item, "setVisible:", .{@as(objc.BOOL, if (owner.options.status == .passive) no else yes)});
        const timer = objc.retain(objc.send(objc.Id, objc.class("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", .{
            @as(f64, 0.1), target, objc.sel("perchTick:"), @as(objc.Id, null), yes,
        }));
        if (timer == null) return error.OutOfMemory;
        self.timer = timer;
        // Only stable Tray addresses reach Objective-C. Backend is still a movable local.
        _ = objc.object_setInstanceVariable(target, "perchOwner", owner);
        _ = objc.object_setInstanceVariable(view, "perchOwner", owner);
        objc.send(void, button, "setTarget:", .{target});
        objc.send(void, button, "setAction:", .{objc.sel("perchPress:")});
        const loop = objc.send(objc.Id, objc.class("NSRunLoop"), "mainRunLoop", .{});
        objc.send(void, loop, "addTimer:forMode:", .{ timer, NSRunLoopCommonModes });
        const center = objc.send(objc.Id, objc.class("NSNotificationCenter"), "defaultCenter", .{});
        objc.send(void, center, "addObserver:selector:name:object:", .{
            target, objc.sel("perchTerminate:"), NSApplicationWillTerminateNotification, app,
        });
        return self;
    }

    pub fn deinit(self: *Backend) void {
        if (pthread_main_np() == 0) @panic("perch: macOS Tray.destroy must run on the main thread");
        const pool = objc.pool();
        defer objc.release(pool);
        self.stop();
        _ = objc.object_setInstanceVariable(self.target, "perchOwner", null);
        _ = objc.object_setInstanceVariable(self.view, "perchOwner", null);
        objc.send(void, self.timer, "invalidate", .{});
        objc.release(self.timer);
        const center = objc.send(objc.Id, objc.class("NSNotificationCenter"), "defaultCenter", .{});
        objc.send(void, center, "removeObserver:", .{self.target});
        if (self.tracking) objc.send(void, self.native_menu, "cancelTracking", .{});
        self.notifications.deinit();
        objc.send(void, self.button, "setTarget:", .{@as(objc.Id, null)});
        objc.send(void, self.view, "removeFromSuperview", .{});
        objc.release(self.view);
        objc.send(void, objc.send(objc.Id, objc.class("NSStatusBar"), "systemStatusBar", .{}), "removeStatusItem:", .{self.item});
        objc.release(self.item);
        objc.release(self.native_menu);
        objc.release(self.pending_menu);
        objc.release(self.icon);
        objc.release(self.attention);
        objc.release(self.overlay);
        objc.release(self.target);
    }

    pub fn setIcon(self: *Backend, icon: Icon) Error!void {
        try self.replaceIcon(&self.icon, icon);
    }

    pub fn setAttentionIcon(self: *Backend, icon: ?Icon) Error!void {
        try self.replaceIcon(&self.attention, icon);
    }

    pub fn setOverlayIcon(self: *Backend, icon: ?Icon) Error!void {
        try self.replaceIcon(&self.overlay, icon);
    }

    fn replaceIcon(self: *Backend, slot: *objc.Id, icon: ?Icon) Error!void {
        try mainThread(self.owner);
        const pool = objc.pool();
        defer objc.release(pool);
        const replacement = if (icon) |value| try images.load(self.owner, value, icon_size) else null;
        const previous = slot.*;
        slot.* = replacement;
        self.refreshIcon() catch |err| {
            slot.* = previous;
            objc.release(replacement);
            return err;
        };
        objc.release(previous);
    }

    fn refreshIcon(self: *Backend) Error!void {
        const base = if (self.owner.options.status == .needs_attention and self.attention != null) self.attention else self.icon;
        const result = if (base != null and self.overlay != null)
            try images.composite(self.owner, base, self.overlay, icon_size)
        else
            objc.retain(base orelse self.overlay);
        defer objc.release(result);
        objc.send(void, self.button, "setImage:", .{result});
        objc.send(void, self.button, "setImagePosition:", .{@as(usize, 2)});
    }

    pub fn setTooltip(self: *Backend, tooltip: ?[]const u8) Error!void {
        try mainThread(self.owner);
        const pool = objc.pool();
        defer objc.release(pool);
        const text = if (tooltip) |value| objc.string(value) else null;
        objc.send(void, self.button, "setToolTip:", .{text});
        objc.send(void, self.view, "setToolTip:", .{text});
    }

    pub fn setTitle(self: *Backend, title: []const u8) Error!void {
        try mainThread(self.owner);
        const pool = objc.pool();
        defer objc.release(pool);
        objc.send(void, self.button, "setTitle:", .{objc.string(title)});
    }

    pub fn setStatus(self: *Backend, status: tray_mod.Status) Error!void {
        try mainThread(self.owner);
        const pool = objc.pool();
        defer objc.release(pool);
        try self.refreshIcon();
        objc.send(void, self.item, "setVisible:", .{@as(objc.BOOL, if (status == .passive) no else yes)});
    }

    pub fn setMenu(self: *Backend, menu: ?*Menu) Error!void {
        try mainThread(self.owner);
        const pool = objc.pool();
        defer objc.release(pool);
        const replacement = if (menu) |value| try self.buildMenu(value, 0) else null;
        if (self.tracking) {
            objc.release(self.pending_menu);
            self.pending_menu = replacement;
            self.menu_pending = true;
        } else {
            objc.release(self.native_menu);
            self.native_menu = replacement;
        }
    }

    fn buildMenu(self: *Backend, source: *Menu, depth: usize) Error!objc.Id {
        if (depth > 64) return fail(self.owner, "macos: menu nesting exceeds 64 levels (or contains a cycle)");
        const menu = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.string("")});
        if (menu == null) return error.OutOfMemory;
        errdefer objc.release(menu);
        objc.send(void, menu, "setAutoenablesItems:", .{no});
        for (source.items.items) |entry| {
            if (entry.kind == .separator) {
                objc.send(void, menu, "addItem:", .{objc.send(objc.Id, objc.class("NSMenuItem"), "separatorItem", .{})});
                continue;
            }
            const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
                objc.string(entry.label), objc.sel("perchActivate:"), objc.string(""),
            });
            if (item == null) return error.OutOfMemory;
            defer objc.release(item);
            objc.send(void, item, "setTarget:", .{self.target});
            objc.send(void, item, "setTag:", .{@as(isize, @intCast(entry.id))});
            objc.send(void, item, "setEnabled:", .{@as(objc.BOOL, if (entry.enabled) yes else no)});
            objc.send(void, item, "setState:", .{@as(isize, if ((entry.kind == .checkbox or entry.kind == .radio) and entry.checked) 1 else 0)});
            if (entry.kind == .radio) {
                const dot = objc.send(objc.Id, objc.class("NSImage"), "imageNamed:", .{objc.string("NSMenuItemBullet")});
                objc.send(void, item, "setOnStateImage:", .{dot});
            }
            if (entry.tooltip) |text| objc.send(void, item, "setToolTip:", .{objc.string(text)});
            if (entry.accelerator) |text| try accelerator(self.owner, item, text);
            if (entry.icon) |icon| {
                const image = try images.load(self.owner, icon, 16);
                defer objc.release(image);
                objc.send(void, item, "setImage:", .{image});
            }
            if (entry.kind == .submenu) {
                if (entry.submenu) |child| {
                    const sub = try self.buildMenu(child, depth + 1);
                    defer objc.release(sub);
                    objc.send(void, item, "setSubmenu:", .{sub});
                }
            }
            objc.send(void, menu, "addItem:", .{item});
        }
        return menu;
    }

    pub fn notify(self: *Backend, notification: Notification) Error!void {
        try mainThread(self.owner);
        try self.notifications.notify(notification);
    }

    pub fn closeNotification(self: *Backend, tag: Notification.Tag) Error!void {
        try mainThread(self.owner);
        try self.notifications.close(tag);
    }

    pub fn showMenu(self: *Backend) Error!void {
        try mainThread(self.owner);
        if (self.tracking) return fail(self.owner, "macos: cannot open a second menu while this tray's menu is tracking");
        const menu = objc.retain(self.native_menu orelse return);
        defer objc.release(menu);
        const target = objc.retain(self.target);
        defer objc.release(target);
        const pool = objc.pool();
        defer objc.release(pool);
        self.tracking = true;
        objc.send(void, self.button, "highlight:", .{yes});
        const location = objc.send(objc.Point, objc.class("NSEvent"), "mouseLocation", .{});
        _ = objc.send(objc.BOOL, menu, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(objc.Id, null), location, @as(objc.Id, null) });
        // A selected item's callback may replace the menu or destroy the entire tray.
        if (ownerFor(target)) |owner| {
            const current = &owner.impl;
            current.tracking = false;
            objc.send(void, current.button, "highlight:", .{no});
            if (current.menu_pending) {
                objc.release(current.native_menu);
                current.native_menu = current.pending_menu;
                current.pending_menu = null;
                current.menu_pending = false;
            }
        }
    }

    pub fn run(self: *Backend) Error!void {
        try mainThread(self.owner);
        if (self.running) return fail(self.owner, "macos: Tray.run cannot be nested; use Tray.pump inside a host event loop");
        const target = objc.retain(self.target);
        defer objc.release(target);
        self.running = true;
        self.stopping.store(false, .release);
        self.quit = false;
        ready(target);
        while (ownerFor(target)) |owner| {
            if (owner.impl.stopping.load(.acquire)) break;
            const pool = objc.pool();
            defer objc.release(pool);
            const event = objc.send(objc.Id, owner.impl.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
                @as(usize, std.math.maxInt(usize)), objc.send(objc.Id, objc.class("NSDate"), "distantFuture", .{}), NSDefaultRunLoopMode, yes,
            });
            if (ownerFor(target)) |live| {
                if (event != null) objc.send(void, live.impl.app, "sendEvent:", .{event});
            }
            if (ownerFor(target)) |live| objc.send(void, live.impl.app, "updateWindows", .{});
            if (ownerFor(target)) |live| live.impl.notifications.pump();
        }
        if (ownerFor(target)) |owner| {
            owner.impl.running = false;
            quitting(target);
        }
    }

    pub fn pump(self: *Backend) Error!void {
        try mainThread(self.owner);
        const target = objc.retain(self.target);
        defer objc.release(target);
        ready(target);
        while (ownerFor(target)) |owner| {
            const pool = objc.pool();
            defer objc.release(pool);
            const event = objc.send(objc.Id, owner.impl.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
                @as(usize, std.math.maxInt(usize)), objc.send(objc.Id, objc.class("NSDate"), "distantPast", .{}), NSDefaultRunLoopMode, yes,
            }) orelse break;
            if (ownerFor(target)) |live| objc.send(void, live.impl.app, "sendEvent:", .{@as(objc.Id, event)});
        }
        if (ownerFor(target)) |owner| objc.send(void, owner.impl.app, "updateWindows", .{});
        if (ownerFor(target)) |owner| owner.impl.notifications.pump();
        if (ownerFor(target)) |owner| {
            if (owner.impl.stopping.load(.acquire)) quitting(target);
        }
    }

    pub fn stop(self: *Backend) void {
        self.stopping.store(true, .release);
        // postEvent is thread-safe, unlike NSApplication.stop, and wakes a blocked
        // nextEventMatchingMask call without stopping an embedding app's own loop.
        const pool = objc.pool();
        defer objc.release(pool);
        const event = objc.send(objc.Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(usize, 15), objc.Point{ .x = 0, .y = 0 }, @as(usize, 0), @as(f64, 0), @as(isize, 0), @as(objc.Id, null), @as(i16, 0), @as(isize, 0), @as(isize, 0),
        });
        objc.send(void, self.app, "postEvent:atStart:", .{ event, yes });
    }
};

fn mainThread(owner: *Tray) Error!void {
    if (pthread_main_np() != 0) return;
    owner.last_diagnostic = "macos: AppKit requires the main thread for every tray operation except stop";
    return error.Unsupported;
}

fn fail(owner: *Tray, diagnostic: []const u8) Error {
    owner.last_diagnostic = diagnostic;
    return error.PlatformFailure;
}

fn ownerFor(object: objc.Id) ?*Tray {
    var pointer: ?*anyopaque = null;
    _ = objc.object_getInstanceVariable(object, "perchOwner", &pointer);
    return if (pointer) |value| @ptrCast(@alignCast(value)) else null;
}

fn ready(target: objc.Id) void {
    const owner = ownerFor(target) orelse return;
    if (owner.impl.ready) return;
    owner.impl.ready = true;
    if (owner.handler.on_ready) |callback| callback(owner.handler.ctx, owner);
}

fn quitting(target: objc.Id) void {
    const owner = ownerFor(target) orelse return;
    if (owner.impl.quit) return;
    owner.impl.quit = true;
    if (owner.handler.on_quit) |callback| callback(owner.handler.ctx, owner);
}

fn tick(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const pool = objc.pool();
    defer objc.release(pool);
    const target = objc.retain(receiver);
    defer objc.release(target);
    ready(target);
    if (ownerFor(target)) |owner| owner.impl.notifications.pump();
    if (ownerFor(target)) |owner| {
        if (owner.impl.stopping.load(.acquire)) {
            if (owner.impl.tracking) objc.send(void, owner.impl.native_menu, "cancelTracking", .{});
            if (!owner.impl.running) quitting(target);
        }
    }
}

fn terminate(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const target = objc.retain(receiver);
    defer objc.release(target);
    if (ownerFor(target)) |owner| owner.impl.stop();
    quitting(target);
}

// NSStatusBarButton's accessibility/keyboard action remains available even
// though its transparent child view handles pointer events.
fn press(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const target = objc.retain(receiver);
    defer objc.release(target);
    const owner = ownerFor(target) orelse return;
    const policy = owner.options.left_click orelse if (owner.menu != null) tray_mod.LeftClick.show_menu else tray_mod.LeftClick.activate;
    if (policy == .show_menu and owner.menu != null) {
        owner.impl.showMenu() catch {};
    } else {
        owner.dispatchClick(.{ .button = .left });
    }
}

fn activate(receiver: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const target = objc.retain(receiver);
    defer objc.release(target);
    const owner = ownerFor(target) orelse return;
    const tag = objc.send(isize, sender, "tag", .{});
    if (tag <= 0 or tag > std.math.maxInt(MenuItem.Id)) return;
    const id: MenuItem.Id = @intCast(tag);
    const menu = owner.menu orelse return;
    const entry = menu.find(id) orelse return;
    if (!entry.enabled or entry.kind == .separator or entry.kind == .submenu) return;
    owner.dispatchActivate(id);
    if (ownerFor(target)) |live| {
        if (live.menu) |source| syncChecks(live.impl.native_menu, source);
        live.impl.setMenu(live.menu) catch {};
    }
}

fn syncChecks(native: objc.Id, source: *Menu) void {
    const count = objc.send(isize, native, "numberOfItems", .{});
    var index: isize = 0;
    while (index < count) : (index += 1) {
        const item = objc.send(objc.Id, native, "itemAtIndex:", .{index});
        const tag = objc.send(isize, item, "tag", .{});
        if (tag > 0 and tag <= std.math.maxInt(MenuItem.Id)) {
            if (source.find(@intCast(tag))) |entry| {
                objc.send(void, item, "setState:", .{@as(isize, if ((entry.kind == .checkbox or entry.kind == .radio) and entry.checked) 1 else 0)});
            }
        }
        const sub = objc.send(objc.Id, item, "submenu", .{});
        if (sub != null) syncChecks(sub, source);
    }
}

fn mouseDown(receiver: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (ownerFor(receiver)) |owner| objc.send(void, owner.impl.button, "highlight:", .{yes});
}

fn mouseUp(receiver: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const view = objc.retain(receiver);
    defer objc.release(view);
    const owner = ownerFor(view) orelse return;
    objc.send(void, owner.impl.button, "highlight:", .{no});
    const number = objc.send(isize, event, "buttonNumber", .{});
    const button: tray_mod.MouseButton = switch (number) {
        0 => .left,
        1 => .right,
        2 => .middle,
        else => return,
    };
    const opens_menu = button == .right or (button == .left and (owner.options.left_click orelse if (owner.menu != null) tray_mod.LeftClick.show_menu else tray_mod.LeftClick.activate) == .show_menu);
    if (opens_menu and owner.menu != null) {
        owner.impl.showMenu() catch {};
        return;
    }
    const window = objc.send(objc.Id, event, "window", .{});
    const at = if (window != null)
        objc.send(objc.Point, window, "convertPointToScreen:", .{objc.send(objc.Point, event, "locationInWindow", .{})})
    else
        objc.send(objc.Point, objc.class("NSEvent"), "mouseLocation", .{});
    owner.dispatchClick(.{ .button = button, .mods = modifiers(event), .at = .{ .x = coordinate(at.x), .y = coordinate(at.y) } });
}

fn coordinate(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(value, @as(f64, std.math.minInt(i32)), @as(f64, std.math.maxInt(i32))));
}

fn scroll(receiver: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const view = objc.retain(receiver);
    defer objc.release(view);
    const mods = modifiers(event);
    const deltas = [_]f64{ objc.send(f64, event, "scrollingDeltaY", .{}), objc.send(f64, event, "scrollingDeltaX", .{}) };
    for (deltas, 0..) |delta, index| {
        const owner = ownerFor(view) orelse return;
        if (!std.math.isFinite(delta)) continue;
        const remainder = if (index == 0) &owner.impl.scroll_y else &owner.impl.scroll_x;
        remainder.* += delta;
        const whole = coordinate(remainder.*);
        remainder.* -= @floatFromInt(whole);
        if (whole != 0) owner.dispatchScroll(.{ .axis = if (index == 0) .vertical else .horizontal, .delta = whole, .mods = mods });
    }
}

fn modifiers(event: objc.Id) tray_mod.Modifiers {
    const mask = objc.send(usize, event, "modifierFlags", .{});
    return .{ .shift = mask & shift_mask != 0, .ctrl = mask & control_mask != 0, .alt = mask & option_mask != 0, .super = mask & command_mask != 0 };
}

fn acceptsFirstMouse(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.BOOL {
    return yes;
}

fn targetClass(owner: *Tray) Error!objc.Class {
    if (objc.objc_getClass("PerchTrayTarget")) |existing| return existing;
    const class = objc.objc_allocateClassPair(objc.class("NSObject"), "PerchTrayTarget", 0) orelse return fail(owner, "macos: cannot register the tray action target");
    if (!objc.class_addIvar(class, "perchOwner", @sizeOf(?*anyopaque), @intCast(@ctz(@as(usize, @alignOf(?*anyopaque)))), "^v") or
        !objc.addMethod(class, "perchActivate:", &activate, "v@:@") or
        !objc.addMethod(class, "perchPress:", &press, "v@:@") or
        !objc.addMethod(class, "perchTick:", &tick, "v@:@") or
        !objc.addMethod(class, "perchTerminate:", &terminate, "v@:@")) return fail(owner, "macos: cannot install tray target methods");
    objc.objc_registerClassPair(class);
    return class;
}

fn viewClass(owner: *Tray) Error!objc.Class {
    if (objc.objc_getClass("PerchTrayInputView")) |existing| return existing;
    const class = objc.objc_allocateClassPair(objc.class("NSView"), "PerchTrayInputView", 0) orelse return fail(owner, "macos: cannot register the status input view");
    if (!objc.class_addIvar(class, "perchOwner", @sizeOf(?*anyopaque), @intCast(@ctz(@as(usize, @alignOf(?*anyopaque)))), "^v")) return fail(owner, "macos: cannot install the input view owner");
    inline for (.{ "mouseDown:", "rightMouseDown:", "otherMouseDown:" }) |name| {
        if (!objc.addMethod(class, name, &mouseDown, "v@:@")) return fail(owner, "macos: cannot install mouse-down handling");
    }
    inline for (.{ "mouseUp:", "rightMouseUp:", "otherMouseUp:" }) |name| {
        if (!objc.addMethod(class, name, &mouseUp, "v@:@")) return fail(owner, "macos: cannot install mouse-up handling");
    }
    if (!objc.addMethod(class, "scrollWheel:", &scroll, "v@:@") or
        !objc.addMethod(class, "acceptsFirstMouse:", &acceptsFirstMouse, "c@:@")) return fail(owner, "macos: cannot install status input methods");
    objc.objc_registerClassPair(class);
    return class;
}

fn accelerator(owner: *Tray, item: objc.Id, text: []const u8) Error!void {
    if (text.len == 0) return;
    var key = text;
    var prefix: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, text, '+')) |last| {
        if (last == text.len - 1) {
            key = "+";
            if (text.len > 1) {
                if (text[text.len - 2] != '+') return badAccelerator(owner);
                prefix = text[0 .. text.len - 2];
            }
        } else {
            key = text[last + 1 ..];
            prefix = text[0..last];
        }
    }
    var explicit_meta = false;
    var probe = std.mem.splitScalar(u8, prefix, '+');
    while (probe.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, "Meta")) explicit_meta = true;
    }
    var mask: usize = 0;
    var parts = std.mem.splitScalar(u8, prefix, '+');
    while (parts.next()) |part| {
        if (part.len == 0 and prefix.len == 0) break;
        if (std.ascii.eqlIgnoreCase(part, "Ctrl")) {
            mask |= if (explicit_meta) control_mask else command_mask;
        } else if (std.ascii.eqlIgnoreCase(part, "Control")) {
            mask |= control_mask;
        } else if (std.ascii.eqlIgnoreCase(part, "Meta") or std.ascii.eqlIgnoreCase(part, "Cmd") or std.ascii.eqlIgnoreCase(part, "Command") or std.ascii.eqlIgnoreCase(part, "Super")) {
            mask |= command_mask;
        } else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            mask |= shift_mask;
        } else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Option")) {
            mask |= option_mask;
        } else return badAccelerator(owner);
    }
    const named = .{
        .{ "Return", @as(u21, 0x0d) },    .{ "Enter", @as(u21, 0x0d) },
        .{ "Tab", @as(u21, 0x09) },       .{ "Escape", @as(u21, 0x1b) },
        .{ "Esc", @as(u21, 0x1b) },       .{ "Space", @as(u21, 0x20) },
        .{ "Backspace", @as(u21, 0x08) }, .{ "Delete", @as(u21, 0xf728) },
        .{ "Up", @as(u21, 0xf700) },      .{ "Down", @as(u21, 0xf701) },
        .{ "Left", @as(u21, 0xf702) },    .{ "Right", @as(u21, 0xf703) },
        .{ "Home", @as(u21, 0xf729) },    .{ "End", @as(u21, 0xf72b) },
        .{ "PageUp", @as(u21, 0xf72c) },  .{ "PageDown", @as(u21, 0xf72d) },
        .{ "Insert", @as(u21, 0xf727) },  .{ "Help", @as(u21, 0xf746) },
    };
    var codepoint: ?u21 = null;
    inline for (named) |pair| {
        if (std.ascii.eqlIgnoreCase(key, pair[0])) codepoint = pair[1];
    }
    if (key.len > 1 and (key[0] == 'F' or key[0] == 'f')) {
        const number = std.fmt.parseInt(u8, key[1..], 10) catch return badAccelerator(owner);
        if (number < 1 or number > 35) return badAccelerator(owner);
        codepoint = 0xf704 + @as(u21, number) - 1;
    }
    var buffer: [4]u8 = undefined;
    if (codepoint) |value| {
        const length = std.unicode.utf8Encode(value, &buffer) catch return badAccelerator(owner);
        key = buffer[0..length];
    } else if ((std.unicode.utf8CountCodepoints(key) catch return badAccelerator(owner)) != 1) return badAccelerator(owner);
    const equivalent = objc.send(objc.Id, objc.string(key), "lowercaseString", .{});
    objc.send(void, item, "setKeyEquivalent:", .{equivalent});
    objc.send(void, item, "setKeyEquivalentModifierMask:", .{mask});
}

fn badAccelerator(owner: *Tray) Error {
    owner.last_diagnostic = "macos: accelerator must be modifiers joined by '+' and one character, F1–F35, or a named navigation key";
    return error.Unsupported;
}

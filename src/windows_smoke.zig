//! Native smoke tests. Run `zig build windows-smoke` in an Explorer session.
//! Shell calls exercise the real notification area; input callbacks are injected
//! through Win32 messages so these tests need no mouse or keyboard interaction.
const std = @import("std");
const perch = @import("root.zig");
const win32 = @import("windows/win32.zig");

const State = struct {
    ready: usize = 0,
    quit: usize = 0,
    clicks: usize = 0,
    last_click: ?perch.ClickEvent = null,
    actions: usize = 0,
    closed: usize = 0,
    last_tag: ?perch.Notification.Tag = null,
    last_reason: ?perch.Notification.CloseReason = null,

    fn get(ctx: ?*anyopaque) *State {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn onReady(ctx: ?*anyopaque, _: *perch.Tray) void {
        get(ctx).ready += 1;
    }
    fn onQuit(ctx: ?*anyopaque, _: *perch.Tray) void {
        get(ctx).quit += 1;
    }
    fn onClick(ctx: ?*anyopaque, _: *perch.Tray, event: perch.ClickEvent) void {
        const self = get(ctx);
        self.clicks += 1;
        self.last_click = event;
    }
    fn onAction(ctx: ?*anyopaque, _: *perch.Tray, tag: perch.Notification.Tag, action: []const u8) void {
        const self = get(ctx);
        if (std.mem.eql(u8, action, "default")) self.actions += 1;
        self.last_tag = tag;
    }
    fn onClosed(ctx: ?*anyopaque, _: *perch.Tray, tag: perch.Notification.Tag, reason: perch.Notification.CloseReason) void {
        const self = get(ctx);
        self.closed += 1;
        self.last_tag = tag;
        self.last_reason = reason;
    }
    fn handler(self: *State) perch.Handler {
        return .{
            .ctx = self,
            .on_ready = onReady,
            .on_quit = onQuit,
            .on_click = onClick,
            .on_notification_action = onAction,
            .on_notification_closed = onClosed,
        };
    }
};

fn pixels(comptime size: usize, comptime color: [4]u8) [size * size * 4]u8 {
    @setEvalBranchQuota(size * size + 1000);
    var result: [size * size * 4]u8 = undefined;
    for (0..size * size) |i| result[i * 4 ..][0..4].* = color;
    return result;
}
const red = pixels(16, .{ 255, 0, 0, 255 });
const blue = pixels(32, .{ 0, 0, 255, 255 });
const red_icon: perch.Icon = .{ .raw = .{ .width = 16, .height = 16, .pixels = &red, .format = .rgba32 } };
const blue_icon: perch.Icon = .{ .raw = .{ .width = 32, .height = 32, .pixels = &blue, .format = .rgba32 } };

fn create(state: *State) !*perch.Tray {
    return perch.Tray.create(std.testing.allocator, .{
        .io = std.testing.io,
        .app_id = "dev.perch.windows.smoke",
        .icon = red_icon,
        .tooltip = "Windows smoke test 中😀",
        .handler = state.handler(),
    });
}

fn iconEvent(tray: *perch.Tray, event: win32.UINT) void {
    // Signed screen coordinates (-12, -34), version 4 icon id in lParam's high word.
    const coordinates = @as(u32, @as(u16, @bitCast(@as(i16, -12)))) |
        (@as(u32, @as(u16, @bitCast(@as(i16, -34)))) << 16);
    _ = win32.SendMessageW(tray.impl.window, win32.WM_PERCH_ICON, coordinates, @intCast(event | (tray.impl.icon_id << 16)));
}

test "native tray creation, updates, shell registration and recovery" {
    var state: State = .{};
    const tray = try create(&state);
    defer tray.destroy();
    try std.testing.expect(win32.GetParent(tray.impl.window) == null);
    try std.testing.expect(!win32.IsWindowVisible(tray.impl.window).toBool());
    try std.testing.expect(tray.impl.icon != null);
    try std.testing.expectEqual(@as(usize, 1), tray.impl.icon_frames.len);

    const long_tooltip: [250]u8 = @splat('x');
    try tray.setTooltip(&long_tooltip);
    try tray.setTooltip(null);
    try tray.setTitle("Updated title 中😀");
    try tray.setIcon(blue_icon);
    try tray.setAttentionIcon(red_icon);
    try tray.setStatus(.needs_attention);
    try tray.setStatus(.passive);
    try tray.setStatus(.active);

    // Remove just this test icon, then send the same registered message Explorer
    // broadcasts. A subsequent update fails unless the backend re-adds the icon.
    var data: win32.NOTIFYICONDATAW = std.mem.zeroes(win32.NOTIFYICONDATAW);
    data.cbSize = @sizeOf(win32.NOTIFYICONDATAW);
    data.hWnd = tray.impl.window;
    data.uID = tray.impl.icon_id;
    try std.testing.expect(win32.Shell_NotifyIconW(win32.NIM_DELETE, &data).toBool());
    try std.testing.expectError(error.PlatformFailure, tray.setTooltip("removed"));
    _ = win32.SendMessageW(tray.impl.window, tray.impl.taskbar_created, 0, 0);
    try tray.setTooltip("recovered");
    try tray.pump();
}

test "version 4 click coordinates and notification callbacks" {
    var state: State = .{};
    const tray = try create(&state);
    defer tray.destroy();
    iconEvent(tray, win32.NIN_SELECT);
    try std.testing.expectEqual(@as(usize, 1), state.clicks);
    try std.testing.expectEqual(perch.MouseButton.left, state.last_click.?.button);
    try std.testing.expectEqual(perch.Point{ .x = -12, .y = -34 }, state.last_click.?.at.?);
    iconEvent(tray, win32.WM_MBUTTONUP);
    try std.testing.expectEqual(perch.MouseButton.middle, state.last_click.?.button);
    iconEvent(tray, win32.WM_CONTEXTMENU);
    try std.testing.expectEqual(perch.MouseButton.right, state.last_click.?.button);
    iconEvent(tray, win32.NIN_KEYSELECT);
    try std.testing.expectEqual(perch.MouseButton.left, state.last_click.?.button);

    try tray.notify(.{ .title = "Perch smoke", .body = "Native shell notification", .tag = 7, .suppress_sound = true });
    try tray.closeNotification(999);
    try std.testing.expectEqual(@as(?perch.Notification.Tag, 7), tray.impl.balloon_tag);
    try tray.closeNotification(7);
    try std.testing.expectEqual(@as(usize, 1), state.closed);
    try std.testing.expectEqual(perch.Notification.CloseReason.closed, state.last_reason.?);
    // Callback routing is deterministic even if the OS suppresses the banner.
    tray.impl.balloon_tag = 8;
    iconEvent(tray, win32.NIN_BALLOONUSERCLICK);
    try std.testing.expectEqual(@as(usize, 1), state.actions);
    try std.testing.expectEqual(@as(?perch.Notification.Tag, 8), state.last_tag);
    try std.testing.expectEqual(perch.Notification.CloseReason.dismissed, state.last_reason.?);
    tray.impl.balloon_tag = 9;
    iconEvent(tray, win32.NIN_BALLOONTIMEOUT);
    try std.testing.expectEqual(perch.Notification.CloseReason.expired, state.last_reason.?);
    tray.impl.balloon_tag = 10;
    iconEvent(tray, win32.NIN_BALLOONHIDE);
    try std.testing.expectEqual(perch.Notification.CloseReason.closed, state.last_reason.?);
}

fn stopLater(tray: *perch.Tray) void {
    std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    tray.stop();
}

test "off-thread stop and multiple trays do not leave WM_QUIT behind" {
    var first_state: State = .{};
    var second_state: State = .{};
    const first = try create(&first_state);
    defer first.destroy();
    const second = try create(&second_state);
    defer second.destroy();
    const worker = try std.Thread.spawn(.{}, stopLater, .{first});
    defer worker.join();
    try first.run();
    try std.testing.expect(first.impl.stopping);
    try std.testing.expectEqual(@as(usize, 1), first_state.ready);
    try std.testing.expectEqual(@as(usize, 1), first_state.quit);
    try second.pump();
    try std.testing.expect(!second.impl.stopping);
    iconEvent(second, win32.NIN_SELECT);
    try std.testing.expectEqual(@as(usize, 1), second_state.clicks);
    second.stop();
    try second.pump();
    try std.testing.expect(second.impl.stopping);
    var message: win32.MSG = undefined;
    try std.testing.expect(!win32.PeekMessageW(&message, null, win32.WM_QUIT, win32.WM_QUIT, win32.PM_REMOVE).toBool());
}

test "initial passive tray can be activated and destroyed repeatedly" {
    for (0..3) |_| {
        const tray = try perch.Tray.create(std.testing.allocator, .{
            .io = std.testing.io,
            .app_id = "dev.perch.windows.passive",
            .status = .passive,
            .icon = red_icon,
        });
        defer tray.destroy();
        try tray.setStatus(.active);
        try tray.setStatus(.passive);
    }
}

fn allocationFailureScenario(gpa: std.mem.Allocator) !void {
    const tray = try perch.Tray.create(gpa, .{
        .io = std.testing.io,
        .app_id = "dev.perch.windows.allocations",
        .icon = red_icon,
        .attention_icon = blue_icon,
        .status = .passive,
    });
    defer tray.destroy();
    // Replacing both decoded slots must also leave a destructible backend when
    // allocation of the attention slot fails after the main slot succeeded.
    try tray.setIcon(blue_icon);
}

test "native tray creation and icon replacement clean up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{});
}

test "native PNG icons can be loaded from a Unicode file path" {
    const gpa = std.testing.allocator;
    const png = try perch.image.png.testImage(gpa, 16, 16, &red);
    defer gpa.free(png);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "图标😀.png", .data = png });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "图标😀.png", gpa);
    defer gpa.free(path);
    const tray = try perch.Tray.create(gpa, .{
        .io = std.testing.io,
        .app_id = "dev.perch.windows.path",
        .icon = .{ .path = path },
        .status = .passive,
    });
    defer tray.destroy();
    try std.testing.expectEqual(@as(usize, 1), tray.impl.icon_frames.len);
    try std.testing.expectEqual(@as(u32, 16), tray.impl.icon_frames[0].width);
    try std.testing.expect(tray.impl.icon != null);
}

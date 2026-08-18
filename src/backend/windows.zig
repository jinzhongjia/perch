//! Windows backend: a hidden message-only window owning a `NOTIFYICONDATAW`
//! entry in the shell notification area, with an `HMENU` popup.
//!
//! The shell talks to a tray icon through a window message, so everything hangs
//! off one message-only window: mouse events, balloon notifications and the
//! `TaskbarCreated` broadcast that says Explorer restarted and the icon has to be
//! added again.

const std = @import("std");
const windows = std.os.windows;

const win32 = @import("../windows/win32.zig");
const win_icon = @import("../windows/icon.zig");

const image = @import("../image.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const Menu = @import("../menu.zig").Menu;
const MenuItem = @import("../menu.zig").MenuItem;
const Notification = @import("../notification.zig").Notification;
const tray_mod = @import("../tray.zig");
const Error = tray_mod.Error;
const Tray = tray_mod.Tray;

const log = std.log.scoped(.perch);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("PerchTrayWindow");

pub const Backend = struct {
    pub const supported = true;

    owner: *Tray,
    gpa: std.mem.Allocator,

    window: win32.HWND,
    /// Identifies our icon within the window; one tray, one id.
    icon_id: win32.UINT = 1,
    /// Broadcast when Explorer restarts and every icon has to be re-added.
    taskbar_created: win32.UINT,

    /// The current icons, owned. Rebuilt whenever the source or the DPI changes.
    icon: ?win32.HICON = null,
    attention_icon: ?win32.HICON = null,
    /// Decoded frames, kept so the icon can be rebuilt at a new size without
    /// decoding again.
    icon_frames: []image.Image = &.{},
    attention_frames: []image.Image = &.{},
    /// The size the icons were built for, so a DPI change can be noticed.
    built_for: u32 = 0,

    /// The balloon currently on screen. Windows shows one at a time, so a single
    /// tag is enough to route its callbacks back to the caller.
    balloon_tag: ?Notification.Tag = null,

    stopping: bool = false,

    pub fn init(owner: *Tray) Error!Backend {
        const gpa = owner.gpa;

        const instance: ?win32.HINSTANCE = win32.GetModuleHandleW(null);

        const class: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        // A second tray in the same process finds the class already registered,
        // which is not an error.
        _ = win32.RegisterClassExW(&class);

        const window = win32.CreateWindowExW(
            0,
            class_name,
            null,
            win32.WS_OVERLAPPED,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            0,
            0,
            win32.HWND_MESSAGE,
            null,
            instance,
            null,
        ) orelse {
            owner.last_diagnostic = "cannot create the message window";
            return error.PlatformFailure;
        };
        errdefer _ = win32.DestroyWindow(window);

        var self: Backend = .{
            .owner = owner,
            .gpa = gpa,
            .window = window,
            .taskbar_created = win32.RegisterWindowMessageW(
                std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"),
            ),
        };

        // The window procedure reaches the backend through the owning tray.
        _ = win32.SetWindowLongPtrW(window, GWLP_USERDATA, @bitCast(@intFromPtr(owner)));

        try self.loadIcons();
        try self.addIcon();
        return self;
    }

    /// Offset of the user data slot, where the owning tray is stashed.
    const GWLP_USERDATA: i32 = -21;

    pub fn deinit(self: *Backend) void {
        var data = self.iconData(win32.NIF_MESSAGE);
        _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &data);

        if (self.icon) |handle| _ = win32.DestroyIcon(handle);
        if (self.attention_icon) |handle| _ = win32.DestroyIcon(handle);
        image.freeAll(self.gpa, self.icon_frames);
        image.freeAll(self.gpa, self.attention_frames);

        _ = win32.DestroyWindow(self.window);
        self.* = undefined;
    }

    // -- perch API ----------------------------------------------------------

    pub fn setIcon(self: *Backend, icon: Icon) Error!void {
        _ = icon;
        try self.loadIcons();
        return self.refreshIcon();
    }

    pub fn setAttentionIcon(self: *Backend, icon: ?Icon) Error!void {
        _ = icon;
        try self.loadIcons();
        return self.refreshIcon();
    }

    /// Windows has no overlay for notification-area icons; the closest thing is
    /// a taskbar button overlay, which a message-only window does not have.
    pub fn setOverlayIcon(self: *Backend, icon: ?Icon) Error!void {
        _ = self;
        _ = icon;
        return;
    }

    pub fn setStatus(self: *Backend, status: tray_mod.Status) Error!void {
        _ = status;
        // Status drives both which icon is shown and whether it is hidden.
        try self.refreshIcon();

        var data = self.iconData(win32.NIF_STATE);
        data.dwStateMask = win32.NIS_HIDDEN;
        data.dwState = if (self.owner.options.status == .passive) win32.NIS_HIDDEN else 0;
        if (!win32.Shell_NotifyIconW(win32.NIM_MODIFY, &data).toBool()) {
            return error.PlatformFailure;
        }
    }

    pub fn setTooltip(self: *Backend, tooltip: ?[]const u8) Error!void {
        _ = tooltip;
        var data = self.iconData(win32.NIF_TIP | win32.NIF_SHOWTIP);
        win32.copyWide(&data.szTip, self.tooltipText());
        if (!win32.Shell_NotifyIconW(win32.NIM_MODIFY, &data).toBool()) {
            return error.PlatformFailure;
        }
    }

    /// The notification area shows a tooltip, not a title, so this folds into
    /// the same field.
    pub fn setTitle(self: *Backend, title: []const u8) Error!void {
        _ = title;
        return self.setTooltip(null);
    }

    /// The menu is rebuilt from `owner.menu` each time it pops up, so there is
    /// nothing to push here.
    pub fn setMenu(self: *Backend, menu: ?*Menu) Error!void {
        _ = self;
        _ = menu;
        return;
    }

    pub fn notify(self: *Backend, notification: Notification) Error!void {
        var data = self.iconData(win32.NIF_INFO);
        win32.copyWide(&data.szInfoTitle, notification.title);
        win32.copyWide(&data.szInfo, notification.body);
        data.dwInfoFlags = switch (notification.urgency) {
            .low => win32.NIIF_NONE,
            .normal => win32.NIIF_INFO,
            .critical => win32.NIIF_WARNING,
        };
        if (notification.suppress_sound) data.dwInfoFlags |= win32.NIIF_NOSOUND;
        if (notification.urgency != .critical) {
            data.dwInfoFlags |= win32.NIIF_RESPECT_QUIET_TIME;
        }

        // Balloons have no buttons. Saying so once beats dropping them silently.
        if (notification.actions.len > 0) {
            log.warn("perch: notification actions are not supported by shell balloons", .{});
        }

        self.balloon_tag = notification.tag;
        if (!win32.Shell_NotifyIconW(win32.NIM_MODIFY, &data).toBool()) {
            return error.PlatformFailure;
        }
    }

    pub fn closeNotification(self: *Backend, tag: Notification.Tag) Error!void {
        const current = self.balloon_tag orelse return;
        if (current != tag) return;

        // An empty balloon body withdraws whatever is on screen.
        var data = self.iconData(win32.NIF_INFO);
        @memset(&data.szInfo, 0);
        @memset(&data.szInfoTitle, 0);
        _ = win32.Shell_NotifyIconW(win32.NIM_MODIFY, &data);

        self.balloon_tag = null;
        self.owner.dispatchNotificationClosed(tag, .closed);
    }

    pub fn showMenu(self: *Backend) Error!void {
        self.popupMenu();
        return;
    }

    pub fn run(self: *Backend) Error!void {
        if (self.owner.handler.on_ready) |cb| cb(self.owner.handler.ctx, self.owner);

        var message: win32.MSG = undefined;
        while (!self.stopping) {
            const result = win32.GetMessageW(&message, null, 0, 0);
            // GetMessage returns -1 on error and 0 on WM_QUIT.
            if (@intFromEnum(result) <= 0) break;
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }

        if (self.owner.handler.on_quit) |cb| cb(self.owner.handler.ctx, self.owner);
    }

    pub fn pump(self: *Backend) Error!void {
        var message: win32.MSG = undefined;
        while (!self.stopping and
            win32.PeekMessageW(&message, null, 0, 0, win32.PM_REMOVE).toBool())
        {
            if (message.message == win32.WM_QUIT) {
                self.stopping = true;
                break;
            }
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }
    }

    /// Safe from any thread: `PostMessageW` is the documented way in.
    pub fn stop(self: *Backend) void {
        _ = win32.PostMessageW(self.window, win32.WM_PERCH_STOP, 0, 0);
    }

    // -- the notification area ----------------------------------------------

    fn iconData(self: *Backend, flags: win32.UINT) win32.NOTIFYICONDATAW {
        return .{
            .cbSize = @sizeOf(win32.NOTIFYICONDATAW),
            .hWnd = self.window,
            .uID = self.icon_id,
            .uFlags = flags,
            .uCallbackMessage = win32.WM_PERCH_ICON,
            .hIcon = self.currentIcon(),
            .szTip = @splat(0),
            .dwState = 0,
            .dwStateMask = 0,
            .szInfo = @splat(0),
            // Zero, not the version: outside NIM_SETVERSION this field is the
            // balloon timeout, and 4 would mean four milliseconds.
            .uVersion = 0,
            .szInfoTitle = @splat(0),
            .dwInfoFlags = 0,
            .guidItem = std.mem.zeroes(windows.GUID),
            .hBalloonIcon = null,
        };
    }

    fn tooltipText(self: *const Backend) []const u8 {
        const options = self.owner.options;
        return options.tooltip orelse if (options.title.len > 0) options.title else options.app_id;
    }

    fn currentIcon(self: *const Backend) ?win32.HICON {
        if (self.owner.options.status == .needs_attention) {
            if (self.attention_icon) |handle| return handle;
        }
        return self.icon;
    }

    fn addIcon(self: *Backend) Error!void {
        var data = self.iconData(
            win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP | win32.NIF_SHOWTIP,
        );
        win32.copyWide(&data.szTip, self.tooltipText());

        if (!win32.Shell_NotifyIconW(win32.NIM_ADD, &data).toBool()) {
            self.owner.last_diagnostic = "the shell refused to add the tray icon";
            return error.PlatformFailure;
        }

        // Version 4 is what makes the shell report the pointer position and use
        // the modern callback packing.
        var version = self.iconData(0);
        version.uVersion = win32.NOTIFYICON_VERSION_4;
        _ = win32.Shell_NotifyIconW(win32.NIM_SETVERSION, &version);
    }

    fn refreshIcon(self: *Backend) Error!void {
        var data = self.iconData(win32.NIF_ICON);
        if (!win32.Shell_NotifyIconW(win32.NIM_MODIFY, &data).toBool()) {
            return error.PlatformFailure;
        }
    }

    /// Decodes both icon slots and builds handles at the current DPI size.
    fn loadIcons(self: *Backend) Error!void {
        const options = self.owner.options;
        const wanted = win32.smallIconSize();

        image.freeAll(self.gpa, self.icon_frames);
        self.icon_frames = &.{};
        image.freeAll(self.gpa, self.attention_frames);
        self.attention_frames = &.{};

        self.icon_frames = try self.decode(options.icon);
        self.attention_frames = try self.decode(options.attention_icon);
        self.built_for = wanted;

        if (self.icon) |handle| _ = win32.DestroyIcon(handle);
        if (self.attention_icon) |handle| _ = win32.DestroyIcon(handle);
        self.icon = build(self.icon_frames, options.icon, wanted);
        self.attention_icon = build(self.attention_frames, options.attention_icon, wanted);
    }

    fn decode(self: *Backend, icon: ?Icon) Error![]image.Image {
        const source = icon orelse return &.{};
        return icon_mod.decodeAll(self.gpa, source) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => blk: {
                log.warn("perch: cannot decode a tray icon: {t}", .{err});
                break :blk &.{};
            },
        };
    }

    /// Falls back to the shell's stock icon rather than showing nothing, since a
    /// missing icon leaves an invisible but clickable gap in the tray.
    fn build(frames: []const image.Image, icon: ?Icon, wanted: u32) ?win32.HICON {
        if (win_icon.pickBest(frames, wanted)) |frame| {
            if (win_icon.create(frame)) |handle| return handle;
            log.warn("perch: cannot build an icon from the decoded pixels", .{});
        }
        if (icon) |source| {
            if (source.themedName()) |name| {
                // A themed name on Windows means a resource in this executable.
                var buffer: [256]u16 = undefined;
                win32.copyWide(&buffer, name);
                const instance: ?win32.HINSTANCE = win32.GetModuleHandleW(null);
                if (win32.LoadIconW(instance, @ptrCast(&buffer))) |handle| return handle;
            }
        }
        return win32.LoadIconW(null, win32.IDI_APPLICATION);
    }

    // -- menus ---------------------------------------------------------------

    fn popupMenu(self: *Backend) void {
        const menu = self.owner.menu orelse return;

        const handle = self.buildMenu(menu) orelse return;
        defer _ = win32.DestroyMenu(handle);

        var point: win32.POINT = undefined;
        _ = win32.GetCursorPos(&point);

        // Without this the menu refuses to close when the user clicks away.
        _ = win32.SetForegroundWindow(self.window);

        const chosen = win32.TrackPopupMenuEx(
            handle,
            win32.TPM_RETURNCMD | win32.TPM_NONOTIFY | win32.TPM_RIGHTBUTTON | win32.TPM_BOTTOMALIGN,
            point.x,
            point.y,
            self.window,
            null,
        );

        // The other half of the same workaround.
        _ = win32.PostMessageW(self.window, win32.WM_NULL, 0, 0);

        if (chosen > 0) self.owner.dispatchActivate(@intCast(chosen));
    }

    fn buildMenu(self: *Backend, menu: *Menu) ?win32.HMENU {
        const handle = win32.CreatePopupMenu() orelse return null;

        for (menu.items.items, 0..) |*item, index| {
            self.appendItem(handle, item, @intCast(index)) catch {
                _ = win32.DestroyMenu(handle);
                return null;
            };
        }
        return handle;
    }

    fn appendItem(
        self: *Backend,
        handle: win32.HMENU,
        item: *const MenuItem,
        position: win32.UINT,
    ) !void {
        var info: win32.MENUITEMINFOW = std.mem.zeroes(win32.MENUITEMINFOW);
        info.cbSize = @sizeOf(win32.MENUITEMINFOW);

        if (item.kind == .separator) {
            info.fMask = win32.MIIM_FTYPE;
            info.fType = win32.MFT_SEPARATOR;
            _ = win32.InsertMenuItemW(handle, position, win32.BOOL.TRUE, &info);
            return;
        }

        // The label carries the accelerator after a tab, which is how Windows
        // right-aligns it.
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(self.gpa);
        try label.appendSlice(self.gpa, item.label);
        if (item.accelerator) |accelerator| {
            try label.append(self.gpa, '\t');
            try label.appendSlice(self.gpa, accelerator);
        }

        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.gpa, label.items);
        defer self.gpa.free(wide);

        info.fMask = win32.MIIM_STRING | win32.MIIM_ID | win32.MIIM_STATE | win32.MIIM_FTYPE;
        info.fType = win32.MFT_STRING;
        info.wID = item.id;
        info.dwTypeData = wide.ptr;
        info.fState = if (item.enabled) win32.MFS_ENABLED else win32.MFS_GRAYED;

        switch (item.kind) {
            .checkbox => if (item.checked) {
                info.fState |= win32.MFS_CHECKED;
            },
            .radio => {
                info.fType |= win32.MFT_RADIOCHECK;
                if (item.checked) info.fState |= win32.MFS_CHECKED;
            },
            .submenu => if (item.submenu) |sub| {
                if (self.buildMenu(sub)) |child| {
                    info.fMask |= win32.MIIM_SUBMENU;
                    info.hSubMenu = child;
                }
            },
            else => {},
        }

        _ = win32.InsertMenuItemW(handle, position, win32.BOOL.TRUE, &info);
    }

    // -- messages -------------------------------------------------------------

    fn handleIconMessage(self: *Backend, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        // Version 4 packs the event in the low word of lParam and the pointer
        // position in wParam.
        const event: win32.UINT = @intCast(@as(usize, @bitCast(lparam)) & 0xffff);
        const raw: usize = wparam;
        const at: tray_mod.Point = .{
            .x = @as(i16, @bitCast(@as(u16, @truncate(raw)))),
            .y = @as(i16, @bitCast(@as(u16, @truncate(raw >> 16)))),
        };

        switch (event) {
            win32.NIN_SELECT, win32.NIN_KEYSELECT, win32.WM_LBUTTONUP => {
                if (self.owner.options.leftClick() == .show_menu and self.owner.menu != null) {
                    self.popupMenu();
                } else {
                    self.owner.dispatchClick(.{ .button = .left, .at = at });
                }
            },
            win32.WM_MBUTTONUP => self.owner.dispatchClick(.{ .button = .middle, .at = at }),
            win32.WM_RBUTTONUP, win32.WM_CONTEXTMENU => {
                self.owner.dispatchClick(.{ .button = .right, .at = at });
                if (self.owner.menu != null) self.popupMenu();
            },
            win32.NIN_BALLOONUSERCLICK => {
                if (self.balloon_tag) |tag| {
                    // A balloon has no buttons, so a click is the default action.
                    self.owner.dispatchNotificationAction(tag, "default");
                    self.balloon_tag = null;
                    self.owner.dispatchNotificationClosed(tag, .dismissed);
                }
            },
            win32.NIN_BALLOONTIMEOUT => {
                if (self.balloon_tag) |tag| {
                    self.balloon_tag = null;
                    self.owner.dispatchNotificationClosed(tag, .expired);
                }
            },
            win32.NIN_BALLOONHIDE => {
                if (self.balloon_tag) |tag| {
                    self.balloon_tag = null;
                    self.owner.dispatchNotificationClosed(tag, .closed);
                }
            },
            else => {},
        }
    }

    /// Explorer restarted: every icon is gone and has to be added again. The DPI
    /// may have changed with it, so the handles are rebuilt too.
    fn handleTaskbarCreated(self: *Backend) void {
        if (win32.smallIconSize() != self.built_for) {
            self.loadIcons() catch {};
        }
        self.addIcon() catch |err| {
            log.warn("perch: cannot re-add the tray icon after a shell restart: {t}", .{err});
        };
    }
};

/// Routes messages to the backend through the owning tray, which is stashed in
/// the window's user data.
fn windowProc(
    window: win32.HWND,
    message: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    const raw = win32.GetWindowLongPtrW(window, Backend.GWLP_USERDATA);
    if (raw == 0) return win32.DefWindowProcW(window, message, wparam, lparam);

    const tray: *Tray = @ptrFromInt(@as(usize, @bitCast(raw)));
    const self = &tray.impl;

    switch (message) {
        win32.WM_PERCH_ICON => {
            self.handleIconMessage(wparam, lparam);
            return 0;
        },
        win32.WM_PERCH_STOP => {
            self.stopping = true;
            // Ends the GetMessage loop even while it is blocked.
            _ = win32.PostMessageW(window, win32.WM_QUIT, 0, 0);
            return 0;
        },
        win32.WM_DESTROY, win32.WM_CLOSE => {
            self.stopping = true;
            return 0;
        },
        else => {
            if (message == self.taskbar_created) {
                self.handleTaskbarCreated();
                return 0;
            }
            return win32.DefWindowProcW(window, message, wparam, lparam);
        },
    }
}

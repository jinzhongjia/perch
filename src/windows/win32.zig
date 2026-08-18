//! The Win32 surface perch needs, declared by hand.
//!
//! `std.os.windows` carries the base types but almost none of user32, gdi32 or
//! shell32, so the structs, constants and entry points live here. Everything is
//! the wide (`W`) variant: perch strings are UTF-8 and get converted once, at the
//! boundary.

const std = @import("std");
const windows = std.os.windows;

pub const ATOM = windows.ATOM;
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HDC = windows.HDC;
pub const HICON = windows.HICON;
pub const HINSTANCE = windows.HINSTANCE;
pub const HMENU = windows.HMENU;
pub const HWND = windows.HWND;
pub const UINT = windows.UINT;
pub const WORD = windows.WORD;

pub const HBITMAP = *opaque {};
pub const HBRUSH = *opaque {};
pub const HCURSOR = *opaque {};
pub const LRESULT = isize;
pub const LPARAM = isize;
pub const WPARAM = usize;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

/// `szTip` is 128 wide characters and `szInfo` 256, both nul-terminated, so the
/// text has to be truncated rather than allocated.
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: ?HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    /// A union of uTimeout and uVersion in the SDK. It only means "version"
    /// during NIM_SETVERSION; every other call reads it as a balloon timeout,
    /// so it has to stay zero there.
    uVersion: UINT,
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: windows.GUID,
    hBalloonIcon: ?HICON,
};

pub const MENUITEMINFOW = extern struct {
    cbSize: UINT,
    fMask: UINT,
    fType: UINT,
    fState: UINT,
    wID: UINT,
    hSubMenu: ?HMENU,
    hbmpChecked: ?HBITMAP,
    hbmpUnchecked: ?HBITMAP,
    dwItemData: usize,
    dwTypeData: ?[*:0]u16,
    cch: UINT,
    hbmpItem: ?HBITMAP,
};

pub const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: ?HBITMAP,
    hbmColor: ?HBITMAP,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: i32,
    biHeight: i32,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32,
};

pub const TPMPARAMS = extern struct {
    cbSize: UINT,
    rcExclude: RECT,
};

// -- constants --------------------------------------------------------------

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
/// Parent for a message-only window: no pixels, no taskbar button, still pumps.
pub const HWND_MESSAGE: HWND = @ptrFromInt(std.math.maxInt(usize) - 2); // (HWND)-3

pub const WS_OVERLAPPED: DWORD = 0;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_NULL: UINT = 0x0000;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_CONTEXTMENU: UINT = 0x007B;
pub const WM_APP: UINT = 0x8000;

/// Our own messages, on top of WM_APP.
pub const WM_PERCH_ICON: UINT = WM_APP + 1;
pub const WM_PERCH_STOP: UINT = WM_APP + 2;

pub const PM_REMOVE: UINT = 0x0001;

pub const NIM_ADD: DWORD = 0x00000000;
pub const NIM_MODIFY: DWORD = 0x00000001;
pub const NIM_DELETE: DWORD = 0x00000002;
pub const NIM_SETFOCUS: DWORD = 0x00000003;
pub const NIM_SETVERSION: DWORD = 0x00000004;

pub const NIF_MESSAGE: UINT = 0x00000001;
pub const NIF_ICON: UINT = 0x00000002;
pub const NIF_TIP: UINT = 0x00000004;
pub const NIF_STATE: UINT = 0x00000008;
pub const NIF_INFO: UINT = 0x00000010;
pub const NIF_SHOWTIP: UINT = 0x00000080;

pub const NIS_HIDDEN: DWORD = 0x00000001;

pub const NOTIFYICON_VERSION_4: UINT = 4;

pub const NIIF_NONE: DWORD = 0x00000000;
pub const NIIF_INFO: DWORD = 0x00000001;
pub const NIIF_WARNING: DWORD = 0x00000002;
pub const NIIF_ERROR: DWORD = 0x00000003;
pub const NIIF_USER: DWORD = 0x00000004;
pub const NIIF_NOSOUND: DWORD = 0x00000010;
pub const NIIF_RESPECT_QUIET_TIME: DWORD = 0x00000080;

/// Notification-area callbacks, sent as the low word of lParam under version 4.
pub const NIN_SELECT: UINT = WM_APP + 0;
pub const NINF_KEY: UINT = 0x1;
pub const NIN_KEYSELECT: UINT = NIN_SELECT | NINF_KEY;
pub const NIN_BALLOONSHOW: UINT = WM_APP + 2;
pub const NIN_BALLOONHIDE: UINT = WM_APP + 3;
pub const NIN_BALLOONTIMEOUT: UINT = WM_APP + 4;
pub const NIN_BALLOONUSERCLICK: UINT = WM_APP + 5;
pub const NIN_POPUPOPEN: UINT = WM_APP + 6;
pub const NIN_POPUPCLOSE: UINT = WM_APP + 7;

pub const MF_BYPOSITION: UINT = 0x00000400;

pub const MIIM_STATE: UINT = 0x00000001;
pub const MIIM_ID: UINT = 0x00000002;
pub const MIIM_SUBMENU: UINT = 0x00000004;
pub const MIIM_STRING: UINT = 0x00000040;
pub const MIIM_FTYPE: UINT = 0x00000100;

pub const MFT_STRING: UINT = 0x00000000;
pub const MFT_SEPARATOR: UINT = 0x00000800;
pub const MFT_RADIOCHECK: UINT = 0x00000200;

pub const MFS_ENABLED: UINT = 0x00000000;
pub const MFS_GRAYED: UINT = 0x00000003;
pub const MFS_CHECKED: UINT = 0x00000008;

pub const TPM_LEFTALIGN: UINT = 0x0000;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const TPM_RETURNCMD: UINT = 0x0100;
pub const TPM_NONOTIFY: UINT = 0x0080;
pub const TPM_BOTTOMALIGN: UINT = 0x0020;

pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: UINT = 0;

pub const SM_CXSMICON: i32 = 49;
pub const SM_CYSMICON: i32 = 50;

pub const IDI_APPLICATION: [*:0]const u16 = @ptrFromInt(32512);
pub const IDC_ARROW: [*:0]const u16 = @ptrFromInt(32512);

pub const IMAGE_ICON: UINT = 1;
pub const LR_DEFAULTSIZE: UINT = 0x00000040;
pub const LR_SHARED: UINT = 0x00008000;

// -- entry points -----------------------------------------------------------

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW([*:0]const u16, ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterWindowMessageW([*:0]const u16) callconv(.winapi) UINT;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
pub extern "user32" fn LoadIconW(?HINSTANCE, [*:0]const u16) callconv(.winapi) ?HICON;
pub extern "user32" fn LoadImageW(?HINSTANCE, [*:0]const u16, UINT, i32, i32, UINT) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn DestroyIcon(HICON) callconv(.winapi) BOOL;
pub extern "user32" fn CreateIconIndirect(*ICONINFO) callconv(.winapi) ?HICON;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn DestroyMenu(HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn InsertMenuItemW(HMENU, UINT, BOOL, *const MENUITEMINFOW) callconv(.winapi) BOOL;
/// Returns the chosen command id when TPM_RETURNCMD is set, and 0 when the menu
/// was dismissed — not a BOOL, despite the SDK's return type.
pub extern "user32" fn TrackPopupMenuEx(HMENU, UINT, i32, i32, HWND, ?*TPMPARAMS) callconv(.winapi) i32;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;

pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: UINT,
    ppvBits: *?*anyopaque,
    hSection: ?*anyopaque,
    offset: DWORD,
) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn CreateBitmap(i32, i32, UINT, UINT, ?*const anyopaque) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;

pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(.winapi) BOOL;

/// `GetSystemMetrics` reports the tray icon size the current DPI wants.
pub fn smallIconSize() u32 {
    const size = GetSystemMetrics(SM_CXSMICON);
    return if (size > 0) @intCast(size) else 16;
}

/// Copies UTF-8 into a fixed wide buffer, truncating and always terminating.
/// Win32 fixed-size fields have no other option.
pub fn copyWide(dest: []u16, source: []const u8) void {
    @memset(dest, 0);
    if (dest.len == 0) return;
    const written = std.unicode.utf8ToUtf16Le(dest[0 .. dest.len - 1], source) catch blk: {
        // Invalid UTF-8 should not lose the whole string; take what converts.
        var count: usize = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = source, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (cp > 0xffff or count + 1 >= dest.len) break;
            dest[count] = @intCast(cp);
            count += 1;
        }
        break :blk count;
    };
    dest[@min(written, dest.len - 1)] = 0;
}

test "copyWide truncates and terminates" {
    var buffer: [8]u16 = undefined;
    copyWide(&buffer, "hello");
    try std.testing.expectEqual(@as(u16, 'h'), buffer[0]);
    try std.testing.expectEqual(@as(u16, 0), buffer[5]);

    copyWide(&buffer, "a much longer string than fits");
    try std.testing.expectEqual(@as(u16, 0), buffer[7]);

    var empty: [1]u16 = undefined;
    copyWide(&empty, "x");
    try std.testing.expectEqual(@as(u16, 0), empty[0]);
}

test "the notify structure matches the documented layout" {
    // cbSize is validated by the shell, so the layout has to be exact.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(NOTIFYICONDATAW, "cbSize"));
    try std.testing.expectEqual(@sizeOf(usize), @offsetOf(NOTIFYICONDATAW, "hWnd"));
    try std.testing.expect(@offsetOf(NOTIFYICONDATAW, "szTip") % @alignOf(u16) == 0);
    try std.testing.expect(@sizeOf(NOTIFYICONDATAW) > 900);
}

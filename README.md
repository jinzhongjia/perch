# perch

A cross-platform system tray library for Zig. One API, three native backends —
no GTK, no Qt, no Electron.

| Platform | Backend | Status |
| --- | --- | --- |
| Linux | `StatusNotifierItem` over DBus | **working**, verified on Plasma |
| Windows | `Shell_NotifyIcon` + message-only window | **written, not yet run** |
| macOS | `NSStatusItem` via the Objective-C runtime | **working**, tray and notification interactions verified on M4 |
| BSD | same protocol, but the code uses Linux syscalls | not yet |

> **Status: alpha on Linux and macOS, unverified on Windows.** Linux is verified
> against Plasma. macOS has a pure Zig AppKit backend, with tray interactions,
> notification delivery, action callbacks and tagged replacement/close verified
> on an M4 Mac. Windows cross-compiles and links but has not run on Windows — see
> [issue #1](https://github.com/jinzhongjia/perch/issues/1).
> See [the roadmap](docs/ROADMAP.md).

## Install

```sh
zig fetch --save git+https://github.com/jinzhongjia/perch
```

```zig
// build.zig
const perch = b.dependency("perch", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("perch", perch.module("perch"));
```

Requires Zig 0.16.

## Use

```zig
const perch = @import("perch");

var menu = perch.Menu.init(gpa);
defer menu.deinit();

const verbose = try menu.addCheckbox("Verbose logging", false);
const theme = try menu.addSubmenu("Theme");
_ = try theme.addRadio("Light", 1, true);
_ = try theme.addRadio("Dark", 1, false);
try menu.addSeparator();
const quit = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });

const tray = try perch.Tray.create(gpa, .{
    .io = init.io, // std.Io from main; std.testing.io in tests
    .app_id = "dev.example.myapp",
    .tooltip = "My app",
    .icon = .{ .bytes = @embedFile("icon.png") },
    .menu = &menu,
    .handler = .{ .ctx = &app, .on_activate = onActivate },
    // Linux only, and required there: see "Linux" below.
    .linux = .{ .environ = init.minimal.environ },
});
defer tray.destroy();

try tray.run(); // blocks; call tray.stop() to return
```

`Tray.pump()` is available when perch has to share a thread with another event
loop instead of owning it.

## Design notes

- **Allocator- and `Io`-explicit.** Models and shared decoders use the supplied
  allocator; Linux transport uses the supplied `std.Io`. Native frameworks own
  their objects and event queues. macOS asynchronous notification state uses
  the C heap so completion blocks can outlive `Tray.destroy`. Multiple tray
  icons are supported; macOS notification authority is exclusive per process.
- **Slices are borrowed.** Menu labels, tooltips and icon bytes are not copied;
  keep them alive while the menu is attached. `@embedFile` and string literals
  are the intended case.
- **Ids, not pointers, in callbacks.** `MenuItem.Id` stays stable across menu
  rebuilds, which is what platforms like Windows want anyway.
- **Checkbox and radio state lives in the `Menu`.** Backends only render it, so
  behaviour is identical on all three platforms and unit-testable without a
  desktop session.
- **One event-loop model.** `run` owns the loop, `pump` doesn't; `stop` is
  callable from any thread.

## Linux

The backend speaks DBus directly — no libdbus, no GTK, no libappindicator. It
publishes an `org.kde.StatusNotifierItem-<pid>-<n>` name, exports
`/StatusNotifierItem` and a `com.canonical.dbusmenu` at `/MenuBar`, and registers
with `org.kde.StatusNotifierWatcher`. Starting before the desktop shell is fine:
if no watcher is running, perch waits for `NameOwnerChanged` and registers then,
which also covers a shell restart.

**`Options.linux.environ` is required.** perch needs
`DBUS_SESSION_BUS_ADDRESS`, and Zig 0.16 gives library code no way to read the
environment on its own — so pass `init.minimal.environ` from `main`, or set
`Options.linux.bus_address` yourself.

Working today: every icon source below, tooltips, status and category, the full
menu tree with submenus, checkboxes, radio groups, separators, accelerators and
per-item icons, left/middle/right clicks with their position, scroll events,
notifications with action buttons and replacement, and live updates through
`NewIcon`/`NewStatus`/`LayoutUpdated`/`ItemsPropertiesUpdated`.

Not yet: the XEmbed fallback for sessions with no StatusNotifierHost (so bare X
sessions and trayer-style trays see nothing), and `MenuItem.visible`.

perch registers with `org.kde.StatusNotifierWatcher` and falls back to the
`org.freedesktop` and `org.x` names. GNOME has no built-in host: it needs the
AppIndicator extension. `zig build run` reports which of these is the case.

## Windows

A message-only window owns one `NOTIFYICONDATAW` entry and receives the shell's
callbacks. `NOTIFYICON_VERSION_4` is requested, so the pointer position comes
with each event. The menu is an `HMENU` built fresh from `perch.Menu` on every
popup, shown with `TrackPopupMenuEx`. Icons are decoded, then converted to an
`HICON` at the size `SM_CXSMICON` reports for the current DPI. `TaskbarCreated`
is handled, so the icon survives an Explorer restart and picks up a DPI change
with it.

What the platform does not offer, and perch therefore does not pretend to:

- **Scroll events.** The shell does not deliver the wheel to tray icons, so
  `on_scroll` never fires.
- **Notification buttons.** Shell balloons have no actions; `Notification.actions`
  is ignored with a warning, and a balloon click arrives as the action
  `"default"`. Real buttons would mean WinRT toasts and an AppUserModelID.
- **Overlay icons.** There is no overlay for a notification-area icon.
- **`timeout_ms`.** Deprecated since Vista; the shell uses the accessibility
  timeout instead.

`Options.status` maps to the tray's own vocabulary: `.passive` hides the icon
with `NIS_HIDDEN`, and `.needs_attention` swaps in `attention_icon`.

## macOS

Pure Zig calls the system Objective-C runtime, AppKit, Foundation,
CoreGraphics and UserNotifications. No Objective-C source, wrapper dependency
or third-party UI toolkit is required. Install Apple's Command Line Tools or
Xcode for the SDK. SF Symbols and notifications require macOS 11 or newer;
symbol names and SVG features depend on the installed OS.

Implemented: `NSStatusItem` icons and titles, optional tooltips, native menus
with submenus, separators, disabled items, checkboxes, radio groups, item
icons and keyboard equivalents; left/right/middle clicks, modifier keys and
screen positions, both scroll axes, live updates, attention/overlay images,
and passive visibility. `Ctrl+Q` renders as Command-Q; use `Control+Q` for
literal Control, or `Meta+Ctrl+Q` for Command-Control. These are menu keyboard
equivalents, not global hotkeys. Screen coordinates use AppKit's bottom-left
origin. Fractional trackpad deltas accumulate until they can be reported as
integer `ScrollEvent.delta` values.

**Create, update, run, pump and destroy on the main thread.** Only `stop` is
thread-safe. Standalone programs create an accessory application without a
Dock icon; an existing application's activation policy and delegate are left
alone. `pump` integrates with a host event loop; a common-mode timer drains
notification callbacks while idle or while a menu is open.

`Icon.named` means an SF Symbol such as `"gearshape"`, not a Linux theme name.
Native AppKit image names such as `"NSActionTemplate"` also work. PNG, BMP,
ICO, paths, raw pixels, multi-size sets and native SVG decoding are supported.
`Icon.template` follows the menu bar appearance; overlays are composited at
the actual drawing scale. An unsupported image returns an error rather than
silently replacing it with a different icon.

### macOS notifications

The tray itself runs as an ordinary executable, but **notifications require
a real `.app` bundle whose `CFBundleIdentifier` matches `Options.app_id`**.
Build and open the rich example:

```sh
zig build macos-app
codesign --force --sign - zig-out/Perch.app
open zig-out/Perch.app
```

The first notification requests system permission. Bare executables fail
safely without calling the bundle-dependent notification center. A successful
`notify` means the request was queued, not that permission or delivery was
confirmed: asynchronous failures are logged and available through
`Tray.lastDiagnostic()`. After denial, enable notifications in System Settings
and recreate the tray. Focus and system presentation settings still govern
whether a banner appears.

Titles, plain-text bodies, native sounds, image attachments, action buttons,
tagged replacement/withdrawal and action/dismiss callbacks are implemented.
All handlers run on the main tray thread. Apple does not provide a reliable
expiration callback, so `on_notification_closed(.expired)` is not fabricated.
The application icon is used; `Notification.icon`, HTML formatting, Linux
categories/urgency, timeout, transient/resident and progress hints are not
expressed by this backend. `sound_name` is a bundled macOS sound filename,
not a Linux sound-theme name.

Only one live tray may own notification authority. An existing host
`UNUserNotificationCenter` delegate is never replaced. Existing notification
categories are preserved/restored; the host must not concurrently edit them
while perch owns the center. Notification actions do not restore application
state after process exit; registration and routing are scoped to the live tray.

Verification on Apple Silicon covered native popup open/close, checkbox/radio
and keyboard activation, disabled items, synthetic native click/scroll events,
image updates and rendering, multiple trays, callback-triggered destruction,
`pump`/`run`, and off-thread stop. An ad-hoc-signed `.app` exercised attachment
construction, queued replacement/close and denial handling. Manual verification
on an M4 Mac then confirmed checkbox/radio menus, quit, vertical scrolling,
authorized banner delivery, both notification action callbacks, and tagged
replacement/close. Horizontal scrolling has synthetic-event coverage but was
not manually tested with the available mouse. Intel Macs, other macOS versions,
appearance switching and multiple displays still need systematic validation.
Automated visual inspection used an in-process AppKit button snapshot;
notification appearance was also confirmed manually.

## Icons and HiDPI

`StatusNotifierItem` publishes either a themed name the host resolves itself or
an array of pixmaps it picks from per display scale. perch uses both.

| Source | HiDPI | Notes |
| --- | --- | --- |
| `Icon.svg` | best | Exported to a private icon theme; the host renders it at any size |
| `Icon.named` | best | The platform picks the size from the theme |
| `Icon.set` | good | Every listed size is published; the host chooses |
| `Icon.bytes` of an `.ico` | good | Every frame is published, so one file covers the range |
| `Icon.bytes` of a `.png`/`.bmp` | fair | One size, which the host stretches |
| `Icon.raw` | fair | Pre-decoded pixels, ARGB/RGBA/BGRA |

```zig
// Sharp at every scale, no rasteriser involved.
.icon = .{ .svg = @embedFile("icon.svg") },

// Or hand over a ladder of sizes.
.icon = .{ .set = &.{
    .{ .bytes = @embedFile("icon-16.png") },
    .{ .bytes = @embedFile("icon-32.png") },
    .{ .bytes = @embedFile("icon-64.png") },
} },
```

Decoders: PNG (8/16-bit, greyscale, RGB, palette, alpha), BMP (1/4/8/16/24/32-bit,
`BI_BITFIELDS`, either row order) and ICO/CUR, whose frames may be PNG or DIB with
an AND mask. SVG is never rasterised by perch — guessing a size is what makes
tray icons blurry — so it is handed to the platform instead. Menu-item icons go
out as dbusmenu `icon-data`, which specifies PNG, so other formats are skipped
there in favour of a themed name.

## Layout

```
src/root.zig            public API surface
src/tray.zig            Tray, Options, Handler, Error
src/menu.zig            menu tree, ids, checkbox/radio semantics
src/icon.zig            icon sources (bytes / path / named / template)
src/notification.zig    desktop notifications
src/backend.zig         comptime backend selection
src/backend/            windows.zig, macos.zig, linux.zig, unsupported.zig
src/image.zig           format sniffing, ARGB32 pixels
src/image/              png.zig, bmp.zig, ico.zig
src/linux.zig           the Linux internals, exposed for tests
src/linux/wire.zig      DBus marshalling
src/linux/Message.zig   DBus message header and body
src/linux/Connection.zig session bus transport, SASL, message I/O
src/linux/DBusMenu.zig  com.canonical.dbusmenu layout
src/linux/IconExport.zig SVG to a private icon theme
src/windows/win32.zig   the Win32 declarations perch needs
src/windows/icon.zig    ARGB32 pixels to HICON
src/macos/objc.zig      typed Objective-C runtime ABI
src/macos/image.zig     native images and resolution-independent overlays
src/macos/notifications.zig UserNotifications, blocks and callback lifetime
src/main.zig            `perch` doctor CLI
examples/basic.zig      icon, menu, clicks
examples/rich.zig       SVG icon, notification actions, attention status
tests/MockHost.zig      a fake host and notification daemon
tests/integration.zig   host-behaviour scenarios
```

## Notifications

```zig
try tray.notify(.{
    .title = "Update available",
    .body = "perch 0.1 is ready to install.",
    .urgency = .critical,
    .tag = 7, // name it, so it can be replaced or closed later
    .actions = &.{
        .{ .key = "install", .label = "Install now" },
        .{ .key = "later", .label = "Remind me later" },
    },
});
// Posting with tag 7 again replaces it; the progress bar updates in place.
try tray.notify(.{ .title = "Installing", .tag = 7, .progress = 40 });
try tray.closeNotification(7);
```

A pressed button arrives as `Handler.on_notification_action` with the tag and the
action key; dismissal arrives as `on_notification_closed` with a reason. Tags
exist because the platform assigns ids asynchronously — waiting for one would
mean blocking the event loop.

Also supported: `category`, `transient`, `resident`, `sound_name`,
`suppress_sound`, and an inline `image`. Hosts ignore what they do not implement,
so never make an action the only way to reach a feature.

## Development

```sh
zig build test       # unit tests (no desktop session needed)
zig build check      # compile every backend for every supported target
zig build run        # perch doctor: what works on this machine
zig build example-basic
zig build example-rich
zig build macos-app   # macOS: build zig-out/Perch.app for notification use
dbus-run-session -- zig build integration   # mock-host tests
```

`zig build check` compiles and links all five targets. On macOS the build
discovers the selected SDK with `xcrun`; elsewhere supply an Apple SDK with
`-Dmacos-sdk=/path/to/MacOSX.sdk`. CI runs the cross-link job on macOS so the
framework declarations are checked against Apple's SDK, not just compiled.

`zig build integration` drives the library through a mock StatusNotifierItem host
and notification daemon on a private bus. Real desktops differ in how they fetch
icons and menus — name-only versus pixmaps, filtered property lists, one level at
a time, `AboutToShow` first — and only one desktop is ever installed on a given
machine. Those behaviours are modelled in `tests/MockHost.zig` instead, so the
matrix runs anywhere a session bus can start, CI included. It needs its own bus
because a real session already owns the watcher name.

## License

MIT

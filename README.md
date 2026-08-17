# perch

A cross-platform system tray library for Zig. One API, three native backends —
no GTK, no Qt, no Electron.

| Platform | Backend | Status |
| --- | --- | --- |
| Linux | `StatusNotifierItem` over DBus | **working** |
| Windows | `Shell_NotifyIcon` + message-only window | scaffolded |
| macOS | `NSStatusItem` via the Objective-C runtime | scaffolded |
| BSD | same protocol, but the code uses Linux syscalls | not yet |

> **Status: alpha on Linux, pre-alpha elsewhere.** The Linux backend is a
> complete, dependency-free DBus implementation — icon, menu, events and
> notifications all work against a real host. Windows and macOS are documented
> stubs that return `error.NotImplemented`. See [the roadmap](docs/ROADMAP.md).

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

- **Allocator- and `Io`-explicit, no globals.** Every allocation goes through the
  allocator you pass in, and all platform I/O goes through the `std.Io` you pass
  in. A process can host more than one tray.
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
dbus-run-session -- zig build integration   # mock-host tests
```

`zig build check` cross-compiles all backends from a single host, so a change to
the macOS backend fails fast on a Linux box.

`zig build integration` drives the library through a mock StatusNotifierItem host
and notification daemon on a private bus. Real desktops differ in how they fetch
icons and menus — name-only versus pixmaps, filtered property lists, one level at
a time, `AboutToShow` first — and only one desktop is ever installed on a given
machine. Those behaviours are modelled in `tests/MockHost.zig` instead, so the
matrix runs anywhere a session bus can start, CI included. It needs its own bus
because a real session already owns the watcher name.

## License

MIT

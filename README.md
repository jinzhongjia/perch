# perch

A cross-platform system tray library for Zig. One API, three native backends —
no GTK, no Qt, no Electron.

| Platform | Backend | Status |
| --- | --- | --- |
| Linux / BSD | `StatusNotifierItem` over DBus | **working** |
| Windows | `Shell_NotifyIcon` + message-only window | scaffolded |
| macOS | `NSStatusItem` via the Objective-C runtime | scaffolded |

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

Working today: themed and embedded icons (`Icon.bytes` is decoded to ARGB32 by a
built-in PNG decoder for `IconPixmap`), tooltips, the full menu tree with
submenus, checkboxes, radio groups, separators, accelerators and per-item icons,
left/middle/right clicks, scroll events, desktop notifications, and live updates
through `NewIcon`/`LayoutUpdated`/`ItemsPropertiesUpdated`.

Not yet: the XEmbed fallback for sessions with no StatusNotifierHost, and
`Icon.path` is handed to the host as a name rather than decoded.

## Layout

```
src/root.zig            public API surface
src/tray.zig            Tray, Options, Handler, Error
src/menu.zig            menu tree, ids, checkbox/radio semantics
src/icon.zig            icon sources (bytes / path / named / template)
src/notification.zig    desktop notifications
src/backend.zig         comptime backend selection
src/backend/            windows.zig, macos.zig, linux.zig, unsupported.zig
src/linux/wire.zig      DBus marshalling
src/linux/Message.zig   DBus message header and body
src/linux/Connection.zig session bus transport, SASL, message I/O
src/linux/DBusMenu.zig  com.canonical.dbusmenu layout
src/linux/png.zig       PNG to ARGB32, for IconPixmap
src/main.zig            `perch` doctor CLI
examples/basic.zig      end-to-end example
```

## Development

```sh
zig build test       # unit tests (no desktop session needed)
zig build check      # compile every backend for every supported target
zig build run        # perch doctor: what works on this machine
zig build example-basic
```

`zig build check` cross-compiles all backends from a single host, so a change to
the macOS backend fails fast on a Linux box.

## License

MIT

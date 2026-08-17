# perch

A cross-platform system tray library for Zig. One API, three native backends —
no GTK, no Qt, no Electron.

| Platform | Backend | Status |
| --- | --- | --- |
| Windows | `Shell_NotifyIcon` + message-only window | scaffolded |
| macOS | `NSStatusItem` via the Objective-C runtime | scaffolded |
| Linux / BSD | `StatusNotifierItem` over DBus, XEmbed fallback | scaffolded |

> **Status: pre-alpha.** The public API, menu model and build graph are in place
> and tested; the platform backends are documented stubs that return
> `error.NotImplemented`. See [the roadmap](docs/ROADMAP.md).

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

## Layout

```
src/root.zig            public API surface
src/tray.zig            Tray, Options, Handler, Error
src/menu.zig            menu tree, ids, checkbox/radio semantics
src/icon.zig            icon sources (bytes / path / named / template)
src/notification.zig    desktop notifications
src/backend.zig         comptime backend selection
src/backend/            windows.zig, macos.zig, linux.zig, unsupported.zig
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

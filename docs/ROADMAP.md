# Roadmap

Ordered roughly by dependency. Each milestone should keep `zig build check`
green on all five targets.

## 0.1 — a visible icon with a working menu

- [x] **Linux / StatusNotifierItem.** Minimal DBus client (session bus from
      `DBUS_SESSION_BUS_ADDRESS`, SASL EXTERNAL auth, message marshalling),
      export `/StatusNotifierItem` and `com.canonical.dbusmenu`, register with
      `org.kde.StatusNotifierWatcher`. Verified against Plasma.
- [ ] **Windows / notification area.** Message-only window, `NIM_ADD` with
      `NOTIFYICON_VERSION_4`, `HMENU` popup via `TrackPopupMenuEx`, re-add on
      `TaskbarCreated`.
- [ ] **macOS / NSStatusItem.** `objc_msgSend` bindings, accessory activation
      policy, `NSMenu` mirroring, action target registered with `class_addMethod`.
- [x] Icon decoding: raw PNG bytes → ARGB32 for `IconPixmap`. Windows `HICON`
      and macOS `NSImage` still to do.
- [x] `run` / `pump` / `stop` semantics on Linux, `stop` callable off-thread.
- [ ] The same on Windows and macOS.

## 0.2 — the rich surface

Linux covers most of this already; boxes stay open until all three agree.

- [x] Notifications on Linux (`org.freedesktop.Notifications`, urgency hints).
      Actions, and the other two backends, still to do.
- [x] Submenu, checkbox, radio and separator parity on Linux; disabled items.
- [x] Accelerator parsing, rendered as dbusmenu shortcuts. Still to do:
      per-platform rendering (Ctrl → ⌘ on macOS).
- [x] Menu-item icons on Linux (`icon-name` and PNG `icon-data`).
- [x] Live updates without a full menu rebuild (`ItemsPropertiesUpdated`).
- [x] Left, right and middle click plus scroll on Linux. Double click is not
      something SNI reports.
- [ ] Hidden items; `visible` is currently always true.
- [ ] Template and symbolic icons following light and dark themes.
- [ ] Text labels next to the icon (macOS menu bar, Linux SNI title).
- [ ] XEmbed fallback for sessions with no StatusNotifierHost.

## 0.3 — production concerns

- [ ] Thread safety audit; `stop` and setters callable off the loop thread.
- [ ] Host appear/disappear recovery (Explorer restart, desktop shell reload,
      watcher going away).
- [ ] Autostart helpers (registry Run key, LaunchAgent, XDG autostart).
- [ ] Optional global hotkey registration.
- [ ] Manual smoke-test matrix: GNOME (with AppIndicator), KDE, sway/waybar,
      Windows 10/11, macOS 13+.
- [ ] Docs site with per-platform gotchas.

## Non-goals

- Full windowing or widget toolkit. perch is the tray and its menu only.
- Bundling an image codec beyond what each platform already provides.
- Wrapping GTK or Qt to get a tray. Native APIs only.

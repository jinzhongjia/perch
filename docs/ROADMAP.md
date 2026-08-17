# Roadmap

Ordered roughly by dependency. Each milestone should keep `zig build check`
green on all five targets.

## 0.1 — a visible icon with a working menu

- [ ] **Linux / StatusNotifierItem.** Minimal DBus client (session bus from
      `DBUS_SESSION_BUS_ADDRESS`, SASL EXTERNAL auth, message marshalling),
      export `/StatusNotifierItem` and `com.canonical.dbusmenu`, register with
      `org.kde.StatusNotifierWatcher`.
- [ ] **Windows / notification area.** Message-only window, `NIM_ADD` with
      `NOTIFYICON_VERSION_4`, `HMENU` popup via `TrackPopupMenuEx`, re-add on
      `TaskbarCreated`.
- [ ] **macOS / NSStatusItem.** `objc_msgSend` bindings, accessory activation
      policy, `NSMenu` mirroring, action target registered with `class_addMethod`.
- [ ] Icon decoding: raw PNG bytes → each platform's bitmap type.
- [ ] `run` / `pump` / `stop` semantics verified on all three.

## 0.2 — the rich surface

- [ ] Notifications on all three backends, with actions where available.
- [ ] Submenu, checkbox, radio and separator parity; disabled and hidden items.
- [ ] Accelerator parsing and per-platform rendering (Ctrl → ⌘ on macOS).
- [ ] Menu-item icons; template/symbolic icons following light and dark themes.
- [ ] Left vs right vs middle click, double click, scroll events.
- [ ] Text labels next to the icon (macOS menu bar, Linux SNI title).
- [ ] Live updates without a full menu rebuild.
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

# YeelightBar

A native macOS app for controlling **Yeelight** LAN devices — built for the **Yeelight Screen Light Bar Pro**
(`YLTD003`), but it drives plain RGB strips and bulbs too. The official software is Windows-only; this is a clean,
fast SwiftUI replacement with screen-sync ambilight, music reactivity, and multi-lamp group control.

> No cloud, no account. Everything happens over your LAN.

## Features

- **Full control** — power, front white (brightness + colour temperature), ambient RGB, ready-made scenes.
- **Group / "mix" control** — select several lamps and drive them together; each lamp speaks its own protocol
  dialect (the bar has a separate ambient `bg` channel, strips don't).
- **Screen-sync ambilight** — ScreenCaptureKit samples your screen and streams the colour to the lamp's ambient
  channel at ~20 Hz over a UDP session.
  - **Per-lamp display + region**: in a multi-monitor setup, each lamp can sample a *different* display and a
    *different* region of it (top / bottom / left / right / full) — e.g. the bar takes the top of your main screen
    while an under-desk strip takes the bottom of another.
  - Resolution-independent capture (works on 16:9, 4K, portrait, and 32:9 ultrawides alike).
  - Live preview: a screen-shaped panel per display showing exactly which region each lamp samples, in its live colour.
- **Music reactivity** — captures *system* audio (no microphone), splits it into bass/mid/treble with IIR filters.
  - **Beat** mode pumps brightness on the kick; **Spectrum** mode maps bass→red / mid→green / treble→blue.
- **Two surfaces** — a compact menu-bar panel for quick tweaks and a full resizable window (`NavigationSplitView`)
  for setup.
- **Robust on a real network** — auto-discovery (SSDP + active subnet scan), reconnect on DHCP IP changes, and
  serialized control so the lamp never drops a command from concurrent connections.

## Requirements

- macOS 13 (Ventura) or newer, Apple Silicon or Intel.
- Yeelight device(s) with **LAN Control** enabled (Yeelight app → device → *LAN Control*).
- **Screen Recording** permission (System Settings → Privacy & Security) for screen-sync and music modes.

## Build & run

### Xcode
Open `YeelightBar.xcodeproj` and run the **YeelightBar** scheme (⌘R). The project is generated from `project.yml`
with [XcodeGen](https://github.com/yonaskolb/XcodeGen); run `xcodegen generate` after editing the spec.

### Swift Package Manager (no Xcode needed)
```sh
swift build
./scripts/bundle.sh          # assembles + signs build/YeelightBar.app
open build/YeelightBar.app
```
`scripts/setup-signing.sh` creates a stable self-signed code-signing identity so the Screen-Recording grant survives
rebuilds (an ad-hoc signature changes every build and would re-trigger the permission prompt).

## `yeectl` — command-line tool

A small CLI for testing and scripting the protocol:

```sh
swift run yeectl discover                 # SSDP
swift run yeectl auto                      # SSDP, fall back to active subnet scan
swift run yeectl state   <ip>
swift run yeectl on|off  <ip>
swift run yeectl bright  <ip> <0-100>
swift run yeectl ct      <ip> <1700-6500>
swift run yeectl rgb     <ip> <hex e.g. FF8800>   # ambient / bg channel
swift run yeectl rainbow <ip> [seconds]           # UDP 20 Hz streaming test
```

## Architecture

```
Sources/
  YeelightKit/            # transport-only library, no UI
    Yeelight.swift        # TCP 55443 JSON control + UDP 55444 streaming session
    Discovery.swift       # SSDP multicast discovery
    Scan.swift            # active subnet scan + manual-IP validation
  yeectl/                 # CLI
  YeelightBarApp/         # SwiftUI app
    LampController.swift   # @MainActor store: discovery, group control, sync orchestration
    ScreenSyncEngine.swift # multi-display capture → per-(display,region) colour → UDP fan-out
    MusicSyncEngine.swift  # system-audio capture → beat/spectrum → UDP fan-out
    FullView.swift / MenuPanelView.swift
```

The Yeelight LAN protocol (TCP control, the UDP streaming handshake, the bar's quirky `main_power`/`bg_power`
channels) is documented in [`PROTOCOL.md`](PROTOCOL.md).

## Notes on the Screen Light Bar Pro

This lamp has two independent channels — front white (`set_power` / `main_power`) and ambient RGB
(`bg_set_power` / `bg_set_rgb`) — so you can run "ambient only". Its `power` property is unreliable (sticks at `on`
even when the front is dark); the app reads `main_power` instead. Plain strips have a single channel and reject the
bar-only `dev_toggle`, so control is dispatched per device type.

## License

[MIT](LICENSE) — not affiliated with or endorsed by Yeelight / Xiaomi.

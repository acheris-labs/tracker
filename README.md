# Tracker

Tiny macOS system monitor that lives in the dock. The dock icon is a live chart
of CPU (P-core vs E-core, system vs user) and GPU utilization. A larger chart
window adds memory, disk I/O, and battery history; everything is customizable
via Preferences.

Apple Silicon, macOS 14+. Ad-hoc signed.

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/acheris-labs/tracker/releases) and drag
`Tracker.app` into `/Applications`.

Because the build is ad-hoc signed (not notarized), the first launch needs a
right-click → Open to bypass Gatekeeper.

## Build from source

```
make build       # release build via xcodebuild
make run         # build + open the .app
make rerun       # killall + run (handy during iteration)
make clean       # xcodebuild clean
```

Builds land in `./build/Build/Products/Release/Tracker.app`; `make app-path`
prints the absolute path. You can also open `Tracker.xcodeproj` in Xcode and
⌘R, though the GUI build uses Xcode's default DerivedData location.

## Shortcuts

| Shortcut | Action |
|:---------|:-------|
| ⌘0       | Show the chart window |
| ⌘,       | Open Preferences |
| ⌘W       | Close the focused window |
| ⌘H       | Hide Tracker |
| ⌘Q       | Quit |

Right-clicking the dock icon also opens a menu with current readings, history
duration, Preferences, and a shortcut to Activity Monitor.

## Reading the dock icon

Each column is one second of history, oldest on the left.

- **Left half** of each column: P-core utilization, system in red, user in
  green (stacked, normalized to total P-core capacity).
- **Right half**: E-core utilization, system in orange, user in blue
  (normalized to total E-core capacity).
- **Violet line**: GPU "Device Utilization %" sampled from
  `IORegistry → IOAccelerator → PerformanceStatistics`.
- **Badge**: instantaneous power draw in watts (configurable threshold).

## Chart window

⌘0 (or click *Show Chart* in the dock menu) opens a larger version with the
same CPU stack plus:

- **Memory** — gray line, fraction of physical RAM in use.
- **Disk I/O** — cyan = read, amber = write.
- **Battery** — percentage history, with current charge state, watts in/out,
  and time-remaining shown in the legend.

Series can be toggled and recolored from Preferences (⌘,).

## Configuration

History window length, badge threshold, and visible series are stored in
`UserDefaults`:

```
make history-30                   # 30-second history (quick visual feedback)
make history-180                  # restore 180s default
make badge-threshold-25           # show the watt badge once draw ≥ 25 W
make show-defaults
```

Changes apply on the next launch.

## How it works

- `CPUSampler.swift` — `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` once per
  second, diffs tick counts vs the previous sample, splits by P/E using
  `sysctl hw.perflevel{0,1}.logicalcpu`. Per-group fractions of total ticks.
- `GPUSampler.swift` — reads `PerformanceStatistics` from the first
  `IOAccelerator` IORegistry entry; auto-detects which key carries utilization
  (`Device Utilization %`, `GPU Core Utilization`, etc.).
- `MemorySampler.swift`, `DiskSampler.swift`, `BatterySampler.swift` — Mach
  / IOKit polling at the same 1 Hz cadence.
- `HistoryRenderer.swift` — ring buffer of frames, redraws a 128×128 `NSImage`
  each tick for the dock icon, and a larger surface for the chart window.
- `AppDelegate.swift` — schedules the 1 Hz timer in `.common` mode and wires
  the menu bar, dock menu, and windows.

## Reference

CPU sampling approach adapted from
[exelban/stats](https://github.com/exelban/stats) (MIT) — same Mach API call
shape, same per-state tick deltas, reimplemented around Apple Silicon's P/E
topology.

## License

[MIT](LICENSE) © 2026 Chris Madden

# Tracker

Tiny macOS app whose entire UI is its dock icon: a live-updating chart of CPU
(P-cores vs E-cores, user vs system) and GPU utilization. No window, no
preferences UI, ad-hoc signed.

Apple Silicon, macOS 14+.

## Build & run

```
make build       # release build via xcodebuild
make run         # build + open the .app
make rerun       # killall + run (handy during iteration)
make kill        # killall Tracker
make clean       # xcodebuild clean
```

The .app lands in DerivedData; `make app-path` prints the absolute path.

You can also open `Tracker.xcodeproj` in Xcode and ⌘R.

## Configuration

History window length (seconds) is read from `UserDefaults` at launch. Default
is 180s (one bar per second, ~3 minutes of history).

```
make history-30      # 30 seconds (faster visual feedback while testing)
make history-180     # restore default
make show-defaults
```

Changes apply on the next launch (`make rerun`).

## Reading the icon

Each column is one second of history, oldest on the left.

- **Left half** of each column: P-core utilization, system in red, user in green
  (stacked, normalized to total P-core capacity).
- **Right half**: E-core utilization, system in orange, user in mint
  (normalized to total E-core capacity).
- **Yellow line**: GPU "Device Utilization %" sampled from
  `IORegistry → IOAccelerator → PerformanceStatistics`.

## Quitting

Right-click the dock icon → Quit. (Default NSApplication dock menu.)

## How it works

- `CPUSampler.swift`: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` once per
  second, diffs tick counts vs the previous sample, splits by P/E using
  `sysctl hw.perflevel{0,1}.logicalcpu`. Per-group fractions of total ticks.
- `GPUSampler.swift`: reads `PerformanceStatistics` from the first
  `IOAccelerator` IORegistry entry; auto-detects which key carries
  utilization (`Device Utilization %`, `GPU Core Utilization`, etc.).
- `HistoryRenderer.swift`: ring buffer of frames, redraws a 128×128 `NSImage`
  each tick and assigns it to `NSApp.applicationIconImage`.
- `AppDelegate.swift`: schedules the 1 Hz timer in `.common` mode; never
  creates a window, so there's nothing to restore on relaunch.

## Reference

CPU sampling pattern adapted from
[exelban/stats](https://github.com/exelban/stats) — same Mach API call
shape, same per-state tick deltas.

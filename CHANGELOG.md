# Changelog

All notable changes to Tracker are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The CI release workflow extracts the matching `## [x.y.z]` section as the
GitHub release body and as the link target for Sparkle's release notes, so
write each entry as if it were the changelog the user reads in the
auto-update prompt.

## [Unreleased]

### Added
- **Light mode.** Preferences gains an Appearance control — Auto (default,
  follows System Settings live), Light, or Dark — and the whole app honors
  it, chart included. On a light card the chart palette is adjusted for
  legibility (brightness capped, saturation nudged) so near-white and pale
  traces like Memory and Network stay readable; custom colors get the same
  treatment. The dock icon keeps following System Settings rather than the
  app's override, since it's drawn on the Dock's own material.

### Fixed
- Footer panes and the chart card kept their borders from the appearance they
  were created in, so the outlines disappeared after an appearance switch.

## [0.3.0] - 2026-08-12

### Added
- **Network tab.** Per-process Sent/s, Rcvd/s, lifetime Sent/Rcvd Bytes, and
  Sent/Rcvd Packets (sampled via `nettop`; Apple offers no public per-process
  network API), with an Activity-Monitor-style footer: colored rates, a
  mirrored DATA graph, and data received/sent totals.
- **Per-process inspector.** Double-click a row (or the ⓘ toolbar button) for
  a live panel: identity block (executable path, parent process, user, kind,
  % CPU, preventing sleep) and Memory · Statistics · Open Files & Ports tabs,
  plus a Quit button. Open Files & Ports lists real vnode paths and socket
  kinds via libproc. Multiple inspectors can be open; an exited process is
  flagged in the subtitle.
- **Network and Swap chart traces.** Network Rcvd/Sent lines (off by
  default) and a Swap line (used ÷ total, on the percentage axis). Swap Used
  also appears in the Memory tab footer and the chart legend.
- **Preventing Sleep** column on the Energy tab (public
  IOPMCopyAssertionsByProcess — the one AM column that didn't need private
  API).
- **Legend hover highlighting.** Hover a legend chip to spotlight that series
  in the chart; everything else dims to a ghost.
- **Process scopes.** All / My / System Processes in the toolbar's "…" menu,
  with the window subtitle tracking the choice.
- **Per-surface trace selection.** The dock icon and the chart each choose
  their own traces (Preferences shows one table: trace · colors · Dock ·
  Chart). CPU is selectable like everything else.
- **Independent histories.** The dock icon keeps a short "right now" window
  (default 30 s) while the chart can show up to an hour ("…" › Chart
  History); one shared sample store means switching loses nothing.
- Quality of life: windows remember size/position, ⌘F focuses search,
  Reveal in Finder / Copy Path on right-click, per-tab column visibility and
  widths persist, all columns user-resizable, color wells show their metric
  on hover.

### Changed
- **Activity-Monitor look and feel throughout.** Native unified toolbar
  (quit/inspect buttons, "…" menu, centered tab selector, collapsing
  search); tables on system backgrounds with 24pt rows, AM column titles and
  order, Process Name flexing to fill the window; footers as boxed panes
  with live graphs (CPU LOAD, MEMORY USED, ENERGY IMPACT/BATTERY, disk IO).
  The Chart tab and its legend adopt the same system-native styling.
- **Shared logarithmic bytes/sec axis.** Disk and network lines share one
  log-scaled right axis capped at the highest currently-shown trace, so a
  200 MB/s disk burst and a 20 MB/s download stay legible together.
- **Hue-grouped palette.** Cool hues = inbound, warm = outbound; saturated =
  disk, pale = network; battery is yellow. All overridable per-color.
- Preferences slimmed to the trace table, drain-alert slider, and Reset
  Colors; auto-update toggling moved to the app menu, dock-icon history to
  the dock menu.

### Fixed
- **The battery line now actually draws.** It was stored and toggleable but
  never rendered, on either the chart or the dock icon.
- **"All processes" really means all.** Processes whose stats can't be read
  (other users') were silently dropped; they now appear with identity-only
  rows, taking the list from ~530 to ~870 on a typical system.
- Process tables no longer flicker on refresh: cells are reused, column
  widths no longer re-fit every tick, and the selection survives reloads.

## [0.2.8] - 2026-07-24

### Fixed
- A large translucent wedge spanning the Chart window, introduced in 0.2.7.
  Each CPU band's fill was left as an unclosed subpath, so it filled along a
  diagonal from the newest sample back to the oldest one. Most visible shortly
  after launch, when the history is only partly filled.

## [0.2.7] - 2026-07-24

### Changed
- **Translucent Chart rendering.** The stacked CPU areas are now drawn as
  translucent gradient bands with a bright edge along each boundary, and the
  GPU trace moves behind them with a soft glow beneath its line — so GPU stays
  readable through the stack instead of being hidden by it. The menu-bar icon
  is unchanged.

## [0.2.6] - 2026-06-17

### Added
- **Activity-Monitor-style process view.** The categories are now top-level
  siblings of Chart — **Chart · CPU · Memory · Energy · Disk** — each with its
  own sortable columns, process icons, and a per-category summary footer
  (System/User/Idle % and thread/process totals on CPU; memory/energy/disk
  totals elsewhere). Adds a filter field and a toolbar to Inspect / Quit /
  Force-Quit the selected process.
- **Energy** columns: **Drain** (% of a full charge per hour at the current
  rate), lifetime **Energy** consumed, and **% Batt** (lifetime energy vs.
  battery capacity); the footer shows the battery charge/discharge rate and
  time-to-full / time-to-empty.
- **Disk** columns: cumulative **Bytes Written / Bytes Read** alongside the
  live per-second rates.

### Changed
- The blown-up **Chart** view draws CPU as a smoothed stacked area and the
  metric lines as splines; the dock icon keeps its crisp bars.
- The Chart tab now uses the same dark rounded-panel styling as the category
  tabs, for a consistent look across tabs.

### Fixed
- The battery charge/discharge rate now reflects true flow even on AC — it was
  previously forced to zero whenever plugged in, hiding on-AC discharge.

## [0.2.5] - 2026-06-16

### Fixed
- **Signed and notarized builds now actually launch.** The embedded
  `Sparkle.framework` was left ad-hoc-signed while the app itself was
  Developer ID + hardened runtime, so macOS library validation rejected the
  mismatched framework and aborted the app at launch — every signed/notarized
  release was unrunnable (only ad-hoc local builds worked). The build now
  re-signs Sparkle and its nested code with the app's identity, so it
  launches and notarization passes.

### Changed
- The **About Tracker** panel now matches Newt's: the app icon, version,
  copyright, and an MIT-license / no-warranty note.

## [0.2.4] - 2026-06-16

### Fixed
- **Auto-update now actually works.** Every build was shipping with a
  hardcoded version (`CFBundleVersion 1`) regardless of the release tag, so
  Sparkle compared the installed copy against the appcast, decided it was
  already newest, and never offered an update. The version is now stamped
  from the tag with a monotonic build number, and the appcast advertises
  each build's real version — so existing installs will finally be offered
  updates (and every future release will be too).

### Changed
- Local/dev builds now report version `0.0.0`, so they always sit behind
  released versions and will always offer the latest update.

## [0.2.2] - 2026-06-16

### Changed
- **The release DMG is now signed, notarized, and stapled itself** (not just
  the app inside it), so a DMG downloaded directly from the GitHub release
  clears Gatekeeper on mount without a prompt.

### Fixed
- The release workflow now waits for a just-published release to appear in
  the releases API before regenerating the appcast, so a new version isn't
  occasionally missed from the feed.

## [0.2.1] - 2026-05-23

### Added
- **Process explorer** — a per-process list of CPU and memory usage, with
  Kill / Force Kill from the row context menu.
- **Sparkle auto-update** — Tracker can now check for and install updates.

## [0.2.0] - 2026-05-23

### Added
- Developer ID signing + notarization for distributable builds.

## [0.1.0] - 2026-05-11

### Added
- Initial release. A dock-icon system monitor whose icon is a live chart of
  CPU (P-core vs E-core, system vs user) and GPU utilization.
- Chart window with memory, disk I/O, and battery history.
- Battery drain dock badge, customizable chart colors, and Preferences.
- Keyboard shortcuts (⌘0 chart, ⌘, preferences, ⌘W close, ⌘H hide, ⌘Q quit).
- CI build workflow and a tag-driven release workflow.

[Unreleased]: https://github.com/acheris-labs/tracker/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/acheris-labs/tracker/compare/v0.2.8...v0.3.0
[0.2.8]: https://github.com/acheris-labs/tracker/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/acheris-labs/tracker/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/acheris-labs/tracker/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/acheris-labs/tracker/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/acheris-labs/tracker/compare/v0.2.2...v0.2.4
[0.2.2]: https://github.com/acheris-labs/tracker/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/acheris-labs/tracker/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/acheris-labs/tracker/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/acheris-labs/tracker/releases/tag/v0.1.0

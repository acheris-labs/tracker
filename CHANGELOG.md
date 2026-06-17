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
- **Activity-Monitor-style process view.** The categories are now top-level
  siblings of Chart — **Chart · CPU · Memory · Energy · Disk** — each with its
  own sortable columns, process icons, and a per-category summary footer
  (System/User/Idle % with a live CPU-load sparkline and thread/process totals
  on CPU; memory/energy/disk totals elsewhere). Adds a filter field and a
  toolbar to Inspect / Quit / Force-Quit the selected process.
- **Energy** columns: **Drain** (% of a full charge per hour at the current
  rate), lifetime **Energy** consumed, and **% Batt** (lifetime energy vs.
  battery capacity); the footer shows the battery charge/discharge rate and
  time-to-full / time-to-empty.
- **Disk** columns: cumulative **Bytes Written / Bytes Read** alongside the
  live per-second rates.

### Changed
- The blown-up **Chart** window draws CPU as a smoothed stacked area and the
  metric lines as splines; the dock icon keeps its crisp bars.

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

[Unreleased]: https://github.com/acheris-labs/tracker/compare/v0.2.5...HEAD
[0.2.5]: https://github.com/acheris-labs/tracker/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/acheris-labs/tracker/compare/v0.2.2...v0.2.4
[0.2.2]: https://github.com/acheris-labs/tracker/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/acheris-labs/tracker/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/acheris-labs/tracker/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/acheris-labs/tracker/releases/tag/v0.1.0

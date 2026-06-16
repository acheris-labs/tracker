# Changelog

All notable changes to Tracker are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The CI release workflow extracts the matching `## [x.y.z]` section as the
GitHub release body and as the link target for Sparkle's release notes, so
write each entry as if it were the changelog the user reads in the
auto-update prompt.

## [Unreleased]

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

[Unreleased]: https://github.com/acheris-labs/tracker/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/acheris-labs/tracker/compare/v0.2.2...v0.2.4
[0.2.2]: https://github.com/acheris-labs/tracker/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/acheris-labs/tracker/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/acheris-labs/tracker/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/acheris-labs/tracker/releases/tag/v0.1.0

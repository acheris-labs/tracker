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
- **The Memory tab's footer now reports what Activity Monitor's does**:
  Physical Memory, Memory Used, Cached Files and Swap Used beside App Memory,
  Wired Memory and Compressed, with a memory-pressure graph that takes its
  green/yellow/red straight from the kernel's own pressure level rather than a
  threshold we invented. App Memory, Wired, Compressed and Cached Files each
  match Activity Monitor's figure to the hundredth of a GB, verified against a
  simultaneous sample.

  Memory Used is App + Wired + Compressed — Apple's documented definition, and
  the sum of the three parts shown next to it. Activity Monitor's own headline
  runs about 0.5–1.5 GB higher than that, but its displayed parts don't add up
  to its own total either, so the difference lives in that headline rather than
  in the components.

## [0.4.0] - 2026-08-13

### Added
- **Connection Map.** "…" › Connection Map on the Connections tab — or
  Connection Map… in the dock icon's right-click menu, which opens it on its
  own without dragging the main window along — shows a
  radial view: this Mac at the centre, every host it's talking to around it,
  and edges weighted by how much data crossed them (logarithmically, so a
  600 MB upload and a 4 KB poll can share one picture). Edge colour is the
  send/receive ratio on a continuous blue-violet-red scale rather than a
  category, so an even split reads as even instead of flipping at 50%. The
  arrowhead points the way the
  connection was opened — worked out from which end holds the ephemeral port,
  or which end's port we're listening on. Public hosts carry their country
  flag; LAN and loopback peers show a house instead, since they have no
  registry country.
- **Map interaction.** Hovering a node names the processes behind it, with
  their icons and pids, the connection count, byte totals and which side
  opened it — and the map holds still while the pointer is over it. Clicking
  opens that process's inspector; when several processes share a host, it
  offers a pick list. Nodes glide to their places rather than jumping, hold
  still while you're reading one, and a toolbar Pause holds the whole picture
  for as long as you like. Outgoing / Incoming / Unclear filter by which side
  dialled, independently — "unclear" is a real state (UDP has no handshake to
  read, and a host can be dialled both ways), so it gets its own switch rather
  than being folded into one of the others.
- **Country column** in the Connections table, sortable, showing the flag and
  code for public addresses and a house for anything on this network
  (RFC1918, loopback, and their IPv6 equivalents). It uses the same source as
  the map, so "Show Countries" governs both.
  Countries come from a table bundled with the app, compiled from the five
  regional registries' published delegation statistics and refreshed on every
  release: flags appear the instant a row does, and nothing about your
  connections goes anywhere. It is the registry's country rather than
  geolocation, so an anycast address reads as its owner's home country
  instead of the datacentre you actually reached.
- **A footer on the Connections tab**, matching the process tabs: how many
  connections each side opened (outgoing, incoming, and the unclear ones), the
  same split graphed over time, and what the sockets are — TCP, UDP, and how
  many are listening. It counts what the table is showing — the Hide
  Localhost/LAN/Remote scope applies — but not the search field, so a summary
  doesn't shift under you as you type a filter.
- **Hide Localhost / Hide LAN / Hide Remote**, on both the map and the
  Connections table, in the "…" menu on each. They compose, so any slice
  works — hiding remote leaves just this machine and the network around it.
  Localhost starts hidden: traffic that never leaves the machine is rarely
  what you opened this to see. Listening sockets are never hidden by these,
  so "what am I exposing" stays answerable.
- **Direction column** in the Connections table: which end opened the
  connection, not which way the bytes went. It reads the rule the map's
  arrowheads use — landing on a port you're listening on, or which end holds
  the ephemeral port — and says Unclear rather than guessing when neither
  applies. Listening sockets show a dash: nobody has dialled anything yet.
- **Drag columns into the order you want**, in both the process tables and the
  Connections table. The order persists with the widths and the visible set.
  Process categories share one order — a column means the same thing on every
  tab — while the Connections table and the inspector's keep their own.

### Changed
- **The window opens on the process list, not the graphs.** The tab you act on
  is the one you land on; the graphs moved to the end of the row and are named
  **Visualizations**. Clicking the dock icon now just shows the window on
  whatever tab you left it on, rather than forcing the graphs to the front.
- **A shortcut per tab, in tab order**: ⌘1 CPU through ⌘7 Visualizations, the
  way Activity Monitor numbers its own. ⌘1 and ⌘2 previously meant the graphs
  and the process list, from when those were the first two tabs.
- **Roomier footers.** The summary panes were 52pt in a 66pt strip, which left
  the graphs a few pixels of amplitude and the rows no air between them; they
  now follow Activity Monitor's proportions — 84pt panes in a 104pt strip.

## [0.3.1] - 2026-08-12

### Added
- **Connections tab.** A new top-level tab listing every connection on the
  machine — process name (with its icon) and PID, protocol, local port, remote
  host, remote port, TCP state, and bytes received/sent per connection. It
  reads `netstat -anv`, so unlike the per-process view it isn't limited to
  processes you own: root-owned daemons appear too, with their owning user.
  Sortable on every column and filtered by the toolbar's search field.
  Double-click a row to inspect its process; the Quit / Inspect toolbar
  buttons and Force Quit act on the selected connection's process (individual
  connections can't be closed without root or a network extension). "…" ›
  Resolve Host Names switches the Remote Host column between reverse-DNS
  names and raw addresses.
- **Connections tab in the per-process inspector.** Every TCP/UDP socket the
  process holds: protocol, local port, remote host, remote port and TCP state,
  sortable, refreshed on the existing tick. Remote addresses are resolved to
  their reverse-DNS names in the background where they have one (many don't —
  Apple, Cloudflare and Fastly ranges typically have no PTR), falling back to
  the raw IP; the full name, address and local endpoint are on the row's
  tooltip. Processes belonging to another user say so rather than showing an
  empty list — their sockets aren't readable without root, though the panel now
  falls back to netstat for those, so it shows the same rows the top-level tab
  does.
- **Chart hover readouts.** Hovering a line (or a CPU band) in the Chart view
  spotlights it and shows a small panel with the series, its value at that
  moment, and the time it was sampled. Hovering empty space shows nothing —
  the readout is always for one specific trace. The chart holds still while
  the pointer is over it (marked "Paused") so the sample you're aiming at
  doesn't scroll away, and resumes when you leave.
- **Light mode.** Preferences gains an Appearance control — Auto (default,
  follows System Settings live), Light, or Dark — and the whole app honors
  it, chart included. On a light card the chart palette is adjusted for
  legibility (brightness capped, saturation nudged) so near-white and pale
  traces like Memory and Network stay readable; custom colors get the same
  treatment. The dock icon keeps following System Settings rather than the
  app's override, since it's drawn on the Dock's own material.

### Changed
- The dock menu drops "Open Activity Monitor".

### Fixed
- The connection map stopped refreshing if the main window was closed while it
  was open — it kept drawing a stale sample with no sign it had stopped.
- **Other users' processes now show their real name and icon** in the process
  tabs. Their name came from the kernel's 16-character `p_comm` field with no
  executable path, so long names were cut ("AddressBookSourceSy…") and every
  one of them drew a generic icon; both now come from the executable path,
  which is readable for any process.
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

[Unreleased]: https://github.com/acheris-labs/tracker/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/acheris-labs/tracker/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/acheris-labs/tracker/compare/v0.3.0...v0.3.1
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

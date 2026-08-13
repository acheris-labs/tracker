import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle update controller; reads SUFeedURL / SUPublicEDKey from
    // Info.plist and runs scheduled checks per SUEnableAutomaticChecks /
    // SUScheduledCheckInterval (also in Info.plist).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)
    private var timer: Timer?
    private let cpu = CPUSampler()
    private let gpu = GPUSampler()
    private let battery = BatterySampler()
    private let disk = DiskSampler()
    private let memory = MemorySampler()
    private let processes = ProcessSampler()
    private let network = NetworkSampler()
    private var processTickCount: Int = 0
    private var processIntervalSeconds: Int = 2
    private var renderer: HistoryRenderer!
    private var lastCPU = CPUFrame()
    private var lastGPU: Double = 0
    private var lastBatteryInfo = BatteryInfo(
        percent: 0, watts: 0, isCharging: false, externalConnected: false,
        minutesToFull: nil, minutesToEmpty: nil, capacityWh: 0
    )
    private var lastMemory: Double = 0
    private var lastDiskRead: Double = 0
    private var lastDiskWrite: Double = 0
    private let connectionQueue = DispatchQueue(label: "net.acheris.tracker.netstat",
                                                qos: .utility)
    private var connectionsInFlight = false
    private var lastProcessNames: [pid_t: ProcessOwner] = [:]
    private var prefs: PreferencesWindowController?
    private var chart: ChartWindowController?

    private var dockMenu: NSMenu?
    private var pItem: NSMenuItem?
    private var eItem: NSMenuItem?
    private var gItem: NSMenuItem?
    private var bItem: NSMenuItem?
    private var mItem: NSMenuItem?
    private var dItem: NSMenuItem?
    private var durationSubmenu: NSMenu?

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static let durations: [(label: String, seconds: Int)] = [
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("1 minute",   60),
        ("2 minutes", 120),
        ("3 minutes", 180),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]

    /// Chart window durations — the longer-term picture, up to an hour.
    static let chartDurations: [(label: String, seconds: Int)] = durations + [
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window or the first icon render, so nothing flashes the
        // system appearance when the user has pinned light or dark.
        AppearanceMode.load().apply()
        processIntervalSeconds = max(1, min(60, Self.intDefault("ProcessRefreshSeconds", default: 2)))
        // Dock icon: short "right now" view; chart: longer-term picture.
        // Migrates the old single HistorySeconds key to the dock's.
        let d = UserDefaults.standard
        var dockRaw = d.integer(forKey: "DockHistorySeconds")
        if dockRaw <= 0 { dockRaw = d.integer(forKey: "HistorySeconds") }
        let dockCapacity = dockRaw <= 0 ? 30 : max(15, min(600, dockRaw))
        let chartRaw = d.integer(forKey: "ChartHistorySeconds")
        let chartCapacity = chartRaw <= 0 ? 300 : max(15, min(3600, chartRaw))
        renderer = HistoryRenderer(iconCapacity: dockCapacity,
                                   chartCapacity: chartCapacity,
                                   numP: cpu.numP, numE: cpu.numE,
                                   hasBattery: battery.hasBattery,
                                   colors: ChartColors.load())
        renderer.iconTraces = Self.loadTraces(key: "DockTraces")
        renderer.chartTraces = Self.loadTraces(key: "ChartTraces")
        UserDefaults.standard.set(true, forKey: "MigratedCPUTrace")

        NSLog("topology: P=\(cpu.numP) E=\(cpu.numE), dock=\(dockCapacity)s chart=\(chartCapacity)s")
        _ = cpu.sample()
        NSApp.applicationIconImage = renderer.render()
        NSApp.mainMenu = buildMainMenu()

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // If a window is already up, let AppKit bring it forward. Otherwise
        // open the main window on whichever tab it opens on — clicking the
        // dock icon is "show me the app", not "show me the graphs".
        if !flag { ensureChartWindow() }
        return true
    }

    /// Straight to the map from the dock menu. The chart window owns it, so
    /// that has to exist — but it stays where it was rather than being shoved
    /// in front of whatever you were doing.
    @objc func showConnectionMapFromDock(_ sender: Any?) {
        let hadWindow = chart?.window?.isVisible ?? false
        ensureChartWindow()
        if !hadWindow { chart?.window?.orderOut(nil) }
        NSApp.activate()
        chart?.showConnectionMap(nil)
        pushConnections()
    }

    /// ⌘1…⌘7 — the menu item's tag is the segment index.
    @objc func showTab(_ sender: NSMenuItem) {
        ensureChartWindow()
        chart?.selectTab(index: sender.tag)
        // The Connections tab is the one that needs data pushed at it; the
        // sampler is gated on that tab being on screen.
        if sender.tag == ChartWindowController.ConnectionsIndex.value {
            pushConnections()
        }
    }

    private func ensureChartWindow() {
        let wasVisible = chart?.window?.isVisible ?? false
        if chart == nil {
            chart = ChartWindowController(renderer: renderer,
                                          hasBattery: battery.hasBattery)
            chart?.processList.intervalSeconds = processIntervalSeconds
            chart?.processList.onIntervalChange = { [weak self] s in
                self?.applyProcessInterval(s)
            }
        }
        NSApp.activate()
        chart?.showWindow(nil)
        chart?.window?.makeKeyAndOrderFront(nil)
        chart?.refresh(cpu: lastCPU, gpu: lastGPU, battery: lastBatteryInfo,
                       memory: lastMemory,
                       diskRead: lastDiskRead, diskWrite: lastDiskWrite,
                       netRx: network.totals.rxPerSec, netTx: network.totals.txPerSec,
                       swapUsed: SwapUsage.current().used)
        // Populate processes immediately rather than waiting up to a full
        // refresh interval. Reset the sampler if the window was closed so
        // CPU% / disk / power don't average over the time we were idle.
        if !wasVisible { processes.reset() }
        chart?.processList.setSnapshots(processes.sample())
        pushSystemStats()
        processTickCount = 0
    }

    /// System-wide connections for the Connections tab. netstat is a
    /// subprocess, so it runs off the main thread and only while that tab is
    /// on screen; overlapping samples are dropped rather than queued.
    private func pushConnections() {
        guard let chart, chart.isConnectionsPaneVisible, !connectionsInFlight else { return }
        connectionsInFlight = true
        let names = lastProcessNames
        connectionQueue.async { [weak self] in
            let rows = SystemConnectionSampler.sample()
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionsInFlight = false
                self.chart?.setConnections(rows, processNames: names)
            }
        }
    }

    private func applyProcessInterval(_ seconds: Int) {
        let clamped = max(1, min(60, seconds))
        processIntervalSeconds = clamped
        processTickCount = 0
        UserDefaults.standard.set(clamped, forKey: "ProcessRefreshSeconds")
    }

    /// Standard macOS About panel, styled to match Newt: name, version, and
    /// copyright (`NSHumanReadableCopyright`) come from the bundle; we supply the
    /// MIT license + no-warranty note as the credits blurb. The dock icon is a
    /// live chart (`applicationIconImage` is overwritten every tick), so pass the
    /// static app icon explicitly — otherwise the panel would show the chart.
    @objc private func showAbout() {
        let blurb = "Free software under the MIT License.\n"
            + "Provided \u{201C}as is\u{201D}, without warranty of any kind, express or implied."
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: blurb, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let url = Bundle.main.url(forResource: "Tracker", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            options[.applicationIcon] = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        if dockMenu == nil { dockMenu = buildDockMenu() }
        refreshDockMenu()
        return dockMenu
    }

    private func buildDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let p = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        p.isEnabled = false
        menu.addItem(p)
        self.pItem = p

        let e = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        e.isEnabled = false
        menu.addItem(e)
        self.eItem = e

        if renderer.iconTraces.contains(.gpu) {
            let g = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            g.isEnabled = false
            menu.addItem(g)
            self.gItem = g
        } else {
            self.gItem = nil
        }

        if battery.hasBattery, renderer.iconTraces.contains(.battery) {
            let b = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
            self.bItem = b
        } else {
            self.bItem = nil
        }

        if renderer.iconTraces.contains(.memory) {
            let m = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
            self.mItem = m
        } else {
            self.mItem = nil
        }

        if renderer.iconTraces.contains(.disk) {
            let d = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
            self.dItem = d
        } else {
            self.dItem = nil
        }

        menu.addItem(.separator())

        let durationParent = NSMenuItem(title: "Dock Icon History",
                                        action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for d in Self.durations {
            let item = NSMenuItem(title: d.label,
                                  action: #selector(setDurationFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = d.seconds
            submenu.addItem(item)
        }
        durationParent.submenu = submenu
        menu.addItem(durationParent)
        self.durationSubmenu = submenu

        let prefsItem = NSMenuItem(title: "Preferences…",
                                   action: #selector(showPreferences(_:)),
                                   keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let mapItem = NSMenuItem(title: "Connection Map…",
                                 action: #selector(showConnectionMapFromDock(_:)),
                                 keyEquivalent: "")
        mapItem.target = self
        menu.addItem(mapItem)

        return menu
    }

    private func refreshDockMenu() {
        let pTotal = (lastCPU.pUser + lastCPU.pSys) * 100
        let eTotal = (lastCPU.eUser + lastCPU.eSys) * 100
        pItem?.title = String(format: "P-cores: %.0f%%  (user %.0f / sys %.0f)",
                              pTotal, lastCPU.pUser * 100, lastCPU.pSys * 100)
        eItem?.title = String(format: "E-cores: %.0f%%  (user %.0f / sys %.0f)",
                              eTotal, lastCPU.eUser * 100, lastCPU.eSys * 100)
        gItem?.title = String(format: "GPU: %.0f%%", lastGPU * 100)
        bItem?.title = Self.batteryMenuTitle(lastBatteryInfo)
        mItem?.title = String(format: "Memory: %.0f%%", lastMemory * 100)
        let r = Self.bytesFormatter.string(fromByteCount: Int64(lastDiskRead))
        let w = Self.bytesFormatter.string(fromByteCount: Int64(lastDiskWrite))
        dItem?.title = "Disk: R \(r)/s · W \(w)/s"

        let current = renderer?.iconCapacity ?? 0
        if let submenu = durationSubmenu {
            for item in submenu.items {
                item.state = (item.tag == current) ? .on : .off
            }
        }
    }

    @objc func setDurationFromMenu(_ sender: NSMenuItem) {
        applyDockDuration(sender.tag)
    }

    @objc func showPreferences(_ sender: Any?) {
        if prefs == nil {
            prefs = PreferencesWindowController(
                colors: renderer.colors,
                hasBattery: battery.hasBattery,
                iconTraces: renderer.iconTraces,
                chartTraces: renderer.chartTraces,
                drainThreshold: Self.intDefault("BadgeThresholdWatts", default: 20),
                appearance: AppearanceMode.load(),

                onColorsChange: { [weak self] c in self?.applyColors(c) },
                onTracesChange: { [weak self] surface, traces in
                    self?.applyTraces(surface: surface, traces: traces)
                },
                onThresholdChange: { [weak self] v in self?.applyThreshold(v) },
                onAppearanceChange: { [weak self] m in self?.applyAppearance(m) }
            )
        } else {
            prefs?.sync(colors: renderer.colors)
        }
        NSApp.activate()
        prefs?.showWindow(nil)
        prefs?.window?.makeKeyAndOrderFront(nil)
    }

    private static func boolDefault(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func intDefault(_ key: String, default fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    @objc private func toggleAutoUpdateMenu(_ sender: NSMenuItem) {
        let on = sender.state != .on
        sender.state = on ? .on : .off
        applyAutoUpdate(on)
    }

    private func applyAutoUpdate(_ on: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = on
        // Sparkle also reads SUEnableAutomaticChecks from UserDefaults; the
        // setter above is what's authoritative, but keep the key in sync so
        // it shows the right state outside the app too.
        UserDefaults.standard.set(on, forKey: "SUEnableAutomaticChecks")
    }

    private func applyThreshold(_ v: Int) {
        let clamped = max(1, min(200, v))
        UserDefaults.standard.set(clamped, forKey: "BadgeThresholdWatts")
        // tick() reads the value each second, so it picks up immediately.
    }

    private func updateDockBadge(_ b: BatteryInfo) {
        // Only flag heavy drain — light idle discharge doesn't warrant a
        // big red pill. Threshold (in watts) is configurable; default 20W.
        let threshold = UserDefaults.standard.object(forKey: "BadgeThresholdWatts")
            as? Int ?? 20
        if !b.externalConnected, abs(b.watts) >= Double(threshold) {
            NSApp.dockTile.badgeLabel = String(format: "%.0fw", abs(b.watts))
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private static func batteryMenuTitle(_ b: BatteryInfo) -> String {
        let pct = String(format: "%.0f%%", b.percent * 100)
        let flowing = abs(b.watts) >= 0.1
        if flowing, b.isCharging, let m = b.minutesToFull {
            return "Battery: \(pct)  (+\(String(format: "%.1f", b.watts)) W · full in \(formatMinutes(m)))"
        }
        if flowing, !b.isCharging, let m = b.minutesToEmpty {
            return "Battery: \(pct)  (−\(String(format: "%.1f", abs(b.watts))) W · empty in \(formatMinutes(m)))"
        }
        if flowing {
            let sign = b.isCharging ? "+" : "−"
            return "Battery: \(pct)  (\(sign)\(String(format: "%.1f", abs(b.watts))) W)"
        }
        if b.externalConnected {
            return "Battery: \(pct)  (on AC, holding)"
        }
        return "Battery: \(pct)"
    }

    private static func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private func applyTraces(surface: TraceSurface, traces: Set<ChartTrace>) {
        let arr = traces.map(\.rawValue).sorted()
        switch surface {
        case .dock:
            renderer.iconTraces = traces
            UserDefaults.standard.set(arr, forKey: "DockTraces")
            dockMenu = nil
            NSApp.applicationIconImage = renderer.render()
        case .chart:
            renderer.chartTraces = traces
            UserDefaults.standard.set(arr, forKey: "ChartTraces")
            chart?.chartView.needsDisplay = true
        }
    }

    /// Per-surface trace set, migrating the pre-split ShowX bools the first
    /// time (both surfaces inherit the old single configuration).
    private static func loadTraces(key: String) -> Set<ChartTrace> {
        if let arr = UserDefaults.standard.stringArray(forKey: key) {
            var t = Set(arr.compactMap(ChartTrace.init(rawValue:)))
            // Arrays persisted before CPU became selectable imply it was on;
            // write the migrated array back so the next launch doesn't
            // mistake it for a deliberate CPU-off choice.
            if !arr.contains("cpu"), !UserDefaults.standard.bool(forKey: "MigratedCPUTrace") {
                t.insert(.cpu)
                UserDefaults.standard.set(t.map(\.rawValue).sorted(), forKey: key)
            }
            return t
        }
        var t: Set<ChartTrace> = [.cpu]
        if boolDefault("ShowGPU", default: true) { t.insert(.gpu) }
        if boolDefault("ShowBattery", default: false) { t.insert(.battery) }
        if boolDefault("ShowMemory", default: false) { t.insert(.memory) }
        if boolDefault("ShowDisk", default: false) { t.insert(.disk) }
        if boolDefault("ShowNetwork", default: false) { t.insert(.network) }
        return t
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        mode.apply()
        // Windows re-render themselves off NSApp.appearance; the dock icon is
        // a bitmap we own, so redraw it now (auto mode's system switches get
        // picked up by the next tick).
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyColors(_ c: ChartColors) {
        renderer.colors = c
        c.save()
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyDockDuration(_ seconds: Int) {
        guard seconds > 0 else { return }
        let clamped = max(15, min(600, seconds))
        UserDefaults.standard.set(clamped, forKey: "DockHistorySeconds")
        renderer.resizeIcon(capacity: clamped)
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyChartDuration(_ seconds: Int) {
        guard seconds > 0 else { return }
        let clamped = max(15, min(3600, seconds))
        UserDefaults.standard.set(clamped, forKey: "ChartHistorySeconds")
        renderer.resizeChart(capacity: clamped)
        chart?.chartView.needsDisplay = true
    }

    @objc func setChartDurationFromMenu(_ sender: NSMenuItem) {
        applyChartDuration(sender.tag)
    }

    private func tick() {
        let f = cpu.sample()
        let g = gpu.sample()
        let bi = battery.sample() ?? lastBatteryInfo
        let m = memory.sample()
        let (dr, dw) = disk.sample()
        lastCPU = f
        lastGPU = g
        lastBatteryInfo = bi
        lastMemory = m
        lastDiskRead = dr
        lastDiskWrite = dw
        // Network history needs nettop samples even when the process view
        // isn't open; only worth the (async, ~10 ms) cost when the lines are
        // on. kick() drops overlapping requests itself.
        if renderer.iconTraces.contains(.network) || renderer.chartTraces.contains(.network) {
            network.kick()
        }
        let netTotals = network.totals
        let swap = SwapUsage.current()
        let swapFraction = swap.total > 0 ? swap.used / swap.total : 0
        renderer.append(cpu: f, gpu: g, battery: bi.percent, memory: m,
                        diskRead: dr, diskWrite: dw,
                        netRx: netTotals.rxPerSec, netTx: netTotals.txPerSec,
                        swap: swapFraction)
        NSApp.applicationIconImage = renderer.render()
        updateDockBadge(bi)
        chart?.refresh(cpu: f, gpu: g, battery: bi, memory: m,
                       diskRead: dr, diskWrite: dw,
                       netRx: netTotals.rxPerSec, netTx: netTotals.txPerSec,
                       swapUsed: swap.used)

        // Only pay the per-process sampling cost when someone is looking, and
        // only at the user-chosen interval (default 2s). "Looking" includes the
        // connection map on its own — it outlives the main window, and a map
        // quietly showing a stale sample is worse than showing none.
        if chart?.needsLiveSamples == true {
            pushSystemStats()
            processTickCount += 1
            if processTickCount >= processIntervalSeconds {
                network.kick()   // async; merges whatever sample completed last
                var snaps = processes.sample()
                let sleepPids = SleepAssertions.pids()
                for i in snaps.indices {
                    snaps[i].preventsSleep = sleepPids.contains(snaps[i].pid)
                    guard let n = network.latest[snaps[i].pid] else { continue }
                    snaps[i].netRxBytesPerSec = n.rxPerSec
                    snaps[i].netTxBytesPerSec = n.txPerSec
                    snaps[i].netRxTotal = n.rxTotal
                    snaps[i].netTxTotal = n.txTotal
                    snaps[i].netRxPackets = n.rxPackets
                    snaps[i].netTxPackets = n.txPackets
                }
                chart?.processList.setSnapshots(snaps)
                lastProcessNames = Dictionary(
                    snaps.map { ($0.pid, ProcessOwner(name: $0.name, execPath: $0.execPath,
                                                      user: $0.user)) },
                    uniquingKeysWith: { a, _ in a })
                pushConnections()
                processTickCount = 0
            }
        }
    }

    /// Feed the process view's footer with system-wide CPU / memory / disk
    /// numbers. CPUFrame's per-group fractions are weighted by core counts to
    /// get system-wide user / system percentages.
    private func pushSystemStats() {
        let cores = Double(cpu.numP + cpu.numE)
        let user = cores > 0
            ? (lastCPU.pUser * Double(cpu.numP) + lastCPU.eUser * Double(cpu.numE)) / cores * 100
            : 0
        let sys = cores > 0
            ? (lastCPU.pSys * Double(cpu.numP) + lastCPU.eSys * Double(cpu.numE)) / cores * 100
            : 0
        let b = lastBatteryInfo
        chart?.processList.setSystemStats(.init(
            cpuUserPct: user, cpuSysPct: sys,
            memoryUsedPct: lastMemory * 100,
            diskReadPerSec: lastDiskRead, diskWritePerSec: lastDiskWrite,
            hasBattery: battery.hasBattery,
            batteryPercent: b.percent, batteryWatts: abs(b.watts),
            batteryCharging: b.isCharging, batteryExternal: b.externalConnected,
            batteryMinutesToFull: b.minutesToFull,
            batteryMinutesToEmpty: b.minutesToEmpty,
            batteryCapacityWh: b.capacityWh,
            netRxPerSec: network.totals.rxPerSec,
            netTxPerSec: network.totals.txPerSec,
            swapUsedBytes: SwapUsage.current().used))
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About Tracker",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        appMenu.addItem(updateItem)
        let autoItem = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(toggleAutoUpdateMenu(_:)),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.state = updaterController.updater.automaticallyChecksForUpdates ? .on : .off
        appMenu.addItem(autoItem)
        appMenu.addItem(.separator())
        // One shortcut per tab, in tab order, so ⌘N and the tab strip agree.
        // Activity Monitor numbers its tabs the same way.
        for (i, title) in ChartWindowController.tabTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(showTab(_:)),
                                  keyEquivalent: "\(i + 1)")
            item.target = self
            item.tag = i
            appMenu.addItem(item)
        }
        let findItem = NSMenuItem(
            title: "Filter Processes…",
            action: #selector(ChartWindowController.focusSearch(_:)),
            keyEquivalent: "f"
        )
        appMenu.addItem(findItem)   // nil target: resolves via responder chain
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide Tracker",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        appMenu.addItem(NSMenuItem(
            title: "Quit Tracker",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}

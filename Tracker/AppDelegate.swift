import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private let cpu = CPUSampler()
    private let gpu = GPUSampler()
    private let battery = BatterySampler()
    private let disk = DiskSampler()
    private let memory = MemorySampler()
    private var renderer: HistoryRenderer!
    private var lastCPU = CPUFrame()
    private var lastGPU: Double = 0
    private var lastBatteryInfo = BatteryInfo(
        percent: 0, watts: 0, isCharging: false, externalConnected: false,
        minutesToFull: nil, minutesToEmpty: nil
    )
    private var lastMemory: Double = 0
    private var lastDiskRead: Double = 0
    private var lastDiskWrite: Double = 0
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

    private let durations: [(label: String, seconds: Int)] = [
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("1 minute",   60),
        ("2 minutes", 120),
        ("3 minutes", 180),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let raw = UserDefaults.standard.integer(forKey: "HistorySeconds")
        let capacity = raw <= 0 ? 120 : max(15, min(600, raw))
        renderer = HistoryRenderer(capacity: capacity, numP: cpu.numP, numE: cpu.numE,
                                   hasBattery: battery.hasBattery,
                                   colors: ChartColors.load())
        renderer.showGPU = Self.boolDefault("ShowGPU", default: true)
        renderer.showBattery = Self.boolDefault("ShowBattery", default: false)
        renderer.showMemory = Self.boolDefault("ShowMemory", default: false)
        renderer.showDisk = Self.boolDefault("ShowDisk", default: false)

        NSLog("topology: P=\(cpu.numP) E=\(cpu.numE), history=\(capacity)s")
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
        // If a window is already up, let AppKit bring it forward.
        // Otherwise open the chart window.
        if !flag { showChartWindow(nil) }
        return true
    }

    @objc func showChartWindow(_ sender: Any?) {
        if chart == nil {
            chart = ChartWindowController(renderer: renderer,
                                          hasBattery: battery.hasBattery)
        }
        NSApp.activate()
        chart?.showWindow(nil)
        chart?.window?.makeKeyAndOrderFront(nil)
        chart?.refresh(cpu: lastCPU, gpu: lastGPU, battery: lastBatteryInfo,
                       memory: lastMemory,
                       diskRead: lastDiskRead, diskWrite: lastDiskWrite)
    }

    @objc func openActivityMonitor(_ sender: Any?) {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration())
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

        if renderer.showGPU {
            let g = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            g.isEnabled = false
            menu.addItem(g)
            self.gItem = g
        } else {
            self.gItem = nil
        }

        if battery.hasBattery, renderer.showBattery {
            let b = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
            self.bItem = b
        } else {
            self.bItem = nil
        }

        if renderer.showMemory {
            let m = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
            self.mItem = m
        } else {
            self.mItem = nil
        }

        if renderer.showDisk {
            let d = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            d.isEnabled = false
            menu.addItem(d)
            self.dItem = d
        } else {
            self.dItem = nil
        }

        menu.addItem(.separator())

        let durationParent = NSMenuItem(title: "History duration",
                                        action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for d in durations {
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

        let amItem = NSMenuItem(title: "Open Activity Monitor",
                                action: #selector(openActivityMonitor(_:)),
                                keyEquivalent: "")
        amItem.target = self
        menu.addItem(amItem)

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

        let current = renderer?.capacity ?? 0
        if let submenu = durationSubmenu {
            for item in submenu.items {
                item.state = (item.tag == current) ? .on : .off
            }
        }
    }

    @objc private func setDurationFromMenu(_ sender: NSMenuItem) {
        applyDuration(sender.tag)
    }

    @objc func showPreferences(_ sender: Any?) {
        if prefs == nil {
            prefs = PreferencesWindowController(
                durations: durations,
                currentDuration: renderer.capacity,
                colors: renderer.colors,
                hasBattery: battery.hasBattery,
                showGPU: renderer.showGPU,
                showBattery: renderer.showBattery,
                showMemory: renderer.showMemory,
                showDisk: renderer.showDisk,
                drainThreshold: Self.intDefault("BadgeThresholdWatts", default: 20),
                onDurationChange: { [weak self] s in self?.applyDuration(s) },
                onColorsChange: { [weak self] c in self?.applyColors(c) },
                onShowGPUChange: { [weak self] b in self?.applyShowGPU(b) },
                onShowBatteryChange: { [weak self] b in self?.applyShowBattery(b) },
                onShowMemoryChange: { [weak self] b in self?.applyShowMemory(b) },
                onShowDiskChange: { [weak self] b in self?.applyShowDisk(b) },
                onThresholdChange: { [weak self] v in self?.applyThreshold(v) }
            )
        } else {
            prefs?.sync(currentDuration: renderer.capacity)
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

    private func applyShowGPU(_ on: Bool) {
        renderer.showGPU = on
        UserDefaults.standard.set(on, forKey: "ShowGPU")
        dockMenu = nil  // rebuild on next open
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyShowBattery(_ on: Bool) {
        renderer.showBattery = on
        UserDefaults.standard.set(on, forKey: "ShowBattery")
        dockMenu = nil
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyShowMemory(_ on: Bool) {
        renderer.showMemory = on
        UserDefaults.standard.set(on, forKey: "ShowMemory")
        dockMenu = nil
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyShowDisk(_ on: Bool) {
        renderer.showDisk = on
        UserDefaults.standard.set(on, forKey: "ShowDisk")
        dockMenu = nil
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyColors(_ c: ChartColors) {
        renderer.colors = c
        c.save()
        NSApp.applicationIconImage = renderer.render()
    }

    private func applyDuration(_ seconds: Int) {
        guard seconds > 0 else { return }
        let clamped = max(15, min(600, seconds))
        UserDefaults.standard.set(clamped, forKey: "HistorySeconds")
        renderer.resize(capacity: clamped)
        NSApp.applicationIconImage = renderer.render()
        prefs?.sync(currentDuration: clamped)
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
        renderer.append(cpu: f, gpu: g, battery: bi.percent, memory: m,
                        diskRead: dr, diskWrite: dw)
        NSApp.applicationIconImage = renderer.render()
        updateDockBadge(bi)
        chart?.refresh(cpu: f, gpu: g, battery: bi, memory: m,
                       diskRead: dr, diskWrite: dw)
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About Tracker",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        let chartItem = NSMenuItem(
            title: "Show Chart",
            action: #selector(showChartWindow(_:)),
            keyEquivalent: "0"
        )
        chartItem.target = self
        appMenu.addItem(chartItem)
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
        return main
    }
}

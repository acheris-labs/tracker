import AppKit

// MARK: - Tab view with per-tab right-click menus

final class RightClickableTabView: NSTabView {
    /// Returns the context menu to show when `item` is right-clicked, or nil
    /// to fall through to default behavior.
    var contextMenuProvider: ((NSTabViewItem) -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = tabViewItem(at: point),
           let menu = contextMenuProvider?(item) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }
}

// MARK: - Chart drawing view

final class ChartView: NSView {
    weak var renderer: HistoryRenderer?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // The blown-up chart uses smoothed splines / stacked areas; the dock
        // icon keeps the crisp bars (renderer.render()).
        renderer?.draw(in: bounds, smoothed: true)
    }
}

// MARK: - Legend chip

/// "● Name              42.0%" — a single legend row.
final class LegendChip: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(name: String, color: NSColor) {
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 5

        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = .secondaryLabelColor

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right

        let stack = NSStackView(views: [dot, nameLabel, valueLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            nameLabel.widthAnchor.constraint(equalToConstant: 72),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setValue(_ s: String)  { valueLabel.stringValue = s }
    func setColor(_ c: NSColor) { dot.layer?.backgroundColor = c.cgColor }
}

// MARK: - Window

final class ChartWindowController: NSWindowController, NSWindowDelegate {
    let chartView: ChartView
    let processList = ProcessListView()
    private let tabs = RightClickableTabView()
    private let selector = NSSegmentedControl(
        labels: ["Chart", "CPU", "Memory", "Energy", "Disk"],
        trackingMode: .selectOne, target: nil, action: nil)
    private weak var renderer: HistoryRenderer?
    private let hasBattery: Bool

    private var leftLabels: [NSTextField] = []
    private var rightLabels: [NSTextField] = []

    private var pSysChip: LegendChip!
    private var eSysChip: LegendChip!
    private var pUserChip: LegendChip!
    private var eUserChip: LegendChip!
    private var gpuChip: LegendChip!
    private var memoryChip: LegendChip!
    private var batteryChip: LegendChip?
    private var powerChip: LegendChip?
    private var timeChip: LegendChip?
    private var readChip: LegendChip!
    private var writeChip: LegendChip!

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.formattingContext = .standalone
        return f
    }()

    init(renderer: HistoryRenderer, hasBattery: Bool) {
        self.renderer = renderer
        self.hasBattery = hasBattery
        let v = ChartView()
        v.renderer = renderer
        self.chartView = v

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Tracker"
        win.titleVisibility = .visible
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 800, height: 360)
        win.center()

        super.init(window: win)
        win.delegate = self
        buildContent(window: win)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func refresh(cpu: CPUFrame, gpu: Double, battery: BatteryInfo,
                 memory: Double, diskRead: Double, diskWrite: Double) {
        chartView.needsDisplay = true
        updateChips(cpu: cpu, gpu: gpu, battery: battery,
                    memory: memory, diskRead: diskRead, diskWrite: diskWrite)
        updateRightAxis()
        applyCurrentColors()
    }

    // MARK: Layout

    private func buildContent(window: NSWindow) {
        // Vibrant background filling the window (incl. behind titlebar).
        let bg = NSVisualEffectView()
        bg.material = .windowBackground
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState

        // Axis labels
        for s in ["100%", "50%", "0%"] {
            leftLabels.append(Self.axisLabel(s, alignment: .right))
        }
        for _ in 0..<3 {
            rightLabels.append(Self.axisLabel("", alignment: .left))
        }

        // Chart card with rounded corners + subtle border.
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartView.wantsLayer = true
        chartView.layer?.cornerRadius = 10
        chartView.layer?.masksToBounds = true
        chartView.layer?.borderWidth = 0.5
        chartView.layer?.borderColor = NSColor.separatorColor.cgColor

        for l in leftLabels  { bg.addSubview(l) }
        for l in rightLabels { bg.addSubview(l) }
        bg.addSubview(chartView)

        // Section headers + legend chips
        let c0 = NSColor.gray
        pSysChip   = LegendChip(name: "P-sys",  color: c0)
        eSysChip   = LegendChip(name: "E-sys",  color: c0)
        pUserChip  = LegendChip(name: "P-user", color: c0)
        eUserChip  = LegendChip(name: "E-user", color: c0)
        gpuChip    = LegendChip(name: "GPU",    color: c0)
        memoryChip = LegendChip(name: "Memory", color: c0)
        if hasBattery {
            batteryChip = LegendChip(name: "Battery", color: c0)
            // Power and Time have no chart line; clear dot keeps alignment.
            powerChip = LegendChip(name: "Power", color: .clear)
            timeChip  = LegendChip(name: "Time",  color: .clear)
        }
        readChip   = LegendChip(name: "Read",  color: c0)
        writeChip  = LegendChip(name: "Write", color: c0)

        let cpuCol  = Self.legendColumn(title: "Processor",
                                        chips: [pSysChip, eSysChip, pUserChip, eUserChip])
        var sysChips: [LegendChip] = [gpuChip, memoryChip]
        if let b = batteryChip { sysChips.append(b) }
        if let p = powerChip   { sysChips.append(p) }
        if let t = timeChip    { sysChips.append(t) }
        let sysCol  = Self.legendColumn(title: "System", chips: sysChips)
        let diskCol = Self.legendColumn(title: "Storage", chips: [readChip, writeChip])

        let infoStrip = NSStackView(views: [cpuCol, sysCol, diskCol])
        infoStrip.orientation = .horizontal
        infoStrip.alignment = .top
        infoStrip.distribution = .equalSpacing
        infoStrip.spacing = 32
        infoStrip.translatesAutoresizingMaskIntoConstraints = false

        // Hairline separator above the info strip
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(divider)
        bg.addSubview(infoStrip)

        let axisW: CGFloat = 56
        let pad: CGFloat = 16

        NSLayoutConstraint.activate([
            // Chart card
            chartView.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: pad + axisW + 6),
            chartView.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -(pad + axisW + 6)),
            chartView.topAnchor.constraint(equalTo: bg.topAnchor, constant: pad),
            chartView.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -pad),

            // Left axis tick labels
            leftLabels[0].topAnchor.constraint(equalTo: chartView.topAnchor),
            leftLabels[1].centerYAnchor.constraint(equalTo: chartView.centerYAnchor),
            leftLabels[2].bottomAnchor.constraint(equalTo: chartView.bottomAnchor),

            // Right axis tick labels
            rightLabels[0].topAnchor.constraint(equalTo: chartView.topAnchor),
            rightLabels[1].centerYAnchor.constraint(equalTo: chartView.centerYAnchor),
            rightLabels[2].bottomAnchor.constraint(equalTo: chartView.bottomAnchor),

            // Divider + info strip
            divider.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: pad),
            divider.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -pad),
            divider.heightAnchor.constraint(equalToConstant: 1),

            infoStrip.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: pad),
            infoStrip.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -pad),
            infoStrip.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: pad),
            infoStrip.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -pad),
        ])

        for l in leftLabels {
            NSLayoutConstraint.activate([
                l.trailingAnchor.constraint(equalTo: chartView.leadingAnchor, constant: -6),
                l.widthAnchor.constraint(equalToConstant: axisW),
            ])
        }
        for l in rightLabels {
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: chartView.trailingAnchor, constant: 6),
                l.widthAnchor.constraint(equalToConstant: axisW),
            ])
        }

        // Two tabless container views (chart, process list) switched by a single
        // top selector: Chart · CPU · Memory · Energy · Disk. The process
        // categories are now siblings of Chart rather than nested under it.
        let chartTab = NSTabViewItem(identifier: "chart")
        chartTab.view = bg

        let procTab = NSTabViewItem(identifier: "processes")
        processList.translatesAutoresizingMaskIntoConstraints = false
        let procContainer = NSView()
        procContainer.addSubview(processList)
        NSLayoutConstraint.activate([
            processList.topAnchor.constraint(equalTo: procContainer.topAnchor, constant: 4),
            processList.bottomAnchor.constraint(equalTo: procContainer.bottomAnchor, constant: -4),
            processList.leadingAnchor.constraint(equalTo: procContainer.leadingAnchor, constant: 4),
            processList.trailingAnchor.constraint(equalTo: procContainer.trailingAnchor, constant: -4),
        ])
        procTab.view = procContainer

        tabs.tabViewType = .noTabsNoBorder
        tabs.addTabViewItem(chartTab)
        tabs.addTabViewItem(procTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        selector.segmentStyle = .texturedRounded
        selector.target = self
        selector.action = #selector(selectorChanged(_:))
        selector.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(selector)
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            selector.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabs.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 6),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        applySelection(0)

        applyCurrentColors()
        updateRightAxis()
    }

    // Menu-driven selection (⌘1 / ⌘2 from the app's Window menu).
    @objc func selectChartTab(_ sender: Any?)     { applySelection(0) }   // Chart
    @objc func selectProcessesTab(_ sender: Any?) { applySelection(1) }   // CPU category

    @objc private func selectorChanged(_ s: NSSegmentedControl) {
        applySelection(s.selectedSegment)
    }

    /// 0 = Chart; 1…4 = process categories (CPU/Memory/Energy/Disk).
    private func applySelection(_ index: Int) {
        let i = max(0, index)
        selector.selectedSegment = i
        if i == 0 {
            tabs.selectTabViewItem(at: 0)
        } else {
            tabs.selectTabViewItem(at: 1)
            if let t = ProcessListView.Tab(rawValue: i - 1) { processList.showCategory(t) }
        }
    }

    private static func axisLabel(_ s: String, alignment: NSTextAlignment) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        t.textColor = .tertiaryLabelColor
        t.alignment = alignment
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }

    private static func sectionHeader(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s.uppercased())
        t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        t.textColor = .secondaryLabelColor
        // Slight letter-spacing for Apple-style "section caps"
        t.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        return t
    }

    private static func legendColumn(title: String, chips: [LegendChip]) -> NSView {
        let header = sectionHeader(title)
        let stack = NSStackView(views: [header] + chips)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: header)
        return stack
    }

    // MARK: Updates

    private func applyCurrentColors() {
        guard let c = renderer?.colors else { return }
        pSysChip.setColor(c.pSys)
        eSysChip.setColor(c.eSys)
        pUserChip.setColor(c.pUser)
        eUserChip.setColor(c.eUser)
        gpuChip.setColor(c.gpu)
        memoryChip.setColor(c.memory)
        // Battery chip has no chart line; the corner indicator handles
        // the color semantics. A clear dot keeps column alignment.
        batteryChip?.setColor(.clear)
        readChip.setColor(c.diskRead)
        writeChip.setColor(c.diskWrite)
    }

    private func updateRightAxis() {
        guard let r = renderer else { return }
        let max = r.diskScaleMax()
        let mid = max / 2
        rightLabels[0].stringValue = "\(Self.bytesFormatter.string(fromByteCount: Int64(max)))/s"
        rightLabels[1].stringValue = "\(Self.bytesFormatter.string(fromByteCount: Int64(mid)))/s"
        rightLabels[2].stringValue = "0"
    }

    private func updateChips(cpu: CPUFrame, gpu: Double, battery: BatteryInfo,
                             memory: Double, diskRead: Double, diskWrite: Double) {
        pSysChip.setValue(pct(cpu.pSys))
        eSysChip.setValue(pct(cpu.eSys))
        pUserChip.setValue(pct(cpu.pUser))
        eUserChip.setValue(pct(cpu.eUser))
        gpuChip.setValue(pct(gpu))
        memoryChip.setValue(pct(memory))
        batteryChip?.setValue(pct(battery.percent))
        powerChip?.setValue(formatPower(watts: battery.watts, onAC: battery.externalConnected))
        timeChip?.setValue(formatBatteryTime(battery))
        readChip.setValue("\(Self.bytesFormatter.string(fromByteCount: Int64(diskRead)))/s")
        writeChip.setValue("\(Self.bytesFormatter.string(fromByteCount: Int64(diskWrite)))/s")
    }

    private func formatPower(watts w: Double, onAC: Bool) -> String {
        if abs(w) >= 0.1 {
            let sign = w >= 0 ? "+" : "−"
            return String(format: "%@%.1f W", sign, abs(w))
        }
        return onAC ? "on AC" : "idle"
    }

    private func formatBatteryTime(_ b: BatteryInfo) -> String {
        if b.isCharging, let m = b.minutesToFull {
            return "full in \(Self.formatMinutes(m))"
        }
        if !b.externalConnected, let m = b.minutesToEmpty {
            return "empty in \(Self.formatMinutes(m))"
        }
        if b.externalConnected { return "stable" }
        return "—"
    }

    private static func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private func pct(_ v: Double) -> String {
        String(format: "%5.1f%%", v * 100)
    }
}

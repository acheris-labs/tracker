import AppKit

extension NSToolbarItem.Identifier {
    static let quitProcess = NSToolbarItem.Identifier("QuitProcess")
    static let inspect     = NSToolbarItem.Identifier("Inspect")
    static let actions     = NSToolbarItem.Identifier("Actions")
    static let tabSelector = NSToolbarItem.Identifier("TabSelector")
    static let search      = NSToolbarItem.Identifier("Search")
}

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
        // icon keeps the crisp bars (renderer.render()). The card's background
        // is the system text background so it matches the process tables.
        renderer?.draw(in: bounds, smoothed: true, light: effectiveAppearance.isLight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
        needsDisplay = true
    }

    /// See FooterPane: the border is a resolved CGColor snapshot, so it has to
    /// be re-taken whenever the appearance changes.
    func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
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

        // Same type as the process tabs' footer grids (11pt label /
        // 11pt monospaced-digit value), so the panes read as one family.
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 11, weight: .regular)
        nameLabel.textColor = .labelColor

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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

    /// Legend hover: fires true on enter, false on exit.
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    func setValue(_ s: String)  { valueLabel.stringValue = s }
    func setColor(_ c: NSColor) { dot.layer?.backgroundColor = c.cgColor }
}

// MARK: - Window

final class ChartWindowController: NSWindowController, NSWindowDelegate,
                                   NSToolbarDelegate, NSMenuDelegate {
    let chartView: ChartView
    let processList = ProcessListView()
    private let tabs = RightClickableTabView()
    private let selector = NSSegmentedControl(
        labels: ["Chart", "CPU", "Memory", "Energy", "Disk", "Network"],
        trackingMode: .selectOne, target: nil, action: nil)
    private weak var renderer: HistoryRenderer?
    private let hasBattery: Bool

    // Toolbar items, kept so applySelection can enable/disable them per tab.
    private var quitItem: NSToolbarItem?
    private var inspectItem: NSToolbarItem?
    private var actionsItem: NSMenuToolbarItem?
    private var searchItem: NSSearchToolbarItem?

    private var leftLabels: [NSTextField] = []
    private var rightLabels: [NSTextField] = []

    private var pSysChip: LegendChip!
    private var eSysChip: LegendChip!
    private var pUserChip: LegendChip!
    private var eUserChip: LegendChip!
    private var gpuChip: LegendChip!
    private var memoryChip: LegendChip!
    private var swapChip: LegendChip!
    private var batteryChip: LegendChip?
    private var powerChip: LegendChip?
    private var timeChip: LegendChip?
    private var readChip: LegendChip!
    private var writeChip: LegendChip!
    private var netRxChip: LegendChip!
    private var netTxChip: LegendChip!

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
        // Off: the edge-to-edge process table would fight drags; the titlebar
        // remains the drag handle, as in Activity Monitor.
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 800, height: 360)
        win.center()

        super.init(window: win)
        // Remember size/position across launches (restores over center()).
        // Must be configured on the CONTROLLER: NSWindowController cascades
        // windows by default, which silently defeats the window-level
        // setFrameAutosaveName.
        shouldCascadeWindows = false
        windowFrameAutosaveName = "ChartWindow"
        win.delegate = self
        buildContent(window: win)
        buildToolbar(window: win)
    }

    /// ⌘F from the main menu — focuses the toolbar search on process tabs.
    @objc func focusSearch(_ sender: Any?) {
        guard selector.selectedSegment > 0 else { NSSound.beep(); return }
        searchItem?.beginSearchInteraction()
    }

    /// Activity-Monitor-style unified toolbar: quit/inspect/… at the leading
    /// edge next to the title, the tab selector centered, search trailing.
    private func buildToolbar(window win: NSWindow) {
        let toolbar = NSToolbar(identifier: "TrackerMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.tabSelector]
        win.toolbarStyle = .unified
        win.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func refresh(cpu: CPUFrame, gpu: Double, battery: BatteryInfo,
                 memory: Double, diskRead: Double, diskWrite: Double,
                 netRx: Double = 0, netTx: Double = 0, swapUsed: Double = 0) {
        chartView.needsDisplay = true
        updateChips(cpu: cpu, gpu: gpu, battery: battery,
                    memory: memory, diskRead: diskRead, diskWrite: diskWrite,
                    netRx: netRx, netTx: netTx, swapUsed: swapUsed)
        updateRightAxis()
        applyCurrentColors()
    }

    // MARK: Layout

    private func buildContent(window: NSWindow) {
        // Transparent panel — the window background shows through, matching
        // the process tabs' system-standard look. The chart card itself keeps
        // its rounded border and draws a system background.
        let bg = NSView()

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
        chartView.applyBorderColor()

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
        swapChip   = LegendChip(name: "Swap",   color: c0)
        if hasBattery {
            batteryChip = LegendChip(name: "Battery", color: c0)
            // Power and Time have no chart line; clear dot keeps alignment.
            powerChip = LegendChip(name: "Power", color: .clear)
            timeChip  = LegendChip(name: "Time",  color: .clear)
        }
        readChip   = LegendChip(name: "Read",  color: c0)
        writeChip  = LegendChip(name: "Write", color: c0)
        netRxChip  = LegendChip(name: "Rcvd",  color: c0)
        netTxChip  = LegendChip(name: "Sent",  color: c0)

        // Legend hover → highlight that series in the chart, dim the rest.
        func hover(_ chip: LegendChip?, _ series: ChartSeries) {
            chip?.onHover = { [weak self] inside in
                guard let self, let r = self.renderer else { return }
                if inside {
                    r.highlightedSeries = series
                } else if r.highlightedSeries == series {
                    r.highlightedSeries = nil
                }
                self.chartView.needsDisplay = true
            }
        }
        hover(pSysChip, .pSys)
        hover(eSysChip, .eSys)
        hover(pUserChip, .pUser)
        hover(eUserChip, .eUser)
        hover(gpuChip, .gpu)
        hover(batteryChip, .battery)
        hover(memoryChip, .memory)
        hover(swapChip, .swap)
        hover(readChip, .diskRead)
        hover(writeChip, .diskWrite)
        hover(netRxChip, .netRx)
        hover(netTxChip, .netTx)

        let cpuCol  = Self.legendColumn(title: "Processor",
                                        chips: [pSysChip, eSysChip, pUserChip, eUserChip])
        var sysChips: [LegendChip] = [gpuChip, memoryChip, swapChip]
        if let b = batteryChip { sysChips.append(b) }
        if let p = powerChip   { sysChips.append(p) }
        if let t = timeChip    { sysChips.append(t) }
        let sysCol  = Self.legendColumn(title: "System", chips: sysChips)
        let diskCol = Self.legendColumn(title: "Storage", chips: [readChip, writeChip])
        let netCol = Self.legendColumn(title: "Network",
                                       chips: [netRxChip, netTxChip])

        // Centered boxed panes, same rhythm as the process tabs' footers.
        let infoStrip = NSStackView(views: [cpuCol, sysCol, diskCol, netCol])
        infoStrip.orientation = .horizontal
        infoStrip.alignment = .top
        infoStrip.spacing = 12
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

            infoStrip.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            infoStrip.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: pad),
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
        bg.translatesAutoresizingMaskIntoConstraints = false
        let chartContainer = NSView()
        chartContainer.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: chartContainer.topAnchor, constant: 4),
            bg.bottomAnchor.constraint(equalTo: chartContainer.bottomAnchor, constant: -4),
            bg.leadingAnchor.constraint(equalTo: chartContainer.leadingAnchor, constant: 4),
            bg.trailingAnchor.constraint(equalTo: chartContainer.trailingAnchor, constant: -4),
        ])
        chartTab.view = chartContainer

        // Process tabs run edge to edge, like Activity Monitor.
        let procTab = NSTabViewItem(identifier: "processes")
        processList.translatesAutoresizingMaskIntoConstraints = false
        let procContainer = NSView()
        procContainer.addSubview(processList)
        NSLayoutConstraint.activate([
            processList.topAnchor.constraint(equalTo: procContainer.topAnchor),
            processList.bottomAnchor.constraint(equalTo: procContainer.bottomAnchor),
            processList.leadingAnchor.constraint(equalTo: procContainer.leadingAnchor),
            processList.trailingAnchor.constraint(equalTo: procContainer.trailingAnchor),
        ])
        procTab.view = procContainer

        tabs.tabViewType = .noTabsNoBorder
        tabs.addTabViewItem(chartTab)
        tabs.addTabViewItem(procTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        // Lives in the unified toolbar (centered), not in the content.
        selector.segmentStyle = .automatic
        selector.target = self
        selector.action = #selector(selectorChanged(_:))

        let root = NSView()
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        applySelection(0)

        applyCurrentColors()
        updateRightAxis()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.quitProcess, .inspect, .actions, .flexibleSpace, .tabSelector,
         .flexibleSpace, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let onProcess = selector.selectedSegment > 0
        switch id {
        case .quitProcess:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "xmark.circle",
                                 accessibilityDescription: "Quit selected process")
            item.label = "Quit"
            item.toolTip = "Quit the selected process"
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = onProcess
            if #available(macOS 15.0, *) { item.isHidden = !onProcess }
            item.target = processList
            item.action = #selector(ProcessListView.quitSelected)
            quitItem = item
            return item
        case .inspect:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "info.circle",
                                 accessibilityDescription: "Inspect selected process")
            item.label = "Inspect"
            item.toolTip = "Inspect the selected process"
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = onProcess
            if #available(macOS 15.0, *) { item.isHidden = !onProcess }
            item.target = processList
            item.action = #selector(ProcessListView.inspectSelected)
            inspectItem = item
            return item
        case .actions:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle",
                                 accessibilityDescription: "Actions")
            item.label = "Actions"
            item.autovalidates = false
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            actionsItem = item
            return item
        case .tabSelector:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = selector
            item.label = "View"
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.preferredWidthForSearchField = 180
            item.resignsFirstResponderWithCancel = true
            item.searchField.placeholderString = "Search"
            item.searchField.isEnabled = onProcess
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchItem = item
            return item
        default:
            return nil
        }
    }

    /// The toolbar inserts a copy of the item the delegate returns, so wiring
    /// done in itemForItemIdentifier can end up on the wrong instance — this
    /// notification hands us the item actually going into the toolbar.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem else { return }
        switch item.itemIdentifier {
        case .search:
            guard let s = item as? NSSearchToolbarItem else { return }
            s.searchField.target = self
            s.searchField.action = #selector(searchChanged(_:))
            searchItem = s
        case .quitProcess: quitItem = item
        case .inspect:     inspectItem = item
        case .actions:     actionsItem = item as? NSMenuToolbarItem
        default: break
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        processList.setSearch(sender.stringValue)
    }

    // NSMenuDelegate — rebuild the "…" menu on open so the interval checkmark
    // and column toggles always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === actionsItem?.menu else { return }
        menu.removeAllItems()
        let onProcess = selector.selectedSegment > 0

        // The toolbar's menu button is pull-down-style: it consumes the first
        // item as its own face, so give it a hidden placeholder to eat.
        let placeholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        placeholder.isHidden = true
        menu.addItem(placeholder)

        let freq = NSMenuItem(title: "Update Frequency", action: nil, keyEquivalent: "")
        let freqMenu = NSMenu()
        freqMenu.autoenablesItems = false
        for s in ProcessListView.intervalOptions {
            let mi = NSMenuItem(title: "\(s) s", action: #selector(intervalChosen(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = s
            mi.state = (s == processList.intervalSeconds) ? .on : .off
            freqMenu.addItem(mi)
        }
        freq.submenu = freqMenu
        menu.addItem(freq)

        // Scope, like AM's View menu.
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        viewMenu.autoenablesItems = false
        for scope in ProcessListView.Scope.allCases {
            let mi = NSMenuItem(title: scope.label, action: #selector(scopeChosen(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = scope.rawValue
            mi.state = (scope == processList.scope) ? .on : .off
            mi.isEnabled = onProcess
            viewMenu.addItem(mi)
        }
        view.submenu = viewMenu
        view.isEnabled = onProcess
        menu.addItem(view)

        // Chart history window — meaningful on every tab (drives the dock
        // icon too), handled by the app delegate via the responder chain.
        let hist = NSMenuItem(title: "Chart History", action: nil, keyEquivalent: "")
        let histMenu = NSMenu()
        histMenu.autoenablesItems = false
        let current = renderer?.chartCapacity ?? 0
        for d in AppDelegate.chartDurations {
            let mi = NSMenuItem(title: d.label,
                                action: #selector(AppDelegate.setChartDurationFromMenu(_:)),
                                keyEquivalent: "")
            mi.tag = d.seconds
            mi.state = (d.seconds == current) ? .on : .off
            histMenu.addItem(mi)   // nil target → responder chain → app delegate
        }
        hist.submenu = histMenu
        menu.addItem(hist)

        let cols = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        cols.submenu = processList.columnSelectorMenu()
        cols.isEnabled = onProcess
        menu.addItem(cols)

        // Destructive action last.
        menu.addItem(.separator())
        let force = NSMenuItem(title: "Force Quit Process…",
                               action: #selector(ProcessListView.forceQuitSelected),
                               keyEquivalent: "")
        force.target = processList
        force.isEnabled = onProcess
        menu.addItem(force)
    }

    @objc private func intervalChosen(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Int else { return }
        processList.applyInterval(s)
    }

    @objc private func scopeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let scope = ProcessListView.Scope(rawValue: raw) else { return }
        processList.applyScope(scope)
        if selector.selectedSegment > 0 { window?.subtitle = scope.label }
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
        let onProcess = i > 0
        if onProcess {
            tabs.selectTabViewItem(at: 1)
            if let t = ProcessListView.Tab(rawValue: i - 1) { processList.showCategory(t) }
        } else {
            tabs.selectTabViewItem(at: 0)
        }
        // AM-style subtitle under the window title on the process tabs.
        window?.subtitle = onProcess ? processList.scope.label : ""
        // Process-only toolbar items hide on the Chart tab (macOS 15+;
        // merely disabled on 14, where NSToolbarItem.isHidden doesn't exist).
        quitItem?.isEnabled = onProcess
        inspectItem?.isEnabled = onProcess
        if #available(macOS 15.0, *) {
            quitItem?.isHidden = !onProcess
            inspectItem?.isHidden = !onProcess
        }
        if let search = searchItem {
            search.searchField.isEnabled = onProcess
            if !onProcess { search.endSearchInteraction() }
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
        let t = NSTextField(labelWithString: "")
        // Small caps with letter-spacing, matching the footer panes' captions.
        // Centering must live in the attributed string's paragraph style — a
        // field-level alignment is overridden by the attributed value.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        t.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
                .paragraphStyle: style,
            ])
        return t
    }

    /// A legend section as a bordered pane matching the process tabs' footer:
    /// centered small-caps caption over a hairline, then the chip rows with
    /// hairline separators between them.
    private static func legendColumn(title: String, chips: [LegendChip]) -> NSView {
        // Wrapper centers the caption regardless of how the stack stretches it.
        let header = sectionHeader(title)
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerWrap = NSView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(header)
        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: headerWrap.centerXAnchor),
            header.topAnchor.constraint(equalTo: headerWrap.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor),
        ])
        let headerSep = NSBox()
        headerSep.boxType = .separator
        var views: [NSView] = [headerWrap, headerSep]
        for (i, chip) in chips.enumerated() {
            views.append(chip)
            if i < chips.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                views.append(sep)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 3
        stack.setCustomSpacing(4, after: headerWrap)
        return FooterPane(content: stack, minWidth: 210, height: nil)
    }

    // MARK: Updates

    private func applyCurrentColors() {
        guard let c = renderer?.colors else { return }
        // The dots must match the lines, which are appearance-adjusted; the
        // layer-backed dots hold static CGColors, so this runs every refresh.
        let light = (window?.effectiveAppearance ?? NSApp.effectiveAppearance).isLight
        func dot(_ chip: LegendChip?, _ color: NSColor) {
            chip?.setColor(color.onSurface(light: light))
        }
        dot(pSysChip, c.pSys)
        dot(eSysChip, c.eSys)
        dot(pUserChip, c.pUser)
        dot(eUserChip, c.eUser)
        dot(gpuChip, c.gpu)
        dot(memoryChip, c.memory)
        dot(swapChip, c.swap)
        dot(batteryChip, c.battery)
        dot(readChip, c.diskRead)
        dot(writeChip, c.diskWrite)
        dot(netRxChip, c.netRx)
        dot(netTxChip, c.netTx)
    }

    private func updateRightAxis() {
        guard let r = renderer else { return }
        // Shared LOG bytes/sec axis for disk + network. The mid label is the
        // value at half height — the geometric mean of the scale's ends —
        // which is also what tells the reader the axis is logarithmic.
        let max = r.byteScaleMax()
        let mid = (HistoryRenderer.byteScaleMinRate * max).squareRoot()
        rightLabels[0].stringValue = "\(Self.bytesFormatter.string(fromByteCount: Int64(max)))/s"
        rightLabels[1].stringValue = "\(Self.bytesFormatter.string(fromByteCount: Int64(mid)))/s"
        rightLabels[2].stringValue = "0"
    }

    private func updateChips(cpu: CPUFrame, gpu: Double, battery: BatteryInfo,
                             memory: Double, diskRead: Double, diskWrite: Double,
                             netRx: Double, netTx: Double, swapUsed: Double) {
        pSysChip.setValue(pct(cpu.pSys))
        eSysChip.setValue(pct(cpu.eSys))
        pUserChip.setValue(pct(cpu.pUser))
        eUserChip.setValue(pct(cpu.eUser))
        gpuChip.setValue(pct(gpu))
        memoryChip.setValue(pct(memory))
        swapChip.setValue(Self.bytesFormatter.string(fromByteCount: Int64(swapUsed)))
        batteryChip?.setValue(pct(battery.percent))
        powerChip?.setValue(formatPower(watts: battery.watts, onAC: battery.externalConnected))
        timeChip?.setValue(formatBatteryTime(battery))
        readChip.setValue("\(Self.bytesFormatter.string(fromByteCount: Int64(diskRead)))/s")
        writeChip.setValue("\(Self.bytesFormatter.string(fromByteCount: Int64(diskWrite)))/s")
        netRxChip.setValue("\(Self.bytesFormatter.string(fromByteCount: Int64(netRx)))/s")
        netTxChip.setValue("\(Self.bytesFormatter.string(fromByteCount: Int64(netTx)))/s")
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

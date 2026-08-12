import AppKit
import UniformTypeIdentifiers

final class ProcessListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var allRows: [ProcessSnapshot] = []   // unfiltered, from the sampler
    private var rows: [ProcessSnapshot] = []      // filtered + sorted, displayed
    private var searchText = ""
    private var sortKey: SortKey = .cpu
    private var sortAscending = false
    /// As declared in buildTable(); selectTab() applies the user's persisted
    /// widths for the tab, falling back to these.
    private var defaultWidths: [String: CGFloat] = [:]
    /// True while the user has dragged the Process Name divider on this tab —
    /// suspends auto-fill so their width sticks (cleared on tab switch).
    private var nameManuallySized = false
    /// Reentrancy guard: programmatic width changes must not count as manual.
    private var isFittingColumns = false
    private static func columnWidthsKey(for tab: Tab) -> String {
        "ProcessColumnWidths.\(tab.rawValue)"
    }

    /// Called when the user changes the refresh interval (seconds).
    var onIntervalChange: ((Int) -> Void)?

    /// In seconds. Persisted by the caller; the toolbar's "…" menu drives it.
    var intervalSeconds: Int = 2

    static let intervalOptions: [Int] = [1, 2, 3, 5, 10]
    // Per-tab hidden-column overrides ("ProcessColumnsHidden.<tab>"): user
    // toggles from the Columns menu survive tab switches and relaunches.
    private static func hiddenColumnsKey(for tab: Tab) -> String {
        "ProcessColumnsHidden.\(tab.rawValue)"
    }

    enum SortKey: String {
        case cpu, name, memory, threads, read, write, power, pid, user
        case cpuTime, idle, kind, drain, energy, batt, rtotal, wtotal
        case netrx, nettx, netrxtotal, nettxtotal
        case netrxpkts, nettxpkts, sleep
    }

    /// Activity-Monitor-style category tabs: each selects a column set, a
    /// default sort, and the footer summary.
    enum Tab: Int, CaseIterable {
        case cpu, memory, energy, disk, network
        var columns: [String] {
            switch self {
            case .cpu:     return ["name", "cpu", "cputime", "threads", "idle", "kind", "pid"]
            case .memory:  return ["name", "memory", "threads", "pid", "user"]
            case .energy:  return ["name", "power", "drain", "energy", "batt", "sleep", "pid", "user"]
            case .disk:    return ["name", "write", "read", "wtotal", "rtotal", "pid", "user"]
            case .network: return ["name", "nettx", "netrx", "nettxtotal", "netrxtotal",
                                   "nettxpkts", "netrxpkts", "pid", "user"]
            }
        }
        /// Column id (== SortKey rawValue) to sort by when this tab opens.
        var sortColumn: String {
            switch self {
            case .cpu:     return "cpu"
            case .memory:  return "memory"
            case .energy:  return "power"
            case .disk:    return "read"
            case .network: return "netrx"
            }
        }
    }

    /// System-wide summary shown in the footer, fed by the app each refresh.
    struct SystemStats {
        var cpuUserPct = 0.0
        var cpuSysPct = 0.0
        var memoryUsedPct = 0.0
        var diskReadPerSec = 0.0
        var diskWritePerSec = 0.0
        var hasBattery = false
        var batteryPercent = 0.0           // 0…1
        var batteryWatts = 0.0             // magnitude of charge/discharge power (W)
        var batteryCharging = false
        var batteryExternal = false        // AC connected
        var batteryMinutesToFull: Int?
        var batteryMinutesToEmpty: Int?
        var batteryCapacityWh = 0.0        // full charge in watt-hours (0 = unknown)
        var netRxPerSec = 0.0
        var netTxPerSec = 0.0
        var swapUsedBytes = 0.0
    }

    /// AM's View-menu scopes, driven from the toolbar's "…" menu.
    enum Scope: Int, CaseIterable {
        case all, my, system
        var label: String {
            switch self {
            case .all: return "All Processes"
            case .my: return "My Processes"
            case .system: return "System Processes"
            }
        }
    }
    private static let scopeKey = "ProcessScope"
    private let currentUser = NSUserName()
    private(set) var scope: Scope =
        Scope(rawValue: UserDefaults.standard.integer(forKey: "ProcessScope")) ?? .all

    func applyScope(_ s: Scope) {
        scope = s
        UserDefaults.standard.set(s.rawValue, forKey: Self.scopeKey)
        applyFilterAndSort()
    }

    private var currentTab: Tab = .cpu
    private var systemStats = SystemStats()

    private let footer = NSView()
    private let footerStack = NSStackView()
    /// Per-tick footer refresh, rebuilt on tab change to capture that tab's
    /// pane views (Activity-Monitor-style boxed grids/graphs).
    private var footerUpdate: (() -> Void)?

    /// Ring of recent system samples feeding the footer graphs.
    private struct FooterSample {
        var sys = 0.0, user = 0.0     // 0…1
        var mem = 0.0                 // 0…1
        var read = 0.0, write = 0.0   // bytes/sec
        var power = 0.0               // total W across processes
        var batt = 0.0                // 0…1
        var netRx = 0.0, netTx = 0.0  // bytes/sec
    }
    private var history: [FooterSample] = []
    private static let historyCap = 60

    private static let tabKey = "ProcessTab"

    /// Process icons, cached by executable path (an icon never changes for a path).
    private var iconCache: [String: NSImage] = [:]

    static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildTable()
        buildLayout()
        buildRowMenu()

        let saved = Tab(rawValue: UserDefaults.standard.integer(forKey: Self.tabKey)) ?? .cpu
        selectTab(saved)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: data update

    func setSnapshots(_ s: [ProcessSnapshot]) {
        allRows = s
        applyFilterAndSort()
        for (pid, panel) in inspectors {
            let snap = s.first { $0.pid == pid }
            panel.update(with: snap, parentName: snap.flatMap { parentName(of: $0) })
        }
    }

    /// Filter `allRows` by the search text, then sort, then redraw.
    private func applyFilterAndSort() {
        // Capture the selection (by pid) before `rows` is replaced.
        let keepPID: pid_t? = selectedRowIndex().map { rows[$0].pid }

        let scoped: [ProcessSnapshot]
        switch scope {
        case .all:    scoped = allRows
        case .my:     scoped = allRows.filter { $0.user == currentUser }
        case .system: scoped = allRows.filter { $0.user != currentUser }
        }
        let filtered: [ProcessSnapshot]
        if searchText.isEmpty {
            filtered = scoped
        } else {
            let q = searchText.lowercased()
            filtered = scoped.filter {
                $0.name.lowercased().contains(q) || "\($0.pid)".contains(q)
            }
        }
        rows = sort(filtered)
        table.reloadData()
        if let pid = keepPID, let idx = rows.firstIndex(where: { $0.pid == pid }) {
            table.selectRowIndexes([idx], byExtendingSelection: false)
        }
    }

    /// Track window resizes: the name column always fills the width left
    /// over by the fixed columns, like Activity Monitor's Process Name.
    override func layout() {
        super.layout()
        fitNameColumn()
    }

    private func fitNameColumn() {
        guard !nameManuallySized,
              let nameCol = table.tableColumn(withIdentifier: .init("name")) else { return }
        let clipW = scroll.contentSize.width
        guard clipW > 0 else { return }
        // Re-tile so column rects reflect the current column set, then measure
        // the used width from the last visible column's edge. The table's own
        // frame is useless here — it never shrinks below the clip view, so
        // (frame - columns) misreads the real chrome overhead.
        table.tile()
        let idxs = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        guard let first = idxs.first, let last = idxs.last else { return }
        let leadPad = table.rect(ofColumn: first).minX
        // Assume the .inset style pads symmetrically on the trailing side.
        let usedW = table.rect(ofColumn: last).maxX + leadPad
        let target = clipW - (usedW - nameCol.width)
        isFittingColumns = true
        nameCol.width = max(150, target)
        isFittingColumns = false
    }

    // MARK: tabs + footer

    private func selectTab(_ tab: Tab) {
        currentTab = tab
        let visible = Set(tab.columns)
        let userHidden = Set(UserDefaults.standard.stringArray(
            forKey: Self.hiddenColumnsKey(for: tab)) ?? [])
        for col in table.tableColumns {
            let id = col.identifier.rawValue
            col.isHidden = !visible.contains(id) || userHidden.contains(id)
        }
        // Column widths are re-fit by applyFilterAndSort() below.
        if let key = SortKey(rawValue: tab.sortColumn) {
            sortKey = key
            sortAscending = false
        }
        table.sortDescriptors = [NSSortDescriptor(key: tab.sortColumn, ascending: false)]
        clearSortIndicators()
        if let col = table.tableColumn(withIdentifier: .init(tab.sortColumn)) {
            table.setIndicatorImage(NSImage(systemSymbolName: "chevron.down",
                                            accessibilityDescription: nil), in: col)
        }
        nameManuallySized = false
        let savedWidths = (UserDefaults.standard.dictionary(
            forKey: Self.columnWidthsKey(for: tab)) as? [String: Double]) ?? [:]
        isFittingColumns = true
        for col in table.tableColumns where !col.isHidden {
            let id = col.identifier.rawValue
            guard id != "name" else { continue }
            if let w = savedWidths[id] {
                col.width = w
            } else if let w = defaultWidths[id] {
                col.width = w
            }
        }
        isFittingColumns = false
        fitNameColumn()
        applyFilterAndSort()
        rebuildFooterPanes(for: tab)
        refreshFooter()
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
    }

    /// Switch the displayed category — driven by the window's top selector.
    func showCategory(_ tab: Tab) { selectTab(tab) }

    private func clearSortIndicators() {
        for col in table.tableColumns { table.setIndicatorImage(nil, in: col) }
    }

    /// Fed by the app each refresh with system-wide CPU/memory/disk numbers.
    func setSystemStats(_ s: SystemStats) {
        systemStats = s
        history.append(FooterSample(
            sys: s.cpuSysPct / 100, user: s.cpuUserPct / 100,
            mem: s.memoryUsedPct / 100,
            read: s.diskReadPerSec, write: s.diskWritePerSec,
            power: allRows.reduce(0.0) { $0 + $1.powerWatts },
            batt: s.batteryPercent,
            netRx: s.netRxPerSec, netTx: s.netTxPerSec))
        if history.count > Self.historyCap { history.removeFirst(history.count - Self.historyCap) }
        refreshFooter()
    }

    /// Rebuild the three Activity-Monitor-style footer panes for `tab`, and
    /// install a per-tick update closure that only writes values into them.
    private func rebuildFooterPanes(for tab: Tab) {
        footerStack.arrangedSubviews.forEach {
            footerStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let threadsGrid = FooterStatGrid(rows: [.init(label: "Threads:", color: nil),
                                                .init(label: "Processes:", color: nil)])

        switch tab {
        case .cpu:
            let stats = FooterStatGrid(rows: [
                .init(label: "System:", color: .systemRed),
                .init(label: "User:", color: .systemBlue),
                .init(label: "Idle:", color: nil),
            ])
            let graph = FooterGraphView(caption: "CPU Load",
                                        colors: [.systemRed, .systemBlue], mode: .stack)
            addPanes([stats, graph, threadsGrid])
            footerUpdate = { [weak self] in
                guard let self else { return }
                let s = self.systemStats
                let idle = max(0, 100 - s.cpuUserPct - s.cpuSysPct)
                stats.setValue(String(format: "%.2f%%", s.cpuSysPct), at: 0)
                stats.setValue(String(format: "%.2f%%", s.cpuUserPct), at: 1)
                stats.setValue(String(format: "%.2f%%", idle), at: 2)
                graph.setLayers([self.history.map(\.sys), self.history.map(\.user)])
                self.updateThreadsGrid(threadsGrid)
            }
        case .memory:
            let graph = FooterGraphView(caption: "Memory Used",
                                        colors: [.systemGreen], mode: .stack)
            let stats = FooterStatGrid(rows: [
                .init(label: "Memory Used:", color: nil),
                .init(label: "App RSS Total:", color: nil),
                .init(label: "Swap Used:", color: nil),
            ])
            addPanes([graph, stats, threadsGrid])
            footerUpdate = { [weak self] in
                guard let self else { return }
                stats.setValue(String(format: "%.0f%%", self.systemStats.memoryUsedPct), at: 0)
                let totalRSS = self.allRows.reduce(0.0) { $0 + $1.rssMB }
                stats.setValue(Self.formatMB(totalRSS), at: 1)
                stats.setValue(Self.bytesFormatter.string(
                    fromByteCount: Int64(self.systemStats.swapUsedBytes)), at: 2)
                graph.setLayers([self.history.map(\.mem)])
                self.updateThreadsGrid(threadsGrid)
            }
        case .energy:
            let impact = FooterGraphView(caption: "Energy Impact",
                                         colors: [.systemGreen], mode: .stack)
            let stats = FooterStatGrid(rows: [
                .init(label: "Total Power:", color: nil),
                .init(label: "Remaining charge:", color: nil),
                .init(label: "Time:", color: nil),
            ])
            var panes: [NSView] = [impact, stats]
            let battery = FooterGraphView(caption: "Battery",
                                          colors: [.systemGreen], mode: .stack)
            if systemStats.hasBattery { panes.append(battery) } else { panes.append(threadsGrid) }
            addPanes(panes)
            footerUpdate = { [weak self] in
                guard let self else { return }
                let s = self.systemStats
                let totalW = self.allRows.reduce(0.0) { $0 + $1.powerWatts }
                stats.setValue(String(format: "%.2f W", totalW), at: 0)
                stats.setValue(s.hasBattery
                               ? String(format: "%.0f%%", s.batteryPercent * 100) : "—", at: 1)
                stats.setValue(self.batteryTimeText(), at: 2)
                // Auto-scaled power history: normalize by the window's max.
                let maxW = max(1, self.history.map(\.power).max() ?? 1)
                impact.setLayers([self.history.map { $0.power / maxW }])
                if s.hasBattery { battery.setLayers([self.history.map(\.batt)]) }
                else { self.updateThreadsGrid(threadsGrid) }
            }
        case .network:
            let stats = FooterStatGrid(rows: [
                .init(label: "Rcvd in/sec:", color: .systemBlue),
                .init(label: "Sent out/sec:", color: .systemRed),
            ])
            let graph = FooterGraphView(caption: "Data",
                                        colors: [.systemBlue, .systemRed], mode: .mirror)
            let totals = FooterStatGrid(rows: [
                .init(label: "Data received:", color: nil),
                .init(label: "Data sent:", color: nil),
            ])
            addPanes([stats, graph, totals])
            footerUpdate = { [weak self] in
                guard let self else { return }
                let s = self.systemStats
                stats.setValue(Self.bytesFormatter.string(fromByteCount: Int64(s.netRxPerSec)) + "/s", at: 0)
                stats.setValue(Self.bytesFormatter.string(fromByteCount: Int64(s.netTxPerSec)) + "/s", at: 1)
                // Shared auto-scale across rx+tx, floor 128 KiB/s.
                let maxIO = max(131_072, self.history.map { max($0.netRx, $0.netTx) }.max() ?? 0)
                graph.setLayers([self.history.map { $0.netRx / maxIO },
                                 self.history.map { $0.netTx / maxIO }])
                let rxTotal = self.allRows.reduce(0.0) { $0 + $1.netRxTotal }
                let txTotal = self.allRows.reduce(0.0) { $0 + $1.netTxTotal }
                totals.setValue(Self.bytesFormatter.string(fromByteCount: Int64(rxTotal)), at: 0)
                totals.setValue(Self.bytesFormatter.string(fromByteCount: Int64(txTotal)), at: 1)
            }
        case .disk:
            let stats = FooterStatGrid(rows: [
                .init(label: "Reads in/sec:", color: .systemBlue),
                .init(label: "Writes out/sec:", color: .systemRed),
            ])
            let graph = FooterGraphView(caption: "IO",
                                        colors: [.systemBlue, .systemRed], mode: .mirror)
            let totals = FooterStatGrid(rows: [
                .init(label: "Data read:", color: nil),
                .init(label: "Data written:", color: nil),
            ])
            addPanes([stats, graph, totals])
            footerUpdate = { [weak self] in
                guard let self else { return }
                let s = self.systemStats
                stats.setValue(Self.bytesFormatter.string(fromByteCount: Int64(s.diskReadPerSec)) + "/s", at: 0)
                stats.setValue(Self.bytesFormatter.string(fromByteCount: Int64(s.diskWritePerSec)) + "/s", at: 1)
                // Shared auto-scale across read+write, floor 1 MiB/s.
                let maxIO = max(1_048_576, self.history.map { max($0.read, $0.write) }.max() ?? 0)
                graph.setLayers([self.history.map { $0.read / maxIO },
                                 self.history.map { $0.write / maxIO }])
                let readTotal = self.allRows.reduce(0.0) { $0 + $1.diskReadTotal }
                let writeTotal = self.allRows.reduce(0.0) { $0 + $1.diskWriteTotal }
                totals.setValue(Self.bytesFormatter.string(fromByteCount: Int64(readTotal)), at: 0)
                totals.setValue(Self.bytesFormatter.string(fromByteCount: Int64(writeTotal)), at: 1)
            }
        }
    }

    private func addPanes(_ contents: [NSView]) {
        for c in contents { footerStack.addArrangedSubview(FooterPane(content: c)) }
    }

    private func updateThreadsGrid(_ grid: FooterStatGrid) {
        grid.setValue("\(allRows.reduce(0) { $0 + $1.threads })", at: 0)
        grid.setValue("\(allRows.count)", at: 1)
    }

    private func refreshFooter() {
        footerUpdate?()
    }

    /// Time-to-full / time-to-empty summary for the Energy pane.
    private func batteryTimeText() -> String {
        let s = systemStats
        guard s.hasBattery else { return "—" }
        let flowing = s.batteryWatts >= 0.1
        if flowing, s.batteryCharging, let m = s.batteryMinutesToFull {
            return "full in \(Self.formatMinutes(m))"
        }
        if flowing, !s.batteryCharging, let m = s.batteryMinutesToEmpty {
            return "empty in \(Self.formatMinutes(m))"
        }
        if s.batteryExternal { return "on AC" }
        return "—"
    }

    static func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    // MARK: build

    private func buildTable() {
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = Theme.processRowHeight
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))   // AM behavior

        // Process first (matches Activity Monitor); add order is the display
        // order across all tabs. Each tab shows a subset via selectTab().
        addColumn(id: "name",    title: "Process Name", width: 200, key: .name,
                  alignment: .left)
        addColumn(id: "cpu",     title: "% CPU",  width: 60,  key: .cpu,
                  alignment: .right)
        addColumn(id: "cputime", title: "CPU Time", width: 84, key: .cpuTime,
                  alignment: .right)
        addColumn(id: "memory",  title: "Memory", width: 90,  key: .memory,
                  alignment: .right)
        addColumn(id: "threads", title: "Threads", width: 62,  key: .threads,
                  alignment: .right)
        addColumn(id: "idle",    title: "Idle Wake Ups", width: 96, key: .idle,
                  alignment: .right)
        addColumn(id: "kind",    title: "Kind",   width: 56,  key: .kind,
                  alignment: .left)
        addColumn(id: "power",   title: "Power",  width: 84,  key: .power,
                  alignment: .right)
        addColumn(id: "drain",   title: "Drain",  width: 84,  key: .drain,
                  alignment: .right)
        addColumn(id: "energy",  title: "Energy", width: 84,  key: .energy,
                  alignment: .right)
        addColumn(id: "batt",    title: "% Batt", width: 64,  key: .batt,
                  alignment: .right)
        addColumn(id: "write",   title: "Write/s", width: 80, key: .write,
                  alignment: .right)
        addColumn(id: "read",    title: "Read/s", width: 80,  key: .read,
                  alignment: .right)
        addColumn(id: "wtotal",  title: "Bytes Written", width: 104, key: .wtotal,
                  alignment: .right)
        addColumn(id: "rtotal",  title: "Bytes Read", width: 100, key: .rtotal,
                  alignment: .right)
        addColumn(id: "nettx",   title: "Sent/s", width: 84, key: .nettx,
                  alignment: .right)
        addColumn(id: "netrx",   title: "Rcvd/s", width: 84, key: .netrx,
                  alignment: .right)
        addColumn(id: "nettxtotal", title: "Sent Bytes", width: 100, key: .nettxtotal,
                  alignment: .right)
        addColumn(id: "netrxtotal", title: "Rcvd Bytes", width: 100, key: .netrxtotal,
                  alignment: .right)
        addColumn(id: "nettxpkts", title: "Sent Packets", width: 104, key: .nettxpkts,
                  alignment: .right)
        addColumn(id: "netrxpkts", title: "Rcvd Packets", width: 104, key: .netrxpkts,
                  alignment: .right)
        addColumn(id: "sleep",   title: "Preventing Sleep", width: 118, key: .sleep,
                  alignment: .left)
        addColumn(id: "pid",     title: "PID",    width: 66,  key: .pid,
                  alignment: .right)
        addColumn(id: "user",    title: "User",   width: 96,  key: .user,
                  alignment: .left)

        // Process Name absorbs the window's width (like Activity Monitor);
        // every other column keeps its fixed width. fitNameColumn() manages
        // the name width explicitly (on tab switch and in layout()), so no
        // automatic distribution is wanted.
        for col in table.tableColumns {
            col.resizingMask = [.userResizingMask]
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing

        // Column visibility + initial sort are set by selectTab() (see init).
    }

    private func persistColumnVisibility() {
        let tabCols = Set(currentTab.columns)
        let hidden = table.tableColumns
            .filter { $0.isHidden && tabCols.contains($0.identifier.rawValue) }
            .map { $0.identifier.rawValue }
        UserDefaults.standard.set(hidden, forKey: Self.hiddenColumnsKey(for: currentTab))
    }

    /// Column-visibility menu for the CURRENT tab (shown in the toolbar's
    /// "…" menu). Only that tab's columns are listed; toggles persist per tab.
    func columnSelectorMenu() -> NSMenu {
        let menu = NSMenu()
        for id in currentTab.columns {
            guard let col = table.tableColumn(withIdentifier: .init(id)) else { continue }
            let item = NSMenuItem(title: col.title,
                                  action: #selector(toggleColumn(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = col
            item.state = col.isHidden ? .off : .on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        // Prevent hiding the last visible column.
        let visibleCount = table.tableColumns.filter { !$0.isHidden }.count
        if !col.isHidden, visibleCount <= 1 { NSSound.beep(); return }
        col.isHidden = !col.isHidden
        sender.state = col.isHidden ? .off : .on
        persistColumnVisibility()
        fitNameColumn()   // the freed/claimed width goes to Process Name
    }

    private func addColumn(id: String, title: String, width: CGFloat,
                           key: SortKey, alignment: NSTextAlignment) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = 40
        defaultWidths[id] = width
        col.headerCell.alignment = alignment
        col.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue,
                                                       ascending: false)
        table.addTableColumn(col)
    }

    /// Table + footer, edge to edge — the window's unified toolbar hosts the
    /// controls that used to live in a chrome row here.
    private func buildLayout() {
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        buildFooter()

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Theme.footerHeight),
        ])
    }

    /// Activity-Monitor-style footer: three boxed panes centered below a
    /// hairline. Pane contents are per-tab (see rebuildFooterPanes).
    private func buildFooter() {
        // Transparent — the window background shows through, tracking the
        // system appearance (a fixed cgColor would freeze light/dark mode).
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(sep)

        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 12
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerStack)

        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: footer.topAnchor),
            sep.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            footerStack.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            footerStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footerStack.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -12),
        ])
    }

    // MARK: row context menu (kill / force kill)

    private func buildRowMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let kill = NSMenuItem(title: "Kill",
                              action: #selector(killProcess(_:)),
                              keyEquivalent: "")
        kill.target = self
        let force = NSMenuItem(title: "Force Kill",
                               action: #selector(forceKillProcess(_:)),
                               keyEquivalent: "")
        force.target = self
        menu.addItem(kill)
        menu.addItem(force)
        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal in Finder",
                                action: #selector(revealInFinder(_:)),
                                keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let copyPath = NSMenuItem(title: "Copy Path",
                                  action: #selector(copyPath(_:)),
                                  keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)
        table.menu = menu
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let row = clickedRow() else { return }
        let path = rows[row].execPath
        guard !path.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let row = clickedRow() else { return }
        let path = rows[row].execPath
        guard !path.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // NSMenuDelegate — refresh item titles to include the clicked process name.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        let row = table.clickedRow
        let suffix: String
        if row >= 0, row < rows.count {
            let s = rows[row]
            suffix = " “\(s.name)” (\(s.pid))"
        } else {
            suffix = ""
        }
        menu.items.first(where: { $0.action == #selector(killProcess(_:)) })?
            .title = "Kill" + suffix
        menu.items.first(where: { $0.action == #selector(forceKillProcess(_:)) })?
            .title = "Force Kill" + suffix
    }

    @objc private func killProcess(_ sender: Any?) {
        guard let pid = clickedPID() else { return }
        sendSignal(SIGTERM, to: pid)
    }

    @objc private func forceKillProcess(_ sender: Any?) {
        guard let pid = clickedPID(), let row = clickedRow() else { return }
        let name = rows[row].name
        let a = NSAlert()
        a.messageText = "Force Kill “\(name)” (\(pid))?"
        a.informativeText = "Force Kill skips normal cleanup. Unsaved work will be lost."
        a.alertStyle = .warning
        a.addButton(withTitle: "Force Kill")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            sendSignal(SIGKILL, to: pid)
        }
    }

    private func clickedRow() -> Int? {
        let row = table.clickedRow
        return (row >= 0 && row < rows.count) ? row : nil
    }

    private func clickedPID() -> pid_t? {
        clickedRow().map { rows[$0].pid }
    }

    private func sendSignal(_ sig: Int32, to pid: pid_t) {
        let result = Darwin.kill(pid, sig)
        guard result != 0 else { return }
        let err = String(cString: strerror(errno))
        let a = NSAlert()
        a.messageText = "Couldn't signal pid \(pid)"
        a.informativeText = err
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Driven by the window toolbar's search field.
    func setSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        applyFilterAndSort()
    }

    /// Driven by the window toolbar's "…" › Update Frequency menu.
    func applyInterval(_ seconds: Int) {
        intervalSeconds = seconds
        onIntervalChange?(seconds)
    }

    private func selectedRowIndex() -> Int? {
        let r = table.selectedRow
        return (r >= 0 && r < rows.count) ? r : nil
    }

    @objc func quitSelected() {
        guard let r = selectedRowIndex() else { NSSound.beep(); return }
        sendSignal(SIGTERM, to: rows[r].pid)
    }

    @objc func forceQuitSelected() {
        guard let r = selectedRowIndex() else { NSSound.beep(); return }
        let snap = rows[r]
        let a = NSAlert()
        a.messageText = "Force Quit “\(snap.name)” (\(snap.pid))?"
        a.informativeText = "Force Quit skips normal cleanup. Unsaved work will be lost."
        a.alertStyle = .warning
        a.addButton(withTitle: "Force Quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { sendSignal(SIGKILL, to: snap.pid) }
    }

    /// Live inspector panels, one per pid; updated from setSnapshots.
    private var inspectors: [pid_t: InspectorPanelController] = [:]

    @objc func inspectSelected() {
        guard let r = selectedRowIndex() else { NSSound.beep(); return }
        openInspector(for: rows[r])
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let r = clickedRow() else { return }
        openInspector(for: rows[r])
    }

    private func openInspector(for snap: ProcessSnapshot) {
        if let existing = inspectors[snap.pid] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = InspectorPanelController(snapshot: snap,
                                             icon: icon(forExecPath: snap.execPath))
        panel.onClose = { [weak self] in self?.inspectors[snap.pid] = nil }
        // Cascade additional panels so they don't restore exactly on top of
        // one another (they share a frame-autosave name).
        if !inspectors.isEmpty, let frame = panel.window?.frame {
            let n = CGFloat(inspectors.count)
            panel.window?.setFrameOrigin(NSPoint(x: frame.origin.x + 24 * n,
                                                 y: frame.origin.y - 24 * n))
        }
        inspectors[snap.pid] = panel
        panel.update(with: snap, parentName: parentName(of: snap))
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    private func parentName(of snap: ProcessSnapshot) -> String? {
        guard snap.ppid > 0 else { return nil }
        if let name = allRows.first(where: { $0.pid == snap.ppid })?.name {
            return name
        }
        // Parents we can't fully sample (e.g. root's launchd) still resolve
        // via sysctl — unlike proc_name, it works across users.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, snap.ppid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return name.isEmpty ? nil : name
    }

    /// User dragged a column divider. Name: remember it and stop auto-fill.
    /// Others: persist the width for this tab and re-fill Name around it.
    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isFittingColumns,
              let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        if col.identifier.rawValue == "name" {
            nameManuallySized = true
            return
        }
        var saved = (UserDefaults.standard.dictionary(
            forKey: Self.columnWidthsKey(for: currentTab)) as? [String: Double]) ?? [:]
        saved[col.identifier.rawValue] = col.width
        UserDefaults.standard.set(saved, forKey: Self.columnWidthsKey(for: currentTab))
        fitNameColumn()
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = tableView.sortDescriptors.first,
              let key = sd.key.flatMap(SortKey.init(rawValue:)) else { return }
        sortKey = key
        sortAscending = sd.ascending
        applyFilterAndSort()
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let snap = rows[row]
        let id = col.identifier.rawValue
        // Reuse cells via makeView — building fresh views every tick is what
        // made the old table shimmer on refresh. Config (font/alignment) is
        // fixed per column, so reused cells only need their content updated.
        if id == "name" {
            let cell = (table.makeView(withIdentifier: col.identifier, owner: self)
                        as? NSTableCellView) ?? Self.makeNameCell(identifier: col.identifier)
            cell.imageView?.image = icon(forExecPath: snap.execPath)
            cell.textField?.stringValue = snap.name
            return cell
        }
        let plainText = (id == "kind" || id == "user")
        let cell = (table.makeView(withIdentifier: col.identifier, owner: self)
                    as? NSTableCellView)
            ?? Self.makeTextCell(identifier: col.identifier,
                                 monospaced: !plainText,
                                 alignment: plainText ? .left : .right)
        cell.textField?.stringValue = cellText(id: id, snap: snap)
        return cell
    }

    private func cellText(id: String, snap: ProcessSnapshot) -> String {
        switch id {
        case "cpu":     return String(format: "%.1f", snap.cpuPercent)
        case "cputime": return Self.formatCPUTime(snap.cpuTimeSeconds)
        case "memory":  return Self.formatMB(snap.rssMB)
        case "threads": return "\(snap.threads)"
        case "idle":    return "\(snap.idleWakeups)"
        case "kind":    return snap.isTranslated ? "Intel" : "Apple"
        case "read":    return Self.formatRate(snap.diskReadBytesPerSec)
        case "write":   return Self.formatRate(snap.diskWriteBytesPerSec)
        case "rtotal":  return Self.formatTotal(snap.diskReadTotal)
        case "netrx":   return Self.formatRate(snap.netRxBytesPerSec)
        case "nettx":   return Self.formatRate(snap.netTxBytesPerSec)
        case "netrxtotal": return Self.formatTotal(snap.netRxTotal)
        case "nettxtotal": return Self.formatTotal(snap.netTxTotal)
        case "netrxpkts": return Self.formatCount(snap.netRxPackets)
        case "nettxpkts": return Self.formatCount(snap.netTxPackets)
        case "sleep":   return snap.preventsSleep ? "Yes" : "—"
        case "wtotal":  return Self.formatTotal(snap.diskWriteTotal)
        case "power":   return Self.formatPower(snap.powerWatts)
        case "drain":
            let cap = systemStats.batteryCapacityWh
            return cap > 0 ? String(format: "%.2f%%/hr", snap.powerWatts / cap * 100) : "—"
        case "energy":  return Self.formatEnergy(snap.energyJoules)
        case "batt":
            let cap = systemStats.batteryCapacityWh
            return cap > 0 ? String(format: "%.2f%%", (snap.energyJoules / 3600.0) / cap * 100) : "—"
        case "pid":     return "\(snap.pid)"
        case "user":    return snap.user
        default:        return ""
        }
    }

    // MARK: helpers

    /// Shared with ConnectionListView so both tables' rows are identical.
    static func makeTextCell(identifier: NSUserInterfaceItemIdentifier,
                             monospaced: Bool,
                             alignment: NSTextAlignment) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: Theme.processFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: Theme.processFontSize, weight: .regular)
        label.textColor = .labelColor
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Name column: process icon + truncating name label.
    private static func makeNameCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: Theme.processFontSize, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv)
        cell.addSubview(label)
        cell.textField = label
        cell.imageView = iv
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Resolve a process's icon from its executable path, cached. App bundles
    /// get the app icon; pathless system processes get the generic exec icon.
    private func icon(forExecPath p: String) -> NSImage {
        let key = p.isEmpty ? "<none>" : p
        if let c = iconCache[key] { return c }
        let base: NSImage
        if p.isEmpty {
            base = NSWorkspace.shared.icon(for: .unixExecutable)
        } else if let r = p.range(of: ".app/") {
            base = NSWorkspace.shared.icon(forFile: String(p[..<r.lowerBound]) + ".app")
        } else {
            base = NSWorkspace.shared.icon(forFile: p)
        }
        // Redraw into a fixed 16pt image with high-quality interpolation so it
        // downscales smoothly. lockFocus captures at the screen's @2x backing,
        // so the cached icon stays crisp on Retina.
        let size = NSSize(width: 16, height: 16)
        let smooth = NSImage(size: size)
        smooth.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(in: NSRect(origin: .zero, size: size),
                  from: .zero, operation: .sourceOver, fraction: 1)
        smooth.unlockFocus()
        iconCache[key] = smooth
        return smooth
    }

    /// CPU time like Activity Monitor: "S.ss", "M:SS.ss", or "H:MM:SS.ss".
    static func formatCPUTime(_ total: Double) -> String {
        let whole = Int(total)
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = total.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, s) }
        if whole >= 60 { return String(format: "%d:%05.2f", m, s) }
        return String(format: "%.2f", total)
    }

    static func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1   { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    /// Whole counts with thousands separators, "—" for zero (AM style).
    static func formatCount(_ n: Double) -> String {
        if n < 1 { return "—" }
        return Self.countFormatter.string(from: NSNumber(value: Int64(n))) ?? "\(Int64(n))"
    }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return "—" }
        return Self.bytesFormatter.string(fromByteCount: Int64(bytesPerSec))
    }

    /// Cumulative byte total (lifetime), e.g. "1.2 GB"; "—" when nothing yet.
    static func formatTotal(_ bytes: Double) -> String {
        if bytes < 1 { return "—" }
        return Self.bytesFormatter.string(fromByteCount: Int64(bytes))
    }

    static func formatPower(_ watts: Double) -> String {
        if watts < 0.001 { return "—" }
        if watts < 1     { return String(format: "%.0f mW", watts * 1000) }
        return String(format: "%.2f W", watts)
    }

    /// Cumulative energy (joules) → human Wh / mWh.
    static func formatEnergy(_ joules: Double) -> String {
        let wh = joules / 3600.0
        if wh < 0.001  { return "—" }
        if wh < 1      { return String(format: "%.0f mWh", wh * 1000) }
        if wh < 1000   { return String(format: "%.1f Wh", wh) }
        return String(format: "%.0f Wh", wh)
    }

    private func sort(_ s: [ProcessSnapshot]) -> [ProcessSnapshot] {
        let asc = sortAscending
        switch sortKey {
        case .cpu:
            return s.sorted { asc ? $0.cpuPercent < $1.cpuPercent
                                  : $0.cpuPercent > $1.cpuPercent }
        case .name:
            return s.sorted { a, b in
                let r = a.name.localizedCaseInsensitiveCompare(b.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        case .memory:
            return s.sorted { asc ? $0.rssMB < $1.rssMB : $0.rssMB > $1.rssMB }
        case .threads:
            return s.sorted { asc ? $0.threads < $1.threads : $0.threads > $1.threads }
        case .read:
            return s.sorted { asc ? $0.diskReadBytesPerSec < $1.diskReadBytesPerSec
                                  : $0.diskReadBytesPerSec > $1.diskReadBytesPerSec }
        case .write:
            return s.sorted { asc ? $0.diskWriteBytesPerSec < $1.diskWriteBytesPerSec
                                  : $0.diskWriteBytesPerSec > $1.diskWriteBytesPerSec }
        case .power, .drain:
            return s.sorted { asc ? $0.powerWatts < $1.powerWatts
                                  : $0.powerWatts > $1.powerWatts }
        case .energy, .batt:
            return s.sorted { asc ? $0.energyJoules < $1.energyJoules
                                  : $0.energyJoules > $1.energyJoules }
        case .rtotal:
            return s.sorted { asc ? $0.diskReadTotal < $1.diskReadTotal
                                  : $0.diskReadTotal > $1.diskReadTotal }
        case .wtotal:
            return s.sorted { asc ? $0.diskWriteTotal < $1.diskWriteTotal
                                  : $0.diskWriteTotal > $1.diskWriteTotal }
        case .netrx:
            return s.sorted { asc ? $0.netRxBytesPerSec < $1.netRxBytesPerSec
                                  : $0.netRxBytesPerSec > $1.netRxBytesPerSec }
        case .nettx:
            return s.sorted { asc ? $0.netTxBytesPerSec < $1.netTxBytesPerSec
                                  : $0.netTxBytesPerSec > $1.netTxBytesPerSec }
        case .netrxtotal:
            return s.sorted { asc ? $0.netRxTotal < $1.netRxTotal
                                  : $0.netRxTotal > $1.netRxTotal }
        case .nettxtotal:
            return s.sorted { asc ? $0.netTxTotal < $1.netTxTotal
                                  : $0.netTxTotal > $1.netTxTotal }
        case .netrxpkts:
            return s.sorted { asc ? $0.netRxPackets < $1.netRxPackets
                                  : $0.netRxPackets > $1.netRxPackets }
        case .nettxpkts:
            return s.sorted { asc ? $0.netTxPackets < $1.netTxPackets
                                  : $0.netTxPackets > $1.netTxPackets }
        case .sleep:
            return s.sorted { a, b in
                let ai = a.preventsSleep ? 1 : 0, bi = b.preventsSleep ? 1 : 0
                return asc ? ai < bi : ai > bi
            }
        case .cpuTime:
            return s.sorted { asc ? $0.cpuTimeSeconds < $1.cpuTimeSeconds
                                  : $0.cpuTimeSeconds > $1.cpuTimeSeconds }
        case .idle:
            return s.sorted { asc ? $0.idleWakeups < $1.idleWakeups
                                  : $0.idleWakeups > $1.idleWakeups }
        case .kind:
            return s.sorted { a, b in
                // Apple before Intel when ascending.
                let ai = a.isTranslated ? 1 : 0, bi = b.isTranslated ? 1 : 0
                return asc ? ai < bi : ai > bi
            }
        case .pid:
            return s.sorted { asc ? $0.pid < $1.pid : $0.pid > $1.pid }
        case .user:
            return s.sorted { a, b in
                let r = a.user.localizedCaseInsensitiveCompare(b.user)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }
    }
}

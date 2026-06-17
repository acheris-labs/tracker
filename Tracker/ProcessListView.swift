import AppKit
import UniformTypeIdentifiers

final class ProcessListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var allRows: [ProcessSnapshot] = []   // unfiltered, from the sampler
    private var rows: [ProcessSnapshot] = []      // filtered + sorted, displayed
    private var searchText = ""
    private var sortKey: SortKey = .cpu
    private var sortAscending = false

    /// Called when the user changes the refresh interval (seconds).
    var onIntervalChange: ((Int) -> Void)?

    /// In seconds. Persisted by the caller; this view only exposes the UI.
    var intervalSeconds: Int = 2 {
        didSet {
            if let i = Self.intervalOptions.firstIndex(of: intervalSeconds) {
                intervalPopup.selectItem(at: i)
            }
        }
    }

    private static let intervalOptions: [Int] = [1, 2, 3, 5, 10]
    private static let hiddenColumnsKey = "ProcessColumnsHidden"

    enum SortKey: String {
        case cpu, name, memory, threads, read, write, power, pid, user
        case cpuTime, idle, kind, drain, energy, batt, rtotal, wtotal
    }

    /// Activity-Monitor-style category tabs: each selects a column set, a
    /// default sort, and the footer summary.
    enum Tab: Int, CaseIterable {
        case cpu, memory, energy, disk
        var columns: [String] {
            switch self {
            case .cpu:    return ["name", "cpu", "cputime", "threads", "idle", "kind", "pid"]
            case .memory: return ["name", "memory", "threads", "pid", "user"]
            case .energy: return ["name", "power", "drain", "energy", "batt", "pid", "user"]
            case .disk:   return ["name", "write", "read", "wtotal", "rtotal", "pid", "user"]
            }
        }
        /// Column id (== SortKey rawValue) to sort by when this tab opens.
        var sortColumn: String {
            switch self {
            case .cpu:    return "cpu"
            case .memory: return "memory"
            case .energy: return "power"
            case .disk:   return "read"
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
    }

    private var currentTab: Tab = .cpu
    private var systemStats = SystemStats()

    private let footer = NSView()
    private let footerLeft = NSTextField(labelWithString: "")
    private let footerRight = NSTextField(labelWithString: "")
    private let sparkline = Sparkline()

    private static let tabKey = "ProcessTab"

    /// Process icons, cached by executable path (an icon never changes for a path).
    private var iconCache: [String: NSImage] = [:]

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        buildTable()
        buildHeader()
        buildRowMenu()

        let saved = Tab(rawValue: UserDefaults.standard.integer(forKey: Self.tabKey)) ?? .cpu
        selectTab(saved)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: data update

    func setSnapshots(_ s: [ProcessSnapshot]) {
        allRows = s
        applyFilterAndSort()
    }

    /// Filter `allRows` by the search text, then sort, then redraw.
    private func applyFilterAndSort() {
        let filtered: [ProcessSnapshot]
        if searchText.isEmpty {
            filtered = allRows
        } else {
            let q = searchText.lowercased()
            filtered = allRows.filter {
                $0.name.lowercased().contains(q) || "\($0.pid)".contains(q)
            }
        }
        rows = sort(filtered)
        sizeNameColumn()
        table.reloadData()
        table.sizeToFit()   // distribute remaining width to the other columns
    }

    /// Width the Process column to the longest visible name (+20% headroom) plus
    /// icon/padding, clamped to sane bounds. The remaining columns then share
    /// the leftover space via the table's uniform autoresizing.
    private func sizeNameColumn() {
        guard let nameCol = table.tableColumn(withIdentifier: .init("name")) else { return }
        let font = NSFont.systemFont(ofSize: 12)
        var maxText: CGFloat = 0
        for r in rows {
            let w = (r.name as NSString).size(withAttributes: [.font: font]).width
            if w > maxText { maxText = w }
        }
        // icon (15) + leading/gap/trailing (~30) chrome, text given 20% headroom.
        nameCol.width = min(max(150, maxText * 1.2 + 30), 460)
    }

    // MARK: tabs + footer

    private func selectTab(_ tab: Tab) {
        currentTab = tab
        let visible = Set(tab.columns)
        for col in table.tableColumns {
            col.isHidden = !visible.contains(col.identifier.rawValue)
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
        sparkline.isHidden = (tab != .cpu)
        applyFilterAndSort()
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
        if currentTab == .cpu {
            sparkline.push((s.cpuUserPct + s.cpuSysPct) / 100.0)
        }
        refreshFooter()
    }

    private func refreshFooter() {
        let procs = allRows.count
        let threads = allRows.reduce(0) { $0 + $1.threads }
        footerRight.stringValue = "Threads: \(threads)    Processes: \(procs)"
        switch currentTab {
        case .cpu:
            let idle = max(0, 100 - systemStats.cpuUserPct - systemStats.cpuSysPct)
            footerLeft.stringValue = String(
                format: "System: %.1f%%    User: %.1f%%    Idle: %.1f%%",
                systemStats.cpuSysPct, systemStats.cpuUserPct, idle)
        case .memory:
            let totalRSS = allRows.reduce(0.0) { $0 + $1.rssMB }
            footerLeft.stringValue = String(
                format: "Memory used: %.0f%%    App RSS total: %@",
                systemStats.memoryUsedPct, formatMB(totalRSS))
        case .energy:
            let totalW = allRows.reduce(0.0) { $0 + $1.powerWatts }
            var text = String(format: "Total power: %.2f W", totalW)
            if systemStats.hasBattery { text += "        " + batterySummary() }
            footerLeft.stringValue = text
        case .disk:
            let r = Self.bytesFormatter.string(fromByteCount: Int64(systemStats.diskReadPerSec))
            let w = Self.bytesFormatter.string(fromByteCount: Int64(systemStats.diskWritePerSec))
            footerLeft.stringValue = "Read: \(r)/s    Write: \(w)/s"
        }
    }

    /// Battery charge/discharge rate (in watts) + time-to-full / time-to-empty.
    private func batterySummary() -> String {
        let pct = String(format: "%.0f%%", systemStats.batteryPercent * 100)
        let w = String(format: "%.1f", systemStats.batteryWatts)
        let flowing = systemStats.batteryWatts >= 0.1
        if flowing, systemStats.batteryCharging, let m = systemStats.batteryMinutesToFull {
            return "Battery \(pct): +\(w) W · full in \(formatMinutes(m))"
        }
        if flowing, !systemStats.batteryCharging, let m = systemStats.batteryMinutesToEmpty {
            return "Battery \(pct): −\(w) W · empty in \(formatMinutes(m))"
        }
        if flowing {
            return "Battery \(pct): \(systemStats.batteryCharging ? "+" : "−")\(w) W"
        }
        if systemStats.batteryExternal { return "Battery \(pct): on AC" }
        return "Battery \(pct)"
    }

    private func formatMinutes(_ m: Int) -> String {
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
        table.rowHeight = 18
        table.gridStyleMask = []
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self

        // Process first (matches Activity Monitor); add order is the display
        // order across all tabs. Each tab shows a subset via selectTab().
        addColumn(id: "name",    title: "Process", width: 200, key: .name,
                  alignment: .left)
        addColumn(id: "cpu",     title: "%CPU",   width: 60,  key: .cpu,
                  alignment: .right)
        addColumn(id: "cputime", title: "CPU Time", width: 84, key: .cpuTime,
                  alignment: .right)
        addColumn(id: "threads", title: "Threads", width: 62,  key: .threads,
                  alignment: .right)
        addColumn(id: "idle",    title: "Idle Wake Ups", width: 96, key: .idle,
                  alignment: .right)
        addColumn(id: "kind",    title: "Kind",   width: 56,  key: .kind,
                  alignment: .left)
        addColumn(id: "memory",  title: "Memory", width: 80,  key: .memory,
                  alignment: .right)
        addColumn(id: "power",   title: "Power",  width: 72,  key: .power,
                  alignment: .right)
        addColumn(id: "drain",   title: "Drain",  width: 76,  key: .drain,
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
        addColumn(id: "pid",     title: "PID",    width: 66,  key: .pid,
                  alignment: .right)
        addColumn(id: "user",    title: "User",   width: 96,  key: .user,
                  alignment: .left)

        // Process is sized to its content (see sizeNameColumn); every other
        // column shares the leftover width so none collapse.
        for col in table.tableColumns {
            col.resizingMask = col.identifier.rawValue == "name"
                ? [.userResizingMask] : [.autoresizingMask, .userResizingMask]
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // Column visibility + initial sort are set by selectTab() (see init).
    }

    private func loadColumnVisibility() {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenColumnsKey) ?? [])
        for col in table.tableColumns {
            col.isHidden = hidden.contains(col.identifier.rawValue)
        }
    }

    private func persistColumnVisibility() {
        let hidden = table.tableColumns
            .filter(\.isHidden)
            .map { $0.identifier.rawValue }
        UserDefaults.standard.set(hidden, forKey: Self.hiddenColumnsKey)
    }

    /// Build a fresh column-visibility menu reflecting current state.
    /// Exposed so the chart window can show it from a right-click on the
    /// Processes tab label.
    func columnSelectorMenu() -> NSMenu {
        let menu = NSMenu()
        for col in table.tableColumns {
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
    }

    private func addColumn(id: String, title: String, width: CGFloat,
                           key: SortKey, alignment: NSTextAlignment) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = 40
        col.headerCell.alignment = alignment
        col.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue,
                                                       ascending: false)
        table.addTableColumn(col)
    }

    private func buildHeader() {
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // Left: per-selection actions (operate on the selected row).
        let inspect = toolButton("info.circle",  "Inspect selected process",    #selector(inspectSelected))
        let quit    = toolButton("xmark.circle",  "Quit selected process",       #selector(quitSelected))
        let force   = toolButton("xmark.octagon", "Force Quit selected process", #selector(forceQuitSelected))
        let left = NSStackView(views: [inspect, quit, force])
        left.spacing = 4
        left.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)

        // Right: filter field + refresh interval.
        let search = NSSearchField()
        search.placeholderString = "Filter"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let label = NSTextField(labelWithString: "Refresh")
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor

        intervalPopup.removeAllItems()
        for s in Self.intervalOptions {
            intervalPopup.addItem(withTitle: "\(s) s")
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged(_:))
        intervalPopup.bezelStyle = .rounded
        intervalPopup.controlSize = .small
        intervalPopup.font = .systemFont(ofSize: 11, weight: .regular)

        let right = NSStackView(views: [search, label, intervalPopup])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 6
        right.translatesAutoresizingMaskIntoConstraints = false
        addSubview(right)

        buildFooter()

        NSLayoutConstraint.activate([
            // Chrome row: actions (left) · filter / refresh (right).
            right.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: right.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: right.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func buildFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        addSubview(footer)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(sep)

        footerLeft.font = .systemFont(ofSize: 11)
        footerLeft.textColor = .secondaryLabelColor
        footerLeft.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerLeft)

        footerRight.font = .systemFont(ofSize: 11)
        footerRight.textColor = .secondaryLabelColor
        footerRight.alignment = .right
        footerRight.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerRight)

        sparkline.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(sparkline)

        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: footer.topAnchor),
            sep.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            footerLeft.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            footerLeft.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            footerRight.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            footerRight.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            sparkline.trailingAnchor.constraint(equalTo: footerRight.leadingAnchor, constant: -12),
            sparkline.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            sparkline.widthAnchor.constraint(equalToConstant: 110),
            sparkline.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func toolButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.controlSize = .small
        b.target = self
        b.action = action
        b.toolTip = tip
        return b
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
        table.menu = menu
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

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        applyFilterAndSort()
    }

    private func selectedRowIndex() -> Int? {
        let r = table.selectedRow
        return (r >= 0 && r < rows.count) ? r : nil
    }

    @objc private func quitSelected() {
        guard let r = selectedRowIndex() else { NSSound.beep(); return }
        sendSignal(SIGTERM, to: rows[r].pid)
    }

    @objc private func forceQuitSelected() {
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

    @objc private func inspectSelected() {
        guard let r = selectedRowIndex() else { NSSound.beep(); return }
        let s = rows[r]
        let a = NSAlert()
        a.messageText = "\(s.name)  (\(s.pid))"
        a.informativeText = """
            User: \(s.user)    Kind: \(s.isTranslated ? "Intel" : "Apple")
            CPU: \(String(format: "%.1f", s.cpuPercent))%    CPU Time: \(formatCPUTime(s.cpuTimeSeconds))
            Memory: \(formatMB(s.rssMB))    Threads: \(s.threads)    Idle wakes: \(s.idleWakeups)
            Power: \(formatPower(s.powerWatts))    Disk R/W: \(formatRate(s.diskReadBytesPerSec)) / \(formatRate(s.diskWriteBytesPerSec))
            Path: \(s.execPath.isEmpty ? "—" : s.execPath)
            """
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < Self.intervalOptions.count else { return }
        let seconds = Self.intervalOptions[idx]
        intervalSeconds = seconds
        onIntervalChange?(seconds)
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
        if id == "name" { return nameCell(snap) }
        let s: String
        var monospaced = true
        var alignment: NSTextAlignment = .right
        switch id {
        case "cpu":     s = String(format: "%.1f", snap.cpuPercent)
        case "cputime": s = formatCPUTime(snap.cpuTimeSeconds)
        case "memory":  s = formatMB(snap.rssMB)
        case "threads": s = "\(snap.threads)"
        case "idle":    s = "\(snap.idleWakeups)"
        case "kind":    s = snap.isTranslated ? "Intel" : "Apple"
                        monospaced = false; alignment = .left
        case "read":    s = formatRate(snap.diskReadBytesPerSec)
        case "write":   s = formatRate(snap.diskWriteBytesPerSec)
        case "rtotal":  s = formatTotal(snap.diskReadTotal)
        case "wtotal":  s = formatTotal(snap.diskWriteTotal)
        case "power":   s = formatPower(snap.powerWatts)
        case "drain":
            let cap = systemStats.batteryCapacityWh
            s = cap > 0 ? String(format: "%.2f%%/hr", snap.powerWatts / cap * 100) : "—"
        case "energy":  s = formatEnergy(snap.energyJoules)
        case "batt":
            let cap = systemStats.batteryCapacityWh
            s = cap > 0 ? String(format: "%.2f%%", (snap.energyJoules / 3600.0) / cap * 100) : "—"
        case "pid":     s = "\(snap.pid)"
        case "user":    s = snap.user; monospaced = false; alignment = .left
        default:        s = ""
        }
        return Self.cell(string: s, monospaced: monospaced, alignment: alignment)
    }

    // MARK: helpers

    private static func cell(string: String, monospaced: Bool,
                             alignment: NSTextAlignment) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: string)
        label.font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12, weight: .regular)
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
    private func nameCell(_ snap: ProcessSnapshot) -> NSTableCellView {
        let cell = NSTableCellView()
        let iv = NSImageView()
        iv.image = icon(forExecPath: snap.execPath)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: snap.name)
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv)
        cell.addSubview(label)
        cell.textField = label
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
    private func formatCPUTime(_ total: Double) -> String {
        let whole = Int(total)
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = total.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, s) }
        if whole >= 60 { return String(format: "%d:%05.2f", m, s) }
        return String(format: "%.2f", total)
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1   { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    private func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return "—" }
        return Self.bytesFormatter.string(fromByteCount: Int64(bytesPerSec))
    }

    /// Cumulative byte total (lifetime), e.g. "1.2 GB"; "—" when nothing yet.
    private func formatTotal(_ bytes: Double) -> String {
        if bytes < 1 { return "—" }
        return Self.bytesFormatter.string(fromByteCount: Int64(bytes))
    }

    private func formatPower(_ watts: Double) -> String {
        if watts < 0.001 { return "—" }
        if watts < 1     { return String(format: "%.0f mW", watts * 1000) }
        return String(format: "%.2f W", watts)
    }

    /// Cumulative energy (joules) → human Wh / mWh.
    private func formatEnergy(_ joules: Double) -> String {
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

/// A tiny filled line chart of recent total CPU load (0…1), for the footer.
private final class Sparkline: NSView {
    private var values: [Double] = []
    private let capacity = 60

    func push(_ v: Double) {
        values.append(max(0, min(1, v)))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let h = bounds.height
        let step = bounds.width / CGFloat(capacity - 1)

        let area = NSBezierPath()
        area.move(to: NSPoint(x: 0, y: 0))
        for (i, v) in values.enumerated() {
            area.line(to: NSPoint(x: CGFloat(i) * step, y: CGFloat(v) * h))
        }
        area.line(to: NSPoint(x: CGFloat(values.count - 1) * step, y: 0))
        area.close()
        NSColor.systemGreen.withAlphaComponent(0.3).setFill()
        area.fill()

        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let pt = NSPoint(x: CGFloat(i) * step, y: CGFloat(v) * h)
            if i == 0 { line.move(to: pt) } else { line.line(to: pt) }
        }
        line.lineWidth = 1
        NSColor.systemGreen.setStroke()
        line.stroke()
    }
}

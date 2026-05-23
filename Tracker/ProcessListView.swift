import AppKit

final class ProcessListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rows: [ProcessSnapshot] = []
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
    }

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
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: data update

    func setSnapshots(_ s: [ProcessSnapshot]) {
        rows = sort(s)
        // Preserve scroll position; just redraw rows.
        table.reloadData()
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

        addColumn(id: "cpu",     title: "%CPU",   width: 64,  key: .cpu,
                  alignment: .right)
        addColumn(id: "name",    title: "Process", width: 220, key: .name,
                  alignment: .left)
        addColumn(id: "memory",  title: "Memory", width: 80,  key: .memory,
                  alignment: .right)
        addColumn(id: "threads", title: "Threads", width: 58,  key: .threads,
                  alignment: .right)
        addColumn(id: "read",    title: "Read/s", width: 80, key: .read,
                  alignment: .right)
        addColumn(id: "write",   title: "Write/s", width: 80, key: .write,
                  alignment: .right)
        addColumn(id: "power",   title: "Power",  width: 72,  key: .power,
                  alignment: .right)
        addColumn(id: "pid",     title: "PID",    width: 64,  key: .pid,
                  alignment: .right)
        addColumn(id: "user",    title: "User",   width: 100, key: .user,
                  alignment: .left)

        // Initial sort indicator on %CPU desc.
        if let col = table.tableColumn(withIdentifier: .init("cpu")) {
            table.sortDescriptors = [NSSortDescriptor(key: SortKey.cpu.rawValue, ascending: false)]
            table.setIndicatorImage(NSImage(systemSymbolName: "chevron.down",
                                            accessibilityDescription: nil),
                                    in: col)
        }

        loadColumnVisibility()
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

        let label = NSTextField(labelWithString: "Refresh every")
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

        let header = NSStackView(views: [label, intervalPopup])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        rows = sort(rows)
        tableView.reloadData()
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let snap = rows[row]
        let id = col.identifier.rawValue
        let s: String
        var monospaced = true
        var alignment: NSTextAlignment = .right
        switch id {
        case "cpu":     s = String(format: "%.1f", snap.cpuPercent)
        case "name":    s = snap.name; monospaced = false; alignment = .left
        case "memory":  s = formatMB(snap.rssMB)
        case "threads": s = "\(snap.threads)"
        case "read":    s = formatRate(snap.diskReadBytesPerSec)
        case "write":   s = formatRate(snap.diskWriteBytesPerSec)
        case "power":   s = formatPower(snap.powerWatts)
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

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1   { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    private func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return "—" }
        return Self.bytesFormatter.string(fromByteCount: Int64(bytesPerSec))
    }

    private func formatPower(_ watts: Double) -> String {
        if watts < 0.001 { return "—" }
        if watts < 1     { return String(format: "%.0f mW", watts * 1000) }
        return String(format: "%.2f W", watts)
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
        case .power:
            return s.sorted { asc ? $0.powerWatts < $1.powerWatts
                                  : $0.powerWatts > $1.powerWatts }
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

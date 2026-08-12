import AppKit

/// A sortable table of network connections, styled to match the process tabs.
/// Deliberately a sibling of ProcessListView rather than a subclass — that
/// class is welded to ProcessSnapshot, the category tabs, its footer and its
/// search scope — but it borrows that class's conventions (and its cell
/// factory) so both tables render identically.
///
/// Built for two callers: the per-process inspector (`showProcess: false`) and,
/// later, a top-level tab over every process (`showProcess: true`). Only the
/// flag and the defaults namespace differ.
final class ConnectionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum SortKey: String {
        case process, proto, laddr, lport, rhost, rport, state
    }

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private let showProcess: Bool
    private let defaultsKey: String

    private var rows: [Connection] = []
    private var names: [pid_t: String] = [:]
    private var shown: Set<Connection> = []       // for the no-op diff
    private var sortKey: SortKey = .rhost
    private var sortAscending = true
    private var defaultWidths: [String: CGFloat] = [:]
    private var isFittingColumns = false
    /// True while showing a "can't read this" message rather than rows.
    private var unavailable = false

    private var widthsKey: String  { "ConnectionColumnWidths.\(defaultsKey)" }
    private var hiddenKey: String  { "ConnectionColumnsHidden.\(defaultsKey)" }

    /// The column that absorbs leftover width, like Process Name does in the
    /// process tabs.
    private var elasticColumnID: String { showProcess ? "process" : "rhost" }

    init(showProcess: Bool, defaultsKey: String) {
        self.showProcess = showProcess
        self.defaultsKey = defaultsKey
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        // NSTabView positions its item views by frame, so this one stays
        // frame-based (like the sibling panes) and its scroll view autoresizes.
        buildTable()
        buildLayout()
        applySavedColumns()
        table.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue,
                                                  ascending: sortAscending)]
        NotificationCenter.default.addObserver(
            self, selector: #selector(hostsResolved),
            name: HostResolver.resolved, object: nil)
        showPlaceholder("No connections")
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Input

    /// Replace the contents. Unchanged data is a no-op so a 1 Hz refresh
    /// doesn't re-sort and flicker rows that haven't moved.
    func setConnections(_ connections: [Connection],
                        processNames: [pid_t: String] = [:]) {
        let incoming = Set(connections)
        if !unavailable, incoming == shown, processNames == names { return }
        unavailable = false
        shown = incoming
        names = processNames
        rows = sorted(connections)
        reloadPreservingSelection()
        if connections.isEmpty {
            showPlaceholder("No connections")
        } else {
            hidePlaceholder()
        }
    }

    /// Show why there's nothing to show (e.g. the process isn't ours to read).
    func setUnavailable(_ message: String) {
        guard !unavailable || placeholder.stringValue != message else { return }
        unavailable = true
        shown = []
        rows = []
        table.reloadData()
        showPlaceholder(message)
    }

    /// The column menu shape the toolbar's "…" menu expects, for the future
    /// top-level tab.
    func columnSelectorMenu() -> NSMenu {
        let menu = NSMenu()
        for col in table.tableColumns where col.identifier.rawValue != elasticColumnID {
            let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = col
            item.state = col.isHidden ? .off : .on
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Build

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

        if showProcess {
            addColumn(id: "process", title: "Process", width: 170, key: .process,
                      alignment: .left)
        }
        addColumn(id: "proto", title: "Protocol", width: 62, key: .proto, alignment: .left)
        // The .inset style spends 17pt between every column, so a sixth column
        // costs ~120pt of a 570pt pane. The local address is the same LAN IP on
        // every row of a single process, so the inspector spends that width on
        // the remote host instead; the wider top-level view keeps the column.
        if showProcess {
            addColumn(id: "laddr", title: "Local Address", width: 104, key: .laddr,
                      alignment: .left)
        }
        addColumn(id: "lport", title: "Local Port", width: 68, key: .lport,
                  alignment: .right)
        addColumn(id: "rhost", title: "Remote Host", width: 220, key: .rhost,
                  alignment: .left)
        addColumn(id: "rport", title: "Remote Port", width: 76, key: .rport,
                  alignment: .right)
        addColumn(id: "state", title: "State", width: 88, key: .state, alignment: .left)

        for col in table.tableColumns { col.resizingMask = [.userResizingMask] }
        table.columnAutoresizingStyle = .noColumnAutoresizing
    }

    private func addColumn(id: String, title: String, width: CGFloat,
                           key: SortKey, alignment: NSTextAlignment) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = 40
        defaultWidths[id] = width
        col.headerCell.alignment = alignment
        col.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
        table.addTableColumn(col)
    }

    private func buildLayout() {
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    private func showPlaceholder(_ message: String) {
        placeholder.stringValue = message
        placeholder.isHidden = false
        scroll.isHidden = true
    }

    private func hidePlaceholder() {
        placeholder.isHidden = true
        scroll.isHidden = false
    }

    // MARK: - Columns

    private func applySavedColumns() {
        let d = UserDefaults.standard
        let hidden = Set(d.stringArray(forKey: hiddenKey) ?? [])
        let widths = d.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
        isFittingColumns = true
        for col in table.tableColumns {
            let id = col.identifier.rawValue
            col.isHidden = hidden.contains(id)
            if id != elasticColumnID, let w = widths[id] { col.width = CGFloat(w) }
        }
        isFittingColumns = false
        fitElasticColumn()
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        let visible = table.tableColumns.filter { !$0.isHidden }
        if !col.isHidden, visible.count <= 1 { NSSound.beep(); return }
        col.isHidden.toggle()
        sender.state = col.isHidden ? .off : .on
        let hidden = table.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue }
        UserDefaults.standard.set(hidden, forKey: hiddenKey)
        fitElasticColumn()
    }

    override func layout() {
        super.layout()
        fitElasticColumn()
    }

    /// Frame-based views aren't guaranteed a layout pass when the tab view
    /// resizes them, so refit from the resize itself.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitElasticColumn()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitElasticColumn()
    }

    /// Same measurement as ProcessListView.fitNameColumn: tile first, then read
    /// the used width from the visible columns' rects — the table's own frame
    /// never shrinks below the clip view, so it can't be used here.
    private func fitElasticColumn() {
        guard let elastic = table.tableColumn(withIdentifier: .init(elasticColumnID)),
              !elastic.isHidden else { return }
        let clipW = scroll.contentSize.width
        guard clipW > 0 else { return }
        isFittingColumns = true
        defer { isFittingColumns = false }
        // Two passes: the first estimates the chrome overhead by assuming the
        // .inset style pads both sides equally, the second corrects whatever
        // that assumption got wrong (it under-counts, clipping the last column).
        for _ in 0..<2 {
            table.tile()
            let idxs = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
            guard let first = idxs.first, let last = idxs.last else { return }
            let leadPad = table.rect(ofColumn: first).minX
            let usedW = table.rect(ofColumn: last).maxX + leadPad
            let overflow = usedW - clipW
            guard abs(overflow) > 0.5 else { break }
            elastic.width = max(100, elastic.width - overflow)
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isFittingColumns,
              let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              col.identifier.rawValue != elasticColumnID else { return }
        var widths = UserDefaults.standard.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
        widths[col.identifier.rawValue] = Double(col.width)
        UserDefaults.standard.set(widths, forKey: widthsKey)
        fitElasticColumn()
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = tableView.sortDescriptors.first,
              let key = sd.key.flatMap(SortKey.init(rawValue:)) else { return }
        sortKey = key
        sortAscending = sd.ascending
        rows = sorted(rows)
        reloadPreservingSelection()
    }

    private func sorted(_ c: [Connection]) -> [Connection] {
        let asc = sortAscending
        func by<T: Comparable>(_ v: (Connection) -> T) -> [Connection] {
            c.sorted { asc ? v($0) < v($1) : v($0) > v($1) }
        }
        func byText(_ v: (Connection) -> String) -> [Connection] {
            c.sorted {
                let r = v($0).localizedCaseInsensitiveCompare(v($1))
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }
        switch sortKey {
        case .process: return byText { self.names[$0.pid] ?? "\($0.pid)" }
        case .proto:   return byText { $0.proto.label }
        case .laddr:   return byText { $0.localAddr }
        case .lport:   return by { $0.localPort }
        // Sort on what's displayed, so resolved names group together.
        case .rhost:   return byText { self.remoteHost($0) }
        case .rport:   return by { $0.remotePort }
        case .state:   return byText { ConnectionSampler.stateLabel($0.state) }
        }
    }

    // MARK: - Data

    private func remoteHost(_ c: Connection) -> String {
        guard !c.remoteAddr.isEmpty else { return "—" }
        return HostResolver.shared.name(for: c.remoteAddr) ?? c.remoteAddr
    }

    @objc private func hostsResolved() {
        guard !rows.isEmpty else { return }
        if sortKey == .rhost { rows = sorted(rows) }
        reloadPreservingSelection()
    }

    private func reloadPreservingSelection() {
        let keep = table.selectedRow >= 0 && table.selectedRow < rows.count
            ? rows[table.selectedRow] : nil
        table.reloadData()
        if let keep, let idx = rows.firstIndex(of: keep) {
            table.selectRowIndexes([idx], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let col = tableColumn, row < rows.count else { return nil }
        let id = col.identifier.rawValue
        let plainText = (id == "process" || id == "proto" || id == "state")
        let cell = (table.makeView(withIdentifier: col.identifier, owner: self) as? NSTableCellView)
            ?? ProcessListView.makeTextCell(identifier: col.identifier,
                                            monospaced: !plainText,
                                            alignment: plainText ? .left : col.headerCell.alignment)
        cell.textField?.stringValue = text(id: id, row: rows[row])
        return cell
    }

    private func text(id: String, row c: Connection) -> String {
        switch id {
        case "process": return names[c.pid] ?? "\(c.pid)"
        case "proto":   return c.proto.label
        case "laddr":   return c.localAddr.isEmpty ? "—" : c.localAddr
        case "lport":   return c.localPort == 0 ? "—" : "\(c.localPort)"
        case "rhost":   return remoteHost(c)
        case "rport":   return c.remotePort == 0 ? "—" : "\(c.remotePort)"
        case "state":   return ConnectionSampler.stateLabel(c.state)
        default:        return ""
        }
    }

    /// The resolved name replaces the address in the cell, so keep the raw IP
    /// reachable on hover.
    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell,
                   rect: NSRectPointer, tableColumn: NSTableColumn?,
                   row: Int, mouseLocation: NSPoint) -> String {
        guard tableColumn?.identifier.rawValue == "rhost", row < rows.count else { return "" }
        let c = rows[row]
        let local = "local \(c.localAddr):\(c.localPort)"
        guard let name = HostResolver.shared.name(for: c.remoteAddr) else {
            return "\(c.remoteAddr) · \(local)"
        }
        return "\(name)  (\(c.remoteAddr)) · \(local)"
    }
}

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
        case process, pid, user, proto, laddr, lport, rhost, rport, country
        case direction, state, rcvd, sent
    }

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private let showProcess: Bool
    private let defaultsKey: String

    private var all: [Connection] = []            // before the filter
    private var rows: [Connection] = []           // displayed
    private var owners: [pid_t: ProcessOwner] = [:]
    private var resolvedOwners: [pid_t: ProcessOwner?] = [:]
    private var filter = ""
    private var shown: Set<Connection> = []       // identity half of the no-op diff
    private var shownBytes: Double = 0            // byte half of it
    private var sortKey: SortKey
    private var sortAscending = true
    /// Clip width the columns were last fitted to.
    private var lastFitWidth: CGFloat = 0
    private var defaultWidths: [String: CGFloat] = [:]
    private var isFittingColumns = false
    /// True while showing a "can't read this" message rather than rows.
    private var unavailable = false
    /// Ports we're listening on, from the whole sample. One connection's
    /// direction can't be read from that connection alone, and sorting and
    /// filtering ask for every row's direction, so it's built once per sample
    /// rather than per cell.
    private var listeningPorts: Set<UInt16> = []

    private var widthsKey: String  { "ConnectionColumnWidths.\(defaultsKey)" }
    private var hiddenKey: String  { "ConnectionColumnsHidden.\(defaultsKey)" }
    private var orderKey: String   { "ConnectionColumnOrder.\(defaultsKey)" }

    /// The column that absorbs leftover width, like Process Name does in the
    /// process tabs.
    private var elasticColumnID: String { "rhost" }

    /// Summary strip, on the top-level tab only (nil in the inspector).
    private let footer: FooterBar?
    /// Set by buildFooterPanes; called with each new sample.
    private var footerUpdate: (([Connection]) -> Void)?
    /// Recent direction counts feeding the footer graph. Same cap as the
    /// process tabs' history, so both graphs span the same number of samples.
    private var directionHistory: [(out: Double, incoming: Double)] = []
    private static let historyCap = 60

    init(showProcess: Bool, defaultsKey: String) {
        self.showProcess = showProcess
        self.defaultsKey = defaultsKey
        self.sortKey = showProcess ? .process : .rhost
        self.footer = showProcess ? FooterBar() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        // NSTabView positions its item views by frame, so this view is sized
        // by its parent; its own subviews lay out with constraints.
        buildTable()
        buildLayout()
        buildRowMenu()
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
                        processNames: [pid_t: ProcessOwner] = [:]) {
        // Ahead of the no-op check below: the footer graph advances one sample
        // per tick whether or not the socket list changed, or an idle machine
        // would draw a frozen line rather than a flat one.
        footerUpdate?(inScope(connections))
        let incoming = Set(connections)
        // Identity alone isn't enough once byte counters are in play, but they
        // are excluded from ==, so diff them separately rather than reloading
        // whenever a single counter ticks.
        let bytes = connections.reduce(0.0) { $0 + ($1.rxBytes ?? 0) + ($1.txBytes ?? 0) }
        if !unavailable, incoming == shown, bytes == shownBytes, processNames == owners { return }
        unavailable = false
        shown = incoming
        shownBytes = bytes
        owners = processNames
        all = connections
        listeningPorts = ConnectionGraph.listeningPorts(in: connections)
        applyFilterAndSort()
    }

    /// Live filter over process name, addresses, ports and state — what the
    /// window's search field types into.
    func setFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != filter else { return }
        filter = trimmed
        applyFilterAndSort()
    }

    /// Hide Localhost / LAN / Remote, the persistent scope shared with the map.
    ///
    /// Listeners (no remote) always stay: they aren't traffic, and hiding them
    /// would make "what am I exposing" unanswerable.
    private func inScope(_ c: [Connection]) -> [Connection] {
        c.filter { c in
            if c.remoteAddr.isEmpty { return true }
            if Self.hidesLoopback, ConnectionGraph.isLoopback(c.remoteAddr) { return false }
            if Self.hidesLAN, ConnectionGraph.isLAN(c.remoteAddr) { return false }
            if Self.hidesRemote, !ConnectionGraph.isPrivate(c.remoteAddr) { return false }
            return true
        }
    }

    private func applyFilterAndSort() {
        let visible = inScope(all)
        let matches = filter.isEmpty ? visible : visible.filter { c in
            let fields = [processLabel(c), "\(c.pid)", owner(c.pid)?.user ?? "",
                          countryText(c), directionText(c), c.proto.label, c.localAddr,
                          "\(c.localPort)", remoteHost(c), c.remoteAddr,
                          "\(c.remotePort)", ConnectionSampler.stateLabel(c.state)]
            // c.remoteAddr is already in the list above, so typing an IP finds
            // the row whether or not its name is being shown.
            return fields.contains { $0.localizedCaseInsensitiveContains(filter) }
        }
        rows = sorted(matches)
        reloadPreservingSelection()
        // Data arrives long after the tab view sized this view, and the resize
        // hooks don't reliably fire for a frame-based pane, so settle the
        // elastic column here too — it costs a tile() every couple of seconds.
        fitElasticColumn()
        if rows.isEmpty {
            showPlaceholder(all.isEmpty ? "No connections" : "No matching connections")
        } else {
            hidePlaceholder()
        }
    }

    /// Flag plus code for a public address, a house for anything on this
    /// network (RFC1918, loopback, or their IPv6 equivalents), blank for space
    /// no registry has delegated.
    private func countryText(_ c: Connection) -> String {
        guard !c.remoteAddr.isEmpty else { return "" }
        if ConnectionGraph.isPrivate(c.remoteAddr) { return "🏠" }
        guard let code = GeoDatabase.countryCode(for: c.remoteAddr) else { return "" }
        let flag = GeoDatabase.flag(code)
        return flag.isEmpty ? code : "\(flag) \(code)"
    }

    /// Which end opened the connection, by the same rule that points the map's
    /// arrowheads. Listeners get a dash: nobody has dialled anything yet.
    private func directionText(_ c: Connection) -> String {
        guard !c.remoteAddr.isEmpty, c.state != TSI_S_LISTEN else { return "—" }
        switch ConnectionGraph.origin(of: c, listening: listeningPorts) {
        case .weInitiated:   return "Outgoing"
        case .theyInitiated: return "Incoming"
        case .unknown:       return "Unclear"
        }
    }

    /// Full process name where we have it: netstat truncates to 16 characters,
    /// but our own process list knows the whole thing.
    private func processLabel(_ c: Connection) -> String {
        // A socket outlives its process — Time Wait lingers for minutes — so an
        // unresolvable pid usually means the process has exited, not that we
        // failed to look it up.
        owner(c.pid)?.name ?? "(exited)"
    }

    /// The app's process list covers almost everything; anything newer than the
    /// last sample is resolved from the kernel and cached (a pid's path can't
    /// change, and the cache is dropped whenever the row set changes shape).
    private func owner(_ pid: pid_t) -> ProcessOwner? {
        if let o = owners[pid] { return o }
        if let cached = resolvedOwners[pid] { return cached }
        let o = ProcessOwner.forPID(pid)
        resolvedOwners[pid] = o
        return o
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

    /// Double-click hands the row's pid back, so the window can open the same
    /// inspector the process tabs do.
    var onInspect: ((pid_t) -> Void)?
    /// Quit / Force Quit the process owning the selected connection. Killing an
    /// individual connection isn't possible without root or a network
    /// extension, so the process is the unit of action here.
    var onQuit: ((pid_t) -> Void)?
    var onForceQuit: ((pid_t) -> Void)?

    /// pid of the selected row, or of the right-clicked one when a menu is up.
    var selectedPID: pid_t? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].pid
    }

    @objc private func inspectFromMenu() { selectedPID.map { onInspect?($0) } }
    @objc private func quitFromMenu()    { selectedPID.map { onQuit?($0) } }
    @objc private func forceQuitFromMenu() { selectedPID.map { onForceQuit?($0) } }

    private func buildRowMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [("Inspect Process", #selector(inspectFromMenu)),
                                ("Quit Process", #selector(quitFromMenu)),
                                ("Force Quit Process…", #selector(forceQuitFromMenu))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        table.menu = menu
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onInspect?(rows[row].pid)
    }

    /// The column menu shape the toolbar's "…" menu expects.
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
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = Theme.processRowHeight
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))

        if showProcess {
            addColumn(id: "process", title: "Process Name", width: 150, key: .process,
                      alignment: .left)
            addColumn(id: "pid", title: "PID", width: 54, key: .pid, alignment: .right)
            addColumn(id: "user", title: "User", width: 92, key: .user, alignment: .left)
        }
        addColumn(id: "proto", title: "Protocol", width: 56, key: .proto, alignment: .left)
        // The .inset style spends 17pt between every column, so a sixth column
        // costs ~120pt of a 570pt pane. The local address is the same LAN IP on
        // every row of a single process, so the inspector spends that width on
        // the remote host instead; the wider top-level view keeps the column.
        addColumn(id: "lport", title: "Local Port", width: 62, key: .lport,
                  alignment: .right)
        addColumn(id: "rhost", title: "Remote Host", width: 190, key: .rhost,
                  alignment: .left)
        addColumn(id: "rport", title: "Remote Port", width: 80, key: .rport,
                  alignment: .right)
        if showProcess {
            // Same table the map reads, so "Show Countries" governs both.
            addColumn(id: "country", title: "Country", width: 64, key: .country,
                      alignment: .left)
        }
        // Which end opened it, by the same rule the map's arrowheads use.
        addColumn(id: "dir", title: "Direction", width: 76, key: .direction,
                  alignment: .left)
        addColumn(id: "state", title: "State", width: 88, key: .state, alignment: .left)
        if showProcess {
            // netstat carries per-connection counters; libproc doesn't, so
            // these only appear in the system-wide view.
            addColumn(id: "rcvd", title: "Rcvd", width: 68, key: .rcvd, alignment: .right)
            addColumn(id: "sent", title: "Sent", width: 68, key: .sent, alignment: .right)
        }

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
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(placeholder)
        var constraints = [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ]
        // The footer belongs to the top-level tab, where it's the only summary
        // of the whole picture. The inspector's copy is already scoped to one
        // process and is short enough that 66pt of chrome would cost a row.
        if let footer {
            buildFooterPanes(footer)
            addSubview(footer)
            constraints += [
                scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
                footer.leadingAnchor.constraint(equalTo: leadingAnchor),
                footer.trailingAnchor.constraint(equalTo: trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Three panes matching the process tabs': who dialled whom, that same
    /// split over time, and what the sockets are.
    ///
    /// Counts cover what the table is showing you — Hide Localhost and friends
    /// apply, or the footer would report incoming connections on a table with
    /// none in it. The search field is deliberately *not* applied: that's a
    /// transient lookup, and a summary that moved as you typed would be
    /// answering a different question from the one it looks like it answers.
    private func buildFooterPanes(_ bar: FooterBar) {
        // Outbound red, inbound blue — the same way round as the Disk tab's
        // reads and writes.
        let direction = FooterStatGrid(rows: [
            .init(label: "Outgoing:", color: .systemRed),
            .init(label: "Incoming:", color: .systemBlue),
            .init(label: "Unclear:", color: nil),
        ])
        let graph = FooterGraphView(caption: "Connections",
                                    colors: [.systemRed, .systemBlue], mode: .mirror)
        let kinds = FooterStatGrid(rows: [
            .init(label: "TCP:", color: nil),
            .init(label: "UDP:", color: nil),
            .init(label: "Listening:", color: nil),
        ])
        bar.setPanes([direction, graph, kinds])

        footerUpdate = { [weak self] rows in
            guard let self else { return }
            let counts = ConnectionGraph.originCounts(of: rows)
            direction.setValue("\(counts.outgoing)", at: 0)
            direction.setValue("\(counts.incoming)", at: 1)
            direction.setValue("\(counts.unclear)", at: 2)

            self.directionHistory.append((Double(counts.outgoing),
                                          Double(counts.incoming)))
            if self.directionHistory.count > Self.historyCap {
                self.directionHistory.removeFirst()
            }
            // Shared scale across both halves so the mirror compares them,
            // with a floor so a quiet machine doesn't draw one connection as
            // a full-height block.
            let peak = max(10, self.directionHistory
                .map { max($0.out, $0.incoming) }.max() ?? 0)
            graph.setLayers([self.directionHistory.map { $0.out / peak },
                             self.directionHistory.map { $0.incoming / peak }])

            var tcp = 0, udp = 0, listening = 0
            for c in rows {
                switch c.proto {
                case .tcp4, .tcp6: tcp += 1
                case .udp4, .udp6: udp += 1
                }
                if c.state == TSI_S_LISTEN { listening += 1 }
            }
            kinds.setValue("\(tcp)", at: 0)
            kinds.setValue("\(udp)", at: 1)
            kinds.setValue("\(listening)", at: 2)
        }
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

    /// Columns that start hidden until the user says otherwise. The system-wide
    /// view has ten columns and the .inset style spends 17pt between each, so
    /// something has to give at a default window width; the local port is the
    /// least informative (it's an ephemeral number) and it's one click away in
    /// the "…" › Columns menu.
    private var defaultHidden: Set<String> { showProcess ? ["lport"] : [] }

    private func applySavedColumns() {
        let d = UserDefaults.standard
        TableColumnOrder.apply(d.stringArray(forKey: orderKey), to: table)
        let hidden = Set(d.stringArray(forKey: hiddenKey) ?? Array(defaultHidden))
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

    override func viewWillDraw() {
        super.viewWillDraw()
        if scroll.contentSize.width != lastFitWidth { fitElasticColumn() }
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
        lastFitWidth = clipW
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
            elastic.width = max(90, elastic.width - overflow)
        }
    }

    func tableView(_ tableView: NSTableView, didDrag tableColumn: NSTableColumn) {
        UserDefaults.standard.set(TableColumnOrder.of(table), forKey: orderKey)
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
        case .process: return byText { self.processLabel($0) }
        case .pid:     return by { $0.pid }
        case .user:    return byText { self.owner($0.pid)?.user ?? "" }
        case .proto:   return byText { $0.proto.label }
        case .laddr:   return byText { $0.localAddr }
        case .lport:   return by { $0.localPort }
        // Sort on what's displayed, so resolved names group together.
        case .rhost:   return byText { self.remoteHost($0) }
        case .rport:   return by { $0.remotePort }
        case .country: return byText { self.countryText($0) }
        case .direction: return byText { self.directionText($0) }
        case .state:   return byText { ConnectionSampler.stateLabel($0.state) }
        case .rcvd:    return by { $0.rxBytes ?? -1 }
        case .sent:    return by { $0.txBytes ?? -1 }
        }
    }

    // MARK: - Data

    /// Whether the Remote Host column shows PTR names or the raw address.
    /// Shared by every connections table, persisted across launches.
    private static let resolveKey = "ConnectionsResolveHostNames"
    static var resolvesHostNames: Bool {
        get { UserDefaults.standard.object(forKey: resolveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: resolveKey) }
    }

    /// Two independent filters, shared with the connection map so both
    /// surfaces agree. Loopback never leaves the machine and is rarely what
    /// you came to look at, so it starts hidden; LAN peers are real traffic to
    /// real devices and start visible.
    private static let hideLoopbackKey = "ConnectionsHideLoopback"
    private static let hideLANKey = "ConnectionsHideLAN"
    static var hidesLoopback: Bool {
        get { UserDefaults.standard.object(forKey: hideLoopbackKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hideLoopbackKey) }
    }
    static var hidesLAN: Bool {
        get { UserDefaults.standard.bool(forKey: hideLANKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideLANKey) }
    }

    /// The complement of the other two: everything off this network.
    private static let hideRemoteKey = "ConnectionsHideRemote"
    static var hidesRemote: Bool {
        get { UserDefaults.standard.bool(forKey: hideRemoteKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideRemoteKey) }
    }

    /// Map-only for now: the table lists sockets, where direction is a
    /// per-row property rather than a view mode.
    private static let directionsKey = "ConnectionsDirections"
    static var directions: ConnectionGraph.DirectionSet {
        get {
            guard let raw = UserDefaults.standard.object(forKey: directionsKey) as? Int
            else { return .all }
            let set = ConnectionGraph.DirectionSet(rawValue: raw)
            return set.isEmpty ? .all : set
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: directionsKey) }
    }

    /// Re-render after a display setting is toggled (host names also change
    /// the sort order, since that column sorts on what's displayed).
    func hostNameDisplayChanged() {
        // Also covers the scope toggles, which change what the footer counts —
        // waiting for the next sample would leave it a second out of step with
        // the rows.
        footerUpdate?(inScope(all))
        applyFilterAndSort()
    }

    private func remoteHost(_ c: Connection) -> String {
        guard !c.remoteAddr.isEmpty else { return "—" }
        guard Self.resolvesHostNames else { return c.remoteAddr }
        return HostResolver.shared.name(for: c.remoteAddr) ?? c.remoteAddr
    }

    @objc private func hostsResolved() {
        guard !rows.isEmpty else { return }
        if sortKey == .rhost || sortKey == .country { rows = sorted(rows) }
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
        let c = rows[row]
        if id == "process" {
            let cell = (table.makeView(withIdentifier: col.identifier, owner: self) as? NSTableCellView)
                ?? ProcessListView.makeNameCell(identifier: col.identifier)
            cell.imageView?.image = ProcessListView.icon(forExecPath: owner(c.pid)?.execPath ?? "")
            cell.textField?.stringValue = text(id: id, row: c)
            return cell
        }
        let plainText = (id == "proto" || id == "state")
        let cell = (table.makeView(withIdentifier: col.identifier, owner: self) as? NSTableCellView)
            ?? ProcessListView.makeTextCell(identifier: col.identifier,
                                            monospaced: !plainText,
                                            alignment: plainText ? .left : col.headerCell.alignment)
        cell.textField?.stringValue = text(id: id, row: c)
        return cell
    }

    private typealias F = ProcessListView

    private func text(id: String, row c: Connection) -> String {
        switch id {
        case "process": return processLabel(c)
        case "pid":     return "\(c.pid)"
        case "user":    return owner(c.pid)?.user ?? "—"
        case "proto":   return c.proto.label
        case "laddr":   return c.localAddr.isEmpty ? "—" : c.localAddr
        case "lport":   return c.localPort == 0 ? "—" : "\(c.localPort)"
        case "rhost":   return remoteHost(c)
        case "rport":   return c.remotePort == 0 ? "—" : "\(c.remotePort)"
        case "country": return countryText(c)
        case "dir":     return directionText(c)
        case "state":   return ConnectionSampler.stateLabel(c.state)
        case "rcvd":    return c.rxBytes.map(F.formatTotal) ?? "—"
        case "sent":    return c.txBytes.map(F.formatTotal) ?? "—"
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

import AppKit

extension NSToolbarItem.Identifier {
    static let mapDirection = NSToolbarItem.Identifier("MapDirection")
    static let mapActions   = NSToolbarItem.Identifier("MapActions")
    static let mapPause     = NSToolbarItem.Identifier("MapPause")
}

/// Window around ConnectionMapView. One instance at a time, owned by the chart
/// window, which forwards every connection sample to it.
///
/// Chrome follows the main window — a unified toolbar with a centered
/// segmented control and a pull-down menu — rather than controls sitting on
/// the canvas.
final class ConnectionMapWindowController: NSWindowController, NSWindowDelegate,
                                           NSToolbarDelegate, NSMenuDelegate {
    var onClose: (() -> Void)?

    /// Lets the owner re-filter the table when the map's scope changes.
    var onScopeChange: (() -> Void)?

    /// Clicking a node opens the same inspector the process tabs use.
    var onInspect: ((pid_t) -> Void)? {
        get { map.onInspect }
        set { map.onInspect = newValue }
    }

    private let map = ConnectionMapView()
    private let direction = NSSegmentedControl(
        labels: ConnectionGraph.DirectionSet.ordered.map(\.1),
        trackingMode: .selectAny, target: nil, action: nil)
    private var actionsItem: NSMenuToolbarItem?
    private var pauseItem: NSToolbarItem?
    /// Holds the picture still until you say otherwise — the hover freeze only
    /// lasts as long as the pointer rests on a node.
    private var isPaused = false
    private var rows: [Connection] = []
    private var owners: [pid_t: ProcessOwner] = [:]

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Connection Map"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 460)
        super.init(window: win)
        shouldCascadeWindows = false          // would defeat the autosave name
        windowFrameAutosaveName = "ConnectionMap"
        win.delegate = self

        // Neutral selection, like the main window's tab selector and the
        // inspector's — the accent blue reads as a different kind of control.
        direction.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
        direction.target = self
        direction.action = #selector(directionChanged(_:))
        direction.toolTip = "Which side opened the connection. Unclear covers UDP, "
            + "which has no handshake, and hosts dialled in both directions."
        syncDirection()

        let toolbar = NSToolbar(identifier: "ConnectionMap")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.mapDirection]
        win.toolbarStyle = .unified
        win.toolbar = toolbar

        map.frame = NSRect(origin: .zero, size: win.contentLayoutRect.size)
        map.autoresizingMask = [.width, .height]
        win.acceptsMouseMovedEvents = true
        win.contentView = map
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.mapActions, .mapPause, .flexibleSpace, .mapDirection, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .mapDirection:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = direction
            item.label = "Direction"
            return item
        case .mapPause:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "pause.circle",
                                 accessibilityDescription: "Pause")
            item.label = "Pause"
            item.toolTip = "Stop refreshing the map"
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = #selector(togglePause(_:))
            pauseItem = item
            return item
        case .mapActions:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                 accessibilityDescription: "Filter")
            item.label = "Filter"
            item.toolTip = "What to include"
            item.isBordered = true
            item.autovalidates = false
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            actionsItem = item
            return item
        default:
            return nil
        }
    }

    /// NSToolbar inserts a *copy* of the delegate's item, so capture the one
    /// that actually lands in the bar.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSMenuToolbarItem,
              item.itemIdentifier == .mapActions else { return }
        item.menu.delegate = self
        actionsItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // NSMenuToolbarItem is a pull-down: it swallows the first entry.
        let placeholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        placeholder.isHidden = true
        menu.addItem(placeholder)

        for (title, on, tag, tip) in [
            ("Hide Localhost", ConnectionListView.hidesLoopback, 0,
             "Hide 127.0.0.1 and ::1 — traffic that never leaves this Mac"),
            ("Hide LAN", ConnectionListView.hidesLAN, 1,
             "Hide RFC1918 and link-local peers — other devices on this network"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(toggleScope(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.tag = tag
            item.toolTip = tip
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func togglePause(_ sender: Any?) {
        isPaused.toggle()
        pauseItem?.image = NSImage(
            systemSymbolName: isPaused ? "play.circle" : "pause.circle",
            accessibilityDescription: isPaused ? "Resume" : "Pause")
        pauseItem?.toolTip = isPaused ? "Resume refreshing" : "Stop refreshing the map"
        // Resuming catches up on whatever arrived while it was held.
        rebuild(immediate: true)
    }

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        var set = ConnectionGraph.DirectionSet()
        for (i, entry) in ConnectionGraph.DirectionSet.ordered.enumerated()
        where sender.isSelected(forSegment: i) {
            set.insert(entry.0)
        }
        // Turning the last one off would blank the map with no way back from
        // the map itself; refuse it the way the column menu refuses the last
        // column.
        guard !set.isEmpty else {
            NSSound.beep()
            syncDirection()
            return
        }
        ConnectionListView.directions = set
        rebuild(immediate: true)
    }

    private func syncDirection() {
        let set = ConnectionListView.directions
        for (i, entry) in ConnectionGraph.DirectionSet.ordered.enumerated() {
            direction.setSelected(set.contains(entry.0), forSegment: i)
        }
    }

    @objc private func toggleScope(_ sender: NSMenuItem) {
        if sender.tag == 0 { ConnectionListView.hidesLoopback.toggle() }
        else               { ConnectionListView.hidesLAN.toggle() }
        onScopeChange?()
        rebuild(immediate: true)
    }

    // MARK: - Data

    /// Fed from the same sample that drives the Connections table.
    func setConnections(_ rows: [Connection], processNames: [pid_t: ProcessOwner]) {
        // Keep collecting while paused so resuming shows the present, not a
        // replay of the moment you paused.
        self.rows = rows
        self.owners = processNames
        guard !isPaused else { return }
        rebuild()
    }

    /// Also called when a setting changes here or in the Connections tab's "…"
    /// menu, so the two stay in step. `immediate` skips the pointer-freeze,
    /// because a change the user just made has to land now.
    func rebuild(immediate: Bool = false) {
        syncDirection()
        let nodes = ConnectionGraph.nodes(from: rows,
                                          hidingLoopback: ConnectionListView.hidesLoopback,
                                          hidingLAN: ConnectionListView.hidesLAN,
                                          directions: ConnectionListView.directions)
        map.setNodes(nodes, owners: owners, immediate: immediate)
        var subtitle = nodes.isEmpty ? "" : "\(nodes.count) host\(nodes.count == 1 ? "" : "s")"
        if isPaused { subtitle += subtitle.isEmpty ? "paused" : " · paused" }
        window?.subtitle = subtitle
    }
}

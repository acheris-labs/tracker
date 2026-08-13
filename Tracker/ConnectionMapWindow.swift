import AppKit

extension NSToolbarItem.Identifier {
    static let mapDirection = NSToolbarItem.Identifier("MapDirection")
    static let mapActions   = NSToolbarItem.Identifier("MapActions")
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
        labels: ["Both", "Outgoing", "Incoming"],
        trackingMode: .selectOne, target: nil, action: nil)
    private var actionsItem: NSMenuToolbarItem?
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

        direction.selectedSegment = ConnectionListView.directionFilter.rawValue
        direction.target = self
        direction.action = #selector(directionChanged(_:))
        direction.toolTip = "Filter by which side opened the connection"

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
        [.mapActions, .flexibleSpace, .mapDirection, .flexibleSpace]
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

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        ConnectionListView.directionFilter =
            ConnectionGraph.DirectionFilter(rawValue: sender.selectedSegment) ?? .all
        rebuild(immediate: true)
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
        self.rows = rows
        self.owners = processNames
        rebuild()
    }

    /// Also called when a setting changes here or in the Connections tab's "…"
    /// menu, so the two stay in step. `immediate` skips the pointer-freeze,
    /// because a change the user just made has to land now.
    func rebuild(immediate: Bool = false) {
        direction.selectedSegment = ConnectionListView.directionFilter.rawValue
        let nodes = ConnectionGraph.nodes(from: rows,
                                          hidingLoopback: ConnectionListView.hidesLoopback,
                                          hidingLAN: ConnectionListView.hidesLAN,
                                          direction: ConnectionListView.directionFilter)
        map.setNodes(nodes, owners: owners, immediate: immediate)
        window?.subtitle = nodes.isEmpty ? ""
            : "\(nodes.count) host\(nodes.count == 1 ? "" : "s")"
    }
}

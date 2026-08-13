import AppKit

/// Window around ConnectionMapView. One instance at a time, owned by the chart
/// window, which forwards every connection sample to it.
final class ConnectionMapWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let map = ConnectionMapView()
    private let hideLoopback = NSButton(checkboxWithTitle: "Hide localhost",
                                        target: nil, action: nil)
    private let hideLAN = NSButton(checkboxWithTitle: "Hide LAN",
                                   target: nil, action: nil)
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

        let root = NSView(frame: NSRect(origin: .zero, size: win.contentLayoutRect.size))
        map.frame = root.bounds
        map.autoresizingMask = [.width, .height]
        root.addSubview(map)

        // Top-left, over the empty corner the circle never reaches.
        hideLoopback.toolTip = "Hide 127.0.0.1 and ::1 — traffic that never leaves this Mac"
        hideLAN.toolTip = "Hide RFC1918 and link-local peers — other devices on this network"
        let checks = NSStackView(views: [hideLoopback, hideLAN])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 2
        checks.translatesAutoresizingMaskIntoConstraints = false
        for box in [hideLoopback, hideLAN] {
            box.target = self
            box.action = #selector(toggleScope(_:))
        }
        root.addSubview(checks)
        NSLayoutConstraint.activate([
            checks.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            checks.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
        ])

        win.contentView = root
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    @objc private func toggleScope(_ sender: NSButton) {
        if sender === hideLoopback { ConnectionListView.hidesLoopback = sender.state == .on }
        if sender === hideLAN      { ConnectionListView.hidesLAN = sender.state == .on }
        onScopeChange?()
        rebuild()
    }

    /// Lets the owner re-filter the table when the map's checkboxes change.
    var onScopeChange: (() -> Void)?

    /// Fed from the same sample that drives the Connections table.
    func setConnections(_ rows: [Connection], processNames: [pid_t: ProcessOwner]) {
        self.rows = rows
        self.owners = processNames
        rebuild()
    }

    /// Also called when the setting changes from the window's own checkbox or
    /// the Connections tab's "…" menu, so the two stay in step.
    func rebuild() {
        hideLoopback.state = ConnectionListView.hidesLoopback ? .on : .off
        hideLAN.state = ConnectionListView.hidesLAN ? .on : .off
        let nodes = ConnectionGraph.nodes(from: rows,
                                          hidingLoopback: ConnectionListView.hidesLoopback,
                                          hidingLAN: ConnectionListView.hidesLAN)
        map.setNodes(nodes, owners: owners)
        window?.subtitle = nodes.isEmpty ? ""
            : "\(nodes.count) host\(nodes.count == 1 ? "" : "s")"
    }
}

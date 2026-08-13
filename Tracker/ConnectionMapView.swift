import AppKit

/// The machine at the centre, the hosts it is talking to around it, and edges
/// weighted by how much data crossed them. Arrowheads say who dialled whom.
final class ConnectionMapView: NSView {
    private var nodes: [GraphNode] = []
    private var owners: [pid_t: ProcessOwner] = [:]
    /// Where each node was drawn, for hit-testing the pointer.
    private var placements: [(node: GraphNode, center: NSPoint)] = []
    /// Addresses in the order they were first seen. Ordering by traffic made
    /// the circle reshuffle on every refresh; a host keeps its seat instead.
    private var order: [String] = []
    /// Samples that arrived while the pointer was inside, applied on exit.
    private var pending: ([GraphNode], [pid_t: ProcessOwner])?
    private var pointerInside = false
    private var hovered: Int?

    /// Click a node to inspect the process behind it.
    var onInspect: ((pid_t) -> Void)?

    private static let nodeRadius: CGFloat = 26
    /// Discs shrink once the circle gets busy, so 60 hosts still fit.
    private var nodeRadius: CGFloat { nodes.count > 30 ? 19 : Self.nodeRadius }
    private static let hubRadius: CGFloat = 40
    private static let minEdgeWidth: CGFloat = 1
    private static let maxEdgeWidth: CGFloat = 14
    /// Bytes at or below this draw the thinnest edge; the scale is
    /// logarithmic above it, as on the chart's bytes/sec axis.
    private static let edgeFloor: Double = 4096

    override var isFlipped: Bool { false }

    /// `immediate` is for changes the user just made — a filter toggle has to
    /// take effect at once, even with the pointer resting over the map.
    func setNodes(_ n: [GraphNode], owners: [pid_t: ProcessOwner], immediate: Bool = false) {
        // Otherwise hold still while the pointer is over the map: the thing
        // being pointed at must not move out from under it.
        guard immediate || !pointerInside else { pending = (n, owners); return }
        pending = nil
        apply(n, owners)
    }

    private func apply(_ n: [GraphNode], _ newOwners: [pid_t: ProcessOwner]) {
        let present = Set(n.map(\.address))
        order.removeAll { !present.contains($0) }
        // New hosts join in traffic order, behind everyone already seated.
        for node in n.sorted(by: { $0.total > $1.total }) where !order.contains(node.address) {
            order.append(node.address)
        }
        let byAddress = Dictionary(n.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        nodes = order.compactMap { byAddress[$0] }
        owners = newOwners
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for name in [HostResolver.resolved, GeoResolver.resolved] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(lookupsResolved),
                name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func lookupsResolved() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerInside = true
        let p = convert(event.locationInWindow, from: nil)
        let hit = placements.firstIndex { hypot($0.center.x - p.x, $0.center.y - p.y) <= nodeRadius }
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hovered = nil
        if let (n, o) = pending {          // catch up on what we held back
            pending = nil
            apply(n, o)
        } else {
            needsDisplay = true
        }
    }

    /// A click on a node should work even when the map isn't the key window —
    /// otherwise the first click is swallowed activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = placements.first(where: {
            hypot($0.center.x - p.x, $0.center.y - p.y) <= nodeRadius
        }) else { return }
        let pids = hit.node.pids.sorted()
        guard pids.count > 1 else {
            busiestPID(of: hit.node).map { onInspect?($0) }
            return
        }
        // Several processes share this host — let the click choose which.
        let menu = NSMenu()
        menu.addItem(withTitle: label(for: hit.node), action: nil, keyEquivalent: "")
        menu.items.first?.isEnabled = false
        menu.addItem(.separator())
        for (i, pid) in pids.enumerated() {
            let name = owners[pid]?.name ?? ProcessOwner.forPID(pid)?.name
            let item = NSMenuItem(title: name.map { "\($0) (\(pid))" } ?? "pid \(pid) (exited)",
                                  action: #selector(inspectFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(pid)
            item.isEnabled = name != nil
            item.image = name.flatMap { _ in
                owners[pid].map { ProcessListView.icon(forExecPath: $0.execPath) }
            }
            menu.addItem(item)
            _ = i
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func inspectFromMenu(_ sender: NSMenuItem) {
        onInspect?(pid_t(sender.tag))
    }

    /// Prefer a pid the process list still knows about: a host's sockets can
    /// outlive the process that opened them, and inspecting a dead pid does
    /// nothing but beep.
    private func busiestPID(of node: GraphNode) -> pid_t? {
        node.pids.first(where: { owners[$0] != nil })
            ?? node.pids.first(where: { ProcessOwner.forPID($0) != nil })
            ?? node.pids.sorted().first
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        placements.removeAll()

        guard !nodes.isEmpty else {
            drawCentered("No connections", in: bounds)
            return
        }

        let light = effectiveAppearance.isLight
        let hub = NSPoint(x: bounds.midX, y: bounds.midY)
        // Leave room for a node and its label at the rim.
        // Side labels need horizontal room; top and bottom ones need less.
        let radius = max(90, min(bounds.width / 2 - nodeRadius - 190,
                                 bounds.height / 2 - nodeRadius - 40))
        let peak = nodes.map(\.total).max() ?? 0

        // Edges first so the nodes sit on top of them.
        for (i, node) in nodes.enumerated() {
            let p = point(at: i, of: nodes.count, hub: hub, radius: radius)
            drawEdge(from: hub, to: p, node: node, peak: peak, light: light)
        }
        for (i, node) in nodes.enumerated() {
            let p = point(at: i, of: nodes.count, hub: hub, radius: radius)
            drawNode(node, at: p, light: light, index: i, hubCenter: hub)
            placements.append((node, p))
        }
        drawHub(at: hub)
        drawLegend(light: light)
        if let i = hovered, i < placements.count {
            drawHoverPanel(for: placements[i].node, at: placements[i].center)
        }
    }

    /// What the node actually is: which processes, how many sockets, which way
    /// it was opened. Drawn rather than left to NSToolTip so it appears at
    /// once — and because the tooltip rects were being torn down every refresh.
    private func drawHoverPanel(for node: GraphNode, at p: NSPoint) {
        var lines: [PanelLine] = []
        let host = label(for: node)
        lines.append(PanelLine(text: host, weight: .semibold, color: .labelColor))
        if host != node.address, !node.isOverflow {
            lines.append(PanelLine(text: node.address, color: .secondaryLabelColor))
        }
        // Same icon the process tabs and the click menu use, so a row is
        // recognisable without reading it.
        let pids = node.pids.sorted()
        for pid in pids.prefix(6) {
            let owner = owners[pid] ?? ProcessOwner.forPID(pid)
            lines.append(PanelLine(
                text: owner.map { "\($0.name) (\(pid))" } ?? "pid \(pid) (exited)",
                color: owner == nil ? .secondaryLabelColor : .labelColor,
                icon: owner.map { ProcessListView.icon(forExecPath: $0.execPath) }))
        }
        if pids.count > 6 {
            lines.append(PanelLine(text: "+\(pids.count - 6) more", color: .secondaryLabelColor))
        }
        if pids.isEmpty {
            lines.append(PanelLine(text: "process has exited", color: .secondaryLabelColor))
        }
        let direction: String
        switch node.origin {
        case .weInitiated:   direction = "This Mac connected out"
        case .theyInitiated: direction = "Connected in to this Mac"
        case .unknown:       direction = "Direction unclear"
        }
        lines.append(PanelLine(
            text: "\(node.connections) connection\(node.connections == 1 ? "" : "s") · port \(node.port)",
            color: .secondaryLabelColor))
        lines.append(PanelLine(text: "↓\(F.formatTotal(node.rxBytes))  ↑\(F.formatTotal(node.txBytes))",
                               color: .secondaryLabelColor))
        lines.append(PanelLine(text: direction, color: .secondaryLabelColor))
        lines.append(PanelLine(text: pids.count > 1 ? "click to choose a process" : "click to inspect",
                               color: .tertiaryLabelColor))

        let pad: CGFloat = 9
        let iconSize: CGFloat = 14
        let iconGap: CGFloat = 5
        var width: CGFloat = 0, height: CGFloat = 0
        var sizes: [NSSize] = []
        for line in lines {
            let size = line.text.size(withAttributes: attributes(11, .labelColor, line.weight))
            sizes.append(size)
            let indent = line.icon == nil ? 0 : iconSize + iconGap
            width = max(width, size.width + indent)
            height += max(size.height, line.icon == nil ? 0 : iconSize) + 2
        }
        var frame = NSRect(x: p.x + nodeRadius + 8, y: p.y - height / 2 - pad,
                           width: width + pad * 2, height: height + pad * 2)
        if frame.maxX > bounds.maxX - 4 { frame.origin.x = p.x - nodeRadius - 8 - frame.width }
        frame.origin.x = max(4, frame.origin.x)
        frame.origin.y = max(4, min(frame.origin.y, bounds.maxY - frame.height - 4))

        let box = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1
        box.stroke()

        var y = frame.maxY - pad
        for (i, line) in lines.enumerated() {
            let rowHeight = max(sizes[i].height, line.icon == nil ? 0 : iconSize)
            y -= rowHeight + 2
            var x = frame.minX + pad
            if let icon = line.icon {
                icon.draw(in: NSRect(x: x, y: y + (rowHeight - iconSize) / 2,
                                     width: iconSize, height: iconSize))
                x += iconSize + iconGap
            }
            line.text.draw(at: NSPoint(x: x, y: y + (rowHeight - sizes[i].height) / 2),
                           withAttributes: attributes(11, line.color, line.weight))
        }
    }

    /// One row of the hover panel; the icon is the process's, where there is one.
    private struct PanelLine {
        var text: String
        var weight: NSFont.Weight = .regular
        var color: NSColor
        var icon: NSImage?
    }

    /// Nothing about colour or arrow direction is guessable, so say it.
    private func drawLegend(light: Bool) {
        let entries: [(NSColor, String)] = [
            (Self.inboundColor.onSurface(light: light), "mostly received"),
            (Self.outboundColor.onSurface(light: light), "mostly sent"),
        ]
        var y = bounds.minY + 12
        let attrs = attributes(10, .secondaryLabelColor, .regular)
        ("arrow points the way the connection was opened; none = unclear" as NSString)
            .draw(at: NSPoint(x: 14, y: y), withAttributes: attrs)
        y += 15
        for (color, text) in entries.reversed() {
            let swatch = NSRect(x: 14, y: y + 3, width: 18, height: 3)
            color.setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 1.5, yRadius: 1.5).fill()
            (text as NSString).draw(at: NSPoint(x: 38, y: y), withAttributes: attrs)
            y += 15
        }
    }

    /// Clockwise from twelve o'clock, so the busiest host (first) is at the top.
    private func point(at i: Int, of count: Int, hub: NSPoint, radius: CGFloat) -> NSPoint {
        let angle = .pi / 2 - (CGFloat(i) / CGFloat(max(1, count))) * 2 * .pi
        return NSPoint(x: hub.x + cos(angle) * radius, y: hub.y + sin(angle) * radius)
    }

    private func drawHub(at p: NSPoint) {
        let r = Self.hubRadius
        let rect = NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        drawCentered("This Mac", in: rect, weight: .semibold)
    }

    /// Cool inbound, warm outbound — the chart's convention, but saturated.
    /// The chart keeps its network hues pale so they read apart from disk;
    /// here there are only two colours, so they can carry weight.
    private static let inboundColor = NSColor(srgbRed: 0.20, green: 0.58, blue: 1.00, alpha: 1)
    private static let outboundColor = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.30, alpha: 1)

    private func drawEdge(from hub: NSPoint, to p: NSPoint, node: GraphNode,
                          peak: Double, light: Bool) {
        let inbound = node.rxBytes >= node.txBytes
        let color = (inbound ? Self.inboundColor : Self.outboundColor).onSurface(light: light)

        // Start and end outside the two discs so the line reads as a link
        // rather than a spoke through them.
        let dx = p.x - hub.x, dy = p.y - hub.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let ux = dx / len, uy = dy / len
        let a = NSPoint(x: hub.x + ux * Self.hubRadius, y: hub.y + uy * Self.hubRadius)
        let b = NSPoint(x: p.x - ux * nodeRadius, y: p.y - uy * nodeRadius)

        let lineWidth = width(for: node.total, peak: peak)
        // A 9pt head disappears inside a 14pt line, so it scales with the line
        // and the line stops short to leave the point clear.
        let head = max(9, lineWidth * 2.1)
        let inset = node.origin == .unknown ? 0 : head * 0.55

        let path = NSBezierPath()
        switch node.origin {
        case .weInitiated:
            path.move(to: a)
            path.line(to: NSPoint(x: b.x - ux * inset, y: b.y - uy * inset))
        case .theyInitiated:
            path.move(to: NSPoint(x: a.x + ux * inset, y: a.y + uy * inset))
            path.line(to: b)
        case .unknown:
            path.move(to: a)
            path.line(to: b)
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.withAlphaComponent(0.85).setStroke()
        path.stroke()

        switch node.origin {
        case .weInitiated:   drawArrow(at: b, ux: ux, uy: uy, color: color, size: head)
        case .theyInitiated: drawArrow(at: a, ux: -ux, uy: -uy, color: color, size: head)
        case .unknown:       break
        }
    }

    /// Logarithmic, like the chart's bytes/sec axis: a 2 GB transfer and a
    /// 20 KB one have to share a scale without one of them vanishing.
    private func width(for bytes: Double, peak: Double) -> CGFloat {
        guard bytes > Self.edgeFloor, peak > Self.edgeFloor else { return Self.minEdgeWidth }
        let span = log(peak / Self.edgeFloor)
        guard span > 0 else { return Self.minEdgeWidth }
        let t = min(1, log(bytes / Self.edgeFloor) / span)
        return Self.minEdgeWidth + CGFloat(t) * (Self.maxEdgeWidth - Self.minEdgeWidth)
    }

    private func drawArrow(at tip: NSPoint, ux: CGFloat, uy: CGFloat,
                           color: NSColor, size: CGFloat) {
        let back = NSPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        // Perpendicular, for the two barbs.
        let px = -uy * size * 0.42, py = ux * size * 0.42
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: back.x + px, y: back.y + py))
        path.line(to: NSPoint(x: back.x - px, y: back.y - py))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawNode(_ node: GraphNode, at p: NSPoint, light: Bool,
                          index: Int, hubCenter: NSPoint) {
        let r = nodeRadius
        let rect = NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let disc = NSBezierPath(ovalIn: rect)
        NSColor.controlBackgroundColor.setFill()
        disc.fill()
        NSColor.separatorColor.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        // The disc says *where*: a flag for a public host once its registry
        // answers, a house for anything on this network, a globe until then.
        // (Mixing ports in here made two unrelated things share one slot.)
        let inside: String
        if node.isOverflow            { inside = "+\(node.hiddenHosts)" }
        else if node.isPrivate        { inside = "🏠" }
        else if let f = flag(node)    { inside = f }
        else                          { inside = "🌐" }
        drawCentered(inside, in: rect, size: node.isOverflow ? 12 : 15)

        // Host and totals sit just outside the disc, along the spoke — a
        // fixed offset below each node put some labels closer to their
        // neighbour than to their own node.
        let title = node.isOverflow ? "more hosts" : label(for: node)
        let port = node.isOverflow || node.port == 0 ? "" : ":\(node.port)"
        let totals = "↓\(F.formatTotal(node.rxBytes))  ↑\(F.formatTotal(node.txBytes))"
        drawRadialLabel(Self.shorten(title) + port, totals, at: p, hub: hubCenter)
    }

    private typealias F = ProcessListView

    /// Neighbouring nodes sit close enough that a full AWS hostname runs into
    /// its neighbour's. Keep the ends, which carry the identity.
    private static func shorten(_ s: String, max: Int = 24) -> String {
        guard s.count > max else { return s }
        let keep = (max - 1) / 2
        return s.prefix(keep) + "…" + s.suffix(keep)
    }

    private func flag(_ node: GraphNode) -> String? {
        guard !node.isPrivate,
              let code = GeoResolver.shared.countryCode(for: node.address) else { return nil }
        let glyph = GeoResolver.flag(code)
        return glyph.isEmpty ? code : glyph
    }

    /// "Safari (1234)" per process, sorted, so the panel says which pid to
    /// inspect and the click menu can offer the same list.
    private func processLabels(of node: GraphNode) -> [String] {
        node.pids.sorted().map { pid in
            let name = owners[pid]?.name ?? ProcessOwner.forPID(pid)?.name
            return name.map { "\($0) (\(pid))" } ?? "pid \(pid) (exited)"
        }
    }

    private func label(for node: GraphNode) -> String {
        if node.isPrivate { return node.address }
        guard ConnectionListView.resolvesHostNames,
              let name = HostResolver.shared.name(for: node.address) else { return node.address }
        return name
    }

    // MARK: - Text

    private func attributes(_ size: CGFloat, _ color: NSColor,
                            _ weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    }

    private func drawCentered(_ s: String, in rect: NSRect, size: CGFloat = 12,
                              weight: NSFont.Weight = .regular) {
        let attrs = attributes(size, .labelColor, weight)
        let bounds = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.midX - bounds.width / 2,
                           y: rect.midY - bounds.height / 2), withAttributes: attrs)
    }

    /// Two lines placed outside the node, on the far side from the hub, so a
    /// label is always nearer its own node than any other. Nodes to the right
    /// read left-to-right away from the centre; nodes to the left mirror it;
    /// nodes near the top and bottom centre themselves.
    private func drawRadialLabel(_ title: String, _ totals: String,
                                 at p: NSPoint, hub: NSPoint) {
        let titleAttrs = attributes(11, .labelColor, .regular)
        let totalAttrs = attributes(10, .secondaryLabelColor, .regular)
        let titleSize = title.size(withAttributes: titleAttrs)
        let totalSize = totals.size(withAttributes: totalAttrs)
        let block = NSSize(width: max(titleSize.width, totalSize.width),
                           height: titleSize.height + totalSize.height + 1)

        let dx = p.x - hub.x, dy = p.y - hub.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let ux = dx / len, uy = dy / len
        let gap = nodeRadius + 6

        var origin: NSPoint
        if abs(ux) < 0.2 {                        // only the true top and bottom
            // Drift with the spoke so two near-vertical neighbours don't
            // centre on top of each other.
            origin = NSPoint(x: p.x - block.width / 2 + ux * block.width * 0.9,
                             y: uy >= 0 ? p.y + gap : p.y - gap - block.height)
        } else if ux > 0 {                        // right side: text runs right
            origin = NSPoint(x: p.x + gap, y: p.y - block.height / 2)
        } else {                                  // left side: text ends at the node
            origin = NSPoint(x: p.x - gap - block.width, y: p.y - block.height / 2)
        }
        origin.x = max(4, min(origin.x, bounds.maxX - block.width - 4))
        origin.y = max(4, min(origin.y, bounds.maxY - block.height - 4))

        totals.draw(at: origin, withAttributes: totalAttrs)
        title.draw(at: NSPoint(x: origin.x, y: origin.y + totalSize.height + 1),
                   withAttributes: titleAttrs)
    }

    // MARK: - Tooltips

}

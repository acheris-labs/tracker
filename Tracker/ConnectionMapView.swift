import AppKit

/// The machine at the centre, the hosts it is talking to around it, and edges
/// weighted by how much data crossed them. Arrowheads say who dialled whom.
final class ConnectionMapView: NSView, NSViewToolTipOwner {
    private var nodes: [GraphNode] = []
    private var owners: [pid_t: ProcessOwner] = [:]
    /// Where each node was drawn, for tooltips.
    private var placements: [(node: GraphNode, center: NSPoint)] = []

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

    func setNodes(_ n: [GraphNode], owners: [pid_t: ProcessOwner]) {
        nodes = n
        self.owners = owners
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        placements.removeAll()
        removeAllToolTips()

        guard !nodes.isEmpty else {
            drawCentered("No connections", in: bounds)
            return
        }

        let light = effectiveAppearance.isLight
        let hub = NSPoint(x: bounds.midX, y: bounds.midY)
        // Leave room for a node and its label at the rim.
        let labelDepth: CGFloat = nodes.count > 14 ? 96 : 46
        let radius = max(90, min(bounds.width, bounds.height) / 2 - nodeRadius - labelDepth)
        let peak = nodes.map(\.total).max() ?? 0

        // Edges first so the nodes sit on top of them.
        for (i, node) in nodes.enumerated() {
            let p = point(at: i, of: nodes.count, hub: hub, radius: radius)
            drawEdge(from: hub, to: p, node: node, peak: peak, light: light)
        }
        for (i, node) in nodes.enumerated() {
            let p = point(at: i, of: nodes.count, hub: hub, radius: radius)
            drawNode(node, at: p, light: light, index: i)
            placements.append((node, p))
            addToolTip(NSRect(x: p.x - nodeRadius, y: p.y - nodeRadius,
                              width: nodeRadius * 2, height: nodeRadius * 2),
                       owner: self, userData: nil)
        }
        drawHub(at: hub)
        drawLegend(light: light)
    }

    /// Nothing about colour or arrow direction is guessable, so say it.
    private func drawLegend(light: Bool) {
        let colors = ChartColors.load()
        let entries: [(NSColor, String)] = [
            (colors.netRx.onSurface(light: light), "mostly received"),
            (colors.netTx.onSurface(light: light), "mostly sent"),
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

    private func drawEdge(from hub: NSPoint, to p: NSPoint, node: GraphNode,
                          peak: Double, light: Bool) {
        let colors = ChartColors.load()
        // The palette's convention: cool hues inbound, warm outbound.
        let inbound = node.rxBytes >= node.txBytes
        let color = (inbound ? colors.netRx : colors.netTx).onSurface(light: light)

        // Start and end outside the two discs so the line reads as a link
        // rather than a spoke through them.
        let dx = p.x - hub.x, dy = p.y - hub.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let ux = dx / len, uy = dy / len
        let a = NSPoint(x: hub.x + ux * Self.hubRadius, y: hub.y + uy * Self.hubRadius)
        let b = NSPoint(x: p.x - ux * nodeRadius, y: p.y - uy * nodeRadius)

        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width(for: node.total, peak: peak)
        path.lineCapStyle = .round
        color.withAlphaComponent(0.75).setStroke()
        path.stroke()

        switch node.origin {
        case .weInitiated:   drawArrow(at: b, ux: ux, uy: uy, color: color)
        case .theyInitiated: drawArrow(at: a, ux: -ux, uy: -uy, color: color)
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

    private func drawArrow(at tip: NSPoint, ux: CGFloat, uy: CGFloat, color: NSColor) {
        let size: CGFloat = 9
        let back = NSPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        // Perpendicular, for the two barbs.
        let px = -uy * size * 0.45, py = ux * size * 0.45
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: back.x + px, y: back.y + py))
        path.line(to: NSPoint(x: back.x - px, y: back.y - py))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawNode(_ node: GraphNode, at p: NSPoint, light: Bool, index: Int) {
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

        // Below it: the host and the port it's talking to, then the totals.
        let title = node.isOverflow ? "more hosts" : label(for: node)
        let port = node.isOverflow || node.port == 0 ? "" : ":\(node.port)"
        let totals = "↓\(F.formatTotal(node.rxBytes))  ↑\(F.formatTotal(node.txBytes))"
        // Three depths: at 30 hosts the circle gives each label ~80pt of arc
        // and they run 200pt wide, so alternating two rows still collides.
        let stagger: CGFloat = nodes.count > 14 ? CGFloat(index % 3) * 26 : 0
        drawLabel(Self.shorten(title) + port, below: rect, offset: 4 + stagger,
                  size: 11, color: .labelColor)
        drawLabel(totals, below: rect, offset: 18 + stagger,
                  size: 10, color: .secondaryLabelColor)
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

    /// Centred under a node, clamped so rim labels don't run off the view.
    private func drawLabel(_ s: String, below rect: NSRect, offset: CGFloat,
                           size: CGFloat, color: NSColor) {
        let attrs = attributes(size, color, .regular)
        let textSize = s.size(withAttributes: attrs)
        var x = rect.midX - textSize.width / 2
        x = max(2, min(x, bounds.maxX - textSize.width - 2))
        s.draw(at: NSPoint(x: x, y: rect.minY - offset - textSize.height), withAttributes: attrs)
    }

    // MARK: - Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let hit = placements.min(by: {
            hypot($0.center.x - point.x, $0.center.y - point.y)
                < hypot($1.center.x - point.x, $1.center.y - point.y)
        }) else { return "" }
        let n = hit.node
        if n.isOverflow {
            return "\(n.hiddenHosts) more hosts · \(n.connections) connections\n"
                + "↓\(F.formatTotal(n.rxBytes))  ↑\(F.formatTotal(n.txBytes))"
        }
        let who: String
        switch n.origin {
        case .weInitiated:   who = "This Mac connected out"
        case .theyInitiated: who = "Connected in to this Mac"
        case .unknown:       who = "Direction unknown"
        }
        let names = n.pids.compactMap { owners[$0]?.name ?? ProcessOwner.forPID($0)?.name }
        let processes = Set(names).sorted().joined(separator: ", ")
        return """
        \(label(for: n))\(n.address == label(for: n) ? "" : "  (\(n.address))")
        \(n.connections) connection\(n.connections == 1 ? "" : "s") on port \(n.port)
        ↓\(F.formatTotal(n.rxBytes))  ↑\(F.formatTotal(n.txBytes))
        \(who)\(processes.isEmpty ? "" : "\n\(processes)")
        """
    }
}

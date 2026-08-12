import AppKit

// Activity-Monitor-style footer summary panes: bordered rounded boxes holding
// either a label/value grid or a small history graph with a caption.

/// One bordered, rounded footer pane. `height` nil hugs the content (used by
/// the Chart tab's legend panes, whose row counts differ).
final class FooterPane: NSView {
    init(content: NSView, minWidth: CGFloat = 190,
         height: CGFloat? = Theme.footerPaneHeight) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyBorderColor()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var constraints = [
            content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
        ]
        if let height {
            constraints.append(heightAnchor.constraint(equalToConstant: height))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// A CGColor is a snapshot resolved under whatever appearance was current
    /// when it was taken, so it has to be re-taken when the appearance
    /// changes — otherwise the dark separator (a pale translucent white) stays
    /// put and the panes lose their edges on the light background.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Label/value rows with hairline separators between them, like the grids in
/// Activity Monitor's footer. Values update in place via `setValue`.
final class FooterStatGrid: NSView {
    struct Row {
        let label: String
        var color: NSColor?   // value color; nil = labelColor
    }

    private var valueFields: [NSTextField] = []
    private let pinned: Bool

    /// `pinned` gives the grid an intrinsic height (stack pinned to the top
    /// and bottom edges) for use outside the fixed-height footer panes, where
    /// the default centerY-only pin would leave the height ambiguous.
    init(rows: [Row], pinned: Bool = false) {
        self.pinned = pinned
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = []
        for (i, row) in rows.enumerated() {
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = row.color ?? .labelColor
            value.alignment = .right
            valueFields.append(value)
            let line = NSStackView(views: [label, value])
            line.orientation = .horizontal
            line.distribution = .fill
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views.append(line)
            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                views.append(sep)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        if pinned {
            constraints += [
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(stack.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setValue(_ s: String, at i: Int) {
        guard i >= 0, i < valueFields.count else { return }
        valueFields[i].stringValue = s
    }
}

/// Small captioned history graph: "CPU LOAD"-style small-caps title over a
/// hairline, then the series drawn beneath. Two modes:
///  - .stack:  layers are stacked areas from the baseline (layer 0 at bottom).
///  - .mirror: layer 0 fills upward and layer 1 downward from a center
///             baseline, like Activity Monitor's disk IO graph.
final class FooterGraphView: NSView {
    enum Mode { case stack, mirror }

    private let captionLabel = NSTextField(labelWithString: "")
    private let mode: Mode
    private let colors: [NSColor]
    private var layers: [[Double]] = []   // each value 0…1
    private let graphInsetTop: CGFloat = 17

    init(caption: String, colors: [NSColor], mode: Mode) {
        self.mode = mode
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        captionLabel.attributedStringValue = NSAttributedString(
            string: caption.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        captionLabel.alignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionLabel)
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: topAnchor),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Each layer is a 0…1 series; all layers share the x-axis (1 pt per
    /// sample, right-aligned so the newest sample hugs the right edge).
    func setLayers(_ l: [[Double]]) {
        layers = l
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Hairline under the caption, full width.
        let lineY = bounds.maxY - graphInsetTop + 3
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: lineY, width: bounds.width, height: 1).fill()

        let graph = NSRect(x: 0, y: 0, width: bounds.width,
                           height: max(0, bounds.height - graphInsetTop))
        guard graph.height > 4, let first = layers.first, first.count > 1 else { return }

        switch mode {
        case .stack:
            // Cumulative areas, layer 0 at the bottom.
            var base = [Double](repeating: 0, count: first.count)
            for (li, layer) in layers.enumerated() {
                let top = zip(base, layer).map { min(1, $0 + $1) }
                fillArea(lower: base, upper: top, in: graph,
                         color: colors[min(li, colors.count - 1)])
                base = top
            }
        case .mirror:
            let mid = graph.midY
            let upper = NSRect(x: graph.minX, y: mid, width: graph.width,
                               height: graph.height / 2)
            let lower = NSRect(x: graph.minX, y: graph.minY, width: graph.width,
                               height: graph.height / 2)
            if layers.count > 0 {
                fillArea(lower: [Double](repeating: 0, count: layers[0].count),
                         upper: layers[0], in: upper, color: colors.first ?? .systemBlue)
            }
            if layers.count > 1 {
                fillArea(lower: [Double](repeating: 0, count: layers[1].count),
                         upper: layers[1], in: lower, flipped: true,
                         color: colors.count > 1 ? colors[1] : .systemRed)
            }
            NSColor.separatorColor.setFill()
            NSRect(x: graph.minX, y: mid - 0.5, width: graph.width, height: 1).fill()
        }
    }

    /// Fill between two 0…1 series mapped into `rect`; `flipped` grows the
    /// area downward from the rect's top (for the mirror mode's write half).
    private func fillArea(lower: [Double], upper: [Double], in rect: NSRect,
                          flipped: Bool = false, color: NSColor) {
        let n = upper.count
        guard n > 1 else { return }
        // 1 pt per sample, right-aligned.
        let step: CGFloat = max(1, rect.width / CGFloat(max(60, n) - 1))
        let x0 = rect.maxX - CGFloat(n - 1) * step
        func point(_ i: Int, _ v: Double) -> NSPoint {
            let y = flipped ? rect.maxY - CGFloat(v) * rect.height
                            : rect.minY + CGFloat(v) * rect.height
            return NSPoint(x: x0 + CGFloat(i) * step, y: y)
        }
        let path = NSBezierPath()
        path.move(to: point(0, lower[0]))
        for i in 0..<n { path.line(to: point(i, upper[i])) }
        for i in stride(from: n - 1, through: 0, by: -1) {
            path.line(to: point(i, lower[i]))
        }
        path.close()
        color.withAlphaComponent(0.55).setFill()
        path.fill()
        // Bright top edge for legibility.
        let edge = NSBezierPath()
        edge.move(to: point(0, upper[0]))
        for i in 1..<n { edge.line(to: point(i, upper[i])) }
        edge.lineWidth = 1
        color.setStroke()
        edge.stroke()
    }
}

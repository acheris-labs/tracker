import AppKit

final class PreferencesWindowController: NSWindowController {
    private let onColorsChange: (ChartColors) -> Void
    private let onTracesChange: (TraceSurface, Set<ChartTrace>) -> Void
    private var iconTraces: Set<ChartTrace>
    private var chartTraces: Set<ChartTrace>
    private let onThresholdChange: (Int) -> Void
    private weak var thresholdLabel: NSTextField?


    // Order matches the chart stack (bottom to top), then overlays.
    private let colorRows: [(label: String, keyPath: WritableKeyPath<ChartColors, NSColor>)]
    private var colorWells: [NSColorWell] = []
    private var colors: ChartColors
    private var initialThreshold: Int = 20

    init(colors: ChartColors,
         hasBattery: Bool,
         iconTraces: Set<ChartTrace>,
         chartTraces: Set<ChartTrace>,
         drainThreshold: Int,
         onColorsChange: @escaping (ChartColors) -> Void,
         onTracesChange: @escaping (TraceSurface, Set<ChartTrace>) -> Void,
         onThresholdChange: @escaping (Int) -> Void) {
        self.colors = colors
        self.onColorsChange = onColorsChange
        self.onTracesChange = onTracesChange
        self.iconTraces = iconTraces
        self.chartTraces = chartTraces
        self.onThresholdChange = onThresholdChange
        self.initialThreshold = drainThreshold

        var rows: [(label: String, keyPath: WritableKeyPath<ChartColors, NSColor>)] = [
            ("P-core system", \.pSys),
            ("E-core system", \.eSys),
            ("P-core user",   \.pUser),
            ("E-core user",   \.eUser),
            ("GPU",           \.gpu),
        ]
        if hasBattery { rows.append(("Battery", \.battery)) }
        rows.append(("Memory",     \.memory))
        rows.append(("Disk read",  \.diskRead))
        rows.append(("Disk write", \.diskWrite))
        rows.append(("Net received", \.netRx))
        rows.append(("Net sent",     \.netTx))
        self.colorRows = rows

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Preferences"
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.center()

        super.init(window: win)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        // Trace table: one row per trace — label · color well(s) · where it
        // shows (Dock / Chart).
        buildTraceTable(grid: grid, hasBattery: hasBattery)

        // Drain alert threshold (W) — slider + value label.
        let slider = NSSlider(value: Double(initialThreshold),
                              minValue: 5, maxValue: 100,
                              target: self, action: #selector(thresholdChanged(_:)))
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = true
        slider.numberOfTickMarks = 20  // every 5 W
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let valueLabel = NSTextField(labelWithString: "\(initialThreshold) W")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        self.thresholdLabel = valueLabel

        let thresholdRow = NSStackView(views: [slider, valueLabel])
        thresholdRow.orientation = .horizontal
        thresholdRow.spacing = 8
        thresholdRow.alignment = .centerY
        grid.addRow(with: [Self.label("Drain alert above:"), thresholdRow])

        // Right-align the label column
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
        }

        // Reset button
        let reset = NSButton(title: "Reset Colors", target: self,
                             action: #selector(resetColors(_:)))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(reset)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            reset.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        win.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func sync(colors: ChartColors) {
        self.colors = colors
        for (i, row) in colorRows.enumerated() {
            colorWells[i].color = colors[keyPath: row.keyPath]
        }
    }

    private static func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.alignment = .right
        return t
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let i = sender.tag
        guard i >= 0, i < colorRows.count else { return }
        colors[keyPath: colorRows[i].keyPath] = sender.color
        onColorsChange(colors)
    }

    /// One color well bound to a colorRows entry (tag drives colorChanged).
    private func makeWell(colorIndex i: Int) -> NSColorWell {
        let well = NSColorWell()
        well.color = colors[keyPath: colorRows[i].keyPath]
        well.toolTip = colorRows[i].label
        well.tag = i
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        colorWells.append(well)
        return well
    }

    private func makeSurfaceCheck(_ trace: ChartTrace, surface: TraceSurface,
                                  traces: Set<ChartTrace>) -> NSButton {
        let check = NSButton(checkboxWithTitle: "", target: self,
                             action: #selector(traceToggled(_:)))
        check.state = traces.contains(trace) ? .on : .off
        check.tag = (surface == .dock ? 0 : 100) + ChartTrace.allCases.firstIndex(of: trace)!
        return check
    }

    private static func columnHeader(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        t.alignment = .center
        return t
    }

    /// Rows: trace · its color well(s) · Dock checkbox · Chart checkbox.
    /// colorWells must be appended in colorRows order, so wells are created
    /// in that same order here.
    private func buildTraceTable(grid: NSGridView, hasBattery: Bool) {
        grid.addRow(with: [Self.label(""), Self.columnHeader("Color"),
                           Self.columnHeader("Dock"), Self.columnHeader("Chart")])

        func wellStack(_ idxs: [Int]) -> NSView {
            let stack = NSStackView(views: idxs.map(makeWell(colorIndex:)))
            stack.orientation = .horizontal
            stack.spacing = 4
            return stack
        }
        // Index into colorRows by label lookup so battery's presence can't
        // silently shift positions.
        func idx(_ label: String) -> Int {
            colorRows.firstIndex { $0.label == label }!
        }

        func traceRow(_ title: String, _ trace: ChartTrace, wells: [Int]) {
            grid.addRow(with: [Self.label(title),
                               wellStack(wells),
                               makeSurfaceCheck(trace, surface: .dock, traces: iconTraces),
                               makeSurfaceCheck(trace, surface: .chart, traces: chartTraces)])
        }
        traceRow("CPU:", .cpu, wells: [idx("P-core system"), idx("E-core system"),
                                       idx("P-core user"), idx("E-core user")])
        traceRow("GPU:", .gpu, wells: [idx("GPU")])
        if hasBattery { traceRow("Battery:", .battery, wells: [idx("Battery")]) }
        traceRow("Memory:", .memory, wells: [idx("Memory")])
        traceRow("Disk I/O:", .disk, wells: [idx("Disk read"), idx("Disk write")])
        traceRow("Network:", .network, wells: [idx("Net received"), idx("Net sent")])

        // Center the checkbox columns under their headers.
        if grid.numberOfColumns >= 4 {
            grid.column(at: 2).xPlacement = .center
            grid.column(at: 3).xPlacement = .center
        }
    }

    @objc private func traceToggled(_ sender: NSButton) {
        let surface: TraceSurface = sender.tag < 100 ? .dock : .chart
        let idx = sender.tag % 100
        guard idx < ChartTrace.allCases.count else { return }
        let trace = ChartTrace.allCases[idx]
        switch surface {
        case .dock:
            if sender.state == .on { iconTraces.insert(trace) }
            else { iconTraces.remove(trace) }
            onTracesChange(.dock, iconTraces)
        case .chart:
            if sender.state == .on { chartTraces.insert(trace) }
            else { chartTraces.remove(trace) }
            onTracesChange(.chart, chartTraces)
        }
    }

    @objc private func thresholdChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue.rounded())
        thresholdLabel?.stringValue = "\(v) W"
        onThresholdChange(v)
    }

    @objc private func resetColors(_ sender: NSButton) {
        colors = .default
        for (i, row) in colorRows.enumerated() {
            colorWells[i].color = colors[keyPath: row.keyPath]
        }
        onColorsChange(colors)
    }
}

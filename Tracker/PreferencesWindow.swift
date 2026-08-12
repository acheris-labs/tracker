import AppKit

final class PreferencesWindowController: NSWindowController {
    private let durations: [(label: String, seconds: Int)]
    private let onDurationChange: (Int) -> Void
    private let onColorsChange: (ChartColors) -> Void
    private let onTracesChange: (TraceSurface, Set<ChartTrace>) -> Void
    private var iconTraces: Set<ChartTrace>
    private var chartTraces: Set<ChartTrace>
    private let onThresholdChange: (Int) -> Void
    private let onAutoUpdateChange: (Bool) -> Void
    private weak var thresholdLabel: NSTextField?

    private weak var popup: NSPopUpButton?

    // Order matches the chart stack (bottom to top), then overlays.
    private let colorRows: [(label: String, keyPath: WritableKeyPath<ChartColors, NSColor>)]
    private var colorWells: [NSColorWell] = []
    private var colors: ChartColors
    private var initialThreshold: Int = 20

    init(durations: [(label: String, seconds: Int)],
         currentDuration: Int,
         colors: ChartColors,
         hasBattery: Bool,
         iconTraces: Set<ChartTrace>,
         chartTraces: Set<ChartTrace>,
         drainThreshold: Int,
         autoUpdate: Bool,
         onDurationChange: @escaping (Int) -> Void,
         onColorsChange: @escaping (ChartColors) -> Void,
         onTracesChange: @escaping (TraceSurface, Set<ChartTrace>) -> Void,
         onThresholdChange: @escaping (Int) -> Void,
         onAutoUpdateChange: @escaping (Bool) -> Void) {
        self.durations = durations
        self.colors = colors
        self.onDurationChange = onDurationChange
        self.onColorsChange = onColorsChange
        self.onTracesChange = onTracesChange
        self.iconTraces = iconTraces
        self.chartTraces = chartTraces
        self.onThresholdChange = onThresholdChange
        self.onAutoUpdateChange = onAutoUpdateChange
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

        // Duration row
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for d in durations {
            popup.addItem(withTitle: d.label)
            popup.lastItem?.tag = d.seconds
        }
        popup.target = self
        popup.action = #selector(durationChanged(_:))
        self.popup = popup
        select(seconds: currentDuration)
        grid.addRow(with: [Self.label("Dock icon history:"), popup])

        // Per-surface trace toggles: dock icon vs chart window.
        addTraceRows(grid: grid, title: "Dock icon shows:", surface: .dock,
                     traces: iconTraces, hasBattery: hasBattery)
        addTraceRows(grid: grid, title: "Chart shows:", surface: .chart,
                     traces: chartTraces, hasBattery: hasBattery)

        let autoUpdateCheck = NSButton(checkboxWithTitle: "Check for updates automatically",
                                       target: self, action: #selector(toggleAutoUpdate(_:)))
        autoUpdateCheck.state = autoUpdate ? .on : .off
        grid.addRow(with: [Self.label("Updates:"), autoUpdateCheck])

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

        // Color rows
        for (i, row) in colorRows.enumerated() {
            let well = NSColorWell()
            well.color = colors[keyPath: row.keyPath]
            well.tag = i
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 60).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            colorWells.append(well)
            grid.addRow(with: [Self.label(row.label + ":"), well])
        }

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

    func sync(currentDuration: Int) { select(seconds: currentDuration) }

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

    private func select(seconds: Int) {
        guard let popup else { return }
        for i in 0..<popup.numberOfItems where popup.item(at: i)?.tag == seconds {
            popup.selectItem(at: i)
            return
        }
    }

    @objc private func durationChanged(_ sender: NSPopUpButton) {
        let seconds = sender.selectedItem?.tag ?? 0
        if seconds > 0 { onDurationChange(seconds) }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let i = sender.tag
        guard i >= 0, i < colorRows.count else { return }
        colors[keyPath: colorRows[i].keyPath] = sender.color
        onColorsChange(colors)
    }

    private func addTraceRows(grid: NSGridView, title: String,
                              surface: TraceSurface,
                              traces: Set<ChartTrace>, hasBattery: Bool) {
        var first = true
        for (i, trace) in ChartTrace.allCases.enumerated() {
            if trace == .battery, !hasBattery { continue }
            let check = NSButton(checkboxWithTitle: trace.label, target: self,
                                 action: #selector(traceToggled(_:)))
            check.state = traces.contains(trace) ? .on : .off
            check.tag = (surface == .dock ? 0 : 100) + i
            grid.addRow(with: [Self.label(first ? title : ""), check])
            first = false
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

    @objc private func toggleAutoUpdate(_ sender: NSButton) {
        onAutoUpdateChange(sender.state == .on)
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

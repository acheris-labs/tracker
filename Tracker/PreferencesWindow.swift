import AppKit

final class PreferencesWindowController: NSWindowController {
    private let durations: [(label: String, seconds: Int)]
    private let onDurationChange: (Int) -> Void
    private let onColorsChange: (ChartColors) -> Void
    private let onShowGPUChange: (Bool) -> Void
    private let onShowBatteryChange: (Bool) -> Void
    private let onShowMemoryChange: (Bool) -> Void
    private let onShowDiskChange: (Bool) -> Void
    private let onThresholdChange: (Int) -> Void
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
         showGPU: Bool,
         showBattery: Bool,
         showMemory: Bool,
         showDisk: Bool,
         drainThreshold: Int,
         onDurationChange: @escaping (Int) -> Void,
         onColorsChange: @escaping (ChartColors) -> Void,
         onShowGPUChange: @escaping (Bool) -> Void,
         onShowBatteryChange: @escaping (Bool) -> Void,
         onShowMemoryChange: @escaping (Bool) -> Void,
         onShowDiskChange: @escaping (Bool) -> Void,
         onThresholdChange: @escaping (Int) -> Void) {
        self.durations = durations
        self.colors = colors
        self.onDurationChange = onDurationChange
        self.onColorsChange = onColorsChange
        self.onShowGPUChange = onShowGPUChange
        self.onShowBatteryChange = onShowBatteryChange
        self.onShowMemoryChange = onShowMemoryChange
        self.onShowDiskChange = onShowDiskChange
        self.onThresholdChange = onThresholdChange
        self.initialThreshold = drainThreshold

        var rows: [(label: String, keyPath: WritableKeyPath<ChartColors, NSColor>)] = [
            ("P-core system", \.pSys),
            ("E-core system", \.eSys),
            ("P-core user",   \.pUser),
            ("E-core user",   \.eUser),
            ("GPU",           \.gpu),
        ]
        rows.append(("Memory",     \.memory))
        rows.append(("Disk read",  \.diskRead))
        rows.append(("Disk write", \.diskWrite))
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
        grid.addRow(with: [Self.label("History duration:"), popup])

        // Show/hide overlays
        let gpuCheck = NSButton(checkboxWithTitle: "Show GPU",
                                target: self, action: #selector(toggleShowGPU(_:)))
        gpuCheck.state = showGPU ? .on : .off
        grid.addRow(with: [Self.label("Display:"), gpuCheck])
        if hasBattery {
            let batCheck = NSButton(checkboxWithTitle: "Show Battery",
                                    target: self, action: #selector(toggleShowBattery(_:)))
            batCheck.state = showBattery ? .on : .off
            grid.addRow(with: [Self.label(""), batCheck])
        }
        let memCheck = NSButton(checkboxWithTitle: "Show Memory",
                                target: self, action: #selector(toggleShowMemory(_:)))
        memCheck.state = showMemory ? .on : .off
        grid.addRow(with: [Self.label(""), memCheck])

        let diskCheck = NSButton(checkboxWithTitle: "Show Disk I/O",
                                 target: self, action: #selector(toggleShowDisk(_:)))
        diskCheck.state = showDisk ? .on : .off
        grid.addRow(with: [Self.label(""), diskCheck])

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

    @objc private func toggleShowGPU(_ sender: NSButton) {
        onShowGPUChange(sender.state == .on)
    }

    @objc private func toggleShowBattery(_ sender: NSButton) {
        onShowBatteryChange(sender.state == .on)
    }

    @objc private func toggleShowMemory(_ sender: NSButton) {
        onShowMemoryChange(sender.state == .on)
    }

    @objc private func toggleShowDisk(_ sender: NSButton) {
        onShowDiskChange(sender.state == .on)
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

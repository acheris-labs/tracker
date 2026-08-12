import AppKit

struct HistoryFrame {
    let cpu: CPUFrame
    let gpu: Double
    let battery: Double      // 0..1; ignored when renderer.hasBattery == false
    let memory: Double       // 0..1
    let diskRead: Double     // bytes/sec
    let diskWrite: Double    // bytes/sec
    let netRx: Double        // bytes/sec
    let netTx: Double        // bytes/sec
}

struct ChartColors {
    var pSys: NSColor
    var eSys: NSColor
    var pUser: NSColor
    var eUser: NSColor
    var gpu: NSColor
    var battery: NSColor
    var memory: NSColor
    var diskRead: NSColor
    var diskWrite: NSColor
    var netRx: NSColor
    var netTx: NSColor

    static let `default` = ChartColors(
        pSys:      NSColor(srgbRed: 0.95, green: 0.20, blue: 0.20, alpha: 1),
        eSys:      NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1),
        pUser:     NSColor(srgbRed: 0.20, green: 0.85, blue: 0.30, alpha: 1),
        eUser:     NSColor(srgbRed: 0.30, green: 0.62, blue: 1.00, alpha: 1),
        gpu:       NSColor(srgbRed: 0.70, green: 0.45, blue: 1.00, alpha: 1),
        battery:   NSColor(srgbRed: 1.00, green: 0.85, blue: 0.25, alpha: 1),
        memory:    NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1),
        // Hue-grouped bytes/sec palette: cool hues = inbound (read/rcvd),
        // warm hues = outbound (write/sent); disk saturated, network pale.
        diskRead:  NSColor(srgbRed: 0.10, green: 0.80, blue: 0.95, alpha: 1),
        diskWrite: NSColor(srgbRed: 1.00, green: 0.30, blue: 0.45, alpha: 1),
        netRx:     NSColor(srgbRed: 0.65, green: 0.90, blue: 1.00, alpha: 1),
        netTx:     NSColor(srgbRed: 1.00, green: 0.72, blue: 0.62, alpha: 1)
    )

    private static let keys = (
        pSys: "Color.pSys", eSys: "Color.eSys",
        pUser: "Color.pUser", eUser: "Color.eUser",
        gpu: "Color.gpu",
        battery: "Color.battery",
        memory: "Color.memory",
        diskRead: "Color.diskRead", diskWrite: "Color.diskWrite",
        netRx: "Color.netRx", netTx: "Color.netTx"
    )

    static func load() -> ChartColors {
        let d = UserDefaults.standard
        let def = ChartColors.default
        return ChartColors(
            pSys:      d.string(forKey: keys.pSys).flatMap(NSColor.fromHex) ?? def.pSys,
            eSys:      d.string(forKey: keys.eSys).flatMap(NSColor.fromHex) ?? def.eSys,
            pUser:     d.string(forKey: keys.pUser).flatMap(NSColor.fromHex) ?? def.pUser,
            eUser:     d.string(forKey: keys.eUser).flatMap(NSColor.fromHex) ?? def.eUser,
            gpu:       d.string(forKey: keys.gpu).flatMap(NSColor.fromHex) ?? def.gpu,
            battery:   d.string(forKey: keys.battery).flatMap(NSColor.fromHex) ?? def.battery,
            memory:    d.string(forKey: keys.memory).flatMap(NSColor.fromHex) ?? def.memory,
            diskRead:  d.string(forKey: keys.diskRead).flatMap(NSColor.fromHex) ?? def.diskRead,
            diskWrite: d.string(forKey: keys.diskWrite).flatMap(NSColor.fromHex) ?? def.diskWrite,
            netRx:     d.string(forKey: keys.netRx).flatMap(NSColor.fromHex) ?? def.netRx,
            netTx:     d.string(forKey: keys.netTx).flatMap(NSColor.fromHex) ?? def.netTx
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(pSys.hexString,      forKey: ChartColors.keys.pSys)
        d.set(eSys.hexString,      forKey: ChartColors.keys.eSys)
        d.set(pUser.hexString,     forKey: ChartColors.keys.pUser)
        d.set(eUser.hexString,     forKey: ChartColors.keys.eUser)
        d.set(gpu.hexString,       forKey: ChartColors.keys.gpu)
        d.set(battery.hexString,   forKey: ChartColors.keys.battery)
        d.set(memory.hexString,    forKey: ChartColors.keys.memory)
        d.set(diskRead.hexString,  forKey: ChartColors.keys.diskRead)
        d.set(diskWrite.hexString, forKey: ChartColors.keys.diskWrite)
        d.set(netRx.hexString,     forKey: ChartColors.keys.netRx)
        d.set(netTx.hexString,     forKey: ChartColors.keys.netTx)
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Nudge a colour toward white. Translucent fills over the near-black
    /// background read darker than the opaque original, so the palette gets
    /// lifted before it's drawn with alpha.
    func lifted(by amount: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        func f(_ v: CGFloat) -> CGFloat { min(1, v + (1 - v) * amount) }
        return NSColor(srgbRed: f(c.redComponent), green: f(c.greenComponent),
                       blue: f(c.blueComponent), alpha: c.alphaComponent)
    }

    static func fromHex(_ s: String) -> NSColor? {
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8)  & 0xFF) / 255.0
        let b = CGFloat( v        & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// The selectable traces, CPU stack included.
enum ChartTrace: String, CaseIterable {
    case cpu, gpu, battery, memory, disk, network
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .memory: return "Memory"
        case .disk: return "Disk I/O"
        case .network: return "Network"
        }
    }
}

/// Which surface a trace set customizes.
enum TraceSurface { case dock, chart }

/// A single drawable series — finer-grained than ChartTrace (CPU has four,
/// disk and network two each). Used for legend-hover highlighting.
enum ChartSeries: Equatable {
    case pSys, eSys, pUser, eUser, gpu, battery, memory
    case diskRead, diskWrite, netRx, netTx
}

final class HistoryRenderer {
    // Storage holds up to `maxStorage` recent samples; two independent view
    // windows select how many of the most recent samples each surface draws:
    // the dock icon short ("what's happening right now"), the chart window
    // long (up to an hour). Resizing either never loses data.
    static let maxStorage: Int = 3600

    private var frames: [HistoryFrame]
    private var head: Int = 0
    private var count: Int = 0

    private(set) var iconCapacity: Int    // dock icon window (samples = seconds at 1 Hz)
    private(set) var chartCapacity: Int   // chart window view
    /// Window used by the draw helpers; set on entry to draw()/diskScaleMax().
    private var activeWindow: Int = 8

    private let pointSize = NSSize(width: 128, height: 128)
    private let pixelScale: CGFloat = 2

    // Translucency tuning for the smoothed (Chart window) rendering. The
    // menu-bar image stays opaque — at 128px alpha just reads as mud.
    private static let bandAlphaTop: CGFloat = 0.80     // alpha at a band's top edge
    private static let bandAlphaBottom: CGFloat = 0.30  // alpha at its bottom edge
    private static let bandLift: CGFloat = 0.15         // brightness compensation
    private static let bandEdgeWidth: CGFloat = 1.25
    private static let gpuGlowDepth: CGFloat = 0.18     // glow depth, fraction of chart height
    private static let gpuGlowPeak: CGFloat = 0.42      // glow alpha immediately under the line
    private static let gpuGlowLayers = 16

    private let pWeight: Double
    private let eWeight: Double
    let hasBattery: Bool
    var colors: ChartColors
    // Independent per-surface trace sets: the dock icon usually wants the
    // short "right now" essentials, the chart the full picture.
    var iconTraces: Set<ChartTrace> = [.cpu, .gpu]
    var chartTraces: Set<ChartTrace> = [.cpu, .gpu]

    /// While set, the chart draws this series at full strength and dims the
    /// rest (legend hover). The dock icon ignores it.
    var highlightedSeries: ChartSeries?

    /// The series' colour, dimmed toward neutral when another series is
    /// highlighted. Blending (not alpha) keeps the band-alpha math intact.
    private func seriesColor(_ base: NSColor, _ series: ChartSeries,
                             smoothed: Bool) -> NSColor {
        guard smoothed, let h = highlightedSeries, h != series else { return base }
        // Nearly extinguish non-highlighted series: heavy blend toward a
        // dark neutral plus an alpha cut, so even bright hues recede.
        let ghost = base.blended(withFraction: 0.88, of: NSColor(white: 0.25, alpha: 1)) ?? base
        return ghost.withAlphaComponent(0.55)
    }

    init(iconCapacity: Int, chartCapacity: Int, numP: Int, numE: Int,
         hasBattery: Bool, colors: ChartColors) {
        self.colors = colors
        self.hasBattery = hasBattery
        self.iconCapacity = max(8, min(Self.maxStorage, iconCapacity))
        self.chartCapacity = max(8, min(Self.maxStorage, chartCapacity))
        self.activeWindow = self.iconCapacity
        self.frames = Array(repeating: HistoryFrame(cpu: CPUFrame(), gpu: 0, battery: 0,
                                                    memory: 0,
                                                    diskRead: 0, diskWrite: 0,
                                                    netRx: 0, netTx: 0),
                            count: Self.maxStorage)
        let total = max(1, numP + numE)
        self.pWeight = Double(numP) / Double(total)
        self.eWeight = Double(numE) / Double(total)
    }

    func resizeIcon(capacity newCapacity: Int) {
        iconCapacity = max(8, min(Self.maxStorage, newCapacity))
    }

    func resizeChart(capacity newCapacity: Int) {
        chartCapacity = max(8, min(Self.maxStorage, newCapacity))
    }

    func append(cpu: CPUFrame, gpu: Double, battery: Double, memory: Double,
                diskRead: Double, diskWrite: Double,
                netRx: Double = 0, netTx: Double = 0) {
        frames[head] = HistoryFrame(cpu: cpu, gpu: gpu, battery: battery,
                                    memory: memory,
                                    diskRead: diskRead, diskWrite: diskWrite,
                                    netRx: netRx, netTx: netTx)
        head = (head + 1) % Self.maxStorage
        if count < Self.maxStorage { count += 1 }
    }

    private func visibleCount() -> Int {
        return min(count, activeWindow)
    }

    /// Index in `frames` for the i-th visible sample (0 = oldest visible).
    private func visibleIndex(_ i: Int) -> Int {
        let visible = visibleCount()
        return (head - visible + i + Self.maxStorage * 2) % Self.maxStorage
    }

    /// Bottom of the shared logarithmic bytes/sec scale — rates at or below
    /// this sit on the baseline.
    static let byteScaleMinRate: Double = 1024

    /// Top of the shared logarithmic bytes/sec scale: the visible-window max
    /// across every shown bytes/sec series (disk r/w, network rx/tx), floor
    /// 1 MiB/s. Log lets wildly different families share one honest axis.
    func byteScaleMax() -> Double {
        activeWindow = chartCapacity   // the chart's right axis uses this
        return byteScaleMax(visible: visibleCount(), traces: chartTraces)
    }

    private func byteScaleMax(visible: Int, traces: Set<ChartTrace>) -> Double {
        var maxRate: Double = 1_048_576
        for i in 0..<visible {
            let f = frames[visibleIndex(i)]
            if traces.contains(.disk) {
                if f.diskRead > maxRate  { maxRate = f.diskRead }
                if f.diskWrite > maxRate { maxRate = f.diskWrite }
            }
            if traces.contains(.network) {
                if f.netRx > maxRate { maxRate = f.netRx }
                if f.netTx > maxRate { maxRate = f.netTx }
            }
        }
        return maxRate
    }

    /// 0…1 position of a rate on the shared log scale.
    private static func logNorm(_ v: Double, maxRate: Double) -> Double {
        guard v > byteScaleMinRate else { return 0 }
        let denom = log(maxRate / byteScaleMinRate)
        guard denom > 0 else { return 0 }
        return min(1.0, log(v / byteScaleMinRate) / denom)
    }

    func render() -> NSImage {
        let pixelW = Int(pointSize.width * pixelScale)
        let pixelH = Int(pointSize.height * pixelScale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 32
        ) else {
            return NSImage(size: pointSize)
        }
        rep.size = pointSize

        let prevCtx = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.current = prevCtx }

        draw(in: NSRect(origin: .zero, size: pointSize))

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// `background` defaults to the dark fill the menu-bar icon needs; the
    /// Chart window passes a system color so the card tracks the appearance.
    func draw(in rect: NSRect, smoothed: Bool = false,
              background: NSColor = NSColor(white: 0.04, alpha: 1)) {
        // smoothed == the chart window; crisp == the dock icon.
        activeWindow = smoothed ? chartCapacity : iconCapacity
        let traces = smoothed ? chartTraces : iconTraces
        background.setFill()
        rect.fill()

        let inner = rect
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.clip(to: inner)

        let H = inner.height
        let W = inner.width
        let colW = W / CGFloat(activeWindow)
        let visible = visibleCount()

        // Two y-axes share the full drawable area:
        //   - 0..100% metrics (CPU bars, memory/battery/GPU lines) use cpuH.
        //   - Disk read/write use the same height but with an independent
        //     auto-scale, drawn behind the CPU bars so the bars stay dominant.
        let cpuH = H

        // Stack order bottom-to-top: pSys, eSys, pUser, eUser.
        // Each band weighted by its group's share of total cores so the
        // full-height stack corresponds to 100% system-wide CPU.
        let pSysColor = colors.pSys
        let eSysColor = colors.eSys
        let pUsrColor = colors.pUser
        let eUsrColor = colors.eUser

        // Right-align the visible window so the newest sample sits at the
        // right edge even when we have fewer samples than the view width.
        let xOffset = W - CGFloat(visible) * colW

        // Lines drawn BEFORE bars (memory, disk) sit behind the CPU stack.
        // GPU: behind the translucent stack in the smoothed chart (it shows
        // through), on top in the opaque menu-bar image so it stays visible
        // at high CPU load.
        if visible > 1 {
            if traces.contains(.battery), hasBattery {
                drawLine(visible: visible, xOffset: xOffset, colW: colW,
                         bandY: inner.minY, bandH: cpuH,
                         color: seriesColor(colors.battery, .battery, smoothed: smoothed),
                         smoothed: smoothed) { $0.battery }
            }
            if traces.contains(.memory) {
                drawLine(visible: visible, xOffset: xOffset, colW: colW,
                         bandY: inner.minY, bandH: cpuH,
                         color: seriesColor(colors.memory, .memory, smoothed: smoothed),
                         smoothed: smoothed) { $0.memory }
            }
            // Disk and network share one LOGARITHMIC bytes/sec scale: linear
            // sharing would let either family's burst flatten the other, and
            // separate scales made same-unit lines incomparable.
            if traces.contains(.disk) || traces.contains(.network) {
                let maxRate = byteScaleMax(visible: visible, traces: traces)
                if traces.contains(.network) {
                    drawLine(visible: visible, xOffset: xOffset, colW: colW,
                             bandY: inner.minY, bandH: cpuH,
                             color: seriesColor(colors.netRx, .netRx, smoothed: smoothed),
                             lineWidth: 1.25, smoothed: smoothed) {
                        Self.logNorm($0.netRx, maxRate: maxRate)
                    }
                    drawLine(visible: visible, xOffset: xOffset, colW: colW,
                             bandY: inner.minY, bandH: cpuH,
                             color: seriesColor(colors.netTx, .netTx, smoothed: smoothed),
                             lineWidth: 1.25, smoothed: smoothed) {
                        Self.logNorm($0.netTx, maxRate: maxRate)
                    }
                }
                if traces.contains(.disk) {
                    drawLine(visible: visible, xOffset: xOffset, colW: colW,
                             bandY: inner.minY, bandH: cpuH,
                             color: seriesColor(colors.diskRead, .diskRead, smoothed: smoothed),
                             lineWidth: 1.25, smoothed: smoothed) {
                        Self.logNorm($0.diskRead, maxRate: maxRate)
                    }
                    drawLine(visible: visible, xOffset: xOffset, colW: colW,
                             bandY: inner.minY, bandH: cpuH,
                             color: seriesColor(colors.diskWrite, .diskWrite, smoothed: smoothed),
                             lineWidth: 1.25, smoothed: smoothed) {
                        Self.logNorm($0.diskWrite, maxRate: maxRate)
                    }
                }
            }
        }

        if visible > 1, traces.contains(.gpu), smoothed {
            drawLine(visible: visible, xOffset: xOffset, colW: colW,
                     bandY: inner.minY, bandH: cpuH,
                     color: seriesColor(colors.gpu, .gpu, smoothed: true),
                     smoothed: true,
                     glowDepth: Self.gpuGlowDepth) { $0.gpu }
        }

        if traces.contains(.cpu), smoothed {
            drawCPUArea(visible: visible, xOffset: xOffset, colW: colW,
                        baseY: inner.minY, cpuH: cpuH,
                        colors: [seriesColor(pSysColor, .pSys, smoothed: true),
                                 seriesColor(eSysColor, .eSys, smoothed: true),
                                 seriesColor(pUsrColor, .pUser, smoothed: true),
                                 seriesColor(eUsrColor, .eUser, smoothed: true)])
        } else if traces.contains(.cpu) {
            for i in 0..<visible {
                let f = frames[visibleIndex(i)]
                let x = inner.minX + xOffset + CGFloat(i) * colW

                let pSys = CGFloat(f.cpu.pSys * pWeight) * cpuH
                let eSys = CGFloat(f.cpu.eSys * eWeight) * cpuH
                let pUsr = CGFloat(f.cpu.pUser * pWeight) * cpuH
                let eUsr = CGFloat(f.cpu.eUser * eWeight) * cpuH

                var y = inner.minY
                pSysColor.setFill()
                NSRect(x: x, y: y, width: colW, height: pSys).fill()
                y += pSys
                eSysColor.setFill()
                NSRect(x: x, y: y, width: colW, height: eSys).fill()
                y += eSys
                pUsrColor.setFill()
                NSRect(x: x, y: y, width: colW, height: pUsr).fill()
                y += pUsr
                eUsrColor.setFill()
                NSRect(x: x, y: y, width: colW, height: eUsr).fill()
            }
        }

        if visible > 1, traces.contains(.gpu), !smoothed {
            drawLine(visible: visible, xOffset: xOffset, colW: colW,
                     bandY: inner.minY, bandH: cpuH,
                     color: colors.gpu, smoothed: false) { $0.gpu }
        }

        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func drawLine(visible: Int, xOffset: CGFloat, colW: CGFloat,
                          bandY: CGFloat, bandH: CGFloat, color: NSColor,
                          lineWidth: CGFloat = 2.5, smoothed: Bool = false,
                          glowDepth: CGFloat = 0,
                          value: (HistoryFrame) -> Double) {
        // Split into contiguous non-zero segments; idle stretches leave a gap
        // rather than a baseline line.
        var segments: [[NSPoint]] = []
        var cur: [NSPoint] = []
        for i in 0..<visible {
            let v = value(frames[visibleIndex(i)])
            if v <= 0.001 {
                if !cur.isEmpty { segments.append(cur); cur = [] }
                continue
            }
            let x = xOffset + CGFloat(i) * colW + colW / 2
            let y = bandY + CGFloat(v) * bandH
            cur.append(NSPoint(x: x, y: y))
        }
        if !cur.isEmpty { segments.append(cur) }

        for seg in segments {
            let path = smoothed ? Self.smoothPath(seg) : Self.straightPath(seg)
            if glowDepth > 0, seg.count > 1 {
                Self.drawGlow(under: path, points: seg, baseY: bandY,
                              depth: bandH * glowDepth, color: color)
            }
            color.setStroke()
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    /// Filled, smoothed stacked CPU area, drawn translucent so the GPU trace
    /// behind it shows through. Each band is a ribbon between its own lower and
    /// upper cumulative boundary — NOT filled down to the baseline — because
    /// overlapping translucent fills would composite and muddy every colour.
    /// A brighter opaque stroke along each top edge keeps thin bands legible.
    private func drawCPUArea(visible: Int, xOffset: CGFloat, colW: CGFloat,
                             baseY: CGFloat, cpuH: CGFloat, colors bandColors: [NSColor]) {
        guard visible > 1 else { return }
        var tops = [[NSPoint]](repeating: [], count: 5)  // tops[k] = top after k bands
        for i in 0..<visible {
            let f = frames[visibleIndex(i)]
            let x = xOffset + CGFloat(i) * colW + colW / 2
            let y1 = baseY + CGFloat(f.cpu.pSys  * pWeight) * cpuH
            let y2 = y1   + CGFloat(f.cpu.eSys  * eWeight) * cpuH
            let y3 = y2   + CGFloat(f.cpu.pUser * pWeight) * cpuH
            let y4 = y3   + CGFloat(f.cpu.eUser * eWeight) * cpuH
            tops[0].append(NSPoint(x: x, y: baseY))
            tops[1].append(NSPoint(x: x, y: y1))
            tops[2].append(NSPoint(x: x, y: y2))
            tops[3].append(NSPoint(x: x, y: y3))
            tops[4].append(NSPoint(x: x, y: y4))
        }
        for k in 1...4 {
            let c = bandColors[k - 1].lifted(by: Self.bandLift)
            Self.fillVertical(Self.ribbon(upper: tops[k], lower: tops[k - 1]),
                              top: c.withAlphaComponent(Self.bandAlphaTop),
                              bottom: c.withAlphaComponent(Self.bandAlphaBottom))
            let edge = Self.smoothPath(tops[k])
            c.setStroke()
            edge.lineWidth = Self.bandEdgeWidth
            edge.lineJoinStyle = .round
            edge.stroke()
        }
    }

    /// Closed path bounded above by `upper` and below by `lower`, as ONE
    /// subpath. Both boundaries are appended into the same subpath rather than
    /// via `append(_:)` — appending a path starts a fresh subpath (it carries
    /// its own moveTo), which leaves the upper boundary open and fills it
    /// closed along a diagonal from its last point back to its first.
    private static func ribbon(upper: [NSPoint], lower: [NSPoint]) -> NSBezierPath {
        guard !lower.isEmpty else { return smoothPath(upper) }
        let path = NSBezierPath()
        appendSmooth(upper, to: path, startingWithMove: true)
        appendSmooth(lower.reversed(), to: path, startingWithMove: false)
        path.close()
        return path
    }

    /// Fill a path with a vertical gradient spanning its own bounds.
    private static func fillVertical(_ path: NSBezierPath, top: NSColor, bottom: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = path.bounds
        // Degenerate (all-zero) band: a gradient over zero height draws nothing.
        guard b.height > 0.5, let gradient = NSGradient(starting: bottom, ending: top) else {
            top.setFill()
            path.fill()
            return
        }
        ctx.saveGState()
        path.addClip()
        gradient.draw(from: NSPoint(x: b.midX, y: b.minY),
                      to: NSPoint(x: b.midX, y: b.maxY), options: [])
        ctx.restoreGState()
    }

    /// Soft fill hanging a fixed depth below a line: progressively wider strokes
    /// along the curve, clipped to the area beneath it. Following the curve
    /// matters — a single linear gradient keys off the line's maximum, so any
    /// lower excursion falls past the gradient's end stop and gets no fill at
    /// all. Stacking strokes also avoids the seams a per-column gradient leaves.
    private static func drawGlow(under path: NSBezierPath, points: [NSPoint],
                                 baseY: CGFloat, depth: CGFloat, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              depth > 0, let first = points.first, let last = points.last else { return }
        let area = path.copy() as! NSBezierPath
        area.line(to: NSPoint(x: last.x, y: baseY))
        area.line(to: NSPoint(x: first.x, y: baseY))
        area.close()

        ctx.saveGState()
        area.addClip()
        // Per-layer alpha solved so `layers` composites reach gpuGlowPeak.
        let layerAlpha = 1 - pow(1 - gpuGlowPeak, 1 / CGFloat(gpuGlowLayers))
        color.withAlphaComponent(layerAlpha).setStroke()
        let glow = path.copy() as! NSBezierPath
        glow.lineJoinStyle = .round
        glow.lineCapStyle = .round
        for i in 0..<gpuGlowLayers {
            let t = CGFloat(i + 1) / CGFloat(gpuGlowLayers)
            glow.lineWidth = 2 * depth * t * t   // quadratic: tighter near the line
            glow.stroke()
        }
        ctx.restoreGState()
    }

    private static func straightPath(_ pts: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        for (i, p) in pts.enumerated() {
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        return path
    }

    /// Catmull-Rom spline through the points, expressed as cubic bezier curves.
    private static func smoothPath(_ pts: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        appendSmooth(pts, to: path, startingWithMove: true)
        return path
    }

    /// Append the spline through `pts` to `path`. With `startingWithMove` false
    /// it connects to the current point with a line first, keeping everything
    /// in one subpath — see `ribbon(upper:lower:)`.
    private static func appendSmooth(_ pts: [NSPoint], to path: NSBezierPath,
                                     startingWithMove: Bool) {
        func begin(_ p: NSPoint) {
            if startingWithMove { path.move(to: p) } else { path.line(to: p) }
        }
        guard pts.count > 1 else {
            if let p = pts.first { begin(p) }
            return
        }
        if pts.count == 2 {
            begin(pts[0]); path.line(to: pts[1]); return
        }
        begin(pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
    }
}

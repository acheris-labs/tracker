import AppKit

struct HistoryFrame {
    let cpu: CPUFrame
    let gpu: Double
    let battery: Double      // 0..1; ignored when renderer.hasBattery == false
    let memory: Double       // 0..1
    let diskRead: Double     // bytes/sec
    let diskWrite: Double    // bytes/sec
}

struct ChartColors {
    var pSys: NSColor
    var eSys: NSColor
    var pUser: NSColor
    var eUser: NSColor
    var gpu: NSColor
    var memory: NSColor
    var diskRead: NSColor
    var diskWrite: NSColor

    static let `default` = ChartColors(
        pSys:      NSColor(srgbRed: 0.95, green: 0.20, blue: 0.20, alpha: 1),
        eSys:      NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1),
        pUser:     NSColor(srgbRed: 0.20, green: 0.85, blue: 0.30, alpha: 1),
        eUser:     NSColor(srgbRed: 0.30, green: 0.62, blue: 1.00, alpha: 1),
        gpu:       NSColor(srgbRed: 1.00, green: 0.30, blue: 0.85, alpha: 1),
        memory:    NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1),
        diskRead:  NSColor(srgbRed: 0.20, green: 0.85, blue: 0.85, alpha: 1),
        diskWrite: NSColor(srgbRed: 0.85, green: 0.45, blue: 0.95, alpha: 1)
    )

    private static let keys = (
        pSys: "Color.pSys", eSys: "Color.eSys",
        pUser: "Color.pUser", eUser: "Color.eUser",
        gpu: "Color.gpu",
        memory: "Color.memory",
        diskRead: "Color.diskRead", diskWrite: "Color.diskWrite"
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
            memory:    d.string(forKey: keys.memory).flatMap(NSColor.fromHex) ?? def.memory,
            diskRead:  d.string(forKey: keys.diskRead).flatMap(NSColor.fromHex) ?? def.diskRead,
            diskWrite: d.string(forKey: keys.diskWrite).flatMap(NSColor.fromHex) ?? def.diskWrite
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(pSys.hexString,      forKey: ChartColors.keys.pSys)
        d.set(eSys.hexString,      forKey: ChartColors.keys.eSys)
        d.set(pUser.hexString,     forKey: ChartColors.keys.pUser)
        d.set(eUser.hexString,     forKey: ChartColors.keys.eUser)
        d.set(gpu.hexString,       forKey: ChartColors.keys.gpu)
        d.set(memory.hexString,    forKey: ChartColors.keys.memory)
        d.set(diskRead.hexString,  forKey: ChartColors.keys.diskRead)
        d.set(diskWrite.hexString, forKey: ChartColors.keys.diskWrite)
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

final class HistoryRenderer {
    // Storage holds up to `storage` recent samples; the view window
    // (`capacity`) selects how many of the most recent samples to draw.
    // Decoupling the two means resizing the view never loses data.
    static let maxStorage: Int = 600

    private var frames: [HistoryFrame]
    private var head: Int = 0
    private var count: Int = 0

    private(set) var capacity: Int   // current view window in samples (= seconds at 1 Hz)

    private let pointSize = NSSize(width: 128, height: 128)
    private let pixelScale: CGFloat = 2

    private let pWeight: Double
    private let eWeight: Double
    let hasBattery: Bool
    var colors: ChartColors
    var showGPU: Bool = true
    var showBattery: Bool = true
    var showMemory: Bool = true
    var showDisk: Bool = true

    init(capacity: Int, numP: Int, numE: Int, hasBattery: Bool, colors: ChartColors) {
        self.colors = colors
        self.hasBattery = hasBattery
        self.capacity = max(8, min(Self.maxStorage, capacity))
        self.frames = Array(repeating: HistoryFrame(cpu: CPUFrame(), gpu: 0, battery: 0,
                                                    memory: 0,
                                                    diskRead: 0, diskWrite: 0),
                            count: Self.maxStorage)
        let total = max(1, numP + numE)
        self.pWeight = Double(numP) / Double(total)
        self.eWeight = Double(numE) / Double(total)
    }

    func resize(capacity newCapacity: Int) {
        capacity = max(8, min(Self.maxStorage, newCapacity))
    }

    func append(cpu: CPUFrame, gpu: Double, battery: Double, memory: Double,
                diskRead: Double, diskWrite: Double) {
        frames[head] = HistoryFrame(cpu: cpu, gpu: gpu, battery: battery,
                                    memory: memory,
                                    diskRead: diskRead, diskWrite: diskWrite)
        head = (head + 1) % Self.maxStorage
        if count < Self.maxStorage { count += 1 }
    }

    private func visibleCount() -> Int {
        return min(count, capacity)
    }

    /// Index in `frames` for the i-th visible sample (0 = oldest visible).
    private func visibleIndex(_ i: Int) -> Int {
        let visible = visibleCount()
        return (head - visible + i + Self.maxStorage * 2) % Self.maxStorage
    }

    /// Visible-window max disk throughput in bytes/sec — what the chart's
    /// right-axis auto-scale is currently mapped to. Floor 1 MiB/s.
    func diskScaleMax() -> Double {
        let visible = visibleCount()
        var maxIO: Double = 1_048_576
        for i in 0..<visible {
            let f = frames[visibleIndex(i)]
            if f.diskRead > maxIO  { maxIO = f.diskRead }
            if f.diskWrite > maxIO { maxIO = f.diskWrite }
        }
        return maxIO
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

    func draw(in rect: NSRect) {
        let bg = NSColor(white: 0.04, alpha: 1)
        bg.setFill()
        rect.fill()

        let inner = rect
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.clip(to: inner)

        let H = inner.height
        let W = inner.width
        let colW = W / CGFloat(capacity)
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

        // Overlay lines drawn first so CPU bars overpaint them.
        if visible > 1 {
            if showGPU {
                drawLine(visible: visible, xOffset: xOffset, colW: colW,
                         bandY: inner.minY, bandH: cpuH,
                         color: colors.gpu) { $0.gpu }
            }
            if showMemory {
                drawLine(visible: visible, xOffset: xOffset, colW: colW,
                         bandY: inner.minY, bandH: cpuH,
                         color: colors.memory) { $0.memory }
            }
            if showDisk {
                // Independent auto-scale across read+write, floor 1 MiB/s.
                var maxIO: Double = 1_048_576
                for i in 0..<visible {
                    let f = frames[visibleIndex(i)]
                    if f.diskRead > maxIO  { maxIO = f.diskRead }
                    if f.diskWrite > maxIO { maxIO = f.diskWrite }
                }
                drawLine(visible: visible, xOffset: xOffset, colW: colW,
                         bandY: inner.minY, bandH: cpuH,
                         color: colors.diskRead, lineWidth: 1.25) {
                    min(1.0, $0.diskRead / maxIO)
                }
                drawLine(visible: visible, xOffset: xOffset, colW: colW,
                         bandY: inner.minY, bandH: cpuH,
                         color: colors.diskWrite, lineWidth: 1.25) {
                    min(1.0, $0.diskWrite / maxIO)
                }
            }
        }

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

        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func drawLine(visible: Int, xOffset: CGFloat, colW: CGFloat,
                          bandY: CGFloat, bandH: CGFloat, color: NSColor,
                          lineWidth: CGFloat = 2.5,
                          value: (HistoryFrame) -> Double) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        for i in 0..<visible {
            let f = frames[visibleIndex(i)]
            let x = xOffset + CGFloat(i) * colW + colW / 2
            let y = bandY + CGFloat(value(f)) * bandH
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else      { path.line(to: NSPoint(x: x, y: y)) }
        }
        color.setStroke()
        path.stroke()
    }
}

#!/usr/bin/env swift
// Generates a motion-tracker styled iconset for Tracker.
// Usage: swift tools/gen-icon.swift <output-iconset-dir>

import AppKit
import Foundation

func drawIcon(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Rounded squircle background, dark.
    let radius = size * 0.225
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.04, green: 0.05, blue: 0.04, alpha: 1).setFill()
    bgPath.fill()

    // Clip everything to the squircle.
    NSGraphicsContext.current?.cgContext.saveGState()
    bgPath.addClip()

    // Inner CRT screen tint.
    let inset = size * 0.085
    let screen = NSRect(x: inset, y: inset,
                        width: size - 2 * inset, height: size - 2 * inset)
    NSColor(srgbRed: 0.02, green: 0.10, blue: 0.04, alpha: 1).setFill()
    NSBezierPath(rect: screen).fill()

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let maxR = (size - 2 * inset) * 0.46
    let lineW = max(1, size / 256)

    // Concentric rings.
    NSColor(srgbRed: 0.20, green: 0.85, blue: 0.30, alpha: 0.45).setStroke()
    for i in 1...4 {
        let r = maxR * CGFloat(i) / 4
        let circle = NSBezierPath()
        circle.appendArc(withCenter: center, radius: r,
                         startAngle: 0, endAngle: 360)
        circle.lineWidth = lineW
        circle.stroke()
    }

    // Crosshairs.
    NSColor(srgbRed: 0.20, green: 0.85, blue: 0.30, alpha: 0.35).setStroke()
    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: center.x - maxR, y: center.y))
    cross.line(to: NSPoint(x: center.x + maxR, y: center.y))
    cross.move(to: NSPoint(x: center.x, y: center.y - maxR))
    cross.line(to: NSPoint(x: center.x, y: center.y + maxR))
    cross.lineWidth = lineW
    cross.stroke()

    // Sweep line — bright wedge from center.
    let sweepDeg: CGFloat = 55
    let sweepRad = sweepDeg * .pi / 180
    let sweep = NSBezierPath()
    sweep.move(to: center)
    sweep.line(to: NSPoint(x: center.x + cos(sweepRad) * maxR,
                           y: center.y + sin(sweepRad) * maxR))
    NSColor(srgbRed: 0.30, green: 1.00, blue: 0.40, alpha: 0.95).setStroke()
    sweep.lineWidth = max(2, size / 100)
    sweep.lineCapStyle = .round
    sweep.stroke()

    // Faint sweep tail (a short arc trailing the line).
    let trail = NSBezierPath()
    trail.appendArc(withCenter: center, radius: maxR * 0.95,
                    startAngle: sweepDeg - 35, endAngle: sweepDeg, clockwise: false)
    NSColor(srgbRed: 0.20, green: 0.85, blue: 0.30, alpha: 0.35).setStroke()
    trail.lineWidth = max(1.5, size / 150)
    trail.stroke()

    // Blips.
    let blipR = max(1.5, size / 70)
    let blips: [(deg: CGFloat, dist: CGFloat)] = [
        (40,  0.62),
        (200, 0.42),
        (310, 0.85),
    ]
    NSColor(srgbRed: 0.45, green: 1.00, blue: 0.50, alpha: 1).setFill()
    for b in blips {
        let rad = b.deg * .pi / 180
        let bx = center.x + cos(rad) * maxR * b.dist
        let by = center.y + sin(rad) * maxR * b.dist
        NSBezierPath(ovalIn: NSRect(x: bx - blipR, y: by - blipR,
                                    width: blipR * 2, height: blipR * 2)).fill()
    }

    NSGraphicsContext.current?.cgContext.restoreGState()
}

func makePNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "Tracker.iconset"

try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png", 1024),
]

for e in entries {
    let png = makePNG(size: e.size)
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(e.name)"))
}

FileHandle.standardOutput.write("wrote \(outDir) with \(entries.count) images\n".data(using: .utf8)!)

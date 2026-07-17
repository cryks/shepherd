// Renders the five menu-bar status icons as PNGs for the README legend.
// Usage: swift Support/GenerateStatusIcons.swift <output directory>
//
// The drawing duplicates StatusIcons.circleImage in Sources/Shepherd/ShepherdApp.swift
// (18pt canvas, 14pt outer diameter, 1.5 line width, dash pattern [2.5, 2.0]). To keep
// the legend looking identical to the real thing, update this file whenever the app's
// dimensions change and run make icon.
//
// Color handling differs from the app in exactly two ways:
//   - Dynamic colors such as systemRed are resolved with the appearance pinned to aqua.
//     A CLI run has no window appearance context, so this keeps colors from shifting
//     with the settings of whatever environment runs the script.
//   - The two achromatic states (idle / disconnected) are template images in the app and
//     follow the menu bar's light/dark rendering, but a PNG is a single image, so they
//     are fixed to a mid gray (white: 0.5) that stays readable on both GitHub themes.
//
// Output is 4x the 18pt size (72px). The README uses width="18" so the edges
// stay crisp on Retina displays.
import AppKit

struct StatusIcon {
    let filename: String
    let color: NSColor
    let filled: Bool
    var dashed = false
}

let legendGray = NSColor(white: 0.5, alpha: 1)
let icons: [StatusIcon] = [
    StatusIcon(filename: "blocked.png", color: .systemRed, filled: true),
    StatusIcon(filename: "done.png", color: .systemGreen, filled: true),
    StatusIcon(filename: "working.png", color: .systemYellow, filled: false),
    StatusIcon(filename: "quiet.png", color: legendGray, filled: false),
    StatusIcon(filename: "disconnected.png", color: legendGray, filled: false, dashed: true),
]

let pointSize: CGFloat = 18
let scale: CGFloat = 4

func draw(_ icon: StatusIcon, in rect: NSRect) {
    let lineWidth: CGFloat = 1.5
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2 + lineWidth / 2, dy: 2 + lineWidth / 2))
    if icon.dashed {
        var pattern: [CGFloat] = [2.5, 2.0]
        ring.setLineDash(&pattern, count: pattern.count, phase: 0)
    }
    icon.color.setStroke()
    ring.lineWidth = lineWidth
    ring.stroke()
    if icon.filled {
        let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
        icon.color.setFill()
        dot.fill()
    }
}

func render(_ icon: StatusIcon, to url: URL) {
    let pixels = Int(pointSize * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("NSBitmapImageRep 作成失敗: \(icon.filename)") }
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("NSGraphicsContext 作成失敗: \(icon.filename)")
    }
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        draw(icon, in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 変換失敗: \(icon.filename)")
    }
    do {
        try png.write(to: url)
    } catch {
        fatalError("PNG 出力失敗: \(url.path) \(error)")
    }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift Support/GenerateStatusIcons.swift <出力ディレクトリ>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for icon in icons {
    render(icon, to: outDir.appendingPathComponent(icon.filename))
}

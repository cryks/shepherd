// Every size is redrawn on a logical 1024pt canvas through a scale transform
// rather than downscaled from one bitmap, so edges stay sharp down to 16px.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let skyTop = rgb(0x1B2333)
let skyBottom = rgb(0x39496B)
let hillTop = rgb(0x3C7147)
let hillBottom = rgb(0x224730)
let wool = rgb(0xF4F6FA)
let woolShade = rgb(0xD9DFE9)
let face = rgb(0x373238)
let crookColor = rgb(0xC98A4B)
let shadow = rgb(0x000000, 0.30)

func linearGradient(_ ctx: CGContext, in path: CGPath, from top: CGColor, to bottom: CGColor, yTop: CGFloat, yBottom: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: yTop), end: CGPoint(x: 0, y: yBottom), options: [])
    ctx.restoreGState()
}

func circle(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

func ellipse(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, rotation: CGFloat = 0, _ color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: rotation)
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    // Apple's icon grid: 100pt margin, corner radius 22.5% of the 824pt side.
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: iconRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.addPath(squircle)
    ctx.clip()

    linearGradient(ctx, in: squircle, from: skyTop, to: skyBottom, yTop: 924, yBottom: 240)

    // The three colored stars quote the StatusIcons state colors: working, done, blocked.
    circle(ctx, 246, 812, 9, rgb(0xF0C64F))
    circle(ctx, 520, 862, 8, rgb(0x66C97A))
    circle(ctx, 858, 690, 8, rgb(0xE06A5A))
    circle(ctx, 402, 760, 5, rgb(0xFFFFFF, 0.75))
    circle(ctx, 680, 900, 5, rgb(0xFFFFFF, 0.6))

    // The hill is one ellipse far wider than the canvas, so only its flat apex shows.
    let hillPath = CGMutablePath()
    hillPath.addEllipse(in: CGRect(x: 512 - 760, y: 68 - 300, width: 1520, height: 600))
    linearGradient(ctx, in: hillPath, from: hillTop, to: hillBottom, yTop: 368, yBottom: 100)

    ellipse(ctx, cx: 540, cy: 295, rx: 240, ry: 36, shadow)

    let crook = CGMutablePath()
    crook.move(to: CGPoint(x: 812, y: 330))
    crook.addLine(to: CGPoint(x: 812, y: 742))
    crook.addArc(center: CGPoint(x: 744, y: 742), radius: 68, startAngle: 0, endAngle: .pi, clockwise: false)
    crook.addLine(to: CGPoint(x: 676, y: 692))
    ctx.setStrokeColor(crookColor)
    ctx.setLineWidth(36)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(crook)
    ctx.strokePath()

    // Legs come before the body so the fluff covers where they attach; they run up
    // past the body's lower edge (y≈325) and only the last ~35px show.
    ctx.setFillColor(face)
    for x: CGFloat in [480, 610] {
        let leg = CGPath(roundedRect: CGRect(x: x - 22, y: 290, width: 44, height: 120), cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.addPath(leg)
        ctx.fillPath()
    }

    let bodyCX: CGFloat = 545
    let bodyCY: CGFloat = 495
    let fluff: [(CGFloat, CGFloat, CGFloat)] = [
        (-160, 10, 92), (-95, 75, 88), (0, 95, 95), (95, 75, 88),
        (160, 10, 92), (110, -60, 85), (0, -80, 90), (-110, -60, 85),
        (0, 0, 140),
    ]
    // Shading the top circles first and offset down leaves shadow only in the valleys
    // once the white pass covers the rest.
    for (dx, dy, r) in fluff where dy < 0 {
        circle(ctx, bodyCX + dx, bodyCY + dy - 12, r, woolShade)
    }
    for (dx, dy, r) in fluff {
        circle(ctx, bodyCX + dx, bodyCY + dy, r, wool)
    }

    // The ears must reach past the face outline (cx 348 ± rx 84), which is drawn over them.
    ellipse(ctx, cx: 242, cy: 585, rx: 58, ry: 30, rotation: 0.55, face)
    ellipse(ctx, cx: 458, cy: 590, rx: 56, ry: 30, rotation: -0.5, face)
    ellipse(ctx, cx: 348, cy: 548, rx: 84, ry: 102, face)
    circle(ctx, 320, 650, 48, wool)
    circle(ctx, 378, 652, 44, wool)
    circle(ctx, 350, 672, 40, wool)
    circle(ctx, 318, 562, 15, wool)
    circle(ctx, 382, 562, 15, wool)
}

func render(pixels: Int, to url: URL) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext 作成失敗: \(pixels)px") }
    let s = CGFloat(pixels) / canvas
    ctx.scaleBy(x: s, y: s)
    drawIcon(ctx)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("PNG 出力失敗: \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift Support/GenerateAppIcon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// iconutil requires exactly these 10 sizes.
let entries: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for (point, scale) in entries {
    let suffix = scale == 2 ? "@2x" : ""
    render(pixels: point * scale, to: outDir.appendingPathComponent("icon_\(point)x\(point)\(suffix).png"))
}

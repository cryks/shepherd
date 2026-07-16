// メニューバーの状態アイコン 5 種を README の凡例用 PNG として出力する。
// 使い方: swift Support/GenerateStatusIcons.swift <出力ディレクトリ>
//
// 描画は Sources/Shepherd/ShepherdApp.swift の StatusIcons.circleImage の複製
// (18pt キャンバス・外径 14pt・線幅 1.5・破線 [2.5, 2.0])。凡例を実物と同じ
// 見た目に保つため、本体の寸法を変えたらここも揃えて make icon を実行する。
//
// 色の扱いだけ本体と 2 点違う:
//   - systemRed などの動的色は aqua 外観で固定して解決する。CLI 実行には
//     ウィンドウの外観コンテキストがなく、実行環境の設定で色が揺れるのを防ぐ。
//   - 無彩色 2 状態 (idle / 未接続) は本体では template 画像としてメニューバーの
//     明暗に追従するが、PNG は 1 枚なので GitHub の light / dark 両テーマで
//     読める中間グレー (white: 0.5) に固定する。
//
// 出力は 18pt の 4 倍 (72px)。README 側で width="18" にして Retina でも
// 縁が滲まないようにする。
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

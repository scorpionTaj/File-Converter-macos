// Draws the disk image window background (640×400 pt, plus @2x):
//   swift scripts/make-dmg-background.swift build/dmg-background
// Icons sit at x=160 (Kumquat) and x=480 (Applications), y=210 from the top — see scripts/dmg-settings.py.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dmg-background", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let width: CGFloat = 640, height: CGFloat = 400

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// y measured from the top, like Finder's icon positions.
func top(_ y: CGFloat) -> CGFloat { height - y }

func centered(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ])
    let bounds = attributed.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin])
    attributed.draw(in: NSRect(x: 0, y: top(y) - bounds.height / 2, width: width, height: bounds.height))
}

func drawBackground() {
    // Warm citrus gradient.
    NSGradient(colors: [color(0xFFF8EF), color(0xFFE6C7)])!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Soft kumquat slices in the corners.
    for (x, y, r, alpha) in [(40.0, 60.0, 90.0, 0.10), (600.0, 360.0, 110.0, 0.08), (590.0, 40.0, 50.0, 0.07)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        color(0xFF8A00, alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: top(y) - r, width: r * 2, height: r * 2)).fill()
        color(0xFFFFFF, alpha * 2.2).setStroke()
        for segment in 0..<8 {
            let angle = CGFloat(segment) * .pi / 4
            let spoke = NSBezierPath()
            spoke.move(to: NSPoint(x: x, y: top(y)))
            spoke.line(to: NSPoint(x: x + cos(angle) * r * 0.82, y: top(y) + sin(angle) * r * 0.82))
            spoke.lineWidth = 2
            spoke.stroke()
        }
    }

    centered("Kumquat", size: 30, weight: .bold, color: color(0x3A2410), y: 52)
    centered("Drag Kumquat into Applications to install", size: 14, weight: .medium, color: color(0x7A4A1C), y: 88)

    // Curved, dashed arrow between the two icons.
    let arrow = NSBezierPath()
    let start = NSPoint(x: 236, y: top(206)), end = NSPoint(x: 400, y: top(206))
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: NSPoint(x: 290, y: top(176)), controlPoint2: NSPoint(x: 346, y: top(176)))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.setLineDash([12, 9], count: 2, phase: 0)
    color(0xFF8A00).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x + 14, y: end.y + 2))
    head.line(to: NSPoint(x: end.x - 6, y: end.y + 14))
    head.line(to: NSPoint(x: end.x - 2, y: end.y - 10))
    head.close()
    color(0xFF8A00).setFill()
    head.fill()

    centered("First launch: right-click Kumquat ▸ Open (development builds are ad-hoc signed).",
             size: 11, weight: .regular, color: color(0x8A6440), y: 330)
    centered("Optional: brew install ffmpeg pandoc pngquant webp", size: 11, weight: .regular,
             color: color(0x8A6440), y: 350)
}

func render(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try render(scale: 1, to: output.appendingPathComponent("background.png"))
try render(scale: 2, to: output.appendingPathComponent("background@2x.png"))
print("DMG background written to \(output.path)")

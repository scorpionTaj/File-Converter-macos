// Draws Kumquat's app icon into an .iconset folder: `swift scripts/make-icon.swift build/AppIcon.iconset`
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle background with a warm gradient.
    let inset = 100 * s
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let background = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 1.00, green: 0.78, blue: 0.36, alpha: 1),
                        NSColor(red: 0.98, green: 0.45, blue: 0.12, alpha: 1)])!.draw(in: background, angle: -90)

    // Fruit.
    let center = NSPoint(x: size / 2, y: size / 2 - 30 * s)
    let radius = 250 * s
    let fruit = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius * 0.92, width: radius * 2, height: radius * 1.84))
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 40 * s
    shadow.shadowOffset = NSSize(width: 0, height: -18 * s)
    shadow.shadowColor = NSColor(red: 0.55, green: 0.18, blue: 0, alpha: 0.45)
    shadow.set()
    NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1),
                        NSColor(red: 0.95, green: 0.36, blue: 0.02, alpha: 1)])!.draw(in: fruit, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
    NSGraphicsContext.restoreGraphicsState()

    // Highlight.
    NSColor(white: 1, alpha: 0.35).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.55, y: center.y + radius * 0.25, width: radius * 0.45, height: radius * 0.3)).fill()

    // Leaf.
    let leaf = NSBezierPath()
    let stem = NSPoint(x: center.x + 20 * s, y: center.y + radius * 0.9)
    leaf.move(to: stem)
    leaf.curve(to: NSPoint(x: stem.x + 230 * s, y: stem.y + 120 * s),
               controlPoint1: NSPoint(x: stem.x + 60 * s, y: stem.y + 150 * s),
               controlPoint2: NSPoint(x: stem.x + 170 * s, y: stem.y + 170 * s))
    leaf.curve(to: stem,
               controlPoint1: NSPoint(x: stem.x + 170 * s, y: stem.y + 30 * s),
               controlPoint2: NSPoint(x: stem.x + 70 * s, y: stem.y + 10 * s))
    NSColor(red: 0.20, green: 0.62, blue: 0.25, alpha: 1).setFill()
    leaf.fill()

    // Conversion arrows across the fruit.
    NSColor(white: 1, alpha: 0.92).setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 34 * s
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: center.x - 120 * s, y: center.y + 40 * s))
    arrow.line(to: NSPoint(x: center.x + 110 * s, y: center.y + 40 * s))
    arrow.line(to: NSPoint(x: center.x + 50 * s, y: center.y + 100 * s))
    arrow.move(to: NSPoint(x: center.x + 120 * s, y: center.y - 60 * s))
    arrow.line(to: NSPoint(x: center.x - 110 * s, y: center.y - 60 * s))
    arrow.line(to: NSPoint(x: center.x - 50 * s, y: center.y - 120 * s))
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(name: String, pixels: CGFloat)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let data = drawIcon(size: pixels).representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent("icon_\(name).png"))
}
print("Icon written to \(output.path)")

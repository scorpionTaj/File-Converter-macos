import Foundation
import CoreGraphics
import CoreText

/// RGBA colour usable without AppKit.
public struct AnnotationColor: Equatable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }

    public static let red = AnnotationColor(red: 0.96, green: 0.22, blue: 0.20)
    public static let yellow = AnnotationColor(red: 1.0, green: 0.84, blue: 0.0)
    public static let black = AnnotationColor(red: 0, green: 0, blue: 0)
}

/// One mark on an image. Coordinates are image pixels with the origin at the bottom-left (Core Graphics space).
public enum AnnotationShape: Equatable, Sendable {
    case pen([CGPoint])
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    /// Translucent marker over a region.
    case highlight(CGRect)
    /// `origin` is the left end of the text baseline.
    case text(String, origin: CGPoint, fontSize: CGFloat)
    /// Irreversibly mosaics the region (for hiding faces, names, numbers).
    case pixelate(CGRect)
}

public struct Annotation: Equatable, Sendable {
    public var shape: AnnotationShape
    public var color: AnnotationColor
    public var lineWidth: CGFloat

    public init(_ shape: AnnotationShape, color: AnnotationColor = .red, lineWidth: CGFloat = 6) {
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// Draws annotations. The same code renders the live preview and the exported file, so they always match.
public enum AnnotationRenderer {
    /// Flattens annotations into a new image, optionally cropped (crop rect in image coordinates).
    public static func render(_ base: CGImage, annotations: [Annotation], crop: CGRect? = nil) throws -> CGImage {
        let width = base.width, height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KumquatError.conversionFailed("Image is too large to annotate.")
        }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        draw(annotations, base: base, in: context)
        guard var result = context.makeImage() else { throw KumquatError.conversionFailed("Couldn't render the image.") }
        if let crop {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let clipped = crop.standardized.intersection(bounds).integral
            guard clipped.width >= 1, clipped.height >= 1 else { throw KumquatError.invalidInput("The crop area is empty.") }
            // CGImage cropping uses a top-left origin.
            let flipped = CGRect(x: clipped.minX, y: CGFloat(height) - clipped.maxY, width: clipped.width, height: clipped.height)
            guard let cropped = result.cropping(to: flipped) else { throw KumquatError.conversionFailed("Couldn't crop.") }
            result = cropped
        }
        return result
    }

    /// Draws into a context already set up in image coordinates (the base image is drawn by the caller).
    public static func draw(_ annotations: [Annotation], base: CGImage, in context: CGContext) {
        // Mosaics first so other marks stay visible on top of them.
        for annotation in annotations {
            if case .pixelate(let rect) = annotation.shape { pixelate(rect, of: base, in: context) }
        }
        for annotation in annotations {
            context.saveGState()
            draw(annotation, in: context)
            context.restoreGState()
        }
    }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        let color = annotation.color.cgColor
        let width = annotation.lineWidth
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case .pen(let points):
            guard let first = points.first else { return }
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                return
            }
            context.beginPath()
            context.move(to: first)
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.strokePath()

        case .arrow(let from, let to):
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = max(width * 3.5, 14)
            let spread: CGFloat = .pi / 7
            // Stop the shaft short so the round cap doesn't poke through the tip.
            let shaftEnd = CGPoint(x: to.x - cos(angle) * head * 0.6, y: to.y - sin(angle) * head * 0.6)
            context.beginPath()
            context.move(to: from)
            context.addLine(to: shaftEnd)
            context.strokePath()
            context.beginPath()
            context.move(to: to)
            context.addLine(to: CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head))
            context.addLine(to: CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head))
            context.closePath()
            context.fillPath()

        case .rectangle(let rect):
            context.stroke(rect.standardized)

        case .ellipse(let rect):
            context.strokeEllipse(in: rect.standardized)

        case .highlight(let rect):
            context.setBlendMode(.multiply)
            context.setFillColor(color.copy(alpha: 0.4) ?? color)
            context.fill(rect.standardized)

        case .text(let string, let origin, let fontSize):
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let lines = string.components(separatedBy: "\n")
            // View contexts can carry a text matrix; reset it so preview and export match.
            context.textMatrix = .identity
            context.setShadow(offset: .zero, blur: max(fontSize / 8, 2), color: CGColor(gray: 0, alpha: 0.55))
            for (index, text) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: origin.x, y: origin.y - CGFloat(index) * fontSize * 1.2)
                CTLineDraw(line, context)
            }

        case .pixelate:
            break
        }
    }

    /// Replaces a region with a coarse mosaic of itself.
    static func pixelate(_ rect: CGRect, of base: CGImage, in context: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let region = rect.standardized.intersection(bounds).integral
        guard region.width >= 2, region.height >= 2 else { return }
        let flipped = CGRect(x: region.minX, y: CGFloat(base.height) - region.maxY, width: region.width, height: region.height)
        guard let piece = base.cropping(to: flipped) else { return }
        let block = max(8, Int(max(region.width, region.height) / 14))
        let smallWidth = max(1, Int(region.width) / block), smallHeight = max(1, Int(region.height) / block)
        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(piece, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let mosaic = small.makeImage() else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(mosaic, in: region)
        context.restoreGState()
    }
}

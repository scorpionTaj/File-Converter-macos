import Foundation
import AppKit
import CoreText
import PDFKit
import Vision

// Searchable OCR, page arrangement and markup for PDFs.
extension PDFEngine {

    // MARK: Searchable PDF

    /// Adds an invisible, selectable text layer to pages that have none, so a scanned PDF can be searched,
    /// selected and copied. The page image stays exactly as it was; pages that already have text are copied
    /// untouched. Returns the number of pages that were recognised.
    static func makeSearchable(_ document: PDFDocument, output: URL, context: EngineContext) throws -> Int {
        let result = PDFDocument()
        var recognised = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let hasText = !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasText, let searchable = try searchablePage(page) {
                result.insert(searchable, at: result.pageCount)
                recognised += 1
            } else if let copy = page.copy() as? PDFPage {
                result.insert(copy, at: result.pageCount)
            }
            context.progress?(Double(index + 1) / Double(document.pageCount))
        }
        guard recognised > 0 else {
            let allText = (0..<document.pageCount).allSatisfy {
                !(document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            throw KumquatError.nothingToDo(allText ? "This PDF already has a text layer." : "No text recognised.")
        }
        guard result.write(to: output) else { throw KumquatError.conversionFailed(L("Couldn't save the PDF.")) }
        return recognised
    }

    /// The page redrawn with recognised text underneath in invisible ink; nil when nothing was recognised.
    private static func searchablePage(_ page: PDFPage) throws -> PDFPage? {
        guard let cgPage = page.pageRef else { return nil }
        // Recognise on the upright page (sideways text recognises poorly), then map back.
        let lines = try TextRecognizer.lines(in: render(page, dpi: 300))
        guard !lines.isEmpty else { return nil }

        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let upright = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        // The new page is upright with no /Rotate, so its text layer runs horizontally: text extraction
        // (PDFKit, Preview, browsers) reads rotated text one letter at a time. Page space → upright:
        let toUpright: CGAffineTransform
        switch rotation {
        case 90: toUpright = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: box.width)
        case 180: toUpright = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.width, ty: box.height)
        case 270: toUpright = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.height, ty: 0)
        default: toUpright = .identity
        }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: upright)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw KumquatError.conversionFailed(L("Couldn't create the PDF."))
        }
        pdf.beginPDFPage(nil)
        pdf.saveGState()
        pdf.concatenate(toUpright)
        pdf.translateBy(x: -box.minX, y: -box.minY)
        pdf.drawPDFPage(cgPage)
        pdf.restoreGState()

        pdf.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * upright.width, y: line.box.minY * upright.height,
                              width: line.box.width * upright.width, height: line.box.height * upright.height)
            drawInvisible(line.text, in: rect, context: pdf)
        }
        pdf.endPDFPage()
        pdf.closePDF()

        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Text stretched to fill `rect`, so selecting it highlights the words seen on the scan.
    private static func drawInvisible(_ text: String, in rect: CGRect, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, &descent, nil))
        guard width > 0 else { return }
        context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent)
        CTLineDraw(line, context)
    }

    // MARK: Arranging pages

    /// A new PDF with the pages in `entries`' order, each turned by its extra rotation.
    static func arrange(_ document: PDFDocument, entries: [PageArrangement.Entry], output: URL) throws {
        let result = PDFDocument()
        for entry in entries {
            guard let page = document.page(at: entry.page)?.copy() as? PDFPage else {
                throw KumquatError.invalidInput(L("Page \(entry.page + 1) doesn't exist."))
            }
            page.rotation = (page.rotation + entry.rotation) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.write(to: output) else { throw KumquatError.conversionFailed(L("Couldn't save the PDF.")) }
    }

    // MARK: Markup

    /// Saves a copy of `input` with `markups` added as standard PDF annotations, which Preview, Acrobat
    /// and browsers show and can edit.
    public static func annotate(_ input: URL, markups: [PDFMarkup], output: URL) throws {
        let document = try open(input)
        for markup in markups {
            guard let page = document.page(at: markup.page) else {
                throw KumquatError.invalidInput(L("Page \(markup.page + 1) doesn't exist."))
            }
            page.addAnnotation(markup.annotation())
        }
        guard document.write(to: output) else { throw KumquatError.conversionFailed(L("Couldn't save the PDF.")) }
    }
}

/// One mark added in the PDF annotation editor, in the page's coordinate space.
public struct PDFMarkup: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case highlight, underline, strikeOut, text, note, rectangle, ink

        public var title: String {
            switch self {
            case .highlight: return L("Highlight")
            case .underline: return L("Underline")
            case .strikeOut: return L("Strike Out")
            case .text: return L("Text")
            case .note: return L("Note")
            case .rectangle: return L("Box")
            case .ink: return L("Draw")
            }
        }

        /// Marks made over selected text rather than by clicking or dragging on the page.
        public var marksSelection: Bool { [.highlight, .underline, .strikeOut].contains(self) }
    }

    public var page: Int
    public var kind: Kind
    /// Line rectangles for text markup; the box for text, notes and rectangles; ignored for ink.
    public var rects: [CGRect]
    /// Freehand strokes, for ink.
    public var strokes: [[CGPoint]]
    public var text: String
    /// sRGB components.
    public var color: [CGFloat]

    public init(page: Int, kind: Kind, rects: [CGRect] = [], strokes: [[CGPoint]] = [], text: String = "",
                color: [CGFloat] = [1, 0.85, 0, 1]) {
        self.page = page
        self.kind = kind
        self.rects = rects
        self.strokes = strokes
        self.text = text
        self.color = color
    }

    static let lineWidth: CGFloat = 2

    /// Area the mark covers on its page.
    public var bounds: CGRect {
        let points = strokes.flatMap { $0 }
        if kind == .ink, let first = points.first {
            var box = CGRect(origin: first, size: .zero)
            points.forEach { box = box.union(CGRect(origin: $0, size: .zero)) }
            return box.insetBy(dx: -Self.lineWidth * 2, dy: -Self.lineWidth * 2)
        }
        return rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    public var nsColor: NSColor {
        let c = color + Array(repeating: 1, count: max(0, 4 - color.count))
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
    }

    /// The PDFKit annotation for this mark.
    public func annotation() -> PDFAnnotation {
        let annotation: PDFAnnotation
        switch kind {
        case .highlight, .underline, .strikeOut:
            let subtype: PDFAnnotationSubtype = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
            annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            // Quad points are relative to the annotation's origin: top-left, top-right, bottom-left, bottom-right.
            annotation.quadrilateralPoints = rects.flatMap { rect -> [NSValue] in
                let r = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                return [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                        CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)].map { NSValue(point: $0) }
            }
            annotation.color = kind == .highlight ? nsColor.withAlphaComponent(0.5) : nsColor
        case .text:
            annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
            annotation.fontColor = nsColor
            annotation.color = .clear
        case .note:
            annotation = PDFAnnotation(bounds: CGRect(origin: bounds.origin, size: CGSize(width: 20, height: 20)),
                                       forType: .text, withProperties: nil)
            annotation.contents = text
            annotation.color = nsColor
            annotation.iconType = .note
        case .rectangle:
            annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            annotation.color = nsColor
            let border = PDFBorder()
            border.lineWidth = Self.lineWidth
            annotation.border = border
        case .ink:
            let box = bounds
            annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
            annotation.color = nsColor
            let border = PDFBorder()
            border.lineWidth = Self.lineWidth
            annotation.border = border
            for stroke in strokes where !stroke.isEmpty {
                // Ink paths are relative to the annotation's origin.
                let path = NSBezierPath()
                path.lineWidth = Self.lineWidth
                path.move(to: CGPoint(x: stroke[0].x - box.minX, y: stroke[0].y - box.minY))
                for point in stroke.dropFirst() { path.line(to: CGPoint(x: point.x - box.minX, y: point.y - box.minY)) }
                if stroke.count == 1 { path.line(to: CGPoint(x: stroke[0].x - box.minX + 0.5, y: stroke[0].y - box.minY)) }
                annotation.add(path)
            }
        }
        annotation.modificationDate = Date()
        annotation.userName = "Kumquat"
        return annotation
    }
}

extension TextRecognizer {
    struct Line {
        var text: String
        /// Normalised to the image, origin at the bottom left (Vision's convention).
        var box: CGRect
    }

    /// Recognised lines with their positions.
    static func lines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Line(text: text, box: observation.boundingBox)
        }
    }
}

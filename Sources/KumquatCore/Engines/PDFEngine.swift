import Foundation
import AppKit
import PDFKit
import ImageIO
import Quartz

/// PDF rendering, text extraction and page-level tools with PDFKit.
public struct PDFEngine: ConversionEngine {
    public let id = EngineID.pdf

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let document = try Self.open(input)
        switch target {
        case .txt:
            try (document.string ?? "").write(to: output, atomically: true, encoding: .utf8)
            return output
        case .rtf:
            let text = Self.attributedText(document)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: output)
            return output
        default:
            guard target.kind == .image else { throw KumquatError.noRoute(from: source.name, to: target.name) }
            return try await Self.renderPages(document, to: output, format: target, context: context)
        }
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw KumquatError.invalidInput("\(url.lastPathComponent) isn't a readable PDF.")
        }
        if document.isLocked {
            throw KumquatError.invalidInput("\(url.lastPathComponent) is password-protected. Use Tools → Unlock first.")
        }
        return document
    }

    static func plainText(of url: URL) -> String {
        PDFDocument(url: url)?.string ?? ""
    }

    static func attributedText(_ document: PDFDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(text)
        }
        return result
    }

    // MARK: Rendering

    /// Renders a page in its unrotated user space, then applies the page rotation.
    static func render(_ page: PDFPage, dpi: Double, overlay: [CGRect] = []) throws -> CGImage {
        guard let cgPage = page.pageRef else { throw KumquatError.conversionFailed("Unreadable PDF page.") }
        let box = page.bounds(for: .cropBox)
        let scale = dpi / 72
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        let flat = try ImageEngine.render(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(cgPage)
            // Core Graphics skips annotations (highlights, notes, filled form fields); PDFKit draws them
            // in the same unrotated page space.
            for annotation in page.annotations where annotation.shouldDisplay {
                annotation.draw(with: .cropBox, in: ctx)
            }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            overlay.forEach { ctx.fill($0) }
        }
        switch ((page.rotation % 360) + 360) % 360 {
        case 90: return try ImageEngine.rotated(flat, clockwise: true)
        case 180: return try ImageEngine.rotated(ImageEngine.rotated(flat, clockwise: true), clockwise: true)
        case 270: return try ImageEngine.rotated(flat, clockwise: false)
        default: return flat
        }
    }

    static func renderPages(_ document: PDFDocument, to output: URL, format: Format, context: EngineContext) async throws -> URL {
        let dpi = context.options.pdfRenderDPI
        let quality = context.options.quality(for: format)
        guard document.pageCount > 0 else { throw KumquatError.nothingToDo("The PDF has no pages.") }
        let pages = try context.options.pdfPageRange.map { try PageRanges.parse($0, pageCount: document.pageCount) }
            ?? Array(0..<document.pageCount)
        if pages.count == 1, let page = document.page(at: pages[0]) {
            try await ImageEngine.write(render(page, dpi: dpi), to: output, format: format, quality: quality, context: context)
            return output
        }
        let folder = output.deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = output.deletingPathExtension().lastPathComponent
        let digits = String(document.pageCount).count
        for (done, index) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            // Numbered by page, not by position, so "3-5" gives "… 3", "… 4", "… 5".
            let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
            let url = folder.appendingPathComponent("\(base) \(number).\(format.fileExtension)")
            try await ImageEngine.write(render(page, dpi: dpi), to: url, format: format, quality: quality, context: context)
            context.progress?(Double(done + 1) / Double(pages.count))
        }
        return folder
    }

    // MARK: Building

    /// One page per image, one point per pixel. JPEGs are embedded as they are (no decode and re-encode),
    /// so the PDF is about the size of the photos instead of roughly double.
    static func makePDF(fromImages urls: [URL], output: URL, context: EngineContext) async throws {
        guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw KumquatError.conversionFailed("Couldn't create the PDF.")
        }
        var closed = false
        defer { if !closed { pdf.closePDF() } }
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let page: (image: CGImage, transform: CGAffineTransform, size: CGSize)
            if let jpeg = embeddableJPEG(url) {
                page = jpeg
            } else {
                let image = try await ImageEngine.loadImage(url, source: FormatRegistry.format(for: url), context: context)
                page = (image, .identity, CGSize(width: image.width, height: image.height))
            }
            var box = CGRect(origin: .zero, size: page.size)
            pdf.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            pdf.concatenate(page.transform)
            pdf.draw(page.image, in: CGRect(x: 0, y: 0, width: page.image.width, height: page.image.height))
            pdf.endPDFPage()
            context.progress?(Double(index + 1) / Double(urls.count))
        }
        pdf.closePDF()
        closed = true
        guard PDFDocument(url: output)?.pageCount == urls.count else {
            throw KumquatError.conversionFailed("Couldn't save the PDF.")
        }
    }

    /// A JPEG Core Graphics can copy straight into the PDF, with the transform that shows it upright.
    /// Mirrored orientations (rare) return nil and take the decode path instead.
    static func embeddableJPEG(_ url: URL) -> (image: CGImage, transform: CGAffineTransform, size: CGSize)? {
        guard FormatRegistry.format(for: url) == .jpg,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let provider = CGDataProvider(url: url as CFURL),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        switch properties[kCGImagePropertyOrientation] as? Int ?? 1 {
        case 1: return (image, .identity, CGSize(width: w, height: h))
        case 3: return (image, CGAffineTransform(translationX: w, y: h).rotated(by: .pi), CGSize(width: w, height: h))
        case 6: return (image, CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2), CGSize(width: h, height: w))
        case 8: return (image, CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2), CGSize(width: h, height: w))
        default: return nil
        }
    }

    static func merge(_ urls: [URL], output: URL) throws {
        let merged = PDFDocument()
        for url in urls {
            let document = try open(url)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the merged PDF.") }
    }

    // MARK: Tools

    static func runTool(_ tool: ToolID, input: URL, parameter: String?, context: EngineContext) async throws -> ToolArtifact {
        if tool == .pdfDecrypt {
            return try decrypt(input, password: parameter ?? "", context: context)
        }
        let document = try open(input)
        let output = context.scratchURL("pdf")

        switch tool {
        case .pdfCompress:
            let smallest = try await compress(document, original: input, context: context)
            return ToolArtifact(url: smallest, message: SizeReport.savings(original: input, result: smallest))

        case .pdfSplit:
            guard document.pageCount > 1 else { throw KumquatError.nothingToDo("The PDF has only one page.") }
            let base = FormatRegistry.baseName(of: input)
            let folder = context.workDirectory.appendingPathComponent("\(base) (pages)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                guard single.write(to: folder.appendingPathComponent("\(base) – page \(index + 1).pdf")) else {
                    throw KumquatError.conversionFailed("Couldn't save page \(index + 1).")
                }
            }
            return ToolArtifact(url: folder, message: "\(document.pageCount) pages", preferredBaseName: folder.lastPathComponent)

        case .pdfRemovePages, .pdfExtractPages:
            let selected = Set(try PageRanges.parse(parameter ?? "", pageCount: document.pageCount))
            let keep = (0..<document.pageCount).filter { tool == .pdfExtractPages ? selected.contains($0) : !selected.contains($0) }
            guard !keep.isEmpty else { throw KumquatError.nothingToDo("That would remove every page.") }
            let result = PDFDocument()
            for index in keep {
                if let page = document.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
            guard result.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            return ToolArtifact(url: output, message: "\(keep.count) of \(document.pageCount) pages kept")

        case .pdfRotate:
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { page.rotation = (page.rotation + 90) % 360 }
            }
            guard document.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            return ToolArtifact(url: output)

        case .pdfExtractText:
            let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw KumquatError.nothingToDo("No text layer found — try OCR Text for scanned PDFs.")
            }
            let textURL = context.scratchURL("txt")
            try text.write(to: textURL, atomically: true, encoding: .utf8)
            return ToolArtifact(url: textURL)

        case .pdfOCR:
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                pages.append(try TextRecognizer.recognize(render(page, dpi: 300)))
                context.progress?(Double(index + 1) / Double(document.pageCount))
            }
            let text = pages.joined(separator: "\n\n\u{0C}\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KumquatError.nothingToDo("No text recognised.")
            }
            let textURL = context.scratchURL("txt")
            try text.write(to: textURL, atomically: true, encoding: .utf8)
            return ToolArtifact(url: textURL, message: "Recognised \(document.pageCount) page(s)")

        case .pdfSearchable:
            let count = try makeSearchable(document, output: output, context: context)
            return ToolArtifact(url: output, message: "Recognised \(count) of \(document.pageCount) page(s)")

        case .pdfArrange:
            let entries = try PageArrangement.parse(parameter ?? "", pageCount: document.pageCount)
            try arrange(document, entries: entries, output: output)
            return ToolArtifact(url: output, message: "\(entries.count) page(s)")

        case .pdfEncrypt:
            guard let password = parameter, !password.isEmpty else { throw KumquatError.nothingToDo("No password entered.") }
            let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
            guard document.write(to: output, withOptions: options) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            return ToolArtifact(url: output, message: "Password added")

        case .stripMetadata:
            document.documentAttributes = [:]
            guard document.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            return ToolArtifact(url: output, message: "Metadata removed")

        case .pdfRedactPersonalInfo, .pdfRedactText:
            let patterns: [NSRegularExpression]
            if tool == .pdfRedactText {
                guard let phrase = parameter?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty else {
                    throw KumquatError.nothingToDo("No text entered.")
                }
                patterns = [try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: phrase), options: [.caseInsensitive])]
            } else {
                patterns = Redaction.personalInfoPatterns
            }
            let (redacted, count) = try Redaction.redact(document, patterns: patterns,
                                                         accept: tool == .pdfRedactText ? { _ in true } : Redaction.isPersonalInfo)
            guard count > 0 else { throw KumquatError.nothingToDo("Nothing matched — no changes made.") }
            guard redacted.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            return ToolArtifact(url: output, message: "Redacted \(count) match\(count == 1 ? "" : "es")")

        default:
            throw KumquatError.nothingToDo("\(tool.title) doesn't apply to PDFs.")
        }
    }

    // MARK: Compression

    /// Shrinks a PDF by downsampling and re-encoding its images; text, fonts and vector art are kept.
    /// Core Graphics sometimes writes a *larger* file at a given resolution (it re-encodes images that
    /// were already compact), so the level's steps are tried in turn until one saves at least a fifth,
    /// and the smallest result wins. Ghostscript, when installed, adds a candidate that also rewrites
    /// fonts and content streams, which is what shrinks PDFs that are mostly text.
    /// Throws `nothingToDo` when nothing beats the original.
    static func compress(_ document: PDFDocument, original: URL, context: EngineContext) async throws -> URL {
        let originalSize = SizeReport.size(of: original)
        var best: (url: URL, size: Int64)?
        func consider(_ url: URL, written: Bool) {
            let size = SizeReport.size(of: url)
            // A candidate that lost pages or can't be reopened is worse than no compression.
            guard written, size > 0, size < best?.size ?? originalSize,
                  PDFDocument(url: url)?.pageCount == document.pageCount else { return }
            best = (url, size)
        }

        if #available(macOS 13.4, *) {
            // Full resolution, images re-encoded as JPEG: wins for PDFs made from lossless images.
            let url = context.scratchURL("pdf")
            consider(url, written: document.write(to: url, withOptions: [.saveImagesAsJPEGOption: true,
                                                                         .optimizeImagesForScreenOption: true]))
        }
        if let gs = context.tools.ghostscript {
            let url = context.scratchURL("pdf")
            let written: Bool
            do {
                try await ProcessRunner.runChecked(gs, [
                    "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5",
                    "-dPDFSETTINGS=\(context.options.pdfCompression.ghostscriptPreset)",
                    "-dDetectDuplicateImages=true", "-dCompressFonts=true",
                    "-dNOPAUSE", "-dBATCH", "-dQUIET", "-dSAFER",
                    "-sOutputFile=\(url.path)", original.path,
                ], timeout: 300)
                written = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A PDF Ghostscript can't handle still gets the built-in compression.
                written = false
            }
            consider(url, written: written)
        }
        let steps = context.options.pdfCompression.steps
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            if let filter = try downsamplingFilter(dpi: step.dpi, quality: step.quality, context: context) {
                let url = context.scratchURL("pdf")
                consider(url, written: document.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]))
            }
            context.progress?(Double(index + 1) / Double(steps.count))
            if let best, best.size * 5 <= originalSize * 4 { break }
        }
        guard let best else {
            throw KumquatError.nothingToDo("This PDF is already as small as Kumquat can make it.")
        }
        return best.url
    }

    /// The same mechanism as Preview's "Reduce File Size", with our own resolution and quality.
    static func downsamplingFilter(dpi: Int, quality: Double, context: EngineContext) throws -> QuartzFilter? {
        let settings: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Kumquat Compress",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true,
                                       "ImageSizeMax": 3000, "ImageSizeMin": 0],
            ]]],
        ]
        let url = context.scratchURL("qfilter")
        try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0).write(to: url)
        return QuartzFilter(url: url)
    }

    static func decrypt(_ input: URL, password: String, context: EngineContext) throws -> ToolArtifact {
        guard let document = PDFDocument(url: input) else { throw KumquatError.invalidInput("Unreadable PDF.") }
        guard document.isEncrypted else { throw KumquatError.nothingToDo("This PDF isn't password-protected.") }
        guard document.unlock(withPassword: password) else { throw KumquatError.invalidInput("Wrong password.") }
        // Copying pages into a fresh document guarantees the result is written without encryption.
        let unlocked = PDFDocument()
        for index in 0..<document.pageCount {
            if let page = document.page(at: index)?.copy() as? PDFPage { unlocked.insert(page, at: unlocked.pageCount) }
        }
        let output = context.scratchURL("pdf")
        guard unlocked.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
        return ToolArtifact(url: output, message: "Password removed")
    }
}

/// True redaction: matched pages are flattened to images with the matches painted over, so the
/// hidden text is gone from the file rather than just covered.
enum Redaction {
    static let personalInfoPatterns: [NSRegularExpression] = [
        "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",                          // email
        // Phones need a country code, a national leading 0 or North American grouping, so plain
        // number runs (invoices, dates, references) aren't blacked out.
        "(?<![\\w+])\\+\\d[\\d .()-]{6,16}\\d(?!\\d)",                         // +1 415 555 0134, +212 6 12 34 56 78
        "(?<!\\d)0\\d(?:[ .-]?\\d{2}){4}(?!\\d)",                         // 06 12 34 56 78, 0612345678
        "(?<!\\d)\\(?\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}(?!\\d)",                     // (415) 555-0134
        "\\b(?:\\d[ -]?){13,19}\\b",                                         // card numbers (Luhn-checked)
        "\\b\\d{3}-\\d{2}-\\d{4}\\b",                                        // US SSN
        "\\b[A-Z]{2}\\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\\b",    // IBAN
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Digit-only matches of card length must pass the Luhn check, so order and invoice numbers stay.
    static func isPersonalInfo(_ match: String) -> Bool {
        guard match.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return true }
        let digits = match.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return true }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            let doubled = item.offset % 2 == 1 ? item.element * 2 : item.element
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    /// Throws rather than saving when a match can't be located on its page: a file that still shows
    /// text the user asked to hide must never look redacted.
    static func redact(_ document: PDFDocument, patterns: [NSRegularExpression], accept: (String) -> Bool = { _ in true },
                       dpi: Double = 200) throws -> (PDFDocument, Int) {
        let result = PDFDocument()
        var total = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            let nsText = NSString(string: text)
            let found = patterns.flatMap { $0.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range) }
            // Overlapping matches (digits inside an IBAN that also look like a card) count once.
            var ranges: [NSRange] = []
            for range in found.filter({ accept(nsText.substring(with: $0)) }).sorted(by: { $0.location < $1.location }) {
                if let last = ranges.last, range.location < NSMaxRange(last) {
                    ranges[ranges.count - 1] = NSUnionRange(last, range)
                } else {
                    ranges.append(range)
                }
            }
            var rects: [CGRect] = []
            for range in ranges {
                let lines = (page.selection(for: range)?.selectionsByLine() ?? [])
                    .map { $0.bounds(for: page) }
                    .filter { !$0.isEmpty }
                guard !lines.isEmpty else {
                    throw KumquatError.conversionFailed("Couldn't find “\(nsText.substring(with: range))” on page \(index + 1), so nothing was saved.")
                }
                rects += lines.map { $0.insetBy(dx: -1.5, dy: -1.5) }
            }
            guard !rects.isEmpty, let copy = page.copy() as? PDFPage else {
                if let copy = page.copy() as? PDFPage { result.insert(copy, at: result.pageCount) }
                continue
            }
            total += ranges.count
            let rotation = page.rotation
            copy.rotation = 0
            let flat = try PDFEngine.render(copy, dpi: dpi, overlay: rects)
            let box = page.bounds(for: .cropBox)
            guard let flattened = PDFPage(image: NSImage(cgImage: flat, size: box.size)) else {
                throw KumquatError.conversionFailed("Couldn't redact page \(index + 1).")
            }
            flattened.rotation = rotation
            result.insert(flattened, at: result.pageCount)
        }
        return (result, total)
    }
}

import Foundation
import AppKit
import PDFKit

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
        if document.pageCount == 1, let page = document.page(at: 0) {
            try await ImageEngine.write(render(page, dpi: dpi), to: output, format: format, quality: quality, context: context)
            return output
        }
        let folder = output.deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = output.deletingPathExtension().lastPathComponent
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
            let url = folder.appendingPathComponent("\(base) \(number).\(format.fileExtension)")
            try await ImageEngine.write(render(page, dpi: dpi), to: url, format: format, quality: quality, context: context)
            context.progress?(Double(index + 1) / Double(document.pageCount))
        }
        return folder
    }

    // MARK: Building

    static func makePDF(fromImages urls: [URL], output: URL, context: EngineContext) async throws {
        let document = PDFDocument()
        for url in urls {
            let image = try await ImageEngine.loadImage(url, source: FormatRegistry.format(for: url), context: context)
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            guard let page = PDFPage(image: nsImage) else {
                throw KumquatError.conversionFailed("Couldn't add \(url.lastPathComponent) to the PDF.")
            }
            document.insert(page, at: document.pageCount)
        }
        guard document.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
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
            guard #available(macOS 13.4, *) else {
                throw KumquatError.engineUnavailable("PDF compression (macOS 13.4 or later)")
            }
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard document.write(to: output, withOptions: options) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            guard SizeReport.size(of: output) < SizeReport.size(of: input) else {
                throw KumquatError.nothingToDo("This PDF is already as small as Kumquat can make it.")
            }
            return ToolArtifact(url: output, message: SizeReport.savings(original: input, result: output))

        case .pdfSplit:
            guard document.pageCount > 1 else { throw KumquatError.nothingToDo("The PDF has only one page.") }
            let base = FormatRegistry.baseName(of: input)
            let folder = context.workDirectory.appendingPathComponent("\(base) (pages)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                single.write(to: folder.appendingPathComponent("\(base) – page \(index + 1).pdf"))
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
            let (redacted, count) = try Redaction.redact(document, patterns: patterns)
            guard count > 0 else { throw KumquatError.nothingToDo("Nothing matched — no changes made.") }
            guard redacted.write(to: output) else { throw KumquatError.conversionFailed("Couldn't save the PDF.") }
            return ToolArtifact(url: output, message: "Redacted \(count) match\(count == 1 ? "" : "es")")

        default:
            throw KumquatError.nothingToDo("\(tool.title) doesn't apply to PDFs.")
        }
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
        "(?:\\+?\\d{1,3}[\\s.-]?)?(?:\\(\\d{2,4}\\)|\\d{2,4})[\\s.-]?\\d{3,4}[\\s.-]?\\d{3,4}", // phone
        "\\b(?:\\d[ -]?){13,19}\\b",                                         // card numbers
        "\\b\\d{3}-\\d{2}-\\d{4}\\b",                                        // US SSN
        "\\b[A-Z]{2}\\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\\b",    // IBAN
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func redact(_ document: PDFDocument, patterns: [NSRegularExpression], dpi: Double = 200) throws -> (PDFDocument, Int) {
        let result = PDFDocument()
        var total = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            let length = NSString(string: text).length
            let ranges = patterns.flatMap { $0.matches(in: text, range: NSRange(location: 0, length: length)).map(\.range) }
            var rects: [CGRect] = []
            for range in ranges {
                guard let selection = page.selection(for: range) else { continue }
                for line in selection.selectionsByLine() {
                    rects.append(line.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                }
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
            guard let flattened = PDFPage(image: NSImage(cgImage: flat, size: box.size)) else { continue }
            flattened.rotation = rotation
            result.insert(flattened, at: result.pageCount)
        }
        return (result, total)
    }
}

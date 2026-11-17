import Foundation
import AppKit

/// Word/RTF/ODT/HTML/Markdown/TXT through the Cocoa text system, with PDF output via the print system.
public struct DocumentEngine: ConversionEngine {
    public let id = EngineID.document

    public init() {}

    static let readable: Set<Format> = [.docx, .doc, .rtf, .odt, .txt, .html, .md]

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let text = try await Self.read(input, format: source)
        try await Self.write(text, format: target, to: output, title: FormatRegistry.baseName(of: input))
        return output
    }

    static func documentType(for format: Format) -> NSAttributedString.DocumentType? {
        switch format {
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .rtf: return .rtf
        case .odt: return .openDocument
        case .html: return .html
        case .txt: return .plain
        default: return nil
        }
    }

    static func read(_ url: URL, format: Format) async throws -> NSAttributedString {
        switch format {
        case .md:
            let markdown = try String.readText(from: url)
            let html = MarkdownRenderer.html(fromMarkdown: markdown, title: FormatRegistry.baseName(of: url))
            return try await importHTML(Data(html.utf8), baseURL: url.deletingLastPathComponent())
        case .html:
            return try await importHTML(Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
        case .txt:
            let text = try String.readText(from: url)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        default:
            guard let type = documentType(for: format) else {
                throw KumquatError.unsupportedInput(url.lastPathComponent)
            }
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        }
    }

    /// The HTML importer uses WebKit and must run on the main thread.
    static func importHTML(_ data: Data, baseURL: URL) async throws -> NSAttributedString {
        let result = try await MainActor.run {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .baseURL: baseURL,
            ]
            return UncheckedBox(try NSAttributedString(data: data, options: options, documentAttributes: nil))
        }
        return result.value
    }

    static func write(_ text: NSAttributedString, format: Format, to url: URL, title: String) async throws {
        switch format {
        case .pdf:
            let box = UncheckedBox(text)
            try await MainActor.run { try PDFPrinter.print(box.value, to: url) }
        case .txt:
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case .md:
            try MarkdownWriter.markdown(from: text).write(to: url, atomically: true, encoding: .utf8)
        default:
            guard let type = documentType(for: format) else { throw KumquatError.noRoute(from: "document", to: format.name) }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if format == .html { attributes[.title] = title }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: url)
        }
    }
}

/// Carries an immutable, non-Sendable value across the hop to the main actor.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Paginates attributed text into a PDF using an off-screen text view and the print system,
/// which keeps tables, lists, attachments and colours that a plain Core Text renderer would lose.
@MainActor
enum PDFPrinter {
    static func print(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: url])
        info.jobDisposition = .save
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.appearance = NSAppearance(named: .aqua)
        textView.backgroundColor = .white
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(text)
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(used.height + 1, 100))
        }

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw KumquatError.conversionFailed(L("Couldn't create the PDF."))
        }
    }
}

/// Best-effort attributed text → Markdown (headings by relative size, bold/italic, links, bullets).
enum MarkdownWriter {
    static func markdown(from text: NSAttributedString) -> String {
        let string = NSString(string: text.string)
        let bodySize = dominantFontSize(text)
        var blocks: [(text: String, isListItem: Bool)] = []

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { return }
            let paragraph = text.attributedSubstring(from: range)
            let raw = paragraph.string.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return }

            let firstFont = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let ratio = (firstFont?.pointSize ?? bodySize) / max(bodySize, 1)
            let headingLevel = ratio >= 1.6 ? 1 : ratio >= 1.3 ? 2 : ratio >= 1.12 ? 3 : 0
            let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let isList = !(style?.textLists.isEmpty ?? true)

            var line = ""
            paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attributes, subrange, _ in
                var piece = NSString(string: paragraph.string).substring(with: subrange)
                if let link = attributes[.link] {
                    let target = (link as? URL)?.absoluteString ?? "\(link)"
                    piece = "[\(piece.trimmingCharacters(in: .whitespaces))](\(target))"
                } else if headingLevel == 0, let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { piece = wrap(piece, "**") }
                    if traits.contains(.italic) { piece = wrap(piece, "*") }
                }
                line += piece
            }
            line = line.trimmingCharacters(in: .whitespaces)

            if isList {
                // Cocoa stores the rendered marker ("\t•\t", "\t1.\t") in the text itself.
                let cleaned = line.replacingOccurrences(of: "^\\s*([•◦▪‣⁃–-]|\\d+[.)])\\s*", with: "", options: .regularExpression)
                blocks.append(("- " + cleaned, true))
            } else if headingLevel > 0 {
                blocks.append((String(repeating: "#", count: headingLevel) + " " + raw, false))
            } else {
                blocks.append((line, false))
            }
        }

        var output = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                output += (block.isListItem && blocks[index - 1].isListItem) ? "\n" : "\n\n"
            }
            output += block.text
        }
        return output + "\n"
    }

    /// Wraps non-space content in a marker, keeping surrounding spaces outside (`**bold** `, not `**bold **`).
    static func wrap(_ text: String, _ marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let leading = String(text.prefix(while: { $0 == " " }))
        let trailing = String(String(text.reversed()).prefix(while: { $0 == " " }))
        return leading + marker + trimmed + marker + trailing
    }

    static func dominantFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { counts[font.pointSize, default: 0] += range.length }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 12
    }
}

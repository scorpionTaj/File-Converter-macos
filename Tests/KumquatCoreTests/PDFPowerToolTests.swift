import XCTest
import AppKit
import PDFKit
@testable import KumquatCore

/// 0.7 PDF tools: searchable OCR, page arrangement, annotations, and rendering annotations to images.
final class PDFPowerToolTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
    }

    /// Image-only PDF, one page per text.
    func scannedPDF(_ texts: [String]) async throws -> URL {
        let images = try texts.enumerated().map { try save(try textImage($0.element), "scan\($0.offset).png") }
        if images.count == 1 { return try await converter.convert(images[0], to: .pdf) }
        return try await converter.run(.imagesToPDF, inputs: images).outputs[0]
    }

    func testPageArrangementParsing() throws {
        typealias E = PageArrangement.Entry
        XCTAssertEqual(try PageArrangement.parse("3, 1-2, 4r90", pageCount: 4),
                       [E(page: 2), E(page: 0), E(page: 1), E(page: 3, rotation: 90)])
        XCTAssertEqual(try PageArrangement.parse("3-1", pageCount: 3), [E(page: 2), E(page: 1), E(page: 0)])
        XCTAssertEqual(try PageArrangement.parse("2R180; 2r-90", pageCount: 2),
                       [E(page: 1, rotation: 180), E(page: 1, rotation: 270)])
        XCTAssertThrowsError(try PageArrangement.parse("5", pageCount: 4))
        XCTAssertThrowsError(try PageArrangement.parse("1r45", pageCount: 4))
        XCTAssertThrowsError(try PageArrangement.parse("x", pageCount: 4))
        XCTAssertThrowsError(try PageArrangement.parse(" , ", pageCount: 4))

        let entries = [E(page: 0), E(page: 1), E(page: 2), E(page: 4, rotation: 90), E(page: 5, rotation: 90), E(page: 3)]
        XCTAssertEqual(PageArrangement.format(entries), "1-3, 5-6r90, 4")
        XCTAssertEqual(try PageArrangement.parse(PageArrangement.format(entries), pageCount: 6), entries)
    }

    func testArrangePagesReordersRotatesAndDrops() async throws {
        let pdf = try await scannedPDF(["ONE", "TWO", "THREE"])
        let outcome = try await converter.run(.pdfArrange, inputs: [pdf], parameter: "3, 1r90")
        let result = try XCTUnwrap(PDFDocument(url: outcome.outputs[0]))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.page(at: 0)?.rotation, 0)
        XCTAssertEqual(result.page(at: 1)?.rotation, 90)
        XCTAssertTrue(outcome.outputs[0].lastPathComponent.hasSuffix("(arranged).pdf"))
        // Which source page landed where: OCR the first one.
        let first = try PDFEngine.render(try XCTUnwrap(result.page(at: 0)), dpi: 72)
        XCTAssertTrue(try TextRecognizer.recognize(first).uppercased().contains("THREE"))
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 3, "the original is untouched")
    }

    func testMakeSearchableAddsInvisibleTextLayer() async throws {
        let pdf = try await scannedPDF(["INVOICE 42", "TOTAL DUE"])
        XCTAssertEqual(PDFDocument(url: pdf)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        let outcome = try await converter.run(.pdfSearchable, inputs: [pdf])
        XCTAssertEqual(outcome.message, "Recognised 2 of 2 page(s)")
        let searchable = try XCTUnwrap(PDFDocument(url: outcome.outputs[0]))
        XCTAssertEqual(searchable.pageCount, 2)
        let text = (searchable.string ?? "").uppercased()
        XCTAssertTrue(text.contains("INVOICE"), text)
        XCTAssertTrue(text.contains("TOTAL"), text)
        // The words are found where they appear on the scan (left part of the page).
        let page = try XCTUnwrap(searchable.page(at: 0))
        let hit = try XCTUnwrap(searchable.findString("INVOICE", withOptions: .caseInsensitive).first)
        let bounds = hit.bounds(for: page)
        XCTAssertLessThan(bounds.minX, page.bounds(for: .cropBox).width / 2)
        XCTAssertGreaterThan(bounds.width, 100)
        // The text is invisible: the page looks the same as before.
        let before = try PDFEngine.render(try XCTUnwrap(PDFDocument(url: pdf)?.page(at: 0)), dpi: 36)
        let after = try PDFEngine.render(page, dpi: 36)
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)

        // A PDF that already has text has nothing to do.
        do {
            _ = try await converter.run(.pdfSearchable, inputs: [outcome.outputs[0]])
            XCTFail("already searchable")
        } catch KumquatError.nothingToDo(let message) {
            XCTAssertTrue(message.contains("already"), message)
        }
    }

    func testMakeSearchableOnRotatedPageKeepsTextHorizontal() async throws {
        // A sideways scan stored with /Rotate 90 so it displays upright.
        let sideways = try ImageEngine.rotated(try textImage("SIDEWAYS SCAN"), clockwise: false)
        let pdf = try await converter.convert(try save(sideways, "sideways.png"), to: .pdf)
        let upright = try await converter.run(.pdfArrange, inputs: [pdf], parameter: "1r90").outputs[0]
        let outcome = try await converter.run(.pdfSearchable, inputs: [upright])
        let result = try XCTUnwrap(PDFDocument(url: outcome.outputs[0]))
        XCTAssertTrue((result.string ?? "").uppercased().contains("SIDEWAYS"), result.string ?? "")
        XCTAssertEqual(result.page(at: 0)?.rotation, 0)
        let box = try XCTUnwrap(result.page(at: 0)?.bounds(for: .cropBox))
        XCTAssertGreaterThan(box.width, box.height, "the upright page is landscape")
    }

    func testAnnotationsAreSavedAndRendered() async throws {
        let markdown = try file("note.md", "# Hello\n\nKumquat annotation test\n")
        let pdf = try await converter.convert(markdown, to: .pdf)
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("annotation", withOptions: []).first)
        let lines = selection.selectionsByLine().map { $0.bounds(for: page) }
        let markups = [
            PDFMarkup(page: 0, kind: .highlight, rects: lines),
            PDFMarkup(page: 0, kind: .strikeOut, rects: lines, color: [1, 0, 0, 1]),
            PDFMarkup(page: 0, kind: .text, rects: [CGRect(x: 300, y: 400, width: 120, height: 24)], text: "Approved"),
            PDFMarkup(page: 0, kind: .note, rects: [CGRect(x: 40, y: 40, width: 20, height: 20)], text: "See page 2"),
            PDFMarkup(page: 0, kind: .rectangle, rects: [CGRect(x: 40, y: 500, width: 200, height: 80)], color: [0, 0, 1, 1]),
            PDFMarkup(page: 0, kind: .ink, strokes: [[CGPoint(x: 100, y: 200), CGPoint(x: 160, y: 260), CGPoint(x: 220, y: 200)]]),
        ]
        let output = directory.appendingPathComponent("annotated.pdf")
        try PDFEngine.annotate(pdf, markups: markups, output: output)

        let saved = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        let types = saved.annotations.compactMap(\.type)
        XCTAssertEqual(Set(types), ["Highlight", "StrikeOut", "FreeText", "Text", "Square", "Ink"])
        XCTAssertEqual(saved.annotations.first { $0.type == "FreeText" }?.contents, "Approved")
        XCTAssertEqual(saved.annotations.first { $0.type == "Highlight" }?.quadrilateralPoints?.count, 4 * lines.count)
        XCTAssertEqual(PDFDocument(url: pdf)?.page(at: 0)?.annotations.count, 0, "the original is untouched")

        // Rendering to an image includes the marks (Core Graphics alone skips annotations).
        let plain = try PDFEngine.render(page, dpi: 72)
        let marked = try PDFEngine.render(saved, dpi: 72)
        // The box's left edge: x 40, halfway up the box (page y 540), in top-left image coordinates.
        let y = Int(page.bounds(for: .cropBox).height) - 540
        XCTAssertNotEqual(pixel(plain, x: 41, y: y), pixel(marked, x: 41, y: y), "the blue box is drawn")

        XCTAssertThrowsError(try PDFEngine.annotate(pdf, markups: [PDFMarkup(page: 3, kind: .note, rects: [.zero])],
                                                    output: directory.appendingPathComponent("bad.pdf")))
    }

    func testCatalogOffersPDFPowerTools() {
        let catalog = converter.catalog()
        let pdf = URL(fileURLWithPath: "/tmp/a.pdf"), other = URL(fileURLWithPath: "/tmp/b.pdf")
        let single = Set(catalog.tools(for: [pdf]).compactMap { item -> ToolID? in
            if case .tool(let tool) = item.payload { return tool } else { return nil }
        })
        XCTAssertTrue(single.isSuperset(of: [.pdfSearchable, .pdfArrange, .pdfAnnotate]))
        let double = Set(catalog.tools(for: [pdf, other]).compactMap { item -> ToolID? in
            if case .tool(let tool) = item.payload { return tool } else { return nil }
        })
        XCTAssertFalse(double.contains(.pdfAnnotate), "the editor opens one PDF")
        XCTAssertTrue(ToolID.pdfAnnotate.isInteractive)
        XCTAssertEqual(ToolID.pdfArrange.input, .pages(prompt: ToolID.pdfArrange.input?.prompt ?? ""))
    }

    /// RGBA of one pixel, origin at the top left.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }
}

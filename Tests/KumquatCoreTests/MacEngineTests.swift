import XCTest
import AppKit
import ImageIO
import PDFKit
@testable import KumquatCore

/// Image, PDF and document engines (macOS only).
final class MacEngineTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    override func setUpWithError() throws {
        try super.setUpWithError()
        // PDF printing and the HTML importer expect an application object.
        _ = NSApplication.shared
    }

    /// 300×200 PNG: left half orange, right half transparent.
    func makePNG(_ name: String = "sample.png", width: Int = 300, height: Int = 200) throws -> URL {
        let image = try ImageEngine.render(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        let url = directory.appendingPathComponent(name)
        try ImageEngine.encode(image, to: url, format: .png, quality: 1)
        return url
    }

    func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    func testImageConversions() async throws {
        let png = try makePNG()
        for target in [Format.jpg, .heic, .tiff, .bmp, .gif, .jp2] {
            let output = try await converter.convert(png, to: target)
            XCTAssertEqual(FormatRegistry.format(for: output), target)
            XCTAssertEqual(pixelSize(output)?.0, 300, target.id)
        }
        let icns = try await converter.convert(png, to: .icns)
        XCTAssertGreaterThan(SizeReport.size(of: icns), 0)
        let pdf = try await converter.convert(png, to: .pdf)
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 1)
    }

    func testImageTools() async throws {
        let png = try makePNG()
        let half = try await converter.run(.imageResizeHalf, inputs: [png])
        XCTAssertEqual(pixelSize(half.outputs[0])?.0, 150)
        XCTAssertTrue(half.outputs[0].lastPathComponent.hasSuffix("(50%).png"))

        let rotated = try await converter.run(.imageRotateRight, inputs: [png])
        XCTAssertEqual(pixelSize(rotated.outputs[0]).map { [$0.0, $0.1] }, [200, 300])

        for tool in [ToolID.imageFlip, .imageGrayscale, .stripMetadata] {
            let outcome = try await converter.run(tool, inputs: [png])
            XCTAssertEqual(outcome.outputs.count, 1, tool.rawValue)
        }

        let jpg = try await converter.convert(png, to: .jpg)
        let compressed = try await converter.run(.imageCompress, inputs: [jpg])
        XCTAssertEqual(compressed.outputs.first?.pathExtension, "jpg")

        let second = try makePNG("second.png")
        let combined = try await converter.run(.imagesToPDF, inputs: [png, second])
        XCTAssertEqual(PDFDocument(url: combined.outputs[0])?.pageCount, 2)
    }

    func testDocumentRoundTrips() async throws {
        let markdown = try file("notes.md", "# Shopping\n\nBuy **milk** and *eggs*.\n\n- apples\n- pears\n")
        let docx = try await converter.convert(markdown, to: .docx)
        let text = try await converter.convert(docx, to: .txt)
        let plain = try String(contentsOf: text, encoding: .utf8)
        XCTAssertTrue(plain.contains("Shopping"))
        XCTAssertTrue(plain.contains("milk"))

        let rtf = try await converter.convert(markdown, to: .rtf)
        let backToMarkdown = try await converter.convert(rtf, to: .md)
        let md = try String(contentsOf: backToMarkdown, encoding: .utf8)
        XCTAssertTrue(md.contains("# Shopping"), md)
        XCTAssertTrue(md.contains("**milk**"), md)
        XCTAssertTrue(md.contains("- apples"), md)
    }

    func testDocumentToPDFAndBack() async throws {
        let txt = try file("letter.txt", "Dear team,\ncontact me at jane.doe@example.com or +1 415 555 0134.\nThanks")
        let pdf = try await converter.convert(txt, to: .pdf)
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertTrue(document.string?.contains("jane.doe@example.com") ?? false)

        let extracted = try await converter.convert(pdf, to: .txt)
        XCTAssertTrue(try String(contentsOf: extracted, encoding: .utf8).contains("Dear team"))

        let redacted = try await converter.run(.pdfRedactPersonalInfo, inputs: [pdf])
        let redactedText = PDFDocument(url: redacted.outputs[0])?.string ?? ""
        XCTAssertFalse(redactedText.contains("jane.doe@example.com"))
        XCTAssertEqual(redacted.message, "Redacted 2 matches")
    }

    func testPDFTools() async throws {
        let first = try await converter.convert(try file("a.txt", "First"), to: .pdf)
        let second = try await converter.convert(try file("b.txt", "Second"), to: .pdf)

        let merged = try await converter.run(.pdfMerge, inputs: [first, second])
        let mergedURL = merged.outputs[0]
        XCTAssertEqual(PDFDocument(url: mergedURL)?.pageCount, 2)

        let split = try await converter.run(.pdfSplit, inputs: [mergedURL])
        let pages = try FileManager.default.contentsOfDirectory(atPath: split.outputs[0].path)
        XCTAssertEqual(pages.count, 2)

        let images = try await converter.convert(mergedURL, to: .png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: images.path).count, 2)

        let locked = try await converter.run(.pdfEncrypt, inputs: [first], parameter: "pw")
        XCTAssertTrue(PDFDocument(url: locked.outputs[0])?.isLocked ?? false)
        let unlocked = try await converter.run(.pdfDecrypt, inputs: [locked.outputs[0]], parameter: "pw")
        XCTAssertFalse(PDFDocument(url: unlocked.outputs[0])?.isEncrypted ?? true)

        let rotated = try await converter.run(.pdfRotate, inputs: [first])
        XCTAssertEqual(PDFDocument(url: rotated.outputs[0])?.page(at: 0)?.rotation, 90)
    }

    func testCustomResizeAndAnimatedGIF() async throws {
        let png = try makePNG()
        let resized = try await converter.run(.imageResizeCustom, inputs: [png], parameter: "120x120")
        XCTAssertEqual(pixelSize(resized.outputs[0]).map { [$0.0, $0.1] }, [120, 80])

        let second = try makePNG("frame2.png", width: 150, height: 100)
        let gif = try await converter.run(.imagesToGIF, inputs: [png, second])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif.outputs[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertEqual(pixelSize(gif.outputs[0])?.0, 300)
    }

    func testPageSelection() async throws {
        var pages: [URL] = []
        for name in ["one", "two", "three"] {
            pages.append(try await converter.convert(try file("\(name).txt", name.uppercased()), to: .pdf))
        }
        let merged = try await converter.run(.pdfMerge, inputs: pages).outputs[0]

        let removed = try await converter.run(.pdfRemovePages, inputs: [merged], parameter: "2")
        let remaining = try XCTUnwrap(PDFDocument(url: removed.outputs[0]))
        XCTAssertEqual(remaining.pageCount, 2)
        XCTAssertTrue(remaining.page(at: 1)?.string?.contains("THREE") ?? false)

        let kept = try await converter.run(.pdfExtractPages, inputs: [merged], parameter: "2-3")
        let extracted = try XCTUnwrap(PDFDocument(url: kept.outputs[0]))
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertTrue(extracted.page(at: 0)?.string?.contains("TWO") ?? false)

        do {
            _ = try await converter.run(.pdfRemovePages, inputs: [merged], parameter: "1-3")
            XCTFail("removing every page should fail")
        } catch {}
    }

    /// Reads one pixel (x, y measured from the bottom-left).
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testAnnotationRendering() throws {
        // White 200×100 canvas with a black left half, so pixelation has something to mix.
        let base = try ImageEngine.render(width: 200, height: 100) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let annotations = [
            Annotation(.rectangle(CGRect(x: 120, y: 20, width: 60, height: 60)), color: .red, lineWidth: 6),
            Annotation(.pixelate(CGRect(x: 80, y: 0, width: 40, height: 100))),
            Annotation(.text("Hi", origin: CGPoint(x: 10, y: 10), fontSize: 30), color: .yellow),
        ]
        let rendered = try AnnotationRenderer.render(base, annotations: annotations)
        XCTAssertEqual(rendered.width, 200)
        let edge = pixel(rendered, 120, 50)
        XCTAssertGreaterThan(edge.r, 200)
        XCTAssertLessThan(edge.g, 120)
        XCTAssertEqual(pixel(rendered, 150, 50).g, 255, "inside the rectangle stays white")

        let cropped = try AnnotationRenderer.render(base, annotations: [], crop: CGRect(x: 100, y: 0, width: 50, height: 40))
        XCTAssertEqual(cropped.width, 50)
        XCTAssertEqual(cropped.height, 40)
        XCTAssertEqual(pixel(cropped, 10, 10).r, 255, "crop keeps the white right half")
    }

    func testEditableFormatAndSave() async throws {
        let png = try makePNG()
        XCTAssertEqual(ImageEngine.editableFormat(for: png), .png)
        XCTAssertEqual(ImageEngine.editableFormat(for: directory.appendingPathComponent("x.psd")), .png)
        let image = try await ImageEngine.loadImage(at: png)
        let output = directory.appendingPathComponent("saved.jpg")
        try await ImageEngine.save(image, to: output, format: .jpg)
        XCTAssertEqual(pixelSize(output)?.0, 300)
    }

    func testCatalogOnMac() {
        let catalog = converter.catalog()
        let png = directory.appendingPathComponent("x.png")
        XCTAssertTrue(catalog.conversions(for: [png]).contains { $0.payload == .convert(.jpg) && $0.isAvailable })
        XCTAssertFalse(catalog.tools(for: [png]).isEmpty)
    }
}

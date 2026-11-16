import XCTest
import AppKit
import CoreText
import ImageIO
import PDFKit
@testable import KumquatCore

extension TemporaryDirectoryTestCase {
    /// Black text on white, big enough for OCR.
    func textImage(_ text: String, width: Int = 900, height: Int = 220) throws -> CGImage {
        try ImageEngine.render(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: 40, y: 80)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
        }
    }

    func save(_ image: CGImage, _ name: String, format: Format = .png) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ImageEngine.encode(image, to: url, format: format, quality: 0.9)
        return url
    }
}

/// Behaviour checks against real frameworks and helpers (skipped when a helper isn't installed).
final class RealWorldTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
    }

    func testImageOCR() async throws {
        let url = try save(try textImage("KUMQUAT 2026"), "sign.png")
        let outcome = try await converter.run(.imageExtractText, inputs: [url])
        let text = try XCTUnwrap(outcome.clipboardText)
        XCTAssertTrue(text.uppercased().contains("KUMQUAT"), text)
        XCTAssertEqual(outcome.outputs.first?.pathExtension, "txt")
    }

    func testScannedPDFOCR() async throws {
        let image = try save(try textImage("INVOICE 42"), "scan.png")
        let second = try save(try textImage("TOTAL DUE"), "scan2.png")
        let pdf = try await converter.run(.imagesToPDF, inputs: [image, second]).outputs[0]
        // Image-only PDF: no text layer, so Extract Text must refuse and OCR must succeed.
        do {
            _ = try await converter.run(.pdfExtractText, inputs: [pdf])
            XCTFail("an image-only PDF has no text layer")
        } catch {}
        let ocr = try await converter.run(.pdfOCR, inputs: [pdf])
        let text = try String(contentsOf: ocr.outputs[0], encoding: .utf8).uppercased()
        XCTAssertTrue(text.contains("INVOICE"), text)
        XCTAssertTrue(text.contains("TOTAL"), text)
    }

    func testStripMetadataRemovesLocation() async throws {
        let url = directory.appendingPathComponent("trip.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.63, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 8.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
        ]
        CGImageDestinationAddImage(destination, try textImage("GPS"), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertNotNil(gps(url), "fixture should carry GPS")

        let clean = try await converter.run(.stripMetadata, inputs: [url]).outputs[0]
        XCTAssertNil(gps(clean))
        XCTAssertEqual(clean.pathExtension, "jpg")
    }

    func gps(_ url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    func testOrientationIsApplied() async throws {
        // A 200×100 image tagged "rotated 90° CW" must come out 100×200.
        let url = directory.appendingPathComponent("rotated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let image = try ImageEngine.render(width: 200, height: 100) { $0.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let png = try await converter.convert(url, to: .png)
        let loaded = try await ImageEngine.loadImage(at: png)
        XCTAssertEqual(loaded.width, 100)
        XCTAssertEqual(loaded.height, 200)
    }

    func testSVGThroughQuickLook() async throws {
        let svg = try file("logo.svg", #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="orange"/></svg>"#)
        do {
            let png = try await converter.convert(svg, to: .png)
            let image = try await ImageEngine.loadImage(at: png)
            XCTAssertGreaterThan(image.width, 0)
        } catch let error as KumquatError {
            // Quick Look needs a window server; headless runners may not have one.
            throw XCTSkip("Quick Look unavailable here: \(error.localizedDescription)")
        }
    }

    func testIconFormats() async throws {
        let png = try save(try textImage("K", width: 512, height: 512), "app.png")
        let ico = try await converter.convert(png, to: .ico)
        let icoSource = try XCTUnwrap(CGImageSourceCreateWithURL(ico as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(icoSource), 4)
        let icns = try await converter.convert(png, to: .icns)
        XCTAssertGreaterThan(SizeReport.size(of: icns), 1000)
    }

    func testWebPAndAVIF() async throws {
        let png = try save(try textImage("WEB"), "web.png")
        for target in [Format.webp, .avif] {
            do {
                let output = try await converter.convert(png, to: target)
                XCTAssertGreaterThan(SizeReport.size(of: output), 0)
                XCTAssertEqual(output.pathExtension, target.fileExtension)
            } catch KumquatError.missingDependencies(let missing) {
                // Only acceptable when neither ImageIO nor FFmpeg can encode it.
                XCTAssertEqual(missing, [.ffmpeg])
                XCTAssertFalse(ImageEngine.canWrite(target))
            }
        }
    }

    func testPDFCompressNeverGrowsTheFile() async throws {
        let big = try save(try textImage("PHOTO", width: 2400, height: 1600), "big.png")
        let pdf = try await converter.convert(big, to: .pdf)
        do {
            let outcome = try await converter.run(.pdfCompress, inputs: [pdf])
            XCTAssertLessThan(SizeReport.size(of: outcome.outputs[0]), SizeReport.size(of: pdf))
            XCTAssertTrue(outcome.message?.hasPrefix("Saved") ?? false)
        } catch KumquatError.nothingToDo {
            // Acceptable: nothing to gain, and no larger copy was left behind.
            let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(siblings.contains { $0.contains("(compressed)") })
        }
    }

    /// An A4 page holding a ~290 dpi JPEG of dense detail, like a scanner makes: only downsampling and
    /// re-encoding the image can shrink it.
    func makeScannedPDF() throws -> URL {
        let width = 2400, height = 3400
        var seed: UInt32 = 12345
        let noise = try ImageEngine.render(width: width, height: height) { ctx in
            for y in stride(from: 0, to: height, by: 4) {
                for x in stride(from: 0, to: width, by: 4) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let gray = CGFloat(seed >> 24) / 255
                    ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        let jpg = try save(noise, "scan.jpg", format: .jpg)
        let pdf = directory.appendingPathComponent("scan.pdf")
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &page, nil))
        let provider = try XCTUnwrap(CGDataProvider(url: jpg as CFURL))
        let image = try XCTUnwrap(CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        context.beginPDFPage(nil)
        context.draw(image, in: page)
        context.endPDFPage()
        context.closePDF()
        return pdf
    }

    func testPDFCompressShrinksScans() async throws {
        let pdf = try makeScannedPDF()
        let before = SizeReport.size(of: pdf)
        var sizes: [Int64] = []
        for level in PDFCompression.allCases {
            var options = ConversionOptions()
            options.pdfCompression = level
            options.outputLocation = .folder(directory.appendingPathComponent(level.rawValue).path)
            let outcome: ToolOutcome
            do {
                outcome = try await converter.run(.pdfCompress, inputs: [pdf], options: options)
            } catch {
                return XCTFail("\(level): \(error.localizedDescription) (input \(before) bytes)")
            }
            XCTAssertEqual(PDFDocument(url: outcome.outputs[0])?.pageCount, 1)
            sizes.append(SizeReport.size(of: outcome.outputs[0]))
        }
        // Balanced saves at least 30%, and stronger levels never produce a bigger file than gentler ones.
        XCTAssertLessThan(sizes[1] * 10, before * 7, "expected at least 30% saved: \(before) → \(sizes)")
        XCTAssertEqual(sizes, sizes.sorted(by: >), "light, balanced, strong: \(sizes)")
    }

    func testImageCompressNeverGrowsTheFile() async throws {
        let url = directory.appendingPathComponent("tiny.jpg")
        try ImageEngine.encode(try textImage("PHOTO"), to: url, format: .jpg, quality: 0.1)
        do {
            let outcome = try await converter.run(.imageCompress, inputs: [url])
            XCTAssertLessThan(SizeReport.size(of: outcome.outputs[0]), SizeReport.size(of: url))
        } catch KumquatError.nothingToDo {
            let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(siblings.contains { $0.contains("(compressed)") })
        }
    }

    func testGhostscriptCompressionKeepsTextAndPages() async throws {
        guard converter.tools.ghostscript != nil else { throw XCTSkip("Ghostscript not installed") }
        let letter = directory.appendingPathComponent("long.txt")
        let paragraph = "Kumquat keeps every word of this sentence when it compresses the document. "
        try String(repeating: paragraph + "\n", count: 400).write(to: letter, atomically: true, encoding: .utf8)
        let pdf = try await converter.convert(letter, to: .pdf)
        let pages = try XCTUnwrap(PDFDocument(url: pdf)).pageCount
        do {
            let outcome = try await converter.run(.pdfCompress, inputs: [pdf])
            let result = try XCTUnwrap(PDFDocument(url: outcome.outputs[0]))
            XCTAssertEqual(result.pageCount, pages)
            XCTAssertTrue(result.string?.contains("keeps every word") ?? false)
        } catch KumquatError.nothingToDo {
            // Acceptable: Quartz already wrote this PDF compactly.
        }
    }

    func testJPEGToPDFKeepsTheJPEGData() async throws {
        let jpg = try save(try textImage("PHOTO", width: 1600, height: 1200), "photo.jpg", format: .jpg)
        let pdf = try await converter.convert(jpg, to: .pdf)
        // Embedded as-is: the PDF is the JPEG plus a little structure, not a re-encoded copy.
        XCTAssertLessThan(SizeReport.size(of: pdf), SizeReport.size(of: jpg) + 20_000)
        let page = try XCTUnwrap(PDFDocument(url: pdf)?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 1600, height: 1200))
    }

    func testRedactPersonalInfoSkipsPlainNumbers() async throws {
        let letter = directory.appendingPathComponent("letter.txt")
        try "Card 4111 1111 1111 1111 and mobile 06 12 34 56 78.\nInvoice 20261116, order 1234567890123, total 1234.56"
            .write(to: letter, atomically: true, encoding: .utf8)
        let pdf = try await converter.convert(letter, to: .pdf)
        let outcome = try await converter.run(.pdfRedactPersonalInfo, inputs: [pdf])
        XCTAssertEqual(outcome.message, "Redacted 2 matches")
    }

    func testLuhnFilter() {
        XCTAssertTrue(Redaction.isPersonalInfo("4111 1111 1111 1111"))
        XCTAssertFalse(Redaction.isPersonalInfo("1234567890123"))
        XCTAssertTrue(Redaction.isPersonalInfo("+1 415 555 0134"))
    }

    func testParallelToolsKeepSameNamedInputsApart() async throws {
        var inputs: [URL] = []
        for (folder, pages) in [("a", 2), ("b", 3)] {
            let dir = directory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let images = try (0..<pages).map { try save(try textImage("P\($0)"), "\(folder)\($0).png") }
            let made = try await converter.run(.imagesToPDF, inputs: images).outputs[0]
            let doc = dir.appendingPathComponent("doc.pdf")
            try FileManager.default.moveItem(at: made, to: doc)
            inputs.append(doc)
        }
        var options = ConversionOptions()
        options.outputLocation = .folder(directory.appendingPathComponent("out").path)
        let outcome = try await converter.run(.pdfSplit, inputs: inputs, options: options, concurrency: 2)
        let counts = try outcome.outputs.map { try FileManager.default.contentsOfDirectory(atPath: $0.path).count }
        XCTAssertEqual(counts, [2, 3])
    }

    func testCustomOutputFolder() async throws {
        let out = directory.appendingPathComponent("Exports", isDirectory: true)
        var options = ConversionOptions()
        options.outputLocation = .folder(out.path)
        let csv = try file("data.csv", "a,b\n1,2\n")
        let json = try await converter.convert(csv, to: .json, options: options)
        XCTAssertEqual(json.deletingLastPathComponent().standardizedFileURL, out.standardizedFileURL)
    }

    func testHTMLToWordToMarkdown() async throws {
        let html = try file("page.html", "<h1>Release notes</h1><p>Now with <b>annotations</b> and <a href=\"https://example.com\">links</a>.</p>")
        let docx = try await converter.convert(html, to: .docx)
        let md = try await converter.convert(docx, to: .md)
        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(text.contains("Release notes"), text)
        XCTAssertTrue(text.contains("annotations"), text)
    }

    func testPandocEPUBRoundTrip() async throws {
        guard converter.tools.pandoc != nil else { throw XCTSkip("Pandoc not installed") }
        let md = try file("book.md", "# Chapter One\n\nIt was a *bright* day.\n")
        let epub = try await converter.convert(md, to: .epub)
        XCTAssertGreaterThan(SizeReport.size(of: epub), 500)
        let back = try await converter.convert(epub, to: .md)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("Chapter One"))
    }

    func testPNGQuantCompression() async throws {
        let png = try save(try textImage("SQUEEZE", width: 1200, height: 600), "big-text.png")
        guard converter.tools.pngquant != nil else {
            do {
                _ = try await converter.run(.imageCompress, inputs: [png])
                XCTFail("without pngquant PNG compression should explain what to install")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("pngquant"))
            }
            return
        }
        do {
            let outcome = try await converter.run(.imageCompress, inputs: [png])
            XCTAssertLessThan(SizeReport.size(of: outcome.outputs[0]), SizeReport.size(of: png))
        } catch KumquatError.nothingToDo {
            // pngquant decided it couldn't help; also acceptable.
        }
    }

    func testVideoToolsOnMac() async throws {
        guard let ffmpeg = converter.tools.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let mov = directory.appendingPathComponent("clip.mov")
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                                    "testsrc=duration=1:size=160x120:rate=15", "-f", "lavfi", "-i",
                                                    "sine=duration=1", "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                                    "-c:a", "aac", mov.path])
        let mp4 = try await converter.convert(mov, to: .mp4)
        XCTAssertGreaterThan(SizeReport.size(of: mp4), 0)
        let gif = try await converter.convert(mov, to: .gif)
        let frames = CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0
        XCTAssertGreaterThan(frames, 5)
        let audio = try await converter.run(.videoExtractAudio, inputs: [mov])
        XCTAssertEqual(audio.outputs.first?.pathExtension, "m4a")
    }
}

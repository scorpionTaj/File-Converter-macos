import XCTest
import AppKit
import CoreText
import ImageIO
import PDFKit
@testable import KumquatCore

/// Behaviour checks against real frameworks and helpers (skipped when a helper isn't installed).
final class RealWorldTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
    }

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

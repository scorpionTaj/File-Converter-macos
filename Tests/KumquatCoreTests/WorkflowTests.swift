import XCTest
@testable import KumquatCore

final class WorkflowTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    func makePNG(_ name: String) throws -> URL {
        let image = try ImageEngine.render(width: 60, height: 40) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        let url = directory.appendingPathComponent(name)
        try ImageEngine.encode(image, to: url, format: .png, quality: 1)
        return url
    }

    func testPinsThenRecentsThenUsualOrder() throws {
        let png = URL(fileURLWithPath: "/x/photo.png")
        let items = converter.catalog().conversions(for: [png])
        let key = WheelPreferences.sourceKey(for: [png])
        XCTAssertEqual(key, "png")
        XCTAssertEqual(WheelPreferences.sourceKey(for: [png, URL(fileURLWithPath: "/x/a.jpg")]), "image")
        XCTAssertEqual(WheelPreferences.sourceKey(for: [png, URL(fileURLWithPath: "/x/a.pdf")]), "mixed")

        var prefs = WheelPreferences()
        prefs.noteUsed("convert.webp", source: key)
        prefs.noteUsed("convert.heic", source: key)
        prefs.togglePin("convert.pdf", source: key)
        let ordered = prefs.ordered(items, source: key)
        XCTAssertEqual(ordered.prefix(3).map(\.id), ["convert.pdf", "convert.heic", "convert.webp"])
        XCTAssertTrue(ordered[0].isPinned)
        XCTAssertEqual(Set(ordered.map(\.id)), Set(items.map(\.id)))

        for _ in 0..<10 { prefs.noteUsed(UUID().uuidString, source: key) }
        XCTAssertEqual(prefs.recent[key]?.count, WheelPreferences.recentLimit)
        prefs.togglePin("convert.pdf", source: key)
        XCTAssertNil(prefs.pinned[key])
    }

    func testOverridesAndPresets() {
        let web = OptionOverrides(quality: 0.8, maxImageDimension: 2048)
        var options = ConversionOptions()
        web.apply(to: &options, target: .webp)
        XCTAssertEqual(options.quality(for: .webp), 0.8)
        XCTAssertEqual(options.quality(for: .jpg), 0.85, "only the preset's format changes")
        XCTAssertEqual(options.maxImageDimension, 2048)
        XCTAssertEqual(web.summary, "80% · 2048 px")
        XCTAssertEqual(web.merged(with: OptionOverrides(quality: 0.5)).summary, "50% · 2048 px")
        XCTAssertTrue(OptionOverrides().isEmpty)

        let presets = [OutputPreset(name: "Web", target: "webp", overrides: web), OutputPreset(name: "Song", target: "mp3")]
        let items = converter.catalog().presets(presets, for: [URL(fileURLWithPath: "/x/photo.png")])
        XCTAssertEqual(items.map(\.title), ["Web"], "a preset only shows when the files can become its format")
    }

    func testPDFPageRange() async throws {
        let png = try makePNG("page.png")
        let pdf = try await converter.run(.imagesToPDF, inputs: [png, png, png]).outputs[0]
        var options = ConversionOptions()
        options.outputLocation = .folder(directory.appendingPathComponent("pages").path)
        options.pdfPageRange = "2-3"
        let folder = try await converter.convert(pdf, to: .png, options: options)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].hasSuffix(" 2.png") && files[1].hasSuffix(" 3.png"), "\(files)")

        options.pdfPageRange = "9"
        do {
            _ = try await converter.convert(pdf, to: .png, options: options)
            XCTFail("a page outside the PDF must be refused")
        } catch {}
    }

    func testKindFoldersAndBatchSubfolder() async throws {
        let png = try makePNG("photo.png")
        let text = try file("notes.txt", "hello")
        var options = ConversionOptions()
        options.outputLocation = .folder(directory.appendingPathComponent("default").path)
        options.kindFolders = ["image": directory.appendingPathComponent("Pictures").path]
        options.batchSubfolder = "Batch"
        let image = try await converter.convert(png, to: .jpg, options: options)
        XCTAssertEqual(image.deletingLastPathComponent().lastPathComponent, "Batch")
        XCTAssertEqual(image.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Pictures")
        let html = try await converter.convert(text, to: .html, options: options)
        XCTAssertEqual(html.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "default")
    }
}

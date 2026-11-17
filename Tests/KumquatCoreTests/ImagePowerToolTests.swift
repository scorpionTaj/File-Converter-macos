import XCTest
import AppKit
import ImageIO
@testable import KumquatCore

/// 0.7 image tools: batch rename, metadata editing, upscaling.
final class ImagePowerToolTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func photo(_ name: String = "photo.jpg", taken: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.63, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 8.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Old Artist"],
        ]
        if let taken { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: taken] }
        CGImageDestinationAddImage(destination, try textImage("PHOTO", width: 400, height: 200), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Rename

    func testRenamePattern() throws {
        let url = URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")
        let date = try XCTUnwrap(MetadataEdit.parseDate("2024-05-01 14:30"))
        XCTAssertEqual(try RenamePattern.render("Trip {date} {n}", original: url, index: 2, count: 12, date: date), "Trip 2024-05-01 03")
        XCTAssertEqual(try RenamePattern.render("{name}-web", original: url, index: 0, count: 1, date: date), "IMG_0001-web")
        XCTAssertEqual(try RenamePattern.render("Scan", original: url, index: 4, count: 120, date: date), "Scan 005",
                       "several files without {n} are numbered anyway")
        XCTAssertEqual(try RenamePattern.render("a/b: c", original: url, index: 0, count: 1, date: date), "a-b- c")
        XCTAssertThrowsError(try RenamePattern.render("  ", original: url, index: 0, count: 1, date: date))
    }

    func testBatchRenameMakesNumberedCopiesInDropOrder() async throws {
        let first = try photo("b.jpg", taken: "2023:07:14 09:00:00")
        let second = try file("a.txt", "notes")
        let outcome = try await converter.run(.batchRename, inputs: [first, second], parameter: "Trip {date} {n}", concurrency: 2)
        let names = outcome.outputs.map(\.lastPathComponent)
        XCTAssertEqual(names.first, "Trip 2023-07-14 01.jpg", "the photo's date taken")
        XCTAssertTrue(names.last?.hasPrefix("Trip ") == true && names.last?.hasSuffix(" 02.txt") == true, names.description)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "originals are kept by default")
        XCTAssertEqual(try String(contentsOf: outcome.outputs[1], encoding: .utf8), "notes")

        // With "Originals: move to Trash", it is a rename.
        var options = ConversionOptions()
        options.originals = .trash
        let moved = try await converter.run(.batchRename, inputs: [second], parameter: "Renamed", options: options)
        XCTAssertEqual(moved.outputs.map(\.lastPathComponent), ["Renamed.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: Metadata

    func testMetadataEditParsing() throws {
        let edit = try MetadataEdit.parse("date=2024-05-01 14:30; title=Beach; artist=; location=31.63,-8.01")
        XCTAssertEqual(edit.date, .set("2024:05:01 14:30:00"))
        XCTAssertEqual(edit.title, .set("Beach"))
        XCTAssertEqual(edit.artist, .remove)
        XCTAssertNil(edit.copyright)
        XCTAssertEqual(edit.location, .set(latitude: 31.63, longitude: -8.01))
        XCTAssertEqual(try MetadataEdit.parse("location=").location, .remove)
        XCTAssertThrowsError(try MetadataEdit.parse("date=yesterday"))
        XCTAssertThrowsError(try MetadataEdit.parse("location=200,0"))
        XCTAssertThrowsError(try MetadataEdit.parse("colour=red"))
        XCTAssertThrowsError(try MetadataEdit.parse("title"))
        XCTAssertThrowsError(try MetadataEdit.parse(" ; "))
    }

    func testEditMetadataLosslessly() async throws {
        let url = try photo()
        let before = try Data(contentsOf: url)
        let outcome = try await converter.run(.imageEditMetadata, inputs: [url],
                                              parameter: "date=2024-05-01 14:30; title=Beach; artist=Sam; copyright=© Sam; location=-33.9,151.2")
        let edited = outcome.outputs[0]
        XCTAssertTrue(edited.lastPathComponent.hasSuffix("(edited).jpg"))
        let props = properties(edited)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:05:01 14:30:00")
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        // This photo has an IPTC block, so ImageIO keeps text fields there (files without one get TIFF tags).
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFImageDescription] as? String ?? iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String, "Beach")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFArtist] as? String ?? (iptc?[kCGImagePropertyIPTCByline] as? [String])?.first, "Sam")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFCopyright] as? String ?? iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String, "© Sam")
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual(gps?[kCGImagePropertyGPSLongitudeRef] as? String, "E")
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double ?? 0, 33.9, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: url), before, "the original is untouched")
        XCTAssertEqual(RenamePattern.date(of: edited), MetadataEdit.parseDate("2024-05-01 14:30"))

        // Removing: an empty value clears the field, location= drops GPS.
        let cleared = try await converter.run(.imageEditMetadata, inputs: [url], parameter: "artist=; location=").outputs[0]
        let clearedProps = properties(cleared)
        XCTAssertNil((clearedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
        XCTAssertNil((clearedProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCByline])
        XCTAssertNil(clearedProps[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(clearedProps[kCGImagePropertyPixelWidth] as? Int, 400, "pixels copied as they were")
    }

    func testEditMetadataOnlyOffersRewritableFormats() {
        let catalog = converter.catalog()
        func offers(_ name: String) -> Bool {
            catalog.tools(for: [URL(fileURLWithPath: "/tmp/\(name)")]).contains { $0.payload == .tool(.imageEditMetadata) }
        }
        XCTAssertTrue(offers("a.jpg"))
        XCTAssertTrue(offers("a.heic"))
        XCTAssertFalse(offers("a.webp"))
        XCTAssertTrue(catalog.tools(for: [URL(fileURLWithPath: "/tmp/a.zip")]).contains { $0.payload == .tool(.batchRename) })
        XCTAssertFalse(catalog.tools(for: [directory]).contains { $0.payload == .tool(.batchRename) }, "not folders")
    }

    // MARK: Upscale

    func testUpscaleDoublesTheSize() async throws {
        let url = try save(try textImage("SHARP", width: 300, height: 120), "small.png")
        let outcome = try await converter.run(.imageUpscale, inputs: [url])
        let props = properties(outcome.outputs[0])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 600)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 240)
        XCTAssertTrue(outcome.outputs[0].lastPathComponent.hasSuffix("(2x).png"))
        let text = try TextRecognizer.recognize(try await ImageEngine.loadImage(at: outcome.outputs[0]))
        XCTAssertTrue(text.uppercased().contains("SHARP"), text)

        let huge = try ImageEngine.render(width: 9000, height: 10) { _ in }
        XCTAssertThrowsError(try ImageEngine.upscaled(huge, factor: 2))
    }
}

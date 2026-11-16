import XCTest
@testable import KumquatCore

final class UndoTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    func makePNG(_ name: String) throws -> URL {
        let image = try ImageEngine.render(width: 40, height: 30) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let url = directory.appendingPathComponent(name)
        try ImageEngine.encode(image, to: url, format: .png, quality: 1)
        return url
    }

    func testUndoPutsBackReplacedFilesAndOriginals() async throws {
        let png = try makePNG("photo.png")
        let jpg = try file("photo.jpg", "OLD")
        var options = ConversionOptions()
        options.conflictPolicy = .replace
        options.originals = .trash

        let journal = UndoJournal()
        let output = try await UndoJournal.$current.withValue(journal) {
            try await converter.convert(png, to: .jpg, options: options)
        }
        XCTAssertEqual(Set(journal.trashed.map(\.original.lastPathComponent)), ["photo.jpg", "photo.png"])

        let report = Undo.undo(JobRecord(title: "photo → JPG", outputs: [output], trashed: journal.trashed))
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.restored, 2)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(try String(contentsOf: jpg, encoding: .utf8), "OLD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
    }

    func testUndoNeverOverwritesANewFile() async throws {
        let png = try makePNG("photo.png")
        var options = ConversionOptions()
        options.originals = .trash
        let journal = UndoJournal()
        let output = try await UndoJournal.$current.withValue(journal) {
            try await converter.convert(png, to: .jpg, options: options)
        }
        try Data("NEW".utf8).write(to: png)

        let report = Undo.undo(JobRecord(title: "photo → JPG", outputs: [output], trashed: journal.trashed))
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertEqual(try String(contentsOf: png, encoding: .utf8), "NEW")
    }

    func testJobsOutsideAJournalRecordNothing() async throws {
        let png = try makePNG("photo.png")
        var options = ConversionOptions()
        options.originals = .trash
        let journal = UndoJournal()
        _ = try await converter.convert(png, to: .jpg, options: options)
        XCTAssertEqual(journal.trashed, [])
    }
}

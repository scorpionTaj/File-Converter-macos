import XCTest
@testable import KumquatCore

final class WatchFolderTests: TemporaryDirectoryTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ name: String, size: Int64, addedAfter seconds: TimeInterval) -> WatchFolderTracker.Entry {
        WatchFolderTracker.Entry(url: URL(fileURLWithPath: "/watch/\(name)"), size: size,
                                 added: start.addingTimeInterval(seconds))
    }

    func testNewFilesAreReadyOnceTheirSizeSettles() {
        var tracker = WatchFolderTracker(since: start)
        let old = entry("old.png", size: 10, addedAfter: -60)

        // First sighting: still being checked.
        XCTAssertEqual(tracker.ready([old, entry("a.png", size: 100, addedAfter: 1)], scannedAt: start + 2), [])
        XCTAssertTrue(tracker.isWaiting)
        XCTAssertEqual(tracker.since, start, "since doesn't move while a file is waiting")

        // Still growing.
        XCTAssertEqual(tracker.ready([old, entry("a.png", size: 400, addedAfter: 1)], scannedAt: start + 3), [])

        // Same size twice: ready, exactly once.
        let ready = tracker.ready([old, entry("a.png", size: 400, addedAfter: 1)], scannedAt: start + 4)
        XCTAssertEqual(ready.map(\.lastPathComponent), ["a.png"])
        XCTAssertFalse(tracker.isWaiting)
        XCTAssertEqual(tracker.since, start + 4)
        XCTAssertEqual(tracker.ready([old, entry("a.png", size: 400, addedAfter: 1)], scannedAt: start + 5), [])
        XCTAssertEqual(tracker.ready([old, entry("a.png", size: 400, addedAfter: 1)], scannedAt: start + 6), [])
    }

    func testFilesAlreadyThereAreLeftAlone() {
        var tracker = WatchFolderTracker(since: start)
        let existing = [entry("a.jpg", size: 5, addedAfter: -10), entry("b.jpg", size: 5, addedAfter: 0)]
        XCTAssertEqual(tracker.ready(existing, scannedAt: start + 1), [])
        XCTAssertEqual(tracker.ready(existing, scannedAt: start + 2), [])
        XCTAssertFalse(tracker.isWaiting)
    }

    func testEmptyAndVanishedFilesAreSkipped() {
        var tracker = WatchFolderTracker(since: start)
        _ = tracker.ready([entry("empty.png", size: 0, addedAfter: 1), entry("gone.png", size: 9, addedAfter: 1)],
                          scannedAt: start + 2)
        XCTAssertEqual(tracker.ready([entry("empty.png", size: 0, addedAfter: 1)], scannedAt: start + 3), [])
        XCTAssertFalse(tracker.isWaiting, "an empty file stops being checked; a removed one is forgotten")
    }

    func testAFileAddedAgainIsConvertedAgain() {
        var tracker = WatchFolderTracker(since: start)
        _ = tracker.ready([entry("a.png", size: 9, addedAfter: 1)], scannedAt: start + 2)
        XCTAssertEqual(tracker.ready([entry("a.png", size: 9, addedAfter: 1)], scannedAt: start + 3).count, 1)
        _ = tracker.ready([entry("a.png", size: 9, addedAfter: 10)], scannedAt: start + 11)
        XCTAssertEqual(tracker.ready([entry("a.png", size: 9, addedAfter: 10)], scannedAt: start + 12).count, 1)
    }

    func testScanListsFilesButNotFoldersHiddenOrPartialFiles() throws {
        _ = try file("photo.png", "png")
        _ = try file(".DS_Store", "x")
        _ = try file("movie.mp4.download", "x")
        _ = try file("song.part", "x")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Results"), withIntermediateDirectories: true)
        let package = directory.appendingPathComponent("Report.pages")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "abcdef".write(to: package.appendingPathComponent("Index.zip"), atomically: true, encoding: .utf8)

        let entries = WatchFolderTracker.scan(directory)
        XCTAssertEqual(Set(entries.map(\.url.lastPathComponent)), ["photo.png", "Report.pages"])
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "photo.png" }?.size, 3)
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "Report.pages" }?.size, 6)
        XCTAssertTrue(entries.allSatisfy { $0.added.timeIntervalSinceNow < 60 })
    }

    func testOnlyFilesThePresetCanConvertAreUsed() {
        let preset = OutputPreset(name: "Web", target: Format.webp.id)
        let urls = ["a.png", "b.webp", "c.mp3", "d.jpg"].map { URL(fileURLWithPath: "/watch/\($0)") }
        let picked = WatchFolder.convertible(urls, with: preset, catalog: Converter().catalog())
        XCTAssertEqual(picked.map(\.lastPathComponent), ["a.png", "d.jpg"],
                       "results already in the preset's format are never picked up again")
    }

    func testWatchFoldersRoundTrip() throws {
        let folder = WatchFolder(path: "/Users/me/Inbox", presetID: UUID(), isEnabled: false)
        let decoded = try JSONDecoder().decode([WatchFolder].self, from: JSONEncoder().encode([folder]))
        XCTAssertEqual(decoded, [folder])
        XCTAssertEqual(folder.name, "Inbox")
    }
}

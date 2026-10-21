import XCTest
@testable import KumquatCore

final class ParserTests: XCTestCase {
    func testPageRanges() throws {
        XCTAssertEqual(try PageRanges.parse("1, 3-5", pageCount: 10), [0, 2, 3, 4])
        XCTAssertEqual(try PageRanges.parse("8-", pageCount: 10), [7, 8, 9])
        XCTAssertEqual(try PageRanges.parse("-2; 2", pageCount: 10), [0, 1])
        XCTAssertThrowsError(try PageRanges.parse("0", pageCount: 3))
        XCTAssertThrowsError(try PageRanges.parse("2-9", pageCount: 3))
        XCTAssertThrowsError(try PageRanges.parse("abc", pageCount: 3))
        XCTAssertThrowsError(try PageRanges.parse("  ", pageCount: 3))
    }

    func testResizeSpec() throws {
        XCTAssertEqual(try ResizeSpec.parse("50%"), .scale(0.5))
        XCTAssertEqual(try ResizeSpec.parse("1280"), .width(1280))
        XCTAssertEqual(try ResizeSpec.parse("1280 × 720"), .fit(width: 1280, height: 720))
        XCTAssertEqual(try ResizeSpec.parse("x720"), .height(720))
        XCTAssertEqual(try ResizeSpec.parse("800px"), .width(800))
        XCTAssertThrowsError(try ResizeSpec.parse("big"))

        let fitted = ResizeSpec.fit(width: 1000, height: 1000).size(forWidth: 4000, height: 2000)
        XCTAssertEqual(fitted.width, 1000)
        XCTAssertEqual(fitted.height, 500)
        XCTAssertEqual(ResizeSpec.height(100).size(forWidth: 300, height: 200).width, 150)
    }

    func testTimeRange() throws {
        XCTAssertEqual(try TimeRange.parse("0:05-1:30"), TimeRange(start: 5, end: 90))
        XCTAssertEqual(try TimeRange.parse("1:02:03.5-"), TimeRange(start: 3723.5, end: nil))
        XCTAssertEqual(try TimeRange.parse("-10"), TimeRange(start: 0, end: 10))
        XCTAssertEqual(try TimeRange.parse("2 – 4"), TimeRange(start: 2, end: 4))
        XCTAssertThrowsError(try TimeRange.parse("5-2"))
        XCTAssertThrowsError(try TimeRange.parse("soon"))
        XCTAssertEqual(TimeRange.ffmpegTime(65.25), "65.250")
    }

    func testTrimArguments() {
        let video = FFmpegRecipes.trimArguments(input: "in.mov", output: "out.mov", source: .mov,
                                                range: TimeRange(start: 2, end: 5), options: ConversionOptions())
        XCTAssertEqual(Array(video[video.firstIndex(of: "-ss")!...].prefix(6)), ["-ss", "2.000", "-i", "in.mov", "-t", "3.000"])
        XCTAssertTrue(video.contains("libx264"))

        let audio = FFmpegRecipes.trimArguments(input: "a.flac", output: "b.flac", source: .flac,
                                                range: TimeRange(start: 0, end: nil), options: ConversionOptions())
        XCTAssertFalse(audio.contains("-ss"))
        XCTAssertFalse(audio.contains("-t"))
        XCTAssertTrue(audio.contains("flac"))
    }

    func testNewToolsApplicability() {
        let catalog = Catalog(engines: Set(EngineID.allCases), available: Set(Dependency.allCases), macOSMajorVersion: 15)
        let one = catalog.tools(for: [URL(fileURLWithPath: "/a.jpg")]).map(\.payload)
        XCTAssertTrue(one.contains(.tool(.imageAnnotate)))
        XCTAssertTrue(one.contains(.tool(.imageResizeCustom)))
        XCTAssertFalse(one.contains(.tool(.imagesToGIF)))

        let two = catalog.tools(for: [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.png")]).map(\.payload)
        XCTAssertTrue(two.contains(.tool(.imagesToGIF)))
        XCTAssertFalse(two.contains(.tool(.imageAnnotate)))

        XCTAssertTrue(catalog.tools(for: [URL(fileURLWithPath: "/a.mp3")]).map(\.payload).contains(.tool(.mediaTrim)))
        XCTAssertTrue(catalog.tools(for: [URL(fileURLWithPath: "/a.pdf")]).map(\.payload).contains(.tool(.pdfExtractPages)))
        XCTAssertTrue(ToolID.imageAnnotate.isInteractive)
    }

    func testInteractiveToolsAreRejectedByRunner() async throws {
        do {
            _ = try await Converter().run(.imageAnnotate, inputs: [URL(fileURLWithPath: "/tmp/a.png")])
            XCTFail("expected an error")
        } catch let error as KumquatError {
            XCTAssertTrue(error.localizedDescription.contains("editor"))
        }
    }
}

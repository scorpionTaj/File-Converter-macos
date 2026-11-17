import XCTest
import ImageIO
@testable import KumquatCore

/// 0.7 media recipes that need no FFmpeg.
final class MediaRecipeTests: XCTestCase {
    func testParseChapters() {
        let json = """
        {"chapters": [
          {"id": 1, "start_time": "90.000000", "end_time": "180.000000", "tags": {"title": "  Second  "}},
          {"id": 0, "start_time": "0.000000", "end_time": "90.000000", "tags": {"title": "Intro"}},
          {"id": 2, "start_time": "180.000000", "end_time": "180.000000"},
          {"id": 3, "start_time": "180.000000", "end_time": "200.500000", "tags": {"title": ""}}
        ]}
        """
        XCTAssertEqual(FFmpegRecipes.parseChapters(Data(json.utf8)), [
            MediaChapter(start: 0, end: 90, title: "Intro"),
            MediaChapter(start: 90, end: 180, title: "Second"),
            MediaChapter(start: 180, end: 200.5, title: nil),
        ])
        XCTAssertEqual(FFmpegRecipes.parseChapters(Data("{}".utf8)), [])
        XCTAssertEqual(FFmpegRecipes.parseChapters(Data("nope".utf8)), [])
    }

    func testChapterFileNames() {
        XCTAssertEqual(FFmpegRecipes.chapterFileName(MediaChapter(start: 0, end: 1, title: "Part 1: Intro/Setup"),
                                                     index: 0, count: 9), "01 Part 1- Intro-Setup")
        XCTAssertEqual(FFmpegRecipes.chapterFileName(MediaChapter(start: 0, end: 1), index: 41, count: 120), "042 Chapter 42")
        XCTAssertEqual(FFmpegRecipes.chapterFileName(MediaChapter(start: 0, end: 1, title: ".hidden."), index: 0, count: 2),
                       "01 hidden", "no leading dots (hidden files) or trailing dots")
    }

    func testChapterArgumentsCopyStreams() {
        let args = FFmpegRecipes.chapterArguments(input: "in.mkv", output: "out.mkv",
                                                  chapter: MediaChapter(start: 12.5, end: 20), audioOnly: false)
        XCTAssertEqual(args.firstIndex(of: "-ss").map { args[$0 + 1] }, "12.500")
        XCTAssertEqual(args.firstIndex(of: "-t").map { args[$0 + 1] }, "7.500")
        XCTAssertTrue(args.contains("copy"))
        XCTAssertLessThan(args.firstIndex(of: "-ss")!, args.firstIndex(of: "-i")!, "fast seek before the input")
        let audio = FFmpegRecipes.chapterArguments(input: "a.m4a", output: "b.m4a", chapter: MediaChapter(start: 0, end: 1),
                                                   audioOnly: true)
        XCTAssertFalse(audio.contains("0:v:0"))
        XCTAssertEqual(audio.last, "b.m4a")
    }

    func testGIFArguments() {
        let args = FFmpegRecipes.gifArguments(input: "clip.mov", output: "out.gif",
                                              range: TimeRange(start: 5, end: 9), fps: 10, maxWidth: 480)
        XCTAssertEqual(args.firstIndex(of: "-ss").map { args[$0 + 1] }, "5.000")
        XCTAssertEqual(args.firstIndex(of: "-t").map { args[$0 + 1] }, "4.000")
        XCTAssertTrue(args.contains { $0.hasPrefix("fps=10,") && $0.contains("min(480,iw)") && $0.contains("palettegen") })
        let whole = FFmpegRecipes.gifArguments(input: "clip.mov", output: "out.gif", range: TimeRange(start: 0, end: nil),
                                               fps: 12, maxWidth: 640)
        XCTAssertFalse(whole.contains("-ss"))
        XCTAssertFalse(whole.contains("-t"))
    }

    func testTimeRangeSpecRoundTrips() throws {
        XCTAssertEqual(TimeRange(start: 12.4, end: 18).spec, "12.400-18.000")
        XCTAssertEqual(TimeRange(start: 0, end: nil).spec, "0.000-")
        for range in [TimeRange(start: 1.25, end: 3.5), TimeRange(start: 65, end: nil)] {
            XCTAssertEqual(try TimeRange.parse(range.spec), range)
        }
    }

    func testBurnArgumentsUseOneFilterGraph() {
        let args = FFmpegRecipes.burnSubtitleArguments(input: "v.mov", overlayList: "subs.ffconcat", output: "o.mp4",
                                                       options: ConversionOptions(), encoders: EncoderSet(["libx264", "aac"]))
        XCTAssertFalse(args.contains("-vf"), "-vf can't be combined with -filter_complex")
        let graph = args.firstIndex(of: "-filter_complex").map { args[$0 + 1] }
        XCTAssertTrue(graph?.contains("overlay") == true)
        XCTAssertTrue(args.contains("concat"))
        XCTAssertTrue(args.contains("libx264"))
    }

    func testSubtitleTimelineAndConcatList() {
        let cues = [
            SubtitleCue(start: 2.5, end: 4, text: "<i>Second</i>"),
            SubtitleCue(start: 0.5, end: 3, text: "First"),
            SubtitleCue(start: 5, end: 6, text: "  "),
            SubtitleCue(start: 6, end: 7, text: "{\\an8}Last"),
        ]
        let timeline = SubtitleOverlay.timeline(cues)
        XCTAssertEqual(timeline, [
            SubtitleCue(start: 0.5, end: 3, text: "First"),
            SubtitleCue(start: 3, end: 4, text: "Second"),
            SubtitleCue(start: 6, end: 7, text: "Last"),
        ])
        let list = SubtitleOverlay.concatList(timeline, blank: "/w/blank.png", images: ["/w/a.png", "/w/b.png", "/w/c.png"])
        XCTAssertEqual(list, """
        ffconcat version 1.0
        file '/w/blank.png'
        duration 0.500
        file '/w/a.png'
        duration 2.500
        file '/w/b.png'
        duration 1.000
        file '/w/blank.png'
        duration 2.000
        file '/w/c.png'
        duration 1.000
        file '/w/blank.png'
        duration 1.000
        file '/w/blank.png'

        """)
    }

    func testRenderedSubtitleIsTransparentAboveTheText() throws {
        let image = try SubtitleOverlay.render("Hello", width: 320, height: 240)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
        XCTAssertEqual(alpha(of: image, x: 160, y: 20), 0, "top of the frame stays clear")
        let bottom = (180..<235).map { alpha(of: image, x: 160, y: $0) }.max() ?? 0
        XCTAssertGreaterThan(bottom, 0, "text near the bottom")
    }

    func testToolCatalog() {
        let catalog = Catalog(engines: Set(EngineID.allCases), available: [.ffmpeg])
        func tools(_ names: String...) -> Set<ToolID> {
            Set(catalog.tools(for: names.map { URL(fileURLWithPath: "/tmp/\($0)") }).compactMap { item -> ToolID? in
                if case .tool(let tool) = item.payload { return tool } else { return nil }
            })
        }
        XCTAssertTrue(tools("a.mov").isSuperset(of: [.videoBurnSubtitles, .videoToGIF, .mediaSplitChapters]))
        XCTAssertTrue(tools("a.mov", "a.srt").contains(.videoBurnSubtitles))
        XCTAssertFalse(tools("a.mov", "b.mov").contains(.videoBurnSubtitles), "one video at a time")
        XCTAssertTrue(tools("a.m4a").contains(.mediaSplitChapters))
        XCTAssertFalse(tools("a.m4a").contains(.videoToGIF))
        XCTAssertTrue(ToolID.videoBurnSubtitles.combinesInputs)
        if case .timeRange = ToolID.videoToGIF.input {} else { XCTFail("GIF asks for a time range") }
        if case .timeRange = ToolID.mediaTrim.input {} else { XCTFail("Trim asks for a time range") }
    }

    /// Alpha of one pixel, origin at the top left.
    private func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data[3]
    }
}

/// 0.7 media tools end to end (skipped without FFmpeg).
final class MediaPowerToolTests: TemporaryDirectoryTestCase {
    var converter: Converter!
    var ffmpeg: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        converter = Converter()
        guard let ffmpeg = converter.tools.ffmpeg, converter.tools.ffprobe != nil else { throw XCTSkip("FFmpeg not installed") }
        self.ffmpeg = ffmpeg
    }

    /// 4 s test pattern with a tone and three chapters (the last one untitled).
    func makeChapteredVideo() async throws -> URL {
        let metadata = try file("chapters.txt", """
        ;FFMETADATA1
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1500
        title=Intro: start
        [CHAPTER]
        TIMEBASE=1/1000
        START=1500
        END=3000
        title=Middle
        [CHAPTER]
        TIMEBASE=1/1000
        START=3000
        END=4000

        """)
        let url = directory.appendingPathComponent("clip.mp4")
        try await ProcessRunner.runChecked(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=4:size=320x240:rate=15",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-i", metadata.path,
            "-map", "0", "-map", "1", "-map_metadata", "2", "-map_chapters", "2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "15", "-c:a", "aac", "-shortest", url.path,
        ])
        return url
    }

    func duration(_ url: URL) async -> Double {
        await MediaEngine.probe(url, tools: converter.tools)?.duration ?? 0
    }

    /// Frame at `time` as an image.
    func frame(_ video: URL, at time: Double) async throws -> CGImage {
        let png = directory.appendingPathComponent("frame-\(UUID().uuidString).png")
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", "\(time)",
                                                    "-i", video.path, "-frames:v", "1", png.path])
        return try await ImageEngine.loadImage(at: png)
    }

    /// Mean absolute RGB difference over the bottom third of two same-size frames (0…255).
    func bottomDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        let rows = (a.height * 2 / 3)..<a.height
        var total = 0.0, count = 0.0
        for y in rows {
            for x in 0..<a.width {
                for c in 0..<3 {
                    let i = (y * a.width + x) * 4 + c
                    total += abs(Double(pa[i]) - Double(pb[i]))
                    count += 1
                }
            }
        }
        return total / count
    }

    func testSplitChapters() async throws {
        let video = try await makeChapteredVideo()
        let outcome = try await converter.run(.mediaSplitChapters, inputs: [video])
        XCTAssertEqual(outcome.message, "3 chapters")
        let folder = try XCTUnwrap(outcome.outputs.first)
        XCTAssertEqual(folder.lastPathComponent, "clip (chapters)")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["01 Intro- start.mp4", "02 Middle.mp4", "03 Chapter 3.mp4"])
        let lengths = await [files[0], files[1], files[2]].asyncMap { await self.duration(folder.appendingPathComponent($0)) }
        // Stream copy starts video chapters on the keyframe at or before the marker (one per second here),
        // so they may overlap by up to a second but never miss anything.
        XCTAssertGreaterThanOrEqual(lengths.reduce(0, +), 3.9, "the chapters cover the clip")
        XCTAssertLessThanOrEqual(lengths.reduce(0, +), 4 + 1.2)
        XCTAssertTrue(lengths.allSatisfy { $0 > 0.5 })

        // Audio has no keyframes to snap to: the parts add up to the whole.
        let audio = directory.appendingPathComponent("book.m4a")
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path,
                                                    "-vn", "-c:a", "copy", audio.path])
        let parts = try await converter.run(.mediaSplitChapters, inputs: [audio]).outputs[0]
        let partFiles = try FileManager.default.contentsOfDirectory(atPath: parts.path).sorted()
        XCTAssertEqual(partFiles, ["01 Intro- start.m4a", "02 Middle.m4a", "03 Chapter 3.m4a"])
        var total = 0.0
        for name in partFiles { total += await duration(parts.appendingPathComponent(name)) }
        XCTAssertEqual(total, 4, accuracy: 0.25)

        let plain = directory.appendingPathComponent("plain.mp4")
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path,
                                                    "-map_chapters", "-1", "-c", "copy", plain.path])
        do {
            _ = try await converter.run(.mediaSplitChapters, inputs: [plain])
            XCTFail("no chapters")
        } catch KumquatError.nothingToDo(let message) {
            XCTAssertTrue(message.contains("no chapter"), message)
        }
    }

    func testGIFFromTimeRange() async throws {
        let video = try await makeChapteredVideo()
        let outcome = try await converter.run(.videoToGIF, inputs: [video], parameter: "0:01-0:02")
        let gif = try XCTUnwrap(outcome.outputs.first)
        XCTAssertEqual(gif.pathExtension, "gif")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        // One second at 12 fps.
        XCTAssertEqual(Double(CGImageSourceGetCount(source)), 12, accuracy: 2)
        do {
            _ = try await converter.run(.videoToGIF, inputs: [video], parameter: "0:09-")
            XCTFail("starts after the end")
        } catch {}
    }

    func testBurnSubtitlesFromDroppedFileAndSidecar() async throws {
        let video = try await makeChapteredVideo()
        let srt = try file("other name.srt", "1\n00:00:00,500 --> 00:00:02,500\nHELLO <i>THERE</i>\n")
        let outcome = try await converter.run(.videoBurnSubtitles, inputs: [srt, video])
        let burned = try XCTUnwrap(outcome.outputs.first)
        XCTAssertEqual(burned.lastPathComponent, "clip (subtitled).mp4", "named after the video, not the subtitle file")
        XCTAssertEqual(outcome.message, "1 subtitles burned in")
        let during = bottomDifference(try await frame(video, at: 1.2), try await frame(burned, at: 1.2))
        let after = bottomDifference(try await frame(video, at: 3.5), try await frame(burned, at: 3.5))
        XCTAssertGreaterThan(during, after + 3, "text drawn while the cue shows (\(during) vs \(after))")
        let length = await duration(burned)
        XCTAssertEqual(length, 4, accuracy: 0.3)

        // Sidecar with the video's name, VTT.
        _ = try file("clip.vtt", "WEBVTT\n\n00:00.500 --> 00:02.000\nSIDECAR\n")
        let sidecar = try await converter.run(.videoBurnSubtitles, inputs: [video])
        XCTAssertEqual(sidecar.message, "1 subtitles burned in")

        // Nothing to burn.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("clip.vtt"))
        do {
            _ = try await converter.run(.videoBurnSubtitles, inputs: [video])
            XCTFail("no subtitles")
        } catch KumquatError.nothingToDo(let message) {
            XCTAssertTrue(message.contains("No subtitles"), message)
        }
    }

    func testBurnSubtitlesFromEmbeddedTrack() async throws {
        let video = try await makeChapteredVideo()
        let srt = try file("track.srt", "1\n00:00:00,500 --> 00:00:02,500\nEMBEDDED\n")
        let mkv = directory.appendingPathComponent("movie.mkv")
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path, "-i", srt.path,
                                                    "-map", "0:v", "-map", "0:a", "-map", "1", "-c", "copy", mkv.path])
        let outcome = try await converter.run(.videoBurnSubtitles, inputs: [mkv])
        XCTAssertEqual(outcome.outputs.first?.lastPathComponent, "movie (subtitled).mp4")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

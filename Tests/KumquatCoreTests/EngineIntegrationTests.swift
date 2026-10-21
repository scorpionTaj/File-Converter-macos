import XCTest
@testable import KumquatCore

/// End-to-end conversions through the real engines. Media tests run only where FFmpeg is installed.
class TemporaryDirectoryTestCase: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

final class MediaEngineTests: TemporaryDirectoryTestCase {
    var converter: Converter!
    var ffmpeg: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        converter = Converter()
        guard let ffmpeg = converter.tools.ffmpeg, converter.tools.ffprobe != nil else {
            throw XCTSkip("FFmpeg not installed")
        }
        self.ffmpeg = ffmpeg
    }

    func makeVideo(_ name: String = "clip.mp4", audio: Bool = true) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=161x121:rate=15"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-shortest", "-c:a", "aac"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "scale=160:120", url.path]
        try await ProcessRunner.runChecked(ffmpeg, args)
        return url
    }

    func makeAudio(_ name: String = "tone.wav") async throws -> URL {
        let url = directory.appendingPathComponent(name)
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                                    "-i", "sine=frequency=440:duration=1", url.path])
        return url
    }

    func probe(_ url: URL) async -> MediaProbe? {
        await MediaEngine.probe(url, tools: converter.tools)
    }

    func testAudioConversions() async throws {
        let wav = try await makeAudio()
        for target in [Format.mp3, .m4a, .flac, .ogg, .opus, .aiff, .aac, .wma] {
            let output = try await converter.convert(wav, to: target)
            XCTAssertEqual(FormatRegistry.format(for: output), target)
            let info = await probe(output)
            XCTAssertNotNil(info?.audioCodec, "no audio in \(target.id)")
        }
    }

    func testVideoRemuxAndReencode() async throws {
        let mp4 = try await makeVideo()
        let mov = try await converter.convert(mp4, to: .mov)
        let movProbe = await probe(mov)
        XCTAssertEqual(movProbe?.videoCodec, "h264")

        let webm = try await converter.convert(mp4, to: .webm)
        let webmProbe = await probe(webm)
        XCTAssertEqual(webmProbe?.videoCodec, "vp9")
        XCTAssertEqual(webmProbe?.audioCodec, "opus")

        let gif = try await converter.convert(mp4, to: .gif)
        XCTAssertEqual(FormatRegistry.format(for: gif), .gif)
        let back = try await converter.convert(gif, to: .mp4)
        let backProbe = await probe(back)
        XCTAssertEqual(backProbe?.videoCodec, "h264")

        let mp3 = try await converter.convert(mp4, to: .mp3)
        let mp3Probe = await probe(mp3)
        XCTAssertEqual(mp3Probe?.audioCodec, "mp3")
        XCTAssertFalse(mp3Probe?.hasVideo ?? true)
    }

    func testProgressIsReported() async throws {
        let mp4 = try await makeVideo()
        let recorder = ProgressRecorder()
        _ = try await converter.convert(mp4, to: .avi) { recorder.record($0) }
        XCTAssertEqual(recorder.last, 1)
    }

    func testVideoTools() async throws {
        let mp4 = try await makeVideo()
        let muted = try await converter.run(.videoMute, inputs: [mp4])
        let mutedProbe = await probe(muted.outputs[0])
        XCTAssertFalse(mutedProbe?.hasAudio ?? true)
        XCTAssertTrue(muted.outputs[0].lastPathComponent.contains("(muted)"))

        let audio = try await converter.run(.videoExtractAudio, inputs: [mp4])
        XCTAssertEqual(audio.outputs[0].pathExtension, "m4a")

        let frame = try await converter.run(.videoFirstFrame, inputs: [mp4])
        XCTAssertEqual(frame.outputs[0].pathExtension, "png")

        let rotated = try await converter.run(.videoRotate, inputs: [mp4])
        let rotatedProbe = await probe(rotated.outputs[0])
        XCTAssertEqual(rotatedProbe?.width, 120)
        XCTAssertEqual(rotatedProbe?.height, 160)

        let silent = try await makeVideo("silent.mp4", audio: false)
        let fast = try await converter.run(.videoSpeedUp, inputs: [silent])
        let fastProbe = await probe(fast.outputs[0])
        XCTAssertLessThan(fastProbe?.duration ?? 9, 0.8)

        do {
            _ = try await converter.run(.videoExtractAudio, inputs: [silent])
            XCTFail("Expected an error for a video without audio")
        } catch let error as KumquatError {
            XCTAssertTrue(error.localizedDescription.contains("no audio"))
        }
    }

    func testTrim() async throws {
        let mp4 = try await makeVideo()
        let trimmed = try await converter.run(.mediaTrim, inputs: [mp4], parameter: "0.2-0.7")
        let info = await probe(trimmed.outputs[0])
        XCTAssertEqual(info?.duration ?? 0, 0.5, accuracy: 0.12)
        XCTAssertTrue(trimmed.outputs[0].lastPathComponent.contains("(trimmed)"))

        let wav = try await makeAudio()
        let tail = try await converter.run(.mediaTrim, inputs: [wav], parameter: "0:00.5-")
        let tailInfo = await probe(tail.outputs[0])
        XCTAssertEqual(tailInfo?.duration ?? 0, 0.5, accuracy: 0.05)

        do {
            _ = try await converter.run(.mediaTrim, inputs: [wav], parameter: "5-6")
            XCTFail("starting after the end should fail")
        } catch {}
    }

    func testAudioTools() async throws {
        let wav = try await makeAudio()
        for tool in [ToolID.audioNormalize, .audioMono, .audioTrimSilence, .audioCompress, .stripMetadata] {
            let outcome = try await converter.run(tool, inputs: [wav])
            XCTAssertEqual(outcome.outputs.count, 1, tool.rawValue)
        }
    }

    func testSubtitleTrackConversion() async throws {
        let ass = try file("subs.ass", """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,Hello there

        """)
        let srt = try await converter.convert(ass, to: .srt)
        let text = try String(contentsOf: srt, encoding: .utf8)
        XCTAssertTrue(text.contains("Hello there"))
        XCTAssertTrue(text.contains("00:00:01,000 --> 00:00:02,500"))
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var last: Double? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

final class TextEngineTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    func testCSVToEverything() async throws {
        let csv = try file("people.csv", "name,age\nAda,36\n\"Lovelace, A\",37\n")
        let json = try await converter.convert(csv, to: .json)
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: String]]
        XCTAssertEqual(records?.count, 2)
        XCTAssertEqual(records?[1]["name"], "Lovelace, A")

        let markdown = try await converter.convert(csv, to: .md)
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).hasPrefix("| name | age |"))

        let tsv = try await converter.convert(csv, to: .tsv)
        XCTAssertTrue(try String(contentsOf: tsv, encoding: .utf8).contains("Lovelace, A\t37"))

        let html = try await converter.convert(csv, to: .html)
        XCTAssertTrue(try String(contentsOf: html, encoding: .utf8).contains("<td>Lovelace, A</td>"))
    }

    func testJSONAndPlistRoundTrip() async throws {
        let json = try file("config.json", #"{"name":"Kumquat","tags":["a","b"],"count":3,"none":null}"#)
        let plist = try await converter.convert(json, to: .plist)
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        XCTAssertEqual(object?["name"] as? String, "Kumquat")
        XCTAssertNil(object?["none"])

        let back = try await converter.convert(plist, to: .json)
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: back)) as? [String: Any]
        XCTAssertEqual(decoded?["tags"] as? [String], ["a", "b"])
    }

    func testSubtitleEngine() async throws {
        let srt = try file("movie.srt", "1\n00:00:01,000 --> 00:00:02,000\nHi\n")
        let vtt = try await converter.convert(srt, to: .vtt)
        XCTAssertTrue(try String(contentsOf: vtt, encoding: .utf8).hasPrefix("WEBVTT"))
        XCTAssertEqual(vtt.lastPathComponent, "movie.vtt")

        // Converting again doesn't overwrite the first result.
        let second = try await converter.convert(srt, to: .vtt)
        XCTAssertEqual(second.lastPathComponent, "movie 2.vtt")
    }

    func testArchiveConversionAndExtraction() async throws {
        let folder = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let tar = directory.appendingPathComponent("project.tar")
        try await ArchiveEngine.create(items: [folder], format: .tar, output: tar)
        let tgz = try await converter.convert(tar, to: .tgz)
        XCTAssertEqual(tgz.lastPathComponent, "project.tar.gz")

        let extracted = try await converter.run(.extractArchive, inputs: [tgz])
        let root = try XCTUnwrap(extracted.outputs.first)
        // A single top-level folder is unwrapped, like Archive Utility.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "world")
    }

    func testZipFromSeveralFolders() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { throw XCTSkip("zip not installed") }
        let one = directory.appendingPathComponent("one", isDirectory: true)
        let two = directory.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        let a = one.appendingPathComponent("a.txt"), b = two.appendingPathComponent("b.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        try "B".write(to: b, atomically: true, encoding: .utf8)

        let outcome = try await converter.run(.compressZip, inputs: [a, b])
        let zip = try XCTUnwrap(outcome.outputs.first)
        XCTAssertEqual(zip.lastPathComponent, "Archive.zip")
        let unpacked = try await converter.run(.extractArchive, inputs: [zip])
        let folder = try XCTUnwrap(unpacked.outputs.first)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8), "B")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "A")
    }

    func testChecksum() async throws {
        let url = try file("abc.txt", "abc")
        let outcome = try await converter.run(.checksum, inputs: [url])
        XCTAssertEqual(outcome.clipboardText, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt")
    }

    func testWordCount() async throws {
        let url = try file("essay.md", "# Title\n\nOne two three.")
        let outcome = try await converter.run(.wordCount, inputs: [url])
        XCTAssertEqual(outcome.message, "5 words · 23 characters")
    }

    func testSameFormatIsRejected() async {
        do {
            _ = try await converter.convert(directory.appendingPathComponent("x.png"), to: .png)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is KumquatError)
        }
    }
}

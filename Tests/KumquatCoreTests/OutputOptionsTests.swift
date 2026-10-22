import XCTest
import ImageIO
@testable import KumquatCore

final class FileNameTemplateTests: XCTestCase {
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 1, day: 31,
                              hour: 14, minute: 5, second: 9).date!

    func testDefaultKeepsTheName() {
        XCTAssertEqual(FileNameTemplate.render("{name}", name: "IMG_0042", format: "JPG"), "IMG_0042")
        XCTAssertEqual(FileNameTemplate.render("   ", name: "IMG_0042", format: "JPG"), "IMG_0042")
    }

    func testTokens() {
        XCTAssertEqual(FileNameTemplate.render("{name}-{format}-{date}", name: "photo", format: "WEBP", date: date),
                       "photo-WEBP-2026-01-31")
        XCTAssertEqual(FileNameTemplate.render("{name} {time}", name: "clip", format: "MP4", date: date), "clip 14.05.09")
    }

    func testUnsafeCharactersInTheTemplateOnly() {
        // The original name is kept as is; slashes and colons typed in the template are replaced.
        XCTAssertEqual(FileNameTemplate.render("web/{name}:small", name: "a:b", format: "JPG"), "web-a:b-small")
        XCTAssertEqual(FileNameTemplate.render(".{name}", name: "photo", format: "JPG"), "photo")
        XCTAssertEqual(FileNameTemplate.render("{date}", name: "photo", format: "JPG", date: date), "2026-01-31")
    }
}

final class MediaOptionRecipeTests: XCTestCase {
    let encoders = EncoderSet(["aac", "libmp3lame", "libopus", "libx264", "h264_videotoolbox", "flac"])

    func arguments(_ source: Format, _ target: Format, probe: MediaProbe? = nil,
                   _ configure: (inout ConversionOptions) -> Void) throws -> [String] {
        var options = ConversionOptions()
        configure(&options)
        return try FFmpegRecipes.conversionArguments(input: "in", output: "out", source: source, target: target,
                                                     probe: probe, options: options, encoders: encoders)
    }

    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func testDefaultsAreUnchanged() throws {
        let args = try arguments(.mkv, .mp4) { _ in }
        XCTAssertEqual(value(after: "-c:v", in: args), "libx264")
        XCTAssertEqual(value(after: "-preset", in: args), "medium")
        XCTAssertEqual(value(after: "-vf", in: args), "scale=trunc(iw/2)*2:trunc(ih/2)*2")
        XCTAssertFalse(args.contains("-map_metadata"))
        XCTAssertFalse(args.contains("-an"))
    }

    func testEncoderPreference() throws {
        XCTAssertEqual(value(after: "-c:v", in: try arguments(.mkv, .mp4) { $0.videoEncoder = .hardware }), "h264_videotoolbox")
        XCTAssertEqual(value(after: "-c:v", in: try arguments(.mkv, .mp4) { $0.videoEncoder = .software }), "libx264")
        let noX264 = EncoderSet(["aac", "h264_videotoolbox", "mpeg4"])
        var options = ConversionOptions()
        options.videoEncoder = .software
        let args = try FFmpegRecipes.conversionArguments(input: "in", output: "out", source: .mkv, target: .mp4,
                                                         probe: nil, options: options, encoders: noX264)
        XCTAssertEqual(value(after: "-c:v", in: args), "mpeg4", "software never picks the hardware encoder")
    }

    func testPresetIsValidated() throws {
        XCTAssertEqual(value(after: "-preset", in: try arguments(.mkv, .mp4) { $0.videoPreset = "slow" }), "slow")
        XCTAssertEqual(value(after: "-preset", in: try arguments(.mkv, .mp4) { $0.videoPreset = "; rm -rf" }), "medium")
    }

    func testMaximumHeightScalesAndPreventsRemux() throws {
        let tall = MediaProbe(videoCodec: "h264", audioCodec: "aac", width: 3840, height: 2160)
        let scaled = try arguments(.mov, .mp4, probe: tall) { $0.maxVideoHeight = 1080 }
        XCTAssertFalse(scaled.contains("copy"))
        XCTAssertEqual(value(after: "-vf", in: scaled), "scale=-2:'min(1080,trunc(ih/2)*2)'")

        let small = MediaProbe(videoCodec: "h264", audioCodec: "aac", width: 1280, height: 720)
        XCTAssertTrue(try arguments(.mov, .mp4, probe: small) { $0.maxVideoHeight = 1080 }.contains("copy"),
                      "already small enough: copy streams")
    }

    func testFrameRateCapAndRemoveAudio() throws {
        let args = try arguments(.mov, .mp4, probe: MediaProbe(videoCodec: "h264", audioCodec: "aac")) {
            $0.maxFrameRate = 30
            $0.removeAudio = true
        }
        XCTAssertEqual(value(after: "-fpsmax", in: args), "30")
        XCTAssertTrue(args.contains("-an"))
        XCTAssertFalse(args.contains("0:a?"))
        XCTAssertFalse(args.contains("-c:a"))

        let remux = try arguments(.mov, .mkv, probe: MediaProbe(videoCodec: "h264", audioCodec: "aac")) { $0.removeAudio = true }
        XCTAssertTrue(remux.contains("copy"))
        XCTAssertFalse(remux.contains("0:a?"))
    }

    func testMetadataPolicies() throws {
        XCTAssertEqual(value(after: "-map_metadata", in: try arguments(.wav, .mp3) { _ in }), "0")
        XCTAssertEqual(value(after: "-map_metadata", in: try arguments(.wav, .mp3) { $0.metadata = .removeAll }), "-1")
        XCTAssertEqual(value(after: "-map_metadata", in: try arguments(.mkv, .mp4) { $0.metadata = .removeAll }), "-1")
        let location = try arguments(.mkv, .mp4) { $0.metadata = .removeLocation }
        XCTAssertTrue(location.contains("location="))
        XCTAssertFalse(location.contains("-map_metadata"))
    }

    func testAudioOptions() throws {
        let mp3 = try arguments(.wav, .mp3, probe: MediaProbe(audioCodec: "pcm_s16le", sampleRate: 44100)) {
            $0.audioChannels = 1
            $0.normalizeAudio = true
        }
        XCTAssertEqual(value(after: "-ac", in: mp3), "1")
        XCTAssertTrue(value(after: "-af", in: mp3)?.hasPrefix("loudnorm") ?? false)
        XCTAssertEqual(value(after: "-ar", in: mp3), "44100", "back to the source rate after loudnorm")

        XCTAssertEqual(value(after: "-ar", in: try arguments(.wav, .flac) { $0.audioSampleRate = 48000 }), "48000")
        // Opus can't take 44.1 kHz: the setting is ignored rather than failing the conversion.
        XCTAssertNil(value(after: "-ar", in: try arguments(.wav, .opus) { $0.audioSampleRate = 44100 }))
        XCTAssertEqual(value(after: "-ar", in: try arguments(.wav, .opus) { $0.normalizeAudio = true }), "48000")
    }
}

/// Naming, conflicts, originals, dates, size, quality and metadata through the real converter.
final class OutputPlacementTests: TemporaryDirectoryTestCase {
    let converter = Converter()

    /// Gradient PNG, so JPEG quality visibly changes the file size.
    func makeImage(_ name: String = "sample.png", width: Int = 400, height: Int = 300) throws -> URL {
        let image = try ImageEngine.render(width: width, height: height) { ctx in
            for x in stride(from: 0, to: width, by: 4) {
                ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(x % 37) / 37, blue: 0.4, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 4, height: height))
            }
        }
        let url = directory.appendingPathComponent(name)
        try ImageEngine.encode(image, to: url, format: .png, quality: 1)
        return url
    }

    func options(_ configure: (inout ConversionOptions) -> Void) -> ConversionOptions {
        var options = ConversionOptions()
        configure(&options)
        return options
    }

    func jpgCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jpg") }.count
    }

    func testNameTemplate() async throws {
        let png = try makeImage()
        let output = try await converter.convert(png, to: .jpg, options: options { $0.fileNameTemplate = "{name}-{format}" })
        XCTAssertEqual(output.lastPathComponent, "sample-JPG.jpg")
    }

    func testConflictPolicies() async throws {
        let png = try makeImage()
        let first = try await converter.convert(png, to: .jpg)
        let second = try await converter.convert(png, to: .jpg)
        XCTAssertEqual(second.lastPathComponent, "sample 2.jpg")
        try FileManager.default.removeItem(at: second)

        let replaced = try await converter.convert(png, to: .jpg, options: options { $0.conflictPolicy = .replace })
        XCTAssertEqual(replaced, first)
        XCTAssertEqual(try jpgCount(), 1)

        do {
            _ = try await converter.convert(png, to: .jpg, options: options { $0.conflictPolicy = .skip })
            XCTFail("expected the existing file to be kept")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("skipped"))
        }
        XCTAssertEqual(try jpgCount(), 1)

        // Tools use the same policy; a skipped single file is an error, not a silent no-op.
        _ = try await converter.run(.imageResizeHalf, inputs: [png])
        do {
            _ = try await converter.run(.imageResizeHalf, inputs: [png], options: options { $0.conflictPolicy = .skip })
            XCTFail("expected skip")
        } catch {}
    }

    func testOriginalsAndDates() async throws {
        let png = try makeImage()
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: png.path)
        let output = try await converter.convert(png, to: .jpg, options: options {
            $0.preserveFileDates = true
            $0.originals = .trash
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path), "original moved to the Trash")
        let modified = try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date
        XCTAssertEqual(modified?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
    }

    func testCombinedToolsKeepOriginals() async throws {
        let a = try makeImage("a.png"), b = try makeImage("b.png")
        _ = try await converter.run(.imagesToPDF, inputs: [a, b], options: options { $0.originals = .trash })
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testMaximumSizeAndFormatQuality() async throws {
        let png = try makeImage(width: 1200, height: 600)
        let small = try await converter.convert(png, to: .jpg, options: options {
            $0.maxImageDimension = 300
            $0.formatQuality["jpg"] = 0.3
            $0.fileNameTemplate = "{name}-low"
        })
        let source = CGImageSourceCreateWithURL(small as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 300)

        let low = try await converter.convert(png, to: .jpg, options: options { $0.formatQuality["jpg"] = 0.3 })
        let high = try await converter.convert(png, to: .jpg, options: options { $0.formatQuality["jpg"] = 0.95 })
        XCTAssertLessThan(SizeReport.size(of: low), SizeReport.size(of: high))
        XCTAssertEqual(ConversionOptions().quality(for: .jpg), 0.85)
    }

    func testMetadataPolicies() async throws {
        let png = try makeImage()
        let image = try await ImageEngine.loadImage(at: png)
        let jpg = directory.appendingPathComponent("camera.jpg")
        let destination = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        func read(_ url: URL) -> (gps: Bool, date: String?) {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            return (properties[kCGImagePropertyGPSDictionary] != nil, exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
        }

        let kept = try await converter.convert(jpg, to: .tiff, options: options { $0.fileNameTemplate = "{name}-keep" })
        XCTAssertTrue(read(kept).gps)
        XCTAssertEqual(read(kept).date, "2024:05:01 10:00:00")

        let noLocation = try await converter.convert(jpg, to: .tiff, options: options {
            $0.metadata = .removeLocation
            $0.fileNameTemplate = "{name}-nogps"
        })
        XCTAssertFalse(read(noLocation).gps)
        XCTAssertEqual(read(noLocation).date, "2024:05:01 10:00:00")

        let stripped = try await converter.convert(jpg, to: .tiff, options: options {
            $0.metadata = .removeAll
            $0.fileNameTemplate = "{name}-none"
        })
        XCTAssertFalse(read(stripped).gps)
        XCTAssertNil(read(stripped).date)
    }
}

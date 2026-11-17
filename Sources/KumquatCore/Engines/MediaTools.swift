import Foundation
import CoreGraphics
import CoreText

/// A chapter marker in an audio or video file.
public struct MediaChapter: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var title: String?

    public init(start: Double, end: Double, title: String? = nil) {
        self.start = start
        self.end = end
        self.title = title
    }
}

extension FFmpegRecipes {
    public static func chapterProbeArguments(input: String) -> [String] {
        ["-v", "error", "-show_chapters", "-of", "json", input]
    }

    /// Chapters from `ffprobe -show_chapters -of json`, in order, without empty ones.
    public static func parseChapters(_ data: Data) -> [MediaChapter] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let chapters = root["chapters"] as? [[String: Any]] else { return [] }
        return chapters.compactMap { chapter -> MediaChapter? in
            guard let start = (chapter["start_time"] as? String).flatMap(Double.init),
                  let end = (chapter["end_time"] as? String).flatMap(Double.init), end > start else { return nil }
            let title = ((chapter["tags"] as? [String: Any])?["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MediaChapter(start: start, end: end, title: title?.isEmpty == true ? nil : title)
        }
        .sorted { $0.start < $1.start }
    }

    /// File name for chapter `index` of `count`: "03 The Middle".
    public static func chapterFileName(_ chapter: MediaChapter, index: Int, count: Int) -> String {
        let digits = max(2, String(count).count)
        let number = String(index + 1)
        let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
        let title = (chapter.title ?? "Chapter \(index + 1)")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return "\(padded) \(String(title.prefix(80)))"
    }

    /// One chapter, copied without re-encoding (instant and lossless; video cuts land on the keyframe
    /// at or before the chapter start).
    public static func chapterArguments(input: String, output: String, chapter: MediaChapter, audioOnly: Bool) -> [String] {
        ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
         "-ss", TimeRange.ffmpegTime(chapter.start), "-i", input,
         "-t", TimeRange.ffmpegTime(chapter.end - chapter.start)]
            + (audioOnly ? ["-map", "0:a"] : ["-map", "0:v:0", "-map", "0:a?"])
            + ["-map_chapters", "-1", "-c", "copy", "-avoid_negative_ts", "make_zero", output]
    }

    /// Animated GIF of part of a video, with a generated palette.
    public static func gifArguments(input: String, output: String, range: TimeRange, fps: Int, maxWidth: Int) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        if range.start > 0 { args += ["-ss", TimeRange.ffmpegTime(range.start)] }
        if let end = range.end { args += ["-t", TimeRange.ffmpegTime(end - range.start)] }
        return args + ["-i", input, "-map", "0:v:0", "-vf", gifFilter(fps: fps, maxWidth: maxWidth), "-loop", "0", output]
    }

    /// Video with a stream of transparent subtitle images (an ffconcat list) laid over it.
    public static func burnSubtitleArguments(input: String, overlayList: String, output: String,
                                             options: ConversionOptions, encoders: EncoderSet = .all) -> [String] {
        // The encoder arguments carry a -vf; the scaling goes into the filter graph instead.
        var codec = h264(crf: options.videoCRF, preset: options.videoPreset, encoders: encoders, preference: options.videoEncoder)
        if let vf = codec.firstIndex(of: "-vf") { codec.removeSubrange(vf...(vf + 1)) }
        let graph = "[1:v]format=rgba[subs];[0:v][subs]overlay=0:0:eof_action=pass:format=auto,"
            + evenDimensions + ",format=yuv420p[out]"
        return ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
                "-i", input, "-f", "concat", "-safe", "0", "-i", overlayList,
                "-filter_complex", graph, "-map", "[out]", "-map", "0:a?"]
            + codec + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", output]
    }

    /// Picture-based subtitle codecs (Blu-ray, DVD), which can't be turned into text.
    static let bitmapSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]
}

/// Subtitle cues drawn as transparent full-frame images and listed with their timing, so FFmpeg can
/// overlay them. Works with any FFmpeg build (Homebrew's has no libass, so no `subtitles` filter).
enum SubtitleOverlay {
    /// Cues in order, overlaps trimmed, tags removed, empty ones dropped.
    static func timeline(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let text = Subtitles.stripAllTags(cue.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = max(cue.start, result.last?.end ?? 0)
            guard !text.isEmpty, cue.end > start + 0.01 else { continue }
            result.append(SubtitleCue(start: start, end: cue.end, text: text))
        }
        return result
    }

    /// The ffconcat list: a blank frame for gaps, a cue image while each cue shows.
    static func concatList(_ cues: [SubtitleCue], blank: String, images: [String]) -> String {
        var lines = ["ffconcat version 1.0"]
        var time = 0.0
        func add(_ file: String, _ duration: Double) {
            lines.append("file '\(file)'")
            lines.append("duration \(String(format: "%.3f", duration))")
        }
        for (cue, image) in zip(cues, images) {
            if cue.start > time + 0.0005 { add(blank, cue.start - time) }
            add(image, cue.end - cue.start)
            time = cue.end
        }
        add(blank, 1)
        // The last entry's duration only applies when a file follows it.
        lines.append("file '\(blank)'")
        return lines.joined(separator: "\n") + "\n"
    }

    /// White text with a black outline, centred near the bottom of a `width`×`height` frame.
    static func render(_ text: String, width: Int, height: Int) throws -> CGImage {
        let fontSize = max(14, CGFloat(height) / 16)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { bytes in
            [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)]
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -4.0,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): CTParagraphStyleCreate(paragraph, paragraph.count),
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let margin = CGFloat(width) * 0.06
        let box = CGRect(x: margin, y: CGFloat(height) / 18, width: CGFloat(width) - 2 * margin, height: CGFloat(height) * 0.6)
        // Size the text block to its content so it sits on the bottom margin rather than the box's top.
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: box.width, height: box.height), nil)
        let rect = CGRect(x: box.minX, y: box.minY, width: box.width, height: min(ceil(fitted.height) + 2, box.height))
        return try ImageEngine.render(width: width, height: height) { ctx in
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: fontSize / 8, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
        }
    }
}

extension MediaEngine {
    static func chapters(of url: URL, tools: ToolLocator) async -> [MediaChapter] {
        guard let ffprobe = tools.ffprobe,
              let result = try? await ProcessRunner.run(ffprobe, FFmpegRecipes.chapterProbeArguments(input: url.path)),
              result.status == 0 else { return [] }
        return FFmpegRecipes.parseChapters(Data(result.stdout.utf8))
    }

    /// One file per chapter, in a folder named after the original.
    static func splitChapters(_ input: URL, source: Format, context: EngineContext) async throws -> ToolArtifact {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        let chapters = await chapters(of: input, tools: context.tools)
        guard chapters.count > 1 else {
            throw KumquatError.nothingToDo(chapters.isEmpty ? L("\(input.lastPathComponent) has no chapter markers.")
                                            : L("\(input.lastPathComponent) has only one chapter marker."))
        }
        let base = FormatRegistry.baseName(of: input)
        let folder = context.workDirectory.appendingPathComponent("\(base) (chapters)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = FFmpegRecipes.sameOrFallback(source)
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            let name = FFmpegRecipes.chapterFileName(chapter, index: index, count: chapters.count)
            let output = folder.appendingPathComponent("\(name).\(format.fileExtension)")
            try await ProcessRunner.runChecked(ffmpeg, FFmpegRecipes.chapterArguments(
                input: input.path, output: output.path, chapter: chapter, audioOnly: source.kind == .audio))
            context.progress?(Double(index + 1) / Double(chapters.count))
        }
        return ToolArtifact(url: folder, message: L("\(chapters.count) chapters"), preferredBaseName: folder.lastPathComponent)
    }

    static func makeGIF(_ input: URL, parameter: String?, context: EngineContext) async throws -> ToolArtifact {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        let range = try TimeRange.parse(parameter ?? "")
        let probe = await probe(input, tools: context.tools)
        if let duration = probe?.duration, range.start >= duration {
            let length = Subtitles.formatTimestamp(duration, millisecondSeparator: ".")
            throw KumquatError.invalidInput(L("The clip is only \(length) long."))
        }
        let output = context.scratchURL("gif")
        let args = FFmpegRecipes.gifArguments(input: input.path, output: output.path, range: range,
                                              fps: context.options.gifFPS, maxWidth: context.options.gifMaxWidth)
        let length = range.end.map { $0 - range.start } ?? probe?.duration.map { $0 - range.start }
        try await run(ffmpeg, args, duration: length, context: context)
        return ToolArtifact(url: output, message: SizeReport.size(of: output) > 0 ? nil : "Empty GIF")
    }

    /// Burns subtitles into a video: a subtitle file dropped with it, a file next to it with the same name,
    /// or the video's own first text subtitle track.
    static func burnSubtitles(_ inputs: [URL], context: EngineContext) async throws -> ToolArtifact {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        guard let video = inputs.first(where: { FormatRegistry.kind(for: $0) == .video }) else {
            throw KumquatError.nothingToDo(L("Drop a video (and optionally its subtitle file)."))
        }
        let probe = await probe(video, tools: context.tools)
        guard let width = probe?.width, let height = probe?.height, width > 0, height > 0 else {
            throw KumquatError.invalidInput(L("Couldn't read the size of \(video.lastPathComponent)."))
        }
        let cues = try await subtitleCues(for: video, dropped: inputs.first { FormatRegistry.kind(for: $0) == .subtitle },
                                          ffmpeg: ffmpeg, context: context)
        let timeline = SubtitleOverlay.timeline(cues)
        guard !timeline.isEmpty else { throw KumquatError.nothingToDo(L("The subtitles have no text.")) }

        let folder = context.workDirectory.appendingPathComponent("subtitle-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blank = folder.appendingPathComponent("blank.png")
        try ImageEngine.encode(try ImageEngine.render(width: width, height: height) { _ in }, to: blank, format: .png, quality: 1)
        var images: [String] = []
        for (index, cue) in timeline.enumerated() {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(String(format: "cue%05d.png", index))
            try ImageEngine.encode(try SubtitleOverlay.render(cue.text, width: width, height: height), to: url, format: .png, quality: 1)
            images.append(url.path)
        }
        let list = folder.appendingPathComponent("subtitles.ffconcat")
        try SubtitleOverlay.concatList(timeline, blank: blank.path, images: images).write(to: list, atomically: true, encoding: .utf8)

        let output = context.scratchURL("mp4")
        let encoders = await encoders(of: ffmpeg)
        let args = FFmpegRecipes.burnSubtitleArguments(input: video.path, overlayList: list.path, output: output.path,
                                                       options: context.options, encoders: encoders)
        try await run(ffmpeg, args, duration: probe?.duration, context: context)
        return ToolArtifact(url: output, message: L("\(timeline.count) subtitles burned in"),
                            preferredBaseName: "\(FormatRegistry.baseName(of: video)) (subtitled)", original: video)
    }

    private static func subtitleCues(for video: URL, dropped: URL?, ffmpeg: URL, context: EngineContext) async throws -> [SubtitleCue] {
        let sidecar = ["srt", "vtt", "ass", "ssa"].lazy
            .map { video.deletingPathExtension().appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let file = dropped ?? sidecar {
            if ["srt", "vtt"].contains(file.pathExtension.lowercased()) {
                return Subtitles.parse(try String.readText(from: file))
            }
            // ASS/SSA: FFmpeg turns it into SRT (styling is dropped; libass isn't needed).
            let srt = context.scratchURL("srt")
            try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                                                        "-i", file.path, srt.path])
            return Subtitles.parse(try String.readText(from: srt))
        }
        // The video's own subtitle track.
        let codec = await subtitleCodec(of: video, tools: context.tools)
        guard let codec else {
            throw KumquatError.nothingToDo(L("No subtitles: drop a .srt/.vtt/.ass file with the video, or put one next to it with the same name."))
        }
        guard !FFmpegRecipes.bitmapSubtitleCodecs.contains(codec) else {
            throw KumquatError.nothingToDo(L("The video's subtitles are pictures (\(codec)), not text, so they can't be burned in. Drop a .srt file with it instead."))
        }
        let srt = context.scratchURL("srt")
        try await ProcessRunner.runChecked(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                                                    "-i", video.path, "-map", "0:s:0", srt.path])
        return Subtitles.parse(try String.readText(from: srt))
    }

    static func subtitleCodec(of url: URL, tools: ToolLocator) async -> String? {
        guard let ffprobe = tools.ffprobe,
              let result = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "s:0",
                                                                  "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path]),
              result.status == 0 else { return nil }
        let codec = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return codec.isEmpty ? nil : codec
    }
}

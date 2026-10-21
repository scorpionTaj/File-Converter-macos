import Foundation

/// Audio, video, animated GIF and subtitle-track conversions through FFmpeg.
public struct MediaEngine: ConversionEngine {
    public let id = EngineID.media

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        let probe = await Self.probe(input, tools: context.tools)
        let args = FFmpegRecipes.conversionArguments(input: input.path, output: output.path, source: source, target: target,
                                                     probe: probe, options: context.options)
        try await Self.run(ffmpeg, args, duration: probe?.duration, context: context)
        return output
    }

    static func probe(_ url: URL, tools: ToolLocator) async -> MediaProbe? {
        guard let ffprobe = tools.ffprobe,
              let result = try? await ProcessRunner.run(ffprobe, FFmpegRecipes.probeArguments(input: url.path)),
              result.status == 0 else { return nil }
        return FFmpegRecipes.parseProbe(Data(result.stdout.utf8))
    }

    static func run(_ ffmpeg: URL, _ args: [String], duration: Double?, context: EngineContext) async throws {
        let progress = context.progress
        try await ProcessRunner.runChecked(ffmpeg, args) { line in
            guard let duration, duration > 0, let seconds = FFmpegRecipes.progressSeconds(fromLine: line) else { return }
            progress?(min(seconds / duration, 1))
        }
    }

    /// Encodes a still image with FFmpeg (WebP/AVIF fallback for ImageIO).
    static func encodeStillImage(_ input: URL, to output: URL, format: Format, quality: Double, tools: ToolLocator) async throws {
        let ffmpeg = try tools.require("ffmpeg", .ffmpeg)
        try await ProcessRunner.runChecked(ffmpeg, FFmpegRecipes.stillImageArguments(input: input.path, output: output.path,
                                                                                       target: format, quality: quality))
    }

    static func runTool(_ tool: ToolID, input: URL, source: Format, parameter: String? = nil,
                        context: EngineContext) async throws -> ToolArtifact {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        let probe = await Self.probe(input, tools: context.tools)
        if tool == .mediaTrim {
            let range = try TimeRange.parse(parameter ?? "")
            if let duration = probe?.duration, range.start >= duration {
                throw KumquatError.invalidInput("The clip is only \(Subtitles.formatTimestamp(duration, millisecondSeparator: ".")) long.")
            }
            let output = context.scratchURL(FFmpegRecipes.toolOutputFormat(tool, source: source).fileExtension)
            let args = FFmpegRecipes.trimArguments(input: input.path, output: output.path, source: source, range: range,
                                                   options: context.options)
            let length = range.end.map { $0 - range.start } ?? probe?.duration.map { $0 - range.start }
            try await run(ffmpeg, args, duration: length, context: context)
            return ToolArtifact(url: output)
        }
        if tool == .videoExtractAudio, probe?.hasAudio == false {
            throw KumquatError.nothingToDo("\(input.lastPathComponent) has no audio track.")
        }
        let outputFormat = FFmpegRecipes.toolOutputFormat(tool, source: source)
        let output = context.scratchURL(outputFormat.fileExtension)
        guard let args = FFmpegRecipes.toolArguments(tool, input: input.path, output: output.path, source: source,
                                                     probe: probe, options: context.options) else {
            throw KumquatError.nothingToDo("\(tool.title) doesn't apply to \(input.lastPathComponent).")
        }
        try await run(ffmpeg, args, duration: probe?.duration, context: context)

        var message: String?
        if tool == .videoCompress || tool == .audioCompress {
            message = SizeReport.savings(original: input, result: output)
        }
        return ToolArtifact(url: output, message: message)
    }
}

enum SizeReport {
    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// "Saved 42%" / "No smaller".
    static func savings(original: URL, result: URL) -> String {
        let before = size(of: original), after = size(of: result)
        guard before > 0, after > 0 else { return "Done" }
        let percent = Int((Double(before - after) / Double(before) * 100).rounded())
        return percent > 0 ? "Saved \(percent)%" : "Already compact (\(percent)%)"
    }
}

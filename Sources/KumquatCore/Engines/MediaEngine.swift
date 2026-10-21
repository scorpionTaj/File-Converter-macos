import Foundation

/// Audio, video, animated GIF and subtitle-track conversions through FFmpeg.
public struct MediaEngine: ConversionEngine {
    public let id = EngineID.media

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        let probe = await Self.probe(input, tools: context.tools)
        let encoders = await Self.encoders(of: ffmpeg)
        let args = try FFmpegRecipes.conversionArguments(input: input.path, output: output.path, source: source, target: target,
                                                         probe: probe, options: context.options, encoders: encoders)
        try await Self.run(ffmpeg, args, duration: probe?.duration, context: context)
        return output
    }

    private static let encoderCache = EncoderCache()

    /// Forget detected encoders, e.g. after the user installs or upgrades FFmpeg.
    public static func resetCaches() { encoderCache.removeAll() }

    /// Encoders of a given FFmpeg binary, detected once per path.
    static func encoders(of ffmpeg: URL) async -> EncoderSet {
        if let cached = encoderCache.get(ffmpeg.path) { return cached }
        guard let result = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"]), result.status == 0 else {
            return .all
        }
        let encoders = EncoderSet.parse(result.stdout)
        encoderCache.set(ffmpeg.path, encoders)
        return encoders
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

    /// Encodes a WebP/AVIF still when ImageIO can't: FFmpeg if its build has the encoder, otherwise the
    /// standalone `cwebp` / `avifenc` tools.
    static func encodeStillImage(_ input: URL, to output: URL, format: Format, quality: Double, tools: ToolLocator) async throws {
        if let ffmpeg = tools.ffmpeg {
            let available = await Self.encoders(of: ffmpeg)
            if let args = FFmpegRecipes.stillImageArguments(input: input.path, output: output.path, target: format,
                                                            quality: quality, encoders: available) {
                try await ProcessRunner.runChecked(ffmpeg, args)
                return
            }
        }
        let percent = "\(Int((quality * 100).rounded()))"
        switch format {
        case .webp:
            if let cwebp = tools.path(for: "cwebp") {
                try await ProcessRunner.runChecked(cwebp, ["-quiet", "-q", percent, input.path, "-o", output.path])
                return
            }
        case .avif:
            if let avifenc = tools.path(for: "avifenc") {
                try await ProcessRunner.runChecked(avifenc, ["-q", percent, input.path, output.path])
                return
            }
        default:
            break
        }
        if tools.ffmpeg == nil { throw KumquatError.missingDependencies([.ffmpeg]) }
        let hint = format == .webp ? "brew install webp" : "brew install libavif"
        throw KumquatError.engineUnavailable("A \(format.name) encoder (your FFmpeg lacks one; \(hint) adds it)")
    }

    static func runTool(_ tool: ToolID, input: URL, source: Format, parameter: String? = nil,
                        context: EngineContext) async throws -> ToolArtifact {
        let ffmpeg = try context.tools.require("ffmpeg", .ffmpeg)
        let probe = await Self.probe(input, tools: context.tools)
        let encoders = await Self.encoders(of: ffmpeg)
        if tool == .mediaTrim {
            let range = try TimeRange.parse(parameter ?? "")
            if let duration = probe?.duration, range.start >= duration {
                throw KumquatError.invalidInput("The clip is only \(Subtitles.formatTimestamp(duration, millisecondSeparator: ".")) long.")
            }
            let output = context.scratchURL(FFmpegRecipes.toolOutputFormat(tool, source: source).fileExtension)
            let args = FFmpegRecipes.trimArguments(input: input.path, output: output.path, source: source, range: range,
                                                   options: context.options, encoders: encoders)
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
                                                     probe: probe, options: context.options, encoders: encoders) else {
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

/// Thread-safe cache of detected encoders, keyed by FFmpeg path.
final class EncoderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: EncoderSet] = [:]

    func get(_ key: String) -> EncoderSet? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    func set(_ key: String, _ value: EncoderSet) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }
}

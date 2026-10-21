import Foundation

/// What `ffprobe` told us about a media file.
public struct MediaProbe: Equatable, Sendable {
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var sampleRate: Int?
    public var width: Int?
    public var height: Int?

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioCodec != nil }

    public init(duration: Double? = nil, videoCodec: String? = nil, audioCodec: String? = nil,
                sampleRate: Int? = nil, width: Int? = nil, height: Int? = nil) {
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.sampleRate = sampleRate
        self.width = width
        self.height = height
    }
}

/// Encoders an FFmpeg build actually has. FFmpeg builds differ a lot: Homebrew's current formula, for
/// example, ships without libvorbis and libwebp, so recipes pick the best encoder that exists.
public struct EncoderSet: Equatable, Sendable {
    /// nil means "unknown, assume a full build".
    public let names: Set<String>?

    public init(_ names: Set<String>?) { self.names = names }

    public static let all = EncoderSet(nil)

    public func has(_ encoder: String) -> Bool { names?.contains(encoder) ?? true }

    /// First available encoder from a preference list.
    public func first(_ candidates: String...) -> String? { candidates.first(where: has) }

    /// Parses `ffmpeg -hide_banner -encoders`.
    public static func parse(_ output: String) -> EncoderSet {
        var names = Set<String>()
        var inList = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") { inList = true; continue }
            guard inList else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, "VAS".contains(parts[0].first!) else { continue }
            names.insert(String(parts[1]))
        }
        return EncoderSet(names.isEmpty ? nil : names)
    }
}

/// Builds FFmpeg command lines. Pure functions, so every recipe is unit-tested.
public enum FFmpegRecipes {
    static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    static let lossyAudio: Set<Format> = [.mp3, .m4a, .aac, .ogg, .opus, .wma]

    public static func probeArguments(input: String) -> [String] {
        ["-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,sample_rate,width,height",
         "-of", "json", input]
    }

    public static func parseProbe(_ data: Data) -> MediaProbe? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var probe = MediaProbe()
        if let format = root["format"] as? [String: Any], let duration = format["duration"] as? String {
            probe.duration = Double(duration)
        }
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            let codec = stream["codec_name"] as? String
            switch (stream["codec_type"] as? String) ?? "" {
            case "video" where probe.videoCodec == nil:
                // Cover art in audio files shows up as a single-frame mjpeg/png "video" stream.
                if codec == "mjpeg" || codec == "png" { continue }
                probe.videoCodec = codec
                probe.width = stream["width"] as? Int
                probe.height = stream["height"] as? Int
            case "audio" where probe.audioCodec == nil:
                probe.audioCodec = codec
                probe.sampleRate = (stream["sample_rate"] as? String).flatMap(Int.init)
            default:
                break
            }
        }
        return probe
    }

    /// Arguments common to every run. Progress is reported as `key=value` lines on stdout.
    static func prefix(input: String) -> [String] {
        ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-i", input]
    }

    /// Parses `out_time_us=` progress lines into seconds.
    public static func progressSeconds(fromLine line: String) -> Double? {
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            return Double(line.dropFirst(key.count)).map { $0 / 1_000_000 }
        }
        return nil
    }

    // MARK: Conversions

    public static func audioCodecArguments(for target: Format, bitrate: Int, encoders: EncoderSet = .all) -> [String]? {
        switch target {
        case .mp3:
            if let encoder = encoders.first("libmp3lame", "libshine") { return ["-c:a", encoder, "-b:a", "\(bitrate)k"] }
            return nil
        case .m4a: return ["-c:a", "aac", "-b:a", "\(bitrate)k", "-movflags", "+faststart"]
        case .aac: return ["-c:a", "aac", "-b:a", "\(bitrate)k", "-f", "adts"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .flac: return ["-c:a", "flac"]
        case .ogg:
            if encoders.has("libvorbis") { return ["-c:a", "libvorbis", "-q:a", bitrate >= 160 ? "5" : "3"] }
            // Opus in an Ogg container is standard and plays everywhere Vorbis does.
            if encoders.has("libopus") { return ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"] }
            return ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2"]
        case .opus:
            if encoders.has("libopus") { return ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"] }
            return ["-c:a", "opus", "-strict", "experimental", "-ar", "48000", "-b:a", "\(min(bitrate, 256))k"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .wma: return ["-c:a", "wmav2", "-b:a", "\(bitrate)k"]
        default: return nil
        }
    }

    /// Whether streams can be copied untouched into `target` (instant, lossless).
    public static func canRemux(_ probe: MediaProbe, into target: Format) -> Bool {
        guard let video = probe.videoCodec else { return false }
        let audio = probe.audioCodec
        switch target {
        case .mp4, .m4v:
            return ["h264", "hevc", "av1", "mpeg4"].contains(video)
                && (audio == nil || ["aac", "mp3", "alac", "ac3", "eac3"].contains(audio!))
        case .mov:
            return ["h264", "hevc", "mpeg4", "prores"].contains(video)
                && (audio == nil || ["aac", "mp3", "alac", "ac3", "pcm_s16le", "pcm_s24le"].contains(audio!))
        case .mkv:
            return true
        case .webm:
            return ["vp8", "vp9", "av1"].contains(video) && (audio == nil || ["opus", "vorbis"].contains(audio!))
        default:
            return false
        }
    }

    static func h264(crf: Int, preset: String = "medium", filter: String = evenDimensions, encoders: EncoderSet = .all) -> [String] {
        if encoders.has("libx264") {
            return ["-c:v", "libx264", "-preset", preset, "-crf", "\(crf)", "-pix_fmt", "yuv420p", "-vf", filter]
        }
        if encoders.has("h264_videotoolbox") {
            // Apple's hardware encoder is always present on macOS builds; it takes a bitrate, not a CRF.
            let bitrate = crf <= 20 ? "10M" : crf <= 24 ? "6M" : "3M"
            return ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-pix_fmt", "yuv420p", "-vf", filter]
        }
        return ["-c:v", "mpeg4", "-q:v", "\(max(2, min(31, crf / 5)))", "-pix_fmt", "yuv420p", "-vf", filter]
    }

    static func webmArguments(crf: Int, encoders: EncoderSet) -> [String] {
        var args: [String]
        if encoders.has("libvpx-vp9") {
            args = ["-c:v", "libvpx-vp9", "-crf", "\(min(crf + 8, 63))", "-b:v", "0", "-row-mt", "1",
                    "-deadline", "good", "-cpu-used", "4"]
        } else if encoders.has("libsvtav1") {
            args = ["-c:v", "libsvtav1", "-crf", "\(min(crf + 12, 63))", "-preset", "8", "-vf", evenDimensions]
        } else if encoders.has("libaom-av1") {
            args = ["-c:v", "libaom-av1", "-crf", "\(min(crf + 12, 63))", "-b:v", "0", "-cpu-used", "8", "-row-mt", "1"]
        } else {
            args = ["-c:v", "libvpx", "-crf", "\(min(crf + 8, 63))", "-b:v", "1M"]
        }
        if let audio = encoders.first("libopus", "libvorbis") {
            args += ["-c:a", audio, "-b:a", "128k"]
        } else {
            args += ["-c:a", "opus", "-strict", "experimental", "-ar", "48000", "-b:a", "128k"]
        }
        return args
    }

    static func videoArguments(target: Format, probe: MediaProbe?, options: ConversionOptions, encoders: EncoderSet = .all) -> [String] {
        let maps = ["-map", "0:v:0", "-map", "0:a?"]
        if let probe, canRemux(probe, into: target) {
            var args = ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
            if probe.videoCodec == "hevc", [.mp4, .m4v, .mov].contains(target) { args += ["-tag:v", "hvc1"] }
            if [.mp4, .m4v, .mov].contains(target) { args += ["-movflags", "+faststart"] }
            return args
        }
        let crf = options.videoCRF
        switch target {
        case .mp4, .m4v, .mov:
            return maps + h264(crf: crf, encoders: encoders) + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case .mkv:
            return maps + h264(crf: crf, encoders: encoders) + ["-c:a", "aac", "-b:a", "160k"]
        case .webm:
            return maps + webmArguments(crf: crf, encoders: encoders)
        case .avi:
            let audio = encoders.has("libmp3lame") ? ["-c:a", "libmp3lame", "-b:a", "192k"] : ["-c:a", "ac3", "-b:a", "192k"]
            return maps + ["-c:v", "mpeg4", "-q:v", "4"] + audio
        case .wmv:
            return maps + ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case .gif:
            return ["-map", "0:v:0", "-vf", gifFilter(fps: options.gifFPS, maxWidth: options.gifMaxWidth), "-loop", "0"]
        default:
            return maps
        }
    }

    static func gifFilter(fps: Int, maxWidth: Int) -> String {
        "fps=\(fps),scale='min(\(maxWidth),iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
    }

    /// Full argument list for converting a media file.
    public static func conversionArguments(input: String, output: String, source: Format, target: Format,
                                           probe: MediaProbe?, options: ConversionOptions,
                                           encoders: EncoderSet = .all) throws -> [String] {
        var args = prefix(input: input)
        if target.kind == .audio {
            guard let codec = audioCodecArguments(for: target, bitrate: options.audioBitrateKbps, encoders: encoders) else {
                throw missingEncoder(for: target)
            }
            args += ["-map", "0:a:0", "-vn"] + codec + ["-map_metadata", "0"]
        } else if target.kind == .subtitle {
            args += ["-map", "0:s:0?"]
        } else {
            args += videoArguments(target: target, probe: probe, options: options, encoders: encoders)
        }
        return args + [output]
    }

    static func missingEncoder(for target: Format) -> KumquatError {
        .engineUnavailable("A \(target.name) encoder in your FFmpeg build (install the full build: brew reinstall ffmpeg)")
    }

    /// Still-image encode used when ImageIO can't write WebP/AVIF. Nil when this FFmpeg has no suitable encoder.
    public static func stillImageArguments(input: String, output: String, target: Format, quality: Double,
                                           encoders: EncoderSet = .all) -> [String]? {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", input, "-frames:v", "1"]
        let crf = Int((1 - quality) * 50) + 10
        switch target {
        case .webp where encoders.has("libwebp"):
            args += ["-c:v", "libwebp", "-quality", "\(Int(quality * 100))"]
        case .avif where encoders.has("libaom-av1"):
            args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
        case .avif where encoders.has("libsvtav1"):
            args += ["-c:v", "libsvtav1", "-crf", "\(crf)", "-pix_fmt", "yuv420p", "-vf", evenDimensions]
        default:
            return nil
        }
        return args + [output]
    }

    // MARK: Tools

    /// Same format when FFmpeg can write it, otherwise a sensible container.
    static func sameOrFallback(_ source: Format) -> Format {
        switch source.kind {
        case .audio: return Format.audioOutputs.contains(source) ? source : .m4a
        case .video: return Format.videoOutputs.contains(source) ? source : .mkv
        default: return source
        }
    }

    public static func toolOutputFormat(_ tool: ToolID, source: Format) -> Format {
        switch tool {
        case .videoCompress, .video720p, .videoRotate, .videoSpeedUp: return .mp4
        case .videoExtractAudio: return .m4a
        case .videoFirstFrame: return .png
        case .audioCompress: return lossyAudio.contains(source) ? source : .m4a
        default: return sameOrFallback(source)
        }
    }

    /// Frame-accurate trim. Re-encodes (fast for audio) because stream copy snaps to keyframes and can
    /// leave the container reporting the original duration.
    public static func trimArguments(input: String, output: String, source: Format, range: TimeRange,
                                     options: ConversionOptions, encoders: EncoderSet = .all) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        if range.start > 0 { args += ["-ss", TimeRange.ffmpegTime(range.start)] }
        args += ["-i", input]
        if let end = range.end { args += ["-t", TimeRange.ffmpegTime(end - range.start)] }
        let out = sameOrFallback(source)
        if source.kind == .video {
            args += videoArguments(target: out, probe: nil, options: options, encoders: encoders)
        } else {
            args += ["-map", "0:a:0", "-vn"] + (audioCodecArguments(for: out, bitrate: options.audioBitrateKbps, encoders: encoders) ?? [])
        }
        return args + [output]
    }

    public static func toolArguments(_ tool: ToolID, input: String, output: String, source: Format,
                                     probe: MediaProbe?, options: ConversionOptions, encoders: EncoderSet = .all) -> [String]? {
        let out = toolOutputFormat(tool, source: source)
        let maps = ["-map", "0:v:0", "-map", "0:a?"]
        let aacAudio = ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        let sameCodec = audioCodecArguments(for: out, bitrate: options.audioBitrateKbps, encoders: encoders) ?? []
        let body: [String]
        switch tool {
        case .videoCompress:
            body = maps + h264(crf: 28, preset: "slow", encoders: encoders) + ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        case .video720p:
            body = maps + h264(crf: options.videoCRF, filter: "scale=-2:'min(720,trunc(ih/2)*2)'", encoders: encoders) + aacAudio
        case .videoMute:
            body = ["-map", "0:v", "-c:v", "copy", "-an"]
        case .videoExtractAudio:
            body = probe?.audioCodec == "aac"
                ? ["-map", "0:a:0", "-vn", "-c:a", "copy"]
                : ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k"]
        case .videoRotate:
            body = maps + h264(crf: options.videoCRF, filter: "transpose=1," + evenDimensions, encoders: encoders) + aacAudio
        case .videoSpeedUp:
            body = maps + ["-filter:a", "atempo=2.0"]
                + h264(crf: options.videoCRF, filter: "setpts=0.5*PTS," + evenDimensions, encoders: encoders) + aacAudio
        case .videoFirstFrame:
            body = ["-map", "0:v:0", "-frames:v", "1"]
        case .audioNormalize:
            body = ["-map", "0:a:0", "-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
                    "-ar", "\(probe?.sampleRate ?? 48000)"] + sameCodec
        case .audioCompress:
            let compressed = audioCodecArguments(for: out, bitrate: out == source ? 96 : 160, encoders: encoders) ?? []
            body = ["-map", "0:a:0", "-vn"] + compressed
        case .audioMono:
            body = ["-map", "0:a:0", "-vn", "-ac", "1"] + sameCodec
        case .audioTrimSilence:
            let trim = "silenceremove=start_periods=1:start_threshold=-50dB"
            body = ["-map", "0:a:0", "-vn", "-af", "\(trim),areverse,\(trim),areverse"] + sameCodec
        case .stripMetadata:
            let streams = source.kind == .audio ? ["-map", "0:a"] : ["-map", "0:v?", "-map", "0:a?"]
            body = streams + ["-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"]
        default:
            return nil
        }
        return prefix(input: input) + body + [output]
    }
}

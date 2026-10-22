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

    static let x264Presets = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]

    static func h264(crf: Int, preset: String = "medium", filter: String = evenDimensions, encoders: EncoderSet = .all,
                     preference: VideoEncoderPreference = .automatic) -> [String] {
        let x264 = ["-c:v", "libx264", "-preset", x264Presets.contains(preset) ? preset : "medium",
                    "-crf", "\(crf)", "-pix_fmt", "yuv420p", "-vf", filter]
        // Apple's hardware encoder is always present on macOS builds; it takes a bitrate, not a CRF.
        let bitrate = crf <= 20 ? "10M" : crf <= 24 ? "6M" : "3M"
        let videoToolbox = ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-pix_fmt", "yuv420p", "-vf", filter]
        let order: [(String, [String])]
        switch preference {
        case .automatic: order = [("libx264", x264), ("h264_videotoolbox", videoToolbox)]
        case .hardware: order = [("h264_videotoolbox", videoToolbox), ("libx264", x264)]
        case .software: order = [("libx264", x264)]
        }
        for (encoder, args) in order where encoders.has(encoder) { return args }
        return ["-c:v", "mpeg4", "-q:v", "\(max(2, min(31, crf / 5)))", "-pix_fmt", "yuv420p", "-vf", filter]
    }

    /// WebM video encoder arguments. `filter` is only added when scaling was asked for.
    static func webmVideoArguments(crf: Int, filter: String?, encoders: EncoderSet) -> [String] {
        let scale = filter.map { ["-vf", $0] } ?? []
        if encoders.has("libvpx-vp9") {
            return ["-c:v", "libvpx-vp9", "-crf", "\(min(crf + 8, 63))", "-b:v", "0", "-row-mt", "1",
                    "-deadline", "good", "-cpu-used", "4"] + scale
        }
        if encoders.has("libsvtav1") {
            return ["-c:v", "libsvtav1", "-crf", "\(min(crf + 12, 63))", "-preset", "8", "-vf", filter ?? evenDimensions]
        }
        if encoders.has("libaom-av1") {
            return ["-c:v", "libaom-av1", "-crf", "\(min(crf + 12, 63))", "-b:v", "0", "-cpu-used", "8", "-row-mt", "1"] + scale
        }
        return ["-c:v", "libvpx", "-crf", "\(min(crf + 8, 63))", "-b:v", "1M"] + scale
    }

    static func webmAudioArguments(encoders: EncoderSet) -> [String] {
        if let audio = encoders.first("libopus", "libvorbis") { return ["-c:a", audio, "-b:a", "128k"] }
        return ["-c:a", "opus", "-strict", "experimental", "-ar", "48000", "-b:a", "128k"]
    }

    /// Scale filter honouring the maximum height; nil when no limit is set.
    static func scaleFilter(maxHeight: Int) -> String? {
        maxHeight > 0 ? "scale=-2:'min(\(maxHeight),trunc(ih/2)*2)'" : nil
    }

    static func videoArguments(target: Format, probe: MediaProbe?, options: ConversionOptions, encoders: EncoderSet = .all) -> [String] {
        let maps = options.removeAudio ? ["-map", "0:v:0"] : ["-map", "0:v:0", "-map", "0:a?"]
        func audio(_ args: [String]) -> [String] { options.removeAudio ? ["-an"] : args }
        let scale = scaleFilter(maxHeight: options.maxVideoHeight)
        let fitsHeight = options.maxVideoHeight == 0 || (probe?.height ?? Int.max) <= options.maxVideoHeight
        if let probe, canRemux(probe, into: target), fitsHeight, options.maxFrameRate == 0 {
            var args = maps + ["-c", "copy"]
            if probe.videoCodec == "hevc", [.mp4, .m4v, .mov].contains(target) { args += ["-tag:v", "hvc1"] }
            if [.mp4, .m4v, .mov].contains(target) { args += ["-movflags", "+faststart"] }
            return args
        }
        let fps = options.maxFrameRate > 0 ? ["-fpsmax", "\(options.maxFrameRate)"] : []
        let videoCodec = Self.h264(crf: options.videoCRF, preset: options.videoPreset, filter: scale ?? evenDimensions,
                                        encoders: encoders, preference: options.videoEncoder) + fps
        let aac = ["-c:a", "aac", "-b:a", "160k"]
        let scaleArgs = scale.map { ["-vf", $0] } ?? []
        switch target {
        case .mp4, .m4v, .mov:
            return maps + videoCodec + audio(aac) + ["-movflags", "+faststart"]
        case .mkv:
            return maps + videoCodec + audio(aac)
        case .webm:
            return maps + webmVideoArguments(crf: options.videoCRF, filter: scale, encoders: encoders) + fps
                + audio(webmAudioArguments(encoders: encoders))
        case .avi:
            let mp3 = encoders.has("libmp3lame") ? ["-c:a", "libmp3lame", "-b:a", "192k"] : ["-c:a", "ac3", "-b:a", "192k"]
            return maps + ["-c:v", "mpeg4", "-q:v", "4"] + scaleArgs + fps + audio(mp3)
        case .wmv:
            return maps + ["-c:v", "wmv2", "-b:v", "4M"] + scaleArgs + fps + audio(["-c:a", "wmav2", "-b:a", "192k"])
        case .gif:
            return ["-map", "0:v:0", "-vf", gifFilter(fps: options.gifFPS, maxWidth: options.gifMaxWidth), "-loop", "0"]
        default:
            return maps
        }
    }

    /// Sample rate, channels and loudness options for audio conversions.
    static func audioExtras(target: Format, probe: MediaProbe?, options: ConversionOptions, codec: [String],
                            encoders: EncoderSet) -> [String] {
        var args: [String] = []
        if options.normalizeAudio { args += ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] }
        // Some fallback encoders pin the channel count themselves (native Vorbis is stereo-only).
        if options.audioChannels > 0, !codec.contains("-ac") { args += ["-ac", "\(options.audioChannels)"] }
        var rate = options.audioSampleRate
        // loudnorm resamples to 192 kHz; go back to the source rate unless one was chosen.
        if options.normalizeAudio, rate == 0 { rate = probe?.sampleRate ?? 48000 }
        // Opus only takes 48/24/16/12/8 kHz.
        let isOpus = target == .opus || (target == .ogg && !encoders.has("libvorbis"))
        if isOpus { rate = options.normalizeAudio ? 48000 : 0 }
        if rate > 0 { args += ["-ar", "\(rate)"] }
        return args
    }

    /// Metadata handling for converted media.
    static func metadataArguments(_ policy: MetadataPolicy, audio: Bool) -> [String] {
        switch policy {
        case .keep: return audio ? ["-map_metadata", "0"] : []
        case .removeAll: return ["-map_metadata", "-1"]
        case .removeLocation:
            return (audio ? ["-map_metadata", "0"] : []) + ["-metadata", "location=", "-metadata", "location-eng="]
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
            args += ["-map", "0:a:0", "-vn"] + codec
                + audioExtras(target: target, probe: probe, options: options, codec: codec, encoders: encoders)
                + metadataArguments(options.metadata, audio: true)
        } else if target.kind == .subtitle {
            args += ["-map", "0:s:0?"]
        } else {
            args += videoArguments(target: target, probe: probe, options: options, encoders: encoders)
            if target != .gif { args += metadataArguments(options.metadata, audio: false) }
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
            body = maps + h264(crf: 28, preset: "slow", encoders: encoders, preference: options.videoEncoder) + ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        case .video720p:
            body = maps + h264(crf: options.videoCRF, filter: "scale=-2:'min(720,trunc(ih/2)*2)'", encoders: encoders,
                                preference: options.videoEncoder) + aacAudio
        case .videoMute:
            body = ["-map", "0:v", "-c:v", "copy", "-an"]
        case .videoExtractAudio:
            body = probe?.audioCodec == "aac"
                ? ["-map", "0:a:0", "-vn", "-c:a", "copy"]
                : ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k"]
        case .videoRotate:
            body = maps + h264(crf: options.videoCRF, filter: "transpose=1," + evenDimensions, encoders: encoders,
                                preference: options.videoEncoder) + aacAudio
        case .videoSpeedUp:
            body = maps + ["-filter:a", "atempo=2.0"]
                + h264(crf: options.videoCRF, filter: "setpts=0.5*PTS," + evenDimensions, encoders: encoders,
                       preference: options.videoEncoder) + aacAudio
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

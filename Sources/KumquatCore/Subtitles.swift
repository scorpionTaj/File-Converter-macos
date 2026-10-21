import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// SRT ⇄ WebVTT conversion.
public enum Subtitles {
    /// Parses SRT or WebVTT. Both are "timing line, then text until a blank line", so one parser serves both.
    public static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.contains("-->"), let timing = parseTiming(line) else {
                index += 1
                continue
            }
            index += 1
            var textLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index])
                index += 1
            }
            cues.append(SubtitleCue(start: timing.start, end: timing.end, text: textLines.joined(separator: "\n")))
        }
        return cues
    }

    static func parseTiming(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        // WebVTT may append cue settings after the end time ("00:01.000 align:start").
        let endText = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }
        return (start, end)
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm` and `MM:SS.mmm`.
    public static func parseTimestamp(_ text: String) -> TimeInterval? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    public static func formatTimestamp(_ seconds: TimeInterval, millisecondSeparator: String) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let ms = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d", h, m, s) + millisecondSeparator + String(format: "%03d", ms)
    }

    public static func srt(from cues: [SubtitleCue]) -> String {
        cues.enumerated().map { offset, cue in
            "\(offset + 1)\n\(formatTimestamp(cue.start, millisecondSeparator: ",")) --> \(formatTimestamp(cue.end, millisecondSeparator: ","))\n\(stripVTTTags(cue.text))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(from cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(formatTimestamp(cue.start, millisecondSeparator: ".")) --> \(formatTimestamp(cue.end, millisecondSeparator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func plainText(from cues: [SubtitleCue]) -> String {
        cues.map { stripAllTags($0.text) }.joined(separator: "\n") + "\n"
    }

    /// Removes WebVTT-only markup (voice spans, classes, inline timestamps) that SRT players don't understand.
    static func stripVTTTags(_ text: String) -> String {
        text.replacingOccurrences(of: "</?(v|c|lang|ruby|rt)(\\.[^ >]*)?( [^>]*)?>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<\\d{2}:[\\d:.]+>", with: "", options: .regularExpression)
    }

    static func stripAllTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }
}

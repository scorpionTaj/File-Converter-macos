import Foundation

/// "1, 3-5, 8-" → zero-based page indices, in document order without duplicates.
public enum PageRanges {
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        var pages = Set<Int>()
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
        for rawPart in parts {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let lower: Int
            let upper: Int
            if bounds.count == 2 {
                lower = bounds[0].isEmpty ? 1 : try number(bounds[0], in: text)
                upper = bounds[1].isEmpty ? pageCount : try number(bounds[1], in: text)
            } else {
                lower = try number(bounds[0], in: text)
                upper = lower
            }
            guard lower >= 1, upper <= pageCount, lower <= upper else {
                throw KumquatError.invalidInput(L("“\(part)” is outside pages 1–\(pageCount)."))
            }
            for page in lower...upper { pages.insert(page - 1) }
        }
        guard !pages.isEmpty else { throw KumquatError.invalidInput(L("No pages given.")) }
        return pages.sorted()
    }

    private static func number(_ text: String, in input: String) throws -> Int {
        guard let value = Int(text) else { throw KumquatError.invalidInput(L("“\(input)” isn't a page list like 1, 3-5.")) }
        return value
    }
}

/// "50%", "1280", "1280x720", "x720".
public enum ResizeSpec: Equatable, Sendable {
    case scale(Double)
    case width(Int)
    case height(Int)
    case fit(width: Int, height: Int)

    public static func parse(_ text: String) throws -> ResizeSpec {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "px", with: "")
        if cleaned.hasSuffix("%"), let percent = Double(cleaned.dropLast()), percent > 0, percent <= 1000 {
            return .scale(percent / 100)
        }
        if cleaned.contains("x") {
            let parts = cleaned.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let width = Int(parts[0]), height = parts.count > 1 ? Int(parts[1]) : nil
            switch (width, height) {
            case let (w?, h?) where w > 0 && h > 0: return .fit(width: w, height: h)
            case let (w?, nil) where w > 0 && parts[1].isEmpty: return .width(w)
            case let (nil, h?) where h > 0 && parts[0].isEmpty: return .height(h)
            default: break
            }
        } else if let width = Int(cleaned), width > 0 {
            return .width(width)
        }
        throw KumquatError.invalidInput(L("“\(text)” isn't a size. Try 50%, 1280 or 1280x720."))
    }

    /// Target pixel size for an image, keeping the aspect ratio.
    public func size(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        let factor: Double
        switch self {
        case .scale(let scale): factor = scale
        case .width(let target): factor = Double(target) / w
        case .height(let target): factor = Double(target) / h
        case .fit(let tw, let th): factor = min(Double(tw) / w, Double(th) / h)
        }
        return (max(Int((w * factor).rounded()), 1), max(Int((h * factor).rounded()), 1))
    }
}

/// "0:05-1:30", "5-", "1:02:03.5-1:05:00" → seconds.
public struct TimeRange: Equatable, Sendable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double?) {
        self.start = start
        self.end = end
    }

    public static func parse(_ text: String) throws -> TimeRange {
        let cleaned = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "–", with: "-")
        let parts = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw invalid(text) }
        let start = parts[0].isEmpty ? 0 : try seconds(parts[0], text)
        let end = parts[1].isEmpty ? nil : try seconds(parts[1], text)
        if let end, end <= start { throw KumquatError.invalidInput(L("The end must be after the start.")) }
        return TimeRange(start: start, end: end)
    }

    static func seconds(_ text: String, _ input: String) throws -> Double {
        let components = text.split(separator: ":").map { Double($0) }
        guard (1...3).contains(components.count), components.allSatisfy({ ($0 ?? -1) >= 0 }) else { throw invalid(input) }
        return components.reduce(0) { $0 * 60 + $1! }
    }

    static func invalid(_ text: String) -> KumquatError {
        .invalidInput(L("“\(text)” isn't a time range. Try 0:05-1:30."))
    }

    /// The text `parse` reads back: "12.400-18.000", or "12.400-" when it runs to the end.
    public var spec: String {
        String(format: "%.3f-", start) + (end.map { String(format: "%.3f", $0) } ?? "")
    }

    /// FFmpeg timestamp, e.g. "65.250".
    public static func ffmpegTime(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}

/// "3, 1-2, 5r90, 8-6" → pages in a new order, each with an extra clockwise rotation. Pages that aren't
/// listed are left out; a page may appear more than once (duplicated). Descending ranges reverse.
public enum PageArrangement {
    public struct Entry: Equatable, Sendable {
        /// Zero-based page index in the source document.
        public var page: Int
        /// Extra clockwise rotation: 0, 90, 180 or 270.
        public var rotation: Int

        public init(page: Int, rotation: Int = 0) {
            self.page = page
            self.rotation = ((rotation % 360) + 360) % 360
        }
    }

    public static func parse(_ text: String, pageCount: Int) throws -> [Entry] {
        var entries: [Entry] = []
        for rawPart in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            var part = rawPart.trimmingCharacters(in: .whitespaces).lowercased()
            guard !part.isEmpty else { continue }
            var rotation = 0
            if let marker = part.firstIndex(of: "r") {
                guard let degrees = Int(part[part.index(after: marker)...]), [0, 90, 180, 270, -90].contains(degrees) else {
                    throw KumquatError.invalidInput(L("“\(rawPart)”: rotation must be r90, r180 or r270."))
                }
                rotation = degrees
                part = String(part[..<marker]).trimmingCharacters(in: .whitespaces)
            }
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = Int(bounds[0]), bounds.count == 1 || Int(bounds[1]) != nil else {
                throw KumquatError.invalidInput(L("“\(text)” isn't a page order like 3, 1-2, 4r90."))
            }
            let last = bounds.count == 2 ? Int(bounds[1])! : first
            guard (1...pageCount).contains(first), (1...pageCount).contains(last) else {
                throw KumquatError.invalidInput(L("“\(rawPart.trimmingCharacters(in: .whitespaces))” is outside pages 1–\(pageCount)."))
            }
            let pages = first <= last ? Array(first...last) : Array((last...first).reversed())
            entries += pages.map { Entry(page: $0 - 1, rotation: rotation) }
        }
        guard !entries.isEmpty else { throw KumquatError.invalidInput(L("No pages given.")) }
        return entries
    }

    /// The spec for `entries`, compressing consecutive unrotated runs ("1-3, 5r90").
    public static func format(_ entries: [Entry]) -> String {
        var parts: [String] = []
        var index = 0
        while index < entries.count {
            let start = entries[index]
            var end = index
            while end + 1 < entries.count, entries[end + 1].rotation == start.rotation,
                  entries[end + 1].page == entries[end].page + 1 { end += 1 }
            let range = end > index ? "\(start.page + 1)-\(entries[end].page + 1)" : "\(start.page + 1)"
            parts.append(start.rotation == 0 ? range : "\(range)r\(start.rotation)")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }
}

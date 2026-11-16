import Foundation

// MARK: Favourites and recents

/// Per-file-type wheel order: pinned items first, then recently used ones, then the usual order.
public struct WheelPreferences: Codable, Equatable, Sendable {
    /// Item ids pinned to the front, in pin order, keyed by `sourceKey`.
    public var pinned: [String: [String]] = [:]
    /// Most recently used item ids, newest first, keyed by `sourceKey`.
    public var recent: [String: [String]] = [:]
    public var recentFirst = true

    public static let recentLimit = 6

    public init() {}

    /// "jpg" when every input is a JPG; the shared kind ("image") for a mixed drop of one kind; "mixed" otherwise.
    public static func sourceKey(for inputs: [URL]) -> String {
        let formats = Set(inputs.map { FormatRegistry.format(for: $0)?.id ?? "?" })
        if formats.count == 1, let only = formats.first { return only }
        let kinds = Set(inputs.map { FormatRegistry.kind(for: $0) })
        if kinds.count == 1, let only = kinds.first { return only.rawValue }
        return "mixed"
    }

    public func isPinned(_ id: String, source: String) -> Bool {
        pinned[source]?.contains(id) ?? false
    }

    public mutating func togglePin(_ id: String, source: String) {
        var ids = pinned[source] ?? []
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        pinned[source] = ids.isEmpty ? nil : ids
    }

    public mutating func noteUsed(_ id: String, source: String) {
        var ids = recent[source] ?? []
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        recent[source] = Array(ids.prefix(Self.recentLimit))
    }

    /// Items in wheel order, with pinned ones marked.
    public func ordered(_ items: [WheelItem], source: String) -> [WheelItem] {
        let pins = pinned[source] ?? []
        let recents = recentFirst ? (recent[source] ?? []) : []
        func rank(_ item: WheelItem) -> (Int, Int) {
            if let index = pins.firstIndex(of: item.id) { return (0, index) }
            if let index = recents.firstIndex(of: item.id) { return (1, index) }
            return (2, 0)
        }
        // Stable sort: unranked items keep their usual order.
        return items.enumerated()
            .sorted { lhs, rhs in
                let a = rank(lhs.element), b = rank(rhs.element)
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map { entry in
                var item = entry.element
                item.isPinned = pins.contains(item.id)
                return item
            }
    }
}

// MARK: Option overrides

/// Settings that override the defaults for one conversion: from a preset, the options sheet, or a format's
/// remembered choices. Nil means "use the default".
public struct OptionOverrides: Codable, Hashable, Sendable {
    /// 0...1, for lossy image formats.
    public var quality: Double?
    public var maxImageDimension: Int?
    public var videoCRF: Int?
    public var maxVideoHeight: Int?
    public var removeAudio: Bool?
    public var audioBitrateKbps: Int?
    /// Pages to render when converting a PDF to images, e.g. "1, 3-5".
    public var pdfPages: String?

    public init(quality: Double? = nil, maxImageDimension: Int? = nil, videoCRF: Int? = nil, maxVideoHeight: Int? = nil,
                removeAudio: Bool? = nil, audioBitrateKbps: Int? = nil, pdfPages: String? = nil) {
        self.quality = quality
        self.maxImageDimension = maxImageDimension
        self.videoCRF = videoCRF
        self.maxVideoHeight = maxVideoHeight
        self.removeAudio = removeAudio
        self.audioBitrateKbps = audioBitrateKbps
        self.pdfPages = pdfPages
    }

    public var isEmpty: Bool { self == OptionOverrides() }

    /// `other`'s values win where it has them.
    public func merged(with other: OptionOverrides) -> OptionOverrides {
        OptionOverrides(quality: other.quality ?? quality,
                        maxImageDimension: other.maxImageDimension ?? maxImageDimension,
                        videoCRF: other.videoCRF ?? videoCRF,
                        maxVideoHeight: other.maxVideoHeight ?? maxVideoHeight,
                        removeAudio: other.removeAudio ?? removeAudio,
                        audioBitrateKbps: other.audioBitrateKbps ?? audioBitrateKbps,
                        pdfPages: other.pdfPages ?? pdfPages)
    }

    public func apply(to options: inout ConversionOptions, target: Format) {
        if let quality { options.formatQuality[target.id] = min(max(quality, 0.05), 1) }
        if let maxImageDimension { options.maxImageDimension = max(maxImageDimension, 0) }
        if let videoCRF { options.videoCRF = min(max(videoCRF, 0), 51) }
        if let maxVideoHeight { options.maxVideoHeight = max(maxVideoHeight, 0) }
        if let removeAudio { options.removeAudio = removeAudio }
        if let audioBitrateKbps { options.audioBitrateKbps = max(audioBitrateKbps, 8) }
        if let pages = pdfPages?.trimmingCharacters(in: .whitespaces), !pages.isEmpty { options.pdfPageRange = pages }
    }

    /// "80% · 2048 px", for wheel details and lists.
    public var summary: String {
        var parts: [String] = []
        if let quality { parts.append("\(Int((quality * 100).rounded()))%") }
        if let maxImageDimension, maxImageDimension > 0 { parts.append("\(maxImageDimension) px") }
        if let videoCRF { parts.append("CRF \(videoCRF)") }
        if let maxVideoHeight, maxVideoHeight > 0 { parts.append("\(maxVideoHeight)p") }
        if removeAudio == true { parts.append("no audio") }
        if let audioBitrateKbps { parts.append("\(audioBitrateKbps) kbps") }
        if let pdfPages, !pdfPages.isEmpty { parts.append("pages \(pdfPages)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Presets

/// A saved conversion: a target format plus option overrides, shown as its own slice on the Convert wheel.
public struct OutputPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// `Format.id` of the result.
    public var target: String
    public var overrides: OptionOverrides

    public init(id: UUID = UUID(), name: String, target: String, overrides: OptionOverrides = OptionOverrides()) {
        self.id = id
        self.name = name
        self.target = target
        self.overrides = overrides
    }

    public var targetFormat: Format? { FormatRegistry.all.first { $0.id == target } }

    public var detail: String {
        let format = targetFormat?.name ?? target.uppercased()
        let summary = overrides.summary
        return summary.isEmpty ? "Convert to \(format)" : "\(format) · \(summary)"
    }
}

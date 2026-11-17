import Foundation

/// Identifies the engine responsible for one conversion hop.
public enum EngineID: String, CaseIterable, Codable, Sendable {
    case image, pdf, document, media, archive, data, subtitle, iwork, office, pandoc
    /// The user's own recipes (`UserRecipes`).
    case recipe
}

/// A single direct conversion an engine can perform.
public struct ConversionEdge: Hashable, Sendable, CustomStringConvertible {
    public let from: Format
    public let to: Format
    public let engine: EngineID
    public let requires: Dependency?
    /// Relative preference; cheaper routes win. Higher-fidelity engines get lower costs.
    public let cost: Int

    public var description: String { "\(from.id)→\(to.id) [\(engine.rawValue)]" }
}

/// One or more hops from a source format to a target format.
public struct ConversionRoute: Sendable, CustomStringConvertible {
    public let edges: [ConversionEdge]

    public var source: Format { edges[0].from }
    public var target: Format { edges[edges.count - 1].to }
    public var requirements: Set<Dependency> { Set(edges.compactMap(\.requires)) }
    public var cost: Int { edges.reduce(0) { $0 + $1.cost } }

    public var description: String { edges.map(\.description).joined(separator: " , ") }
}

/// Directed graph of direct conversions. Multi-step conversions (e.g. XLSX → CSV → JSON)
/// are found by searching it, so adding one edge can light up many new conversions.
public struct ConversionGraph: Sendable {
    public let edges: [ConversionEdge]
    public let maxHops: Int
    private let outgoing: [String: [ConversionEdge]]

    public init(edges: [ConversionEdge], maxHops: Int = 3) {
        self.edges = edges
        self.maxHops = maxHops
        var outgoing: [String: [ConversionEdge]] = [:]
        for edge in edges { outgoing[edge.from.id, default: []].append(edge) }
        self.outgoing = outgoing
    }

    public static let standard = ConversionGraph(edges: StandardEdges.make())

    /// Cheapest route using only edges accepted by `isUsable`.
    public func route(from source: Format, to target: Format, where isUsable: (ConversionEdge) -> Bool = { _ in true }) -> ConversionRoute? {
        guard source != target else { return nil }
        var frontier: [String: (cost: Int, path: [ConversionEdge])] = [source.id: (0, [])]
        var bestCost: [String: Int] = [source.id: 0]
        var best: (cost: Int, path: [ConversionEdge])?

        for _ in 0..<maxHops {
            var next: [String: (cost: Int, path: [ConversionEdge])] = [:]
            // Sorted iteration keeps tie-breaking deterministic.
            for node in frontier.keys.sorted() {
                guard let entry = frontier[node] else { continue }
                for edge in outgoing[node] ?? [] where isUsable(edge) {
                    let cost = entry.cost + edge.cost
                    let path = entry.path + [edge]
                    if edge.to == target {
                        if best == nil || cost < best!.cost { best = (cost, path) }
                        continue
                    }
                    if edge.to == source { continue }
                    if let known = bestCost[edge.to.id], known <= cost { continue }
                    bestCost[edge.to.id] = cost
                    next[edge.to.id] = (cost, path)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return best.map { ConversionRoute(edges: $0.path) }
    }

    /// Route preferring installed dependencies; falls back to a route needing missing ones so the
    /// UI can explain what to install.
    public func bestRoute(from source: Format, to target: Format, engines: Set<EngineID>, available: Set<Dependency>) -> ConversionRoute? {
        if let ready = route(from: source, to: target, where: { edge in
            engines.contains(edge.engine) && (edge.requires.map { available.contains($0) } ?? true)
        }) {
            return ready
        }
        return route(from: source, to: target, where: { engines.contains($0.engine) })
    }

    /// Every format `source` can sensibly be converted to, in wheel order. A user recipe's target is always
    /// offered: the user asked for exactly that conversion.
    public func targets(for source: Format, engines: Set<EngineID> = Set(EngineID.allCases)) -> [Format] {
        let recipeTargets = engines.contains(.recipe)
            ? Set((outgoing[source.id] ?? []).filter { $0.engine == .recipe }.map(\.to)) : []
        return FormatRegistry.all
            .filter { TargetPolicy.allows(source: source, target: $0) || recipeTargets.contains($0) }
            .filter { route(from: source, to: $0, where: { engines.contains($0.engine) }) != nil }
    }

    /// Number of distinct (source, target) conversions.
    public func conversionCount(engines: Set<EngineID> = Set(EngineID.allCases)) -> Int {
        let sources = Set(edges.map(\.from))
        return sources.reduce(0) { $0 + targets(for: $1, engines: engines).count }
    }
}

/// Keeps multi-hop search from producing nonsense like JPG → PDF → TXT.
public enum TargetPolicy {
    public static func allows(source: Format, target: Format) -> Bool {
        if source == target { return false }
        switch source.kind {
        case .image:
            return target.kind == .image || target == .pdf || (source == .gif && target.kind == .video)
        case .audio:
            return target.kind == .audio
        case .video:
            return target.kind == .video || target.kind == .audio || target == .gif
        case .pdf:
            return target.kind == .image || target.kind == .document
        case .document:
            return target.kind == .document || target == .pdf
        case .presentation:
            return target.kind == .presentation || target == .pdf
        case .spreadsheet:
            return target.kind == .spreadsheet || [.pdf, .json, .html, .md].contains(target)
        case .subtitle:
            return target.kind == .subtitle || target == .txt
        case .archive:
            return target.kind == .archive
        case .data:
            return target.kind == .data || target == .csv
        case .folder, .other:
            return false
        }
    }
}

enum StandardEdges {
    static func make() -> [ConversionEdge] {
        var edges: [ConversionEdge] = []
        func add(_ from: [Format], _ to: [Format], _ engine: EngineID, requires: Dependency? = nil, cost: Int = 1) {
            for source in from {
                for target in to where source != target {
                    edges.append(ConversionEdge(from: source, to: target, engine: engine, requires: requires, cost: cost))
                }
            }
        }

        // Images (ImageIO; WebP/AVIF writing falls back to FFmpeg inside the engine when needed).
        add(Format.imageInputs, Format.imageOutputs + [.pdf], .image)
        add([.gif], [.mp4, .mov, .webm, .mkv], .media, requires: .ffmpeg)

        // Audio & video (FFmpeg).
        add(Format.audioInputs, Format.audioOutputs, .media, requires: .ffmpeg)
        add(Format.videoInputs, Format.videoOutputs + Format.audioOutputs + [.gif], .media, requires: .ffmpeg)

        // PDF (PDFKit).
        add([.pdf], [.png, .jpg, .heic, .tiff], .pdf)
        add([.pdf], [.txt, .rtf], .pdf)

        // Documents via the Cocoa text system.
        let nativeDocs: [Format] = [.docx, .doc, .rtf, .odt, .txt, .html, .md]
        add(nativeDocs, nativeDocs + [.pdf], .document, cost: 2)

        // LibreOffice: better layout fidelity, so it's preferred whenever installed.
        add([.docx, .doc, .odt, .rtf], [.pdf], .office, requires: .libreOffice, cost: 1)
        add([.pptx, .ppt, .odp], [.pdf, .pptx, .odp], .office, requires: .libreOffice)
        add([.xlsx, .xls, .ods, .csv], [.xlsx, .ods, .csv, .pdf], .office, requires: .libreOffice)

        // Pandoc.
        add([.md, .html, .docx, .odt], [.epub], .pandoc, requires: .pandoc)
        add([.epub], [.html, .md, .docx, .odt, .txt], .pandoc, requires: .pandoc)
        add([.docx, .odt, .html], [.md], .pandoc, requires: .pandoc, cost: 1)

        // iWork via AppleScript.
        add([.pages], [.pdf, .docx, .rtf, .txt, .epub], .iwork, requires: .pages)
        add([.docx, .doc, .rtf, .txt], [.pages], .iwork, requires: .pages)
        add([.key], [.pdf, .pptx], .iwork, requires: .keynote)
        add([.pptx, .ppt], [.key], .iwork, requires: .keynote)
        add([.pptx, .ppt], [.pdf], .iwork, requires: .keynote, cost: 2)
        add([.numbers], [.xlsx, .csv, .pdf], .iwork, requires: .numbers)
        add([.xlsx, .xls, .csv], [.numbers], .iwork, requires: .numbers)
        add([.xlsx, .xls], [.csv, .pdf], .iwork, requires: .numbers, cost: 2)

        // Structured data (pure Swift).
        add([.csv, .tsv], [.csv, .tsv, .json, .html, .md], .data)
        add([.json], [.csv, .plist], .data)
        add([.plist], [.json], .data)

        // Subtitles.
        add([.srt, .vtt], [.srt, .vtt, .txt], .subtitle)
        add([.ass], [.srt, .vtt], .media, requires: .ffmpeg)

        // Archives.
        add(Format.archiveInputs, Format.archiveOutputs, .archive)

        return edges
    }
}

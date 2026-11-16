import Foundation

/// The three wheels, each summoned by its own modifier key while dragging.
public enum WheelMode: String, CaseIterable, Codable, Sendable {
    case convert, tools, actions

    public var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
}

/// Input a tool needs from the user before it can run.
public enum ToolInput: Sendable, Equatable {
    case password(prompt: String)
    case text(prompt: String)
    /// A page order (`PageArrangement`); the app shows page thumbnails to arrange for a single PDF.
    case pages(prompt: String)

    public var prompt: String {
        switch self {
        case .password(let prompt), .text(let prompt), .pages(let prompt): return prompt
        }
    }
}

/// Editing tools shown on the Tools wheel.
public enum ToolID: String, CaseIterable, Codable, Sendable {
    // Images
    case imageCompress, imageResizeHalf, imageFit1920, imageRotateLeft, imageRotateRight, imageFlip
    case imageGrayscale, imageRemoveBackground, imageExtractText, imagesToPDF
    case imageAnnotate, imageResizeCustom, imagesToGIF
    // PDF
    case pdfCompress, pdfMerge, pdfSplit, pdfRotate, pdfExtractText, pdfOCR
    case pdfEncrypt, pdfDecrypt, pdfRedactPersonalInfo, pdfRedactText
    case pdfRemovePages, pdfExtractPages, pdfSearchable, pdfArrange, pdfAnnotate
    // Video
    case videoCompress, video720p, videoMute, videoExtractAudio, videoRotate, videoSpeedUp, videoFirstFrame
    // Audio
    case audioNormalize, audioCompress, audioMono, audioTrimSilence
    // Shared
    case mediaTrim, stripMetadata, extractArchive, compressZip, checksum, wordCount

    public var title: String {
        switch self {
        case .imageCompress, .pdfCompress, .videoCompress, .audioCompress: return "Compress"
        case .imageResizeHalf: return "Resize 50%"
        case .imageFit1920: return "Fit 1920px"
        case .imageRotateLeft: return "Rotate Left"
        case .imageRotateRight: return "Rotate Right"
        case .imageFlip: return "Flip"
        case .imageGrayscale: return "Grayscale"
        case .imageRemoveBackground: return "Remove BG"
        case .imageExtractText: return "Copy Text"
        case .imagesToPDF: return "Make PDF"
        case .imageAnnotate: return "Annotate…"
        case .imageResizeCustom: return "Resize…"
        case .imagesToGIF: return "Make GIF"
        case .pdfRemovePages: return "Remove Pages…"
        case .pdfExtractPages: return "Keep Pages…"
        case .mediaTrim: return "Trim…"
        case .pdfMerge: return "Merge"
        case .pdfSplit: return "Split Pages"
        case .pdfRotate, .videoRotate: return "Rotate"
        case .pdfExtractText: return "Extract Text"
        case .pdfOCR: return "OCR Text"
        case .pdfSearchable: return "Make Searchable"
        case .pdfArrange: return "Arrange Pages…"
        case .pdfAnnotate: return "Annotate…"
        case .pdfEncrypt: return "Add Password"
        case .pdfDecrypt: return "Unlock"
        case .pdfRedactPersonalInfo: return "Redact PII"
        case .pdfRedactText: return "Redact…"
        case .video720p: return "720p"
        case .videoMute: return "Mute"
        case .videoExtractAudio: return "Get Audio"
        case .videoSpeedUp: return "Speed 2×"
        case .videoFirstFrame: return "Poster Frame"
        case .audioNormalize: return "Normalize"
        case .audioMono: return "Mono"
        case .audioTrimSilence: return "Trim Silence"
        case .stripMetadata: return "Strip Metadata"
        case .extractArchive: return "Extract"
        case .compressZip: return "Zip"
        case .checksum: return "SHA-256"
        case .wordCount: return "Word Count"
        }
    }

    /// Longer description for the wheel's centre label.
    public var detail: String {
        switch self {
        case .imageCompress: return "Smaller file, same format"
        case .imageResizeHalf: return "Half the width and height"
        case .imageFit1920: return "Longest side at most 1920px"
        case .imageRotateLeft: return "Rotate 90° counter-clockwise"
        case .imageRotateRight: return "Rotate 90° clockwise"
        case .imageFlip: return "Mirror horizontally"
        case .imageGrayscale: return "Black & white copy"
        case .imageRemoveBackground: return "Cut out the subject (PNG)"
        case .imageExtractText: return "Recognise text and copy it"
        case .imagesToPDF: return "Combine images into one PDF"
        case .imageAnnotate: return "Draw, add text, highlight, pixelate, crop"
        case .imageResizeCustom: return "Choose a size or percentage"
        case .imagesToGIF: return "Animate the images as a GIF"
        case .pdfRemovePages: return "Delete a range of pages"
        case .pdfExtractPages: return "New PDF with only some pages"
        case .mediaTrim: return "Keep only part of the clip"
        case .pdfCompress: return "Downsample images inside the PDF"
        case .pdfMerge: return "Join PDFs in the order dropped"
        case .pdfSplit: return "One PDF per page"
        case .pdfRotate: return "Rotate every page 90°"
        case .pdfExtractText: return "Save the text layer as TXT"
        case .pdfOCR: return "Recognise text in scanned pages"
        case .pdfSearchable: return "Add a hidden text layer to scans (OCR)"
        case .pdfArrange: return "Reorder, rotate or drop pages"
        case .pdfAnnotate: return "Highlight, add notes, text and drawings"
        case .pdfEncrypt: return "Protect with a password"
        case .pdfDecrypt: return "Remove the password"
        case .pdfRedactPersonalInfo: return "Black out emails, phones, cards"
        case .pdfRedactText: return "Black out a word or phrase"
        case .videoCompress: return "H.264 at a smaller size"
        case .video720p: return "Scale down to 720p"
        case .videoMute: return "Remove the audio track"
        case .videoExtractAudio: return "Save the soundtrack as M4A"
        case .videoRotate: return "Rotate 90° clockwise"
        case .videoSpeedUp: return "Play twice as fast"
        case .videoFirstFrame: return "Save the first frame as PNG"
        case .audioNormalize: return "Even out loudness (−16 LUFS)"
        case .audioCompress: return "Lower bitrate copy"
        case .audioMono: return "Mix down to one channel"
        case .audioTrimSilence: return "Cut silence at both ends"
        case .stripMetadata: return "Remove location, camera & tags"
        case .extractArchive: return "Unpack next to the archive"
        case .compressZip: return "Compress into a ZIP"
        case .checksum: return "Copy the SHA-256 hash"
        case .wordCount: return "Count words & characters"
        }
    }

    public var symbol: String {
        switch self {
        case .imageCompress, .pdfCompress, .videoCompress, .audioCompress: return "arrow.down.right.and.arrow.up.left"
        case .imageResizeHalf: return "arrow.down.forward.and.arrow.up.backward"
        case .imageFit1920, .video720p: return "aspectratio"
        case .imageRotateLeft: return "rotate.left"
        case .imageRotateRight, .pdfRotate, .videoRotate: return "rotate.right"
        case .imageFlip: return "arrow.left.and.right"
        case .imageGrayscale: return "circle.lefthalf.filled"
        case .imageRemoveBackground: return "wand.and.stars"
        case .imageExtractText, .pdfOCR: return "text.viewfinder"
        case .pdfSearchable: return "doc.text.magnifyingglass"
        case .pdfArrange: return "square.grid.3x3.square"
        case .pdfAnnotate: return "highlighter"
        case .imagesToPDF: return "doc.richtext"
        case .imageAnnotate: return "pencil.tip.crop.circle"
        case .imageResizeCustom: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .imagesToGIF: return "square.stack.3d.forward.dottedline"
        case .pdfRemovePages: return "minus.rectangle"
        case .pdfExtractPages: return "doc.on.doc"
        case .mediaTrim: return "timeline.selection"
        case .pdfMerge: return "rectangle.stack"
        case .pdfSplit: return "square.split.2x1"
        case .pdfExtractText: return "text.alignleft"
        case .pdfEncrypt: return "lock"
        case .pdfDecrypt: return "lock.open"
        case .pdfRedactPersonalInfo, .pdfRedactText: return "eye.slash"
        case .videoMute: return "speaker.slash"
        case .videoExtractAudio: return "waveform"
        case .videoSpeedUp: return "hare"
        case .videoFirstFrame: return "photo"
        case .audioNormalize: return "speaker.wave.3"
        case .audioMono: return "speaker"
        case .audioTrimSilence: return "scissors"
        case .stripMetadata: return "tag.slash"
        case .extractArchive: return "archivebox"
        case .compressZip: return "doc.zipper"
        case .checksum: return "number"
        case .wordCount: return "textformat.abc"
        }
    }

    /// Suffix appended to the output name, e.g. `photo (compressed).jpg`.
    public var outputSuffix: String? {
        switch self {
        case .imageCompress, .pdfCompress, .videoCompress, .audioCompress: return "compressed"
        case .imageResizeHalf: return "50%"
        case .imageFit1920: return "1920px"
        case .imageRotateLeft, .imageRotateRight, .pdfRotate, .videoRotate: return "rotated"
        case .imageFlip: return "flipped"
        case .imageGrayscale: return "grayscale"
        case .imageRemoveBackground: return "cutout"
        case .imageExtractText, .pdfExtractText, .pdfOCR: return "text"
        case .pdfEncrypt: return "protected"
        case .pdfDecrypt: return "unlocked"
        case .pdfRedactPersonalInfo, .pdfRedactText: return "redacted"
        case .video720p: return "720p"
        case .videoMute: return "muted"
        case .videoExtractAudio: return "audio"
        case .videoSpeedUp: return "2x"
        case .videoFirstFrame: return "frame"
        case .audioNormalize: return "normalized"
        case .audioMono: return "mono"
        case .audioTrimSilence: return "trimmed"
        case .stripMetadata: return "clean"
        case .imageAnnotate: return "annotated"
        case .imageResizeCustom: return "resized"
        case .pdfRemovePages: return "edited"
        case .pdfExtractPages: return "pages"
        case .pdfSearchable: return "searchable"
        case .pdfArrange: return "arranged"
        case .pdfAnnotate: return "annotated"
        case .mediaTrim: return "trimmed"
        case .imagesToPDF, .imagesToGIF, .pdfMerge, .pdfSplit, .extractArchive, .compressZip, .checksum, .wordCount: return nil
        }
    }

    public var requirements: Set<Dependency> {
        switch self {
        case .videoCompress, .video720p, .videoMute, .videoExtractAudio, .videoRotate, .videoSpeedUp, .videoFirstFrame,
             .audioNormalize, .audioCompress, .audioMono, .audioTrimSilence, .mediaTrim:
            return [.ffmpeg]
        default:
            return []
        }
    }

    public var input: ToolInput? {
        switch self {
        case .pdfEncrypt: return .password(prompt: "Choose a password for the PDF")
        case .pdfDecrypt: return .password(prompt: "Enter the PDF's current password")
        case .pdfRedactText: return .text(prompt: "Text to black out (case-insensitive)")
        case .imageResizeCustom: return .text(prompt: "New size: a percentage (50%), a width (1280) or width×height (1280x720)")
        case .pdfRemovePages: return .text(prompt: "Pages to remove, e.g. 1, 3-5")
        case .pdfExtractPages: return .text(prompt: "Pages to keep, e.g. 2-4, 7")
        case .pdfArrange: return .pages(prompt: "New page order; pages left out are dropped. Add r90, r180 or r270 to turn a page, e.g. 3, 1-2, 4r90")
        case .mediaTrim: return .text(prompt: "Part to keep, e.g. 0:05-1:30 (leave the end empty to keep the rest)")
        default: return nil
        }
    }

    /// Minimum macOS major version, when newer than Kumquat's baseline.
    public var minimumMacOS: Int? {
        self == .imageRemoveBackground ? 14 : nil
    }

    /// Tools that combine all dropped files into one result.
    public var combinesInputs: Bool {
        [.imagesToPDF, .imagesToGIF, .pdfMerge, .compressZip].contains(self)
    }

    /// Tools that open a window in the app instead of running in the background.
    public var isInteractive: Bool {
        [.imageAnnotate, .pdfAnnotate].contains(self)
    }

    /// Whether the tool applies to this drop. `formats` has one entry per dropped item (nil for folders/unknown).
    public func applies(to formats: [Format?], kinds: [FileKind]) -> Bool {
        guard !formats.isEmpty else { return false }
        func all(_ kind: FileKind) -> Bool { kinds.allSatisfy { $0 == kind } }
        switch self {
        case .imageCompress, .imageResizeHalf, .imageFit1920, .imageRotateLeft, .imageRotateRight, .imageFlip,
             .imageGrayscale, .imageRemoveBackground, .imageExtractText:
            return all(.image)
        case .imagesToPDF, .imagesToGIF:
            return all(.image) && formats.count > 1
        case .imageAnnotate:
            return all(.image) && formats.count == 1
        case .imageResizeCustom:
            return all(.image)
        case .pdfRemovePages, .pdfExtractPages, .pdfSearchable, .pdfArrange:
            return all(.pdf)
        case .pdfAnnotate:
            return all(.pdf) && formats.count == 1
        case .mediaTrim:
            return all(.audio) || all(.video)
        case .pdfMerge:
            return all(.pdf) && formats.count > 1
        case .pdfCompress, .pdfSplit, .pdfRotate, .pdfExtractText, .pdfOCR, .pdfEncrypt, .pdfDecrypt,
             .pdfRedactPersonalInfo, .pdfRedactText:
            return all(.pdf)
        case .videoCompress, .video720p, .videoMute, .videoExtractAudio, .videoRotate, .videoSpeedUp, .videoFirstFrame:
            return all(.video)
        case .audioNormalize, .audioCompress, .audioMono, .audioTrimSilence:
            return all(.audio)
        case .stripMetadata:
            return kinds.allSatisfy { [.image, .pdf, .audio, .video].contains($0) }
        case .extractArchive:
            return all(.archive)
        case .compressZip:
            return !(formats.count == 1 && formats[0] == .zip)
        case .checksum:
            return !kinds.contains(.folder)
        case .wordCount:
            return formats.count == 1 && [.document, .pdf].contains(kinds[0])
        }
    }
}

/// File actions shown on the Actions wheel.
public enum ActionID: String, CaseIterable, Codable, Sendable {
    case airDrop, float, copy, move, copyTo, copyPath, terminal

    public var title: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move to…"
        case .copyTo: return "Copy to…"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }

    public var detail: String {
        switch self {
        case .airDrop: return "Send with AirDrop"
        case .float: return "Pin a preview above all windows"
        case .copy: return "Copy the file to the clipboard"
        case .move: return "Move to another folder"
        case .copyTo: return "Duplicate into another folder"
        case .copyPath: return "Copy the full path"
        case .terminal: return "Open a Terminal in this folder"
        }
    }

    public var symbol: String {
        switch self {
        case .airDrop: return "dot.radiowaves.left.and.right"
        case .float: return "pip"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyTo: return "folder.badge.plus"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        }
    }
}

/// One segment on a wheel.
public struct WheelItem: Identifiable, Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case convert(Format)
        case preset(OutputPreset)
        case tool(ToolID)
        case action(ActionID)
    }

    public let payload: Payload
    public let title: String
    public let detail: String
    public let symbol: String
    /// Why the item can't run right now (missing helper app, macOS too old). Nil when ready.
    public let unavailableReason: String?
    /// Pinned to the front of the wheel for this file type (see `WheelPreferences`).
    public var isPinned = false

    public var id: String {
        switch payload {
        case .convert(let format): return "convert.\(format.id)"
        case .preset(let preset): return "preset.\(preset.id.uuidString)"
        case .tool(let tool): return "tool.\(tool.rawValue)"
        case .action(let action): return "action.\(action.rawValue)"
        }
    }

    public var isAvailable: Bool { unavailableReason == nil }

    public init(payload: Payload, title: String, detail: String, symbol: String, unavailableReason: String? = nil) {
        self.payload = payload
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.unavailableReason = unavailableReason
    }
}

/// Decides what each wheel shows for a given drop.
public struct Catalog: Sendable {
    public let graph: ConversionGraph
    public let engines: Set<EngineID>
    public let available: Set<Dependency>
    public let macOSMajorVersion: Int

    public init(graph: ConversionGraph = .standard,
                engines: Set<EngineID>,
                available: Set<Dependency>,
                macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.graph = graph
        self.engines = engines
        self.available = available
        self.macOSMajorVersion = macOSMajorVersion
    }

    public func items(for mode: WheelMode, inputs: [URL]) -> [WheelItem] {
        switch mode {
        case .convert: return conversions(for: inputs)
        case .tools: return tools(for: inputs)
        case .actions: return actions(for: inputs)
        }
    }

    public func conversions(for inputs: [URL]) -> [WheelItem] {
        let formats = inputs.map(FormatRegistry.format(for:))
        guard !formats.isEmpty, formats.allSatisfy({ $0 != nil }) else { return [] }
        let sources = Array(Set(formats.compactMap { $0 }))
        // A file already in the target format is simply skipped, so it counts as compatible.
        func reachable(_ source: Format) -> Set<Format> {
            Set(graph.targets(for: source, engines: engines)).union([source])
        }
        var allowed = reachable(sources[0])
        for source in sources.dropFirst() { allowed.formIntersection(reachable(source)) }
        let targets = FormatRegistry.all.filter { target in
            allowed.contains(target) && sources.contains { $0 != target }
        }
        return targets.map { target in
            let missing = sources.reduce(into: Set<Dependency>()) { result, source in
                guard source != target else { return }
                if let route = graph.bestRoute(from: source, to: target, engines: engines, available: available) {
                    result.formUnion(route.requirements.subtracting(available))
                }
            }
            return WheelItem(payload: .convert(target),
                             title: target.shortName,
                             detail: "Convert to \(target.name)",
                             symbol: target.kind.symbol,
                             unavailableReason: Self.reason(for: missing))
        }
    }

    /// Presets whose format the dropped files can be converted to, shown on the Convert wheel.
    public func presets(_ presets: [OutputPreset], for inputs: [URL]) -> [WheelItem] {
        let reachable = Dictionary(uniqueKeysWithValues: conversions(for: inputs).compactMap { item -> (String, WheelItem)? in
            guard case .convert(let format) = item.payload else { return nil }
            return (format.id, item)
        })
        return presets.compactMap { preset in
            guard let conversion = reachable[preset.target], let format = preset.targetFormat else { return nil }
            return WheelItem(payload: .preset(preset), title: preset.name, detail: preset.detail,
                             symbol: format.kind == .image ? "star.square" : "star.circle",
                             unavailableReason: conversion.unavailableReason)
        }
    }

    public func tools(for inputs: [URL]) -> [WheelItem] {
        let formats = inputs.map(FormatRegistry.format(for:))
        let kinds = inputs.map(FormatRegistry.kind(for:))
        return ToolID.allCases
            .filter { $0.applies(to: formats, kinds: kinds) }
            .map { tool in
                var reason = Self.reason(for: tool.requirements.subtracting(available))
                if let minimum = tool.minimumMacOS, macOSMajorVersion < minimum {
                    reason = "Requires macOS \(minimum)"
                }
                return WheelItem(payload: .tool(tool), title: tool.title, detail: tool.detail,
                                 symbol: tool.symbol, unavailableReason: reason)
            }
    }

    public func actions(for inputs: [URL]) -> [WheelItem] {
        guard !inputs.isEmpty else { return [] }
        return ActionID.allCases.map {
            WheelItem(payload: .action($0), title: $0.title, detail: $0.detail, symbol: $0.symbol)
        }
    }

    static func reason(for missing: Set<Dependency>) -> String? {
        guard !missing.isEmpty else { return nil }
        let sorted = missing.sorted { $0.rawValue < $1.rawValue }
        return "Needs " + sorted.map { "\($0.displayName) — \($0.installHint)" }.joined(separator: "; ")
    }
}

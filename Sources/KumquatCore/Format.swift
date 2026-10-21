import Foundation

/// Broad family a file belongs to. Drives which conversions, tools and actions the wheel offers.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case image, audio, video, pdf, document, presentation, spreadsheet, subtitle, archive, data, folder, other

    public var displayName: String {
        switch self {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .presentation: return "Presentation"
        case .spreadsheet: return "Spreadsheet"
        case .subtitle: return "Subtitles"
        case .archive: return "Archive"
        case .data: return "Data"
        case .folder: return "Folder"
        case .other: return "File"
        }
    }

    /// SF Symbol used for format items of this kind.
    public var symbol: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .presentation: return "rectangle.on.rectangle"
        case .spreadsheet: return "tablecells"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .data: return "curlybraces"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }
}

/// A file format Kumquat knows how to read and/or write.
///
/// Identity is the canonical `id` (usually the preferred extension), so two values with the same
/// id compare equal regardless of their other fields.
public struct Format: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let id: String
    public let name: String
    public let kind: FileKind
    /// All recognised extensions, lowercased, preferred first. May contain compound
    /// extensions such as `tar.gz`.
    public let extensions: [String]

    public init(_ id: String, _ name: String, _ kind: FileKind, _ extensions: [String]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.extensions = extensions ?? [id]
    }

    /// Extension used when writing this format.
    public var fileExtension: String { extensions[0] }

    /// Compact label for the wheel, e.g. "JPG", "TAR.GZ".
    public var shortName: String { fileExtension.uppercased() }

    public var description: String { name }

    public static func == (lhs: Format, rhs: Format) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Known formats

extension Format {
    // Images
    public static let jpg = Format("jpg", "JPEG", .image, ["jpg", "jpeg", "jpe", "jfif"])
    public static let png = Format("png", "PNG", .image)
    public static let heic = Format("heic", "HEIC", .image, ["heic", "heif", "hif"])
    public static let tiff = Format("tiff", "TIFF", .image, ["tiff", "tif"])
    public static let webp = Format("webp", "WebP", .image)
    public static let avif = Format("avif", "AVIF", .image)
    public static let bmp = Format("bmp", "BMP", .image)
    public static let gif = Format("gif", "GIF", .image)
    public static let ico = Format("ico", "Windows Icon", .image)
    public static let icns = Format("icns", "macOS Icon", .image)
    public static let jp2 = Format("jp2", "JPEG 2000", .image, ["jp2", "j2k", "jpf"])
    public static let psd = Format("psd", "Photoshop", .image)
    public static let svg = Format("svg", "SVG", .image)
    public static let tga = Format("tga", "TGA", .image)
    public static let raw = Format("raw", "Camera RAW", .image,
                                   ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef"])

    // Audio
    public static let mp3 = Format("mp3", "MP3", .audio)
    public static let m4a = Format("m4a", "M4A (AAC)", .audio)
    public static let aac = Format("aac", "AAC", .audio)
    public static let wav = Format("wav", "WAV", .audio)
    public static let flac = Format("flac", "FLAC", .audio)
    public static let ogg = Format("ogg", "Ogg Vorbis", .audio, ["ogg", "oga"])
    public static let opus = Format("opus", "Opus", .audio)
    public static let aiff = Format("aiff", "AIFF", .audio, ["aiff", "aif"])
    public static let wma = Format("wma", "WMA", .audio)
    public static let caf = Format("caf", "Core Audio", .audio)

    // Video
    public static let mp4 = Format("mp4", "MP4", .video)
    public static let mov = Format("mov", "QuickTime", .video)
    public static let mkv = Format("mkv", "Matroska", .video)
    public static let webm = Format("webm", "WebM", .video)
    public static let avi = Format("avi", "AVI", .video)
    public static let wmv = Format("wmv", "WMV", .video)
    public static let m4v = Format("m4v", "M4V", .video)
    public static let flv = Format("flv", "Flash Video", .video)
    public static let mpeg = Format("mpeg", "MPEG", .video, ["mpg", "mpeg"])
    public static let threeGP = Format("3gp", "3GP", .video)
    public static let mts = Format("mts", "AVCHD", .video, ["mts", "m2ts"])

    // PDF
    public static let pdf = Format("pdf", "PDF", .pdf)

    // Documents
    public static let docx = Format("docx", "Word", .document)
    public static let doc = Format("doc", "Word 97", .document)
    public static let rtf = Format("rtf", "Rich Text", .document)
    public static let odt = Format("odt", "OpenDocument Text", .document)
    public static let txt = Format("txt", "Plain Text", .document, ["txt", "text"])
    public static let html = Format("html", "HTML", .document, ["html", "htm"])
    public static let md = Format("md", "Markdown", .document, ["md", "markdown", "mdown", "mkd"])
    public static let pages = Format("pages", "Pages", .document)
    public static let epub = Format("epub", "EPUB", .document)

    // Presentations
    public static let pptx = Format("pptx", "PowerPoint", .presentation)
    public static let ppt = Format("ppt", "PowerPoint 97", .presentation)
    public static let key = Format("key", "Keynote", .presentation)
    public static let odp = Format("odp", "OpenDocument Slides", .presentation)

    // Spreadsheets
    public static let xlsx = Format("xlsx", "Excel", .spreadsheet)
    public static let xls = Format("xls", "Excel 97", .spreadsheet)
    public static let csv = Format("csv", "CSV", .spreadsheet)
    public static let tsv = Format("tsv", "TSV", .spreadsheet)
    public static let numbers = Format("numbers", "Numbers", .spreadsheet)
    public static let ods = Format("ods", "OpenDocument Sheet", .spreadsheet)

    // Subtitles
    public static let srt = Format("srt", "SubRip", .subtitle)
    public static let vtt = Format("vtt", "WebVTT", .subtitle)
    public static let ass = Format("ass", "Advanced SubStation", .subtitle, ["ass", "ssa"])

    // Archives
    public static let zip = Format("zip", "ZIP", .archive)
    public static let tar = Format("tar", "TAR", .archive)
    public static let tgz = Format("tgz", "TAR.GZ", .archive, ["tar.gz", "tgz"])
    public static let tbz = Format("tbz", "TAR.BZ2", .archive, ["tar.bz2", "tbz2", "tbz"])
    public static let txz = Format("txz", "TAR.XZ", .archive, ["tar.xz", "txz"])
    public static let gz = Format("gz", "GZIP", .archive)
    public static let sevenZip = Format("7z", "7-Zip", .archive)
    public static let rar = Format("rar", "RAR", .archive)

    // Data
    public static let json = Format("json", "JSON", .data)
    public static let plist = Format("plist", "Property List", .data)
}

// MARK: - Format groups

extension Format {
    public static let imageInputs: [Format] = [.jpg, .png, .heic, .tiff, .webp, .avif, .bmp, .gif, .ico, .icns, .jp2, .psd, .svg, .raw, .tga]
    public static let imageOutputs: [Format] = [.jpg, .png, .heic, .webp, .avif, .tiff, .gif, .bmp, .ico, .icns, .jp2]

    public static let audioInputs: [Format] = [.mp3, .m4a, .aac, .wav, .flac, .ogg, .opus, .aiff, .wma, .caf]
    public static let audioOutputs: [Format] = [.mp3, .m4a, .wav, .flac, .aac, .ogg, .opus, .aiff, .wma]

    public static let videoInputs: [Format] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v, .flv, .mpeg, .threeGP, .mts]
    public static let videoOutputs: [Format] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v]

    public static let archiveInputs: [Format] = [.zip, .tar, .tgz, .tbz, .txz, .gz, .sevenZip, .rar]
    public static let archiveOutputs: [Format] = [.zip, .tar, .tgz, .tbz, .txz]
}

// MARK: - Registry

public enum FormatRegistry {
    /// Every known format, in the order the wheel presents them (most common first within a kind).
    public static let all: [Format] = {
        var seen = Set<String>()
        let ordered: [Format] = Format.imageOutputs + Format.imageInputs + [.pdf]
            + Format.audioOutputs + Format.audioInputs
            + Format.videoOutputs + Format.videoInputs
            + [.docx, .pages, .rtf, .txt, .md, .html, .odt, .doc, .epub]
            + [.pptx, .key, .odp, .ppt]
            + [.xlsx, .numbers, .csv, .tsv, .ods, .xls]
            + [.srt, .vtt, .ass]
            + Format.archiveOutputs + Format.archiveInputs
            + [.json, .plist]
        return ordered.filter { seen.insert($0.id).inserted }
    }()

    private static let byID: [String: Format] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byExtension: [String: Format] = {
        var map: [String: Format] = [:]
        for format in all {
            for ext in format.extensions where map[ext] == nil {
                map[ext] = format
            }
        }
        return map
    }()

    private static let compoundExtensions: [(String, Format)] = all.flatMap { format in
        format.extensions.filter { $0.contains(".") }.map { ($0, format) }
    }

    public static func format(id: String) -> Format? {
        byID[id.lowercased()]
    }

    public static func format(forExtension ext: String) -> Format? {
        byExtension[ext.lowercased()]
    }

    public static func format(for url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        for (ext, format) in compoundExtensions where name.hasSuffix("." + ext) {
            return format
        }
        let ext = url.pathExtension
        return ext.isEmpty ? nil : format(forExtension: ext)
    }

    /// Order index used to sort targets on the wheel.
    public static func order(of format: Format) -> Int {
        all.firstIndex(of: format) ?? Int.max
    }

    public static func kind(for url: URL) -> FileKind {
        // iWork documents can be packages (directories), so check the format first.
        if let known = Self.format(for: url) { return known.kind }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        return .other
    }

    /// File name without its (possibly compound) extension: `backup.tar.gz` → `backup`.
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        if let known = Self.format(for: url) {
            let lower = name.lowercased()
            for ext in known.extensions where lower.hasSuffix("." + ext) {
                return String(name.dropLast(ext.count + 1))
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

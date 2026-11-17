import Foundation

/// External helpers some conversions rely on. Everything else uses frameworks built into macOS.
public enum Dependency: String, CaseIterable, Codable, Sendable {
    case ffmpeg, libreOffice, pandoc, pages, keynote, numbers, pngquant, ghostscript

    public var displayName: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .libreOffice: return "LibreOffice"
        case .pandoc: return "Pandoc"
        case .pages: return "Pages"
        case .keynote: return "Keynote"
        case .numbers: return "Numbers"
        case .pngquant: return "pngquant"
        case .ghostscript: return "Ghostscript"
        }
    }

    /// What it unlocks, shown in Settings.
    public var purpose: String {
        switch self {
        case .ffmpeg: return L("Audio, video, GIF, subtitle (ASS) conversions and WebP/AVIF fallback")
        case .libreOffice: return L("High-fidelity Office ↔ PDF, PowerPoint and Excel conversions")
        case .pandoc: return L("EPUB and high-quality Markdown conversions")
        case .pages: return L("Pages documents")
        case .keynote: return L("Keynote presentations")
        case .numbers: return L("Numbers spreadsheets")
        case .pngquant: return L("Much smaller PNGs when compressing")
        case .ghostscript: return L("Smaller text-heavy PDFs when compressing")
        }
    }

    public var installHint: String {
        switch self {
        case .ffmpeg: return "brew install ffmpeg"
        case .libreOffice: return "brew install --cask libreoffice"
        case .pandoc: return "brew install pandoc"
        case .pages: return "Install Pages from the Mac App Store"
        case .keynote: return "Install Keynote from the Mac App Store"
        case .numbers: return "Install Numbers from the Mac App Store"
        case .pngquant: return "brew install pngquant"
        case .ghostscript: return "brew install ghostscript"
        }
    }
}

public enum KumquatError: LocalizedError, Equatable {
    case unsupportedInput(String)
    case noRoute(from: String, to: String)
    case missingDependencies([Dependency])
    case engineUnavailable(String)
    case processFailed(tool: String, status: Int32, message: String)
    case conversionFailed(String)
    case invalidInput(String)
    case nothingToDo(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let name):
            return L("Kumquat doesn't know how to open \(name).")
        case .noRoute(let from, let to):
            return L("Can't convert \(from) to \(to).")
        case .missingDependencies(let deps):
            let list = deps.map { "\($0.displayName) (\($0.installHint))" }.joined(separator: ", ")
            return L("This needs \(list).")
        case .engineUnavailable(let name):
            return L("\(name) isn't available on this system.")
        case .processFailed(let tool, let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L("\(tool) failed (exit \(status)).") : L("\(tool) failed: \(trimmed)")
        case .conversionFailed(let message), .invalidInput(let message), .nothingToDo(let message):
            return message
        }
    }
}

/// Where results are written.
public enum OutputLocation: Codable, Hashable, Sendable {
    case besideOriginal
    case downloads
    case folder(String)
}

/// What to do when a result's file name is already taken.
public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
    /// Save as "photo 2.jpg".
    case keepBoth
    /// Move the existing file to the Trash and take its name.
    case replace
    /// Leave the existing file alone and discard the new result.
    case skip
}

/// What happens to the dropped files once their results are saved.
public enum OriginalsPolicy: String, Codable, CaseIterable, Sendable {
    case keep
    /// Move to the Trash (recoverable).
    case trash
}

/// Photo/media metadata (EXIF, GPS, tags) carried into converted files.
public enum MetadataPolicy: String, Codable, CaseIterable, Sendable {
    case keep
    case removeLocation
    case removeAll
}

/// Which H.264 encoder video conversions prefer.
public enum VideoEncoderPreference: String, Codable, CaseIterable, Sendable {
    /// x264 when available (best quality per byte), else Apple's hardware encoder.
    case automatic
    /// Apple VideoToolbox: much faster, slightly larger files.
    case hardware
    case software
}

/// How hard PDF Compress works on the images inside a PDF. Text, fonts and vector art are never touched.
public enum PDFCompression: String, Codable, CaseIterable, Sendable {
    /// Images stay sharp enough to print; smaller savings.
    case light
    /// Comfortable on screen and readable when zoomed; the default.
    case balanced
    /// Smallest file; scanned text gets soft.
    case strong

    public var title: String {
        switch self {
        case .light: return L("Light (best quality)")
        case .balanced: return L("Balanced")
        case .strong: return L("Strong (smallest file)")
        }
    }

    /// Image resolution (pixels per inch on the page) and JPEG quality to try, in order.
    var steps: [(dpi: Int, quality: Double)] {
        switch self {
        case .light: return [(200, 0.75), (150, 0.65), (120, 0.6)]
        case .balanced: return [(150, 0.6), (120, 0.5), (96, 0.4)]
        case .strong: return [(72, 0.3), (96, 0.4)]
        }
    }

    /// Ghostscript's matching preset (300, 150 and 72 dpi images).
    var ghostscriptPreset: String {
        switch self {
        case .light: return "/printer"
        case .balanced: return "/ebook"
        case .strong: return "/screen"
        }
    }
}

/// User-tunable knobs passed to every engine.
public struct ConversionOptions: Codable, Hashable, Sendable {
    /// 0...1 quality for lossy image formats.
    public var imageQuality: Double = 0.85
    /// Per-format overrides of `imageQuality`, keyed by `Format.id` ("jpg", "heic", "webp", "avif").
    public var formatQuality: [String: Double] = [:]
    /// Longest side of converted images in pixels; 0 keeps the original size.
    public var maxImageDimension: Int = 0
    /// x264 constant rate factor (lower is better quality).
    public var videoCRF: Int = 23
    /// x264 speed preset ("ultrafast"…"veryslow").
    public var videoPreset: String = "medium"
    public var videoEncoder: VideoEncoderPreference = .automatic
    /// Maximum video height in pixels (e.g. 1080); 0 keeps the original.
    public var maxVideoHeight: Int = 0
    /// Frame-rate cap; 0 keeps the original.
    public var maxFrameRate: Int = 0
    /// Drop audio tracks from converted videos.
    public var removeAudio: Bool = false
    public var audioBitrateKbps: Int = 192
    /// Output sample rate for audio conversions; 0 keeps the original.
    public var audioSampleRate: Int = 0
    /// 1 = mono, 2 = stereo, 0 keeps the original.
    public var audioChannels: Int = 0
    /// EBU R128 loudness normalisation for audio conversions.
    public var normalizeAudio: Bool = false
    /// Resolution used when rendering PDF pages to images.
    public var pdfRenderDPI: Double = 200
    public var pdfCompression: PDFCompression = .balanced
    public var gifFPS: Int = 12
    public var gifMaxWidth: Int = 640
    public var outputLocation: OutputLocation = .besideOriginal
    /// Name of converted files; see `FileNameTemplate`.
    public var fileNameTemplate: String = FileNameTemplate.default
    public var conflictPolicy: ConflictPolicy = .keepBoth
    public var originals: OriginalsPolicy = .keep
    public var metadata: MetadataPolicy = .keep
    /// Give results the original's creation and modification dates.
    public var preserveFileDates: Bool = false
    /// Pages to render when converting a PDF to images, e.g. "1, 3-5"; nil renders every page.
    public var pdfPageRange: String?
    /// Results of a multi-file job go into this subfolder of their destination (e.g. "Kumquat 2026-11-16 14.05").
    public var batchSubfolder: String?
    /// Folder per kind of result (`FileKind.rawValue` → path), overriding `outputLocation`; e.g. images → Pictures.
    public var kindFolders: [String: String] = [:]

    public init() {}

    /// Where a result of `kind` goes: its kind's folder when one is set, otherwise `outputLocation`.
    public func outputLocation(for kind: FileKind?) -> OutputLocation {
        if let kind, let path = kindFolders[kind.rawValue]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return .folder(path)
        }
        return outputLocation
    }

    /// Quality for a lossy image format, honouring per-format overrides.
    public func quality(for format: Format) -> Double {
        min(max(formatQuality[format.id] ?? imageQuality, 0.05), 1)
    }
}

/// Builds result names from a template such as "{name}-{format}-{date}".
public enum FileNameTemplate {
    public static let `default` = "{name}"
    public struct Token: Hashable, Sendable {
        public let token: String
        public let meaning: String
    }

    /// Tokens and what they stand for, for the Settings help text.
    public static let tokens = [
        Token(token: "{name}", meaning: "original name"),
        Token(token: "{format}", meaning: "new format, e.g. JPG"),
        Token(token: "{date}", meaning: "today, 2026-01-31"),
        Token(token: "{time}", meaning: "now, 14.05.09"),
    ]

    public static func render(_ template: String, name: String, format: String, date: Date = Date()) -> String {
        // Clean the template before substituting, so the original name is never altered.
        var result = template.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !result.isEmpty, result != Self.default else { return name }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        result = result
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{format}", with: format)
            .replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: time)
            .trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the file.
        while result.hasPrefix(".") { result.removeFirst() }
        if result.count > 200 { result = String(result.prefix(200)) }
        return result.isEmpty ? name : result
    }
}

/// Names handed out but not yet written, so parallel jobs never pick the same file name.
private final class ReservedNames: @unchecked Sendable {
    static let shared = ReservedNames()
    private let lock = NSLock()
    private var paths = Set<String>()

    func reserve(_ make: (_ isTaken: (URL) -> Bool) -> URL) -> URL {
        lock.lock()
        defer { lock.unlock() }
        let url = make { self.paths.contains($0.standardizedFileURL.path) }
        paths.insert(url.standardizedFileURL.path)
        return url
    }

    /// Reserves exactly `url`; false if another job holds it.
    func tryReserve(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(url.standardizedFileURL.path).inserted
    }

    func release(_ url: URL) {
        lock.lock()
        paths.remove(url.standardizedFileURL.path)
        lock.unlock()
    }
}

/// Picks non-clobbering destinations for results.
public enum OutputNamer {
    /// Like `uniqueURL`, but also skips names other jobs in this process have reserved. Call
    /// `release(_:)` once the file is in place (or the move failed).
    public static func reserveUniqueURL(in directory: URL, baseName: String, extension ext: String?) -> URL {
        ReservedNames.shared.reserve { isTaken in
            func make(_ base: String) -> URL {
                let name = (ext?.isEmpty ?? true) ? base : "\(base).\(ext!)"
                return directory.appendingPathComponent(name)
            }
            var candidate = make(baseName)
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) || isTaken(candidate) {
                candidate = make("\(baseName) \(counter)")
                counter += 1
            }
            return candidate
        }
    }

    public static func release(_ url: URL) {
        ReservedNames.shared.release(url)
    }

    /// Reserves exactly this name (no numbering); false while another job in this process holds it.
    public static func reserve(_ url: URL) -> Bool {
        ReservedNames.shared.tryReserve(url)
    }

    public static func url(in directory: URL, baseName: String, extension ext: String?) -> URL {
        directory.appendingPathComponent((ext?.isEmpty ?? true) ? baseName : "\(baseName).\(ext!)")
    }

    /// `dir/base.ext`, or `dir/base 2.ext`, `dir/base 3.ext`… if taken.
    public static func uniqueURL(in directory: URL, baseName: String, extension ext: String?, fileManager: FileManager = .default) -> URL {
        func make(_ base: String) -> URL {
            let name = (ext?.isEmpty ?? true) ? base : "\(base).\(ext!)"
            return directory.appendingPathComponent(name)
        }
        var candidate = make(baseName)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = make("\(baseName) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// Unique URL for an existing file name (keeps compound extensions like `.tar.gz` intact).
    public static func uniqueURL(in directory: URL, fileName: String, fileManager: FileManager = .default) -> URL {
        let url = URL(fileURLWithPath: fileName)
        let base = FormatRegistry.baseName(of: url)
        let ext = String(fileName.dropFirst(base.count)).drop(while: { $0 == "." })
        return uniqueURL(in: directory, baseName: base, extension: ext.isEmpty ? nil : String(ext), fileManager: fileManager)
    }

    /// Folder for a result of `kind` made from `input`, honouring per-kind folders and the batch subfolder.
    public static func destinationDirectory(for input: URL, options: ConversionOptions, outputKind: FileKind?,
                                            fileManager: FileManager = .default) -> URL {
        let base = destinationDirectory(for: input, location: options.outputLocation(for: outputKind), fileManager: fileManager)
        guard let name = options.batchSubfolder?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return base }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = base.appendingPathComponent(safe, isDirectory: true)
        guard (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              fileManager.isWritableFile(atPath: folder.path) else { return base }
        return folder
    }

    /// Folder results for `input` should go in, falling back to Downloads when the original folder is read-only.
    public static func destinationDirectory(for input: URL, location: OutputLocation, fileManager: FileManager = .default) -> URL {
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        switch location {
        case .besideOriginal:
            let parent = input.deletingLastPathComponent()
            return fileManager.isWritableFile(atPath: parent.path) ? parent : downloads
        case .downloads:
            return downloads
        case .folder(let path):
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return fileManager.isWritableFile(atPath: url.path) ? url : downloads
        }
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Fresh scratch directory under the system temp folder.
    func makeWorkDirectory() throws -> URL {
        let url = temporaryDirectory
            .appendingPathComponent("Kumquat", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension String {
    /// Reads text trying UTF-8 first, then common legacy encodings.
    static func readText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let encodings: [String.Encoding] = hasUTF16BOM ? [.utf16] : [.utf8, .windowsCP1252, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
        }
        throw KumquatError.invalidInput(L("\(url.lastPathComponent) isn't readable text."))
    }
}

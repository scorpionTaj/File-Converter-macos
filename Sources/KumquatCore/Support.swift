import Foundation

/// External helpers some conversions rely on. Everything else uses frameworks built into macOS.
public enum Dependency: String, CaseIterable, Codable, Sendable {
    case ffmpeg, libreOffice, pandoc, pages, keynote, numbers, pngquant

    public var displayName: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .libreOffice: return "LibreOffice"
        case .pandoc: return "Pandoc"
        case .pages: return "Pages"
        case .keynote: return "Keynote"
        case .numbers: return "Numbers"
        case .pngquant: return "pngquant"
        }
    }

    /// What it unlocks, shown in Settings.
    public var purpose: String {
        switch self {
        case .ffmpeg: return "Audio, video, GIF, subtitle (ASS) conversions and WebP/AVIF fallback"
        case .libreOffice: return "High-fidelity Office ↔ PDF, PowerPoint and Excel conversions"
        case .pandoc: return "EPUB and high-quality Markdown conversions"
        case .pages: return "Pages documents"
        case .keynote: return "Keynote presentations"
        case .numbers: return "Numbers spreadsheets"
        case .pngquant: return "Much smaller PNGs when compressing"
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
            return "Kumquat doesn't know how to open \(name)."
        case .noRoute(let from, let to):
            return "Can't convert \(from) to \(to)."
        case .missingDependencies(let deps):
            let list = deps.map { "\($0.displayName) (\($0.installHint))" }.joined(separator: ", ")
            return "This needs \(list)."
        case .engineUnavailable(let name):
            return "\(name) isn't available on this system."
        case .processFailed(let tool, let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(tool) failed (exit \(status))." : "\(tool) failed: \(trimmed)"
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

/// User-tunable knobs passed to every engine.
public struct ConversionOptions: Codable, Hashable, Sendable {
    /// 0...1 quality for lossy image formats.
    public var imageQuality: Double = 0.85
    /// x264 constant rate factor (lower is better quality).
    public var videoCRF: Int = 23
    public var audioBitrateKbps: Int = 192
    /// Resolution used when rendering PDF pages to images.
    public var pdfRenderDPI: Double = 200
    public var gifFPS: Int = 12
    public var gifMaxWidth: Int = 640
    public var outputLocation: OutputLocation = .besideOriginal

    public init() {}
}

/// Picks non-clobbering destinations for results.
public enum OutputNamer {
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
        throw KumquatError.invalidInput("\(url.lastPathComponent) isn't readable text.")
    }
}

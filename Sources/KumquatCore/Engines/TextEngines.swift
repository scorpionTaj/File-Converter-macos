import Foundation

/// CSV/TSV/JSON/Property List conversions in pure Swift.
public struct DataEngine: ConversionEngine {
    public let id = EngineID.data

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let result: String
        switch (source, target) {
        case (.json, .plist):
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: input), options: [.fragmentsAllowed])
            let data = try PropertyListSerialization.data(fromPropertyList: Self.plistCompatible(object), format: .xml, options: 0)
            try data.write(to: output)
            return output
        case (.plist, .json):
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: input), options: [], format: nil)
            let data = try JSONSerialization.data(withJSONObject: Self.jsonCompatible(object), options: [.prettyPrinted, .sortedKeys])
            try (data + Data("\n".utf8)).write(to: output)
            return output
        case (.json, _):
            let rows = try Table.rows(fromJSON: Data(contentsOf: input))
            result = Table.serialize(rows, delimiter: target == .tsv ? "\t" : ",")
        default:
            let rows = Table.parse(try String.readText(from: input), delimiter: source == .tsv ? "\t" : ",")
            switch target {
            case .csv: result = Table.serialize(rows)
            case .tsv: result = Table.serialize(rows, delimiter: "\t")
            case .json: result = Table.json(from: rows)
            case .md: result = Table.markdown(from: rows)
            case .html: result = Table.html(from: rows, title: FormatRegistry.baseName(of: input))
            default: throw KumquatError.noRoute(from: source.name, to: target.name)
            }
        }
        try result.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    /// Property lists can't hold null; drop those entries.
    static func plistCompatible(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.filter { !($0.value is NSNull) }.mapValues(plistCompatible)
        case let array as [Any]:
            return array.filter { !($0 is NSNull) }.map(plistCompatible)
        default:
            return value
        }
    }

    /// JSON can't hold dates or raw data; use ISO 8601 strings and Base64.
    static func jsonCompatible(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonCompatible)
        case let array as [Any]:
            return array.map(jsonCompatible)
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let data as Data:
            return data.base64EncodedString()
        default:
            return value
        }
    }
}

/// SRT ⇄ WebVTT, and subtitles → plain transcript.
public struct SubtitleEngine: ConversionEngine {
    public let id = EngineID.subtitle

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let cues = Subtitles.parse(try String.readText(from: input))
        guard !cues.isEmpty else { throw KumquatError.invalidInput("No subtitles found in \(input.lastPathComponent).") }
        let text: String
        switch target {
        case .srt: text = Subtitles.srt(from: cues)
        case .vtt: text = Subtitles.vtt(from: cues)
        case .txt: text = Subtitles.plainText(from: cues)
        default: throw KumquatError.noRoute(from: source.name, to: target.name)
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }
}

/// LibreOffice in headless mode, for Office documents, slides and sheets.
public struct OfficeEngine: ConversionEngine {
    public let id = EngineID.office

    public init() {}

    static func filter(for target: Format) -> String {
        switch target {
        // UTF-8, comma separated, double-quoted text.
        case .csv: return "csv:Text - txt - csv (StarCalc):44,34,76,1"
        default: return target.fileExtension
        }
    }

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let soffice = try context.tools.require("soffice", .libreOffice)
        let outDir = context.workDirectory.appendingPathComponent("office-out", isDirectory: true)
        // A private profile avoids clashing with a LibreOffice window the user already has open.
        let profile = context.workDirectory.appendingPathComponent("office-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try await ProcessRunner.runChecked(soffice, [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--norestore", "--nolockcheck",
            "--convert-to", Self.filter(for: target),
            "--outdir", outDir.path,
            input.path,
        ], timeout: 300)
        guard let produced = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == target.fileExtension }) else {
            throw KumquatError.conversionFailed("LibreOffice didn't produce a \(target.name) file.")
        }
        try FileManager.default.moveItem(at: produced, to: output)
        return output
    }
}

/// Pandoc, for EPUB and high-quality Markdown.
public struct PandocEngine: ConversionEngine {
    public let id = EngineID.pandoc

    public init() {}

    static func pandocName(_ format: Format) -> String {
        switch format {
        case .md: return "gfm"
        case .txt: return "plain"
        default: return format.id
        }
    }

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let pandoc = try context.tools.require("pandoc", .pandoc)
        let from = source == .md ? "markdown" : Self.pandocName(source)
        var args = [input.path, "-f", from, "-t", Self.pandocName(target), "-o", output.path, "--standalone"]
        if target == .epub {
            args += ["--metadata", "title=\(FormatRegistry.baseName(of: input))"]
        }
        try await ProcessRunner.runChecked(pandoc, args, currentDirectory: input.deletingLastPathComponent(), timeout: 300)
        return output
    }
}

/// Pages, Keynote and Numbers, scripted through AppleScript.
public struct IWorkEngine: ConversionEngine {
    public let id = EngineID.iwork

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        guard let script = IWorkScripts.script(input: input.path, output: output.path, source: source, target: target) else {
            throw KumquatError.noRoute(from: source.name, to: target.name)
        }
        // Pages/Keynote/Numbers can sit behind a permission prompt; don't wait forever.
        try await ProcessRunner.runChecked(SystemTool.osascript, ["-e", script], timeout: 180)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw KumquatError.conversionFailed("The iWork app didn't save the file. Check Kumquat's Automation permission in System Settings → Privacy & Security.")
        }
        return output
    }
}

public enum IWorkScripts {
    public static func application(source: Format, target: Format) -> String? {
        for format in [source, target] {
            switch format {
            case .pages: return "Pages"
            case .key: return "Keynote"
            case .numbers: return "Numbers"
            default: continue
            }
        }
        return nil
    }

    /// AppleScript export format constant, or nil to save in the app's native format.
    public static func exportFormat(for target: Format) -> String? {
        switch target {
        case .pdf: return "PDF"
        case .docx: return "Microsoft Word"
        case .rtf: return "formatted text"
        case .txt: return "unformatted text"
        case .epub: return "EPUB"
        case .pptx: return "Microsoft PowerPoint"
        case .xlsx: return "Microsoft Excel"
        case .csv: return "CSV"
        default: return nil
        }
    }

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func script(input: String, output: String, source: Format, target: Format) -> String? {
        guard let app = application(source: source, target: target) else { return nil }
        let action: String
        if let format = exportFormat(for: target), [.pages, .key, .numbers].contains(source) {
            action = "export theDoc to outFile as \(format)"
        } else if [.pages, .key, .numbers].contains(target) {
            action = "save theDoc in outFile"
        } else {
            return nil
        }
        return """
        set inFile to POSIX file \(quoted(input))
        set outFile to POSIX file \(quoted(output))
        tell application "\(app)"
            set theDoc to open inFile
            \(action)
            close theDoc saving no
        end tell
        """
    }
}

/// SHA-256 without depending on CryptoKit, so it also runs on Linux.
enum Checksum {
    static func sha256(of url: URL) async throws -> String {
        #if os(macOS)
        let result = try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", url.path])
        #else
        let result = try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/sha256sum"), [url.path])
        #endif
        guard let digest = result.stdout.split(separator: " ").first, digest.count == 64 else {
            throw KumquatError.conversionFailed("Couldn't compute the checksum.")
        }
        return String(digest)
    }
}

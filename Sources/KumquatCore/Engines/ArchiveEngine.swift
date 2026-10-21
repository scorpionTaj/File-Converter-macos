import Foundation

/// ZIP/TAR/GZ/BZ2/XZ/7z/RAR. Extraction uses the system `tar` (libarchive on macOS reads 7z and RAR too);
/// ZIP creation uses `ditto` on macOS to keep metadata and resource forks.
public struct ArchiveEngine: ConversionEngine {
    public let id = EngineID.archive

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        let extracted = context.workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try await Self.extract(input, format: source, into: extracted)
        let items = try Self.contents(of: extracted)
        guard !items.isEmpty else { throw KumquatError.nothingToDo("\(input.lastPathComponent) is empty.") }
        try await Self.create(items: items, format: target, output: output)
        return output
    }

    static func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func extract(_ archive: URL, format: Format, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch format {
        case .zip where SystemTool.exists(SystemTool.ditto):
            try await ProcessRunner.runChecked(SystemTool.ditto, ["-x", "-k", archive.path, directory.path])
        case .zip where SystemTool.exists(SystemTool.unzip):
            try await ProcessRunner.runChecked(SystemTool.unzip, ["-q", archive.path, "-d", directory.path])
        case .gz:
            let name = FormatRegistry.baseName(of: archive)
            let output = directory.appendingPathComponent(name.isEmpty ? "file" : name)
            try await ProcessRunner.runChecked(SystemTool.gzip, ["-dc", archive.path], stdoutFile: output)
        default:
            try await ProcessRunner.runChecked(SystemTool.tar, ["-xf", archive.path, "-C", directory.path])
        }
    }

    /// Extracts for the "Extract" tool. A single top-level item is returned directly, like Archive Utility does.
    static func extractForUser(_ archive: URL, format: Format, context: EngineContext) async throws -> URL {
        let base = FormatRegistry.baseName(of: archive)
        let container = context.workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        let target = container.appendingPathComponent(base, isDirectory: true)
        try await extract(archive, format: format, into: target)
        let items = try contents(of: target)
        if items.count == 1 { return items[0] }
        return target
    }

    static func create(items: [URL], format: Format, output: URL) async throws {
        guard let first = items.first else { return }
        let parent = first.deletingLastPathComponent()
        let names = items.map(\.lastPathComponent)
        let environment = ["COPYFILE_DISABLE": "1"]
        switch format {
        case .zip:
            if items.count == 1, SystemTool.exists(SystemTool.ditto) {
                try await ProcessRunner.runChecked(SystemTool.ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, output.path])
            } else {
                try await ProcessRunner.runChecked(SystemTool.zip, ["-r", "-y", "-q", output.path] + names + ["-x", "*.DS_Store"],
                                                   currentDirectory: parent)
            }
        case .tar, .tgz, .tbz, .txz:
            let flag: String
            switch format {
            case .tgz: flag = "-czf"
            case .tbz: flag = "-cjf"
            case .txz: flag = "-cJf"
            default: flag = "-cf"
            }
            try await ProcessRunner.runChecked(SystemTool.tar, [flag, output.path, "-C", parent.path] + names,
                                               environment: environment)
        default:
            throw KumquatError.noRoute(from: "files", to: format.name)
        }
    }
}

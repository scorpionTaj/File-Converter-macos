import Foundation

/// ZIP/TAR/GZ/BZ2/XZ/7z/RAR with the tools built into macOS: `ditto` for ZIP (keeps metadata and resource
/// forks), `tar` (libarchive, which also reads 7z and RAR) for the rest.
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
        case .zip:
            try await ProcessRunner.runChecked(SystemTool.ditto, ["-x", "-k", archive.path, directory.path])
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
        let fm = FileManager.default
        var parent = first.deletingLastPathComponent()
        var names = items.map(\.lastPathComponent)
        var followLinks = false
        var staging: URL?
        defer { if let staging { try? fm.removeItem(at: staging) } }
        if items.contains(where: { $0.deletingLastPathComponent().standardizedFileURL != parent.standardizedFileURL }) {
            // Items from different folders (e.g. a Recents selection): stage symlinks side by side.
            let stage = try fm.makeWorkDirectory()
            staging = stage
            names = []
            for item in items {
                let link = OutputNamer.uniqueURL(in: stage, fileName: item.lastPathComponent)
                try fm.createSymbolicLink(at: link, withDestinationURL: item)
                names.append(link.lastPathComponent)
            }
            parent = stage
            followLinks = true
        }
        let environment = ["COPYFILE_DISABLE": "1"]
        switch format {
        case .zip:
            if items.count == 1 {
                try await ProcessRunner.runChecked(SystemTool.ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, output.path])
            } else {
                // -y stores symlinks as links; staged links must be followed instead.
                let linkFlag = followLinks ? [] : ["-y"]
                try await ProcessRunner.runChecked(SystemTool.zip, ["-r", "-q"] + linkFlag + [output.path] + names + ["-x", "*.DS_Store"],
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
            let followFlag = followLinks ? ["-h"] : []
            try await ProcessRunner.runChecked(SystemTool.tar, followFlag + [flag, output.path, "-C", parent.path] + names,
                                               environment: environment)
        default:
            throw KumquatError.noRoute(from: "files", to: format.name)
        }
    }
}

import Foundation

/// Puts the `kumquat-cli` that ships inside Kumquat.app on the user's `PATH` as a symlink, so installing the
/// app is enough to use the CLI. Only links Kumquat made (pointing at a Kumquat.app's bundled CLI) are ever
/// replaced; any other file named `kumquat-cli` is left alone.
public enum CommandLineTool {
    public static let name = "kumquat-cli"

    /// Folders on the default shell `PATH` that Homebrew users can write to without a password.
    public static let directories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public enum Status: Equatable, Sendable {
        /// A link in this folder runs this app's CLI.
        case linked(URL)
        case notLinked
    }

    /// The CLI inside an app bundle.
    public static func executable(inApp app: URL) -> URL {
        app.appendingPathComponent("Contents/Resources/bin/\(name)")
    }

    /// Whether `link` is a symlink Kumquat made: it points at some Kumquat.app's bundled CLI.
    static func isOurs(_ link: URL, fileManager: FileManager = .default) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return false }
        return destination.hasSuffix(".app/Contents/Resources/bin/\(name)")
    }

    public static func status(app: URL, directories: [String] = directories,
                              fileManager: FileManager = .default) -> Status {
        let target = executable(inApp: app).resolvingSymlinksInPath().path
        for directory in directories {
            let link = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if isOurs(link, fileManager: fileManager), link.resolvingSymlinksInPath().path == target {
                return .linked(link)
            }
        }
        return .notLinked
    }

    /// Links (or repairs a stale link to) this app's CLI in the first folder that exists, is writable and
    /// isn't taken by someone else's `kumquat-cli`. Returns the link, or nil when no such folder exists.
    @discardableResult
    public static func install(app: URL, directories: [String] = directories,
                               fileManager: FileManager = .default) throws -> URL? {
        let target = executable(inApp: app)
        guard fileManager.isExecutableFile(atPath: target.path) else {
            throw KumquatError.conversionFailed("\(app.lastPathComponent) doesn't contain \(name).")
        }
        if case .linked(let link) = status(app: app, directories: directories, fileManager: fileManager) { return link }
        for directory in directories {
            guard fileManager.isDirectory(URL(fileURLWithPath: directory)),
                  fileManager.isWritableFile(atPath: directory) else { continue }
            let link = URL(fileURLWithPath: directory).appendingPathComponent(name)
            // `fileExists` follows links, so a broken link needs its own check.
            let occupied = fileManager.fileExists(atPath: link.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil
            if occupied {
                guard isOurs(link, fileManager: fileManager) else { continue }
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            return link
        }
        return nil
    }

    /// Links into /usr/local/bin with an administrator password prompt, for Macs without Homebrew.
    public static func installAsAdministrator(app: URL) async throws -> URL {
        let target = executable(inApp: app)
        let link = URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(name)
        let existing = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
            || FileManager.default.fileExists(atPath: link.path)
        if existing, !isOurs(link) {
            throw KumquatError.conversionFailed("\(link.path) already exists and isn't Kumquat's, so it was left alone.")
        }
        let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuoted(target.path)) \(shellQuoted(link.path))"
        let script = "do shell script \(IWorkScripts.quoted(command)) with administrator privileges"
        try await ProcessRunner.runChecked(SystemTool.osascript, ["-e", script], timeout: 120)
        return link
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

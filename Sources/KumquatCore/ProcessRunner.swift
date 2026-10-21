import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// The process was killed because it ran past its timeout.
    public var timedOut = false
}

/// Thread-safe accumulator for a child process's output.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pendingLine = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        out.append(data)
        if onLine != nil {
            pendingLine.append(data)
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                let lineData = pendingLine[pendingLine.startIndex..<newline]
                lines.append(String(decoding: lineData, as: UTF8.self))
                pendingLine = Data(pendingLine[pendingLine.index(after: newline)...])
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        err.append(data)
        lock.unlock()
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var didTimeOut = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func killForTimeout() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

public enum ProcessRunner {
    /// Runs an executable to completion. Cancelling the calling task terminates the process.
    /// - Parameter stdoutFile: when set, standard output is written to this file instead of being captured.
    /// - Parameter timeout: seconds after which the process is terminated (helpers like LibreOffice can hang).
    @discardableResult
    public static func run(_ executable: URL,
                           _ arguments: [String],
                           currentDirectory: URL? = nil,
                           environment: [String: String]? = nil,
                           stdoutFile: URL? = nil,
                           timeout: TimeInterval? = nil,
                           onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let process = box.process
                process.executableURL = executable
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                process.standardInput = FileHandle.nullDevice

                let collector = OutputCollector(onLine: onStdoutLine)
                let errPipe = Pipe()
                process.standardError = errPipe
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
                }

                let outPipe: Pipe? = stdoutFile == nil ? Pipe() : nil
                let outFile: FileHandle?
                if let stdoutFile {
                    _ = FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
                    do {
                        outFile = try FileHandle(forWritingTo: stdoutFile)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    process.standardOutput = outFile
                } else {
                    outFile = nil
                }
                if let pipe = outPipe {
                    process.standardOutput = pipe
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
                    }
                }

                process.terminationHandler = { finished in
                    if let outPipe {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    try? outFile?.close()
                    continuation.resume(returning: ProcessResult(status: finished.terminationStatus,
                                                                 stdout: collector.stdout,
                                                                 stderr: collector.stderr,
                                                                 timedOut: box.timedOut))
                }

                do {
                    try process.run()
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.killForTimeout() }
                    }
                } catch {
                    process.terminationHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    /// Like `run`, but throws `KumquatError.processFailed` on a non-zero exit status.
    @discardableResult
    public static func runChecked(_ executable: URL,
                                  _ arguments: [String],
                                  currentDirectory: URL? = nil,
                                  environment: [String: String]? = nil,
                                  stdoutFile: URL? = nil,
                                  timeout: TimeInterval? = nil,
                                  onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory, environment: environment,
                                   stdoutFile: stdoutFile, timeout: timeout, onStdoutLine: onStdoutLine)
        try Task.checkCancellation()
        if result.timedOut {
            throw KumquatError.processFailed(tool: executable.lastPathComponent, status: result.status,
                                             message: "didn't finish within \(Int(timeout ?? 0)) seconds and was stopped")
        }
        guard result.status == 0 else {
            let lastLines = result.stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw KumquatError.processFailed(tool: executable.lastPathComponent, status: result.status, message: lastLines)
        }
        return result
    }
}

/// Finds helper tools. GUI apps get a minimal PATH, so the usual Homebrew/MacPorts prefixes are searched explicitly.
public struct ToolLocator: Sendable {
    /// Tool name → absolute path chosen by the user in Settings.
    public var overrides: [String: String]

    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]

    public init(overrides: [String: String] = [:]) {
        self.overrides = overrides.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func path(for tool: String) -> URL? {
        let fm = FileManager.default
        // A custom path that doesn't point at an executable falls back to auto-detection rather than hiding
        // an installed tool (Settings flags it as invalid).
        if let override = overrides[tool] {
            let path = NSString(string: override).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(tool)").path {
            candidates.append(bundled)
        }
        if tool == "soffice" {
            candidates.append("/Applications/LibreOffice.app/Contents/MacOS/soffice")
        }
        candidates += Self.searchDirectories.map { "\($0)/\(tool)" }
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        candidates += pathDirectories.map { "\($0)/\(tool)" }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    /// The user set a custom path for `tool` that isn't an executable file.
    public func overrideIsInvalid(_ tool: String) -> Bool {
        guard let override = overrides[tool] else { return false }
        return !FileManager.default.isExecutableFile(atPath: NSString(string: override).expandingTildeInPath)
    }

    public var ffmpeg: URL? { path(for: "ffmpeg") }
    public var ffprobe: URL? { path(for: "ffprobe") }
    public var soffice: URL? { path(for: "soffice") }
    public var pandoc: URL? { path(for: "pandoc") }
    public var pngquant: URL? { path(for: "pngquant") }

    public func applicationInstalled(_ name: String) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return ["/Applications/\(name).app", "\(home)/Applications/\(name).app"].contains(where: fm.fileExists(atPath:))
    }

    public func isAvailable(_ dependency: Dependency) -> Bool {
        switch dependency {
        case .ffmpeg: return ffmpeg != nil
        case .libreOffice: return soffice != nil
        case .pandoc: return pandoc != nil
        case .pngquant: return pngquant != nil
        case .pages: return applicationInstalled("Pages")
        case .keynote: return applicationInstalled("Keynote")
        case .numbers: return applicationInstalled("Numbers")
        }
    }

    public var availableDependencies: Set<Dependency> {
        Set(Dependency.allCases.filter(isAvailable))
    }

    /// Location of a tool, or a `missingDependencies` error.
    func require(_ tool: String, _ dependency: Dependency) throws -> URL {
        guard let url = path(for: tool) else { throw KumquatError.missingDependencies([dependency]) }
        return url
    }
}

/// System binaries that ship with macOS (and mostly Linux).
enum SystemTool {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    static let qlmanage = URL(fileURLWithPath: "/usr/bin/qlmanage")

    static func exists(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}

/// What Settings shows for each optional helper.
public struct DependencyStatus: Equatable, Sendable {
    public let dependency: Dependency
    /// Executable or app bundle, when found.
    public let path: String?
    public let version: String?
    /// A custom path was set but isn't usable.
    public let invalidOverride: Bool

    public var isInstalled: Bool { path != nil }
}

extension Dependency {
    /// Command-line tool name, for helpers that are executables.
    public var toolName: String? {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .libreOffice: return "soffice"
        case .pandoc: return "pandoc"
        case .pngquant: return "pngquant"
        case .pages, .keynote, .numbers: return nil
        }
    }

    /// Homebrew formula/cask, when the helper can be installed that way.
    public var brewPackage: String? {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .libreOffice: return "--cask libreoffice"
        case .pandoc: return "pandoc"
        case .pngquant: return "pngquant"
        case .pages, .keynote, .numbers: return nil
        }
    }

    /// Mac App Store page for Apple's apps.
    public var appStoreURL: URL? {
        switch self {
        case .pages: return URL(string: "macappstore://apps.apple.com/app/id409201541")
        case .keynote: return URL(string: "macappstore://apps.apple.com/app/id409183694")
        case .numbers: return URL(string: "macappstore://apps.apple.com/app/id409203825")
        default: return nil
        }
    }
}

extension ToolLocator {
    /// Finds a helper and asks it for its version. Runs subprocesses, so call it off the main thread.
    public func status(of dependency: Dependency) async -> DependencyStatus {
        if let tool = dependency.toolName {
            let invalid = overrideIsInvalid(tool)
            guard let url = path(for: tool) else {
                return DependencyStatus(dependency: dependency, path: nil, version: nil, invalidOverride: invalid)
            }
            let flag = dependency == .ffmpeg ? "-version" : "--version"
            let result = try? await ProcessRunner.run(url, [flag], timeout: 15)
            let firstLine = (result?.stdout ?? "").split(separator: "\n").first.map(String.init)
            return DependencyStatus(dependency: dependency, path: url.path,
                                    version: firstLine.map(Self.shortVersion), invalidOverride: invalid)
        }
        let name = dependency.displayName
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let path = ["/Applications/\(name).app", "\(home)/Applications/\(name).app"]
            .first(where: FileManager.default.fileExists(atPath:)) else {
            return DependencyStatus(dependency: dependency, path: nil, version: nil, invalidOverride: false)
        }
        let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String
        return DependencyStatus(dependency: dependency, path: path, version: version, invalidOverride: false)
    }

    public func statuses() async -> [DependencyStatus] {
        var results: [DependencyStatus] = []
        for dependency in Dependency.allCases { results.append(await status(of: dependency)) }
        return results
    }

    /// "ffmpeg version 7.1 Copyright…" → "7.1"; "pandoc 3.5" → "3.5".
    static func shortVersion(_ line: String) -> String {
        let tokens = line.split(separator: " ").map(String.init)
        if let index = tokens.firstIndex(where: { $0.lowercased() == "version" }), index + 1 < tokens.count {
            return tokens[index + 1]
        }
        return tokens.first(where: { $0.first?.isNumber ?? false }) ?? line
    }
}

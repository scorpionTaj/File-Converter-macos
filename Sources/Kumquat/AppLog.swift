#if os(macOS)
import Foundation
import os

/// Errors and notable events, written to the unified log and to ~/Library/Logs/Kumquat/Kumquat.log
/// (Help ▸ "Show Log" in the menu bar opens it), so problems can be reported with details.
enum AppLog {
    private static let logger = Logger(subsystem: "io.github.scorpiontaj.kumquat", category: "app")
    private static let queue = DispatchQueue(label: "Kumquat log")
    private static let maxBytes = 1_000_000

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Kumquat", isDirectory: true)
            .appendingPathComponent("Kumquat.log")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            let url = fileURL
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the log small: start over once it passes ~1 MB.
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
#endif

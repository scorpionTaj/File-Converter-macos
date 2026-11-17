import Foundation

/// A file Kumquat moved to the Trash, and where it came from.
public struct TrashedItem: Hashable, Sendable {
    public let original: URL
    public let inTrash: URL

    public init(original: URL, inTrash: URL) {
        self.original = original
        self.inTrash = inTrash
    }
}

/// Collects what a job moves to the Trash (replaced files, originals) so the job can be undone.
/// Wrap a job in `UndoJournal.$current.withValue(journal) { … }`; child tasks inherit it.
public final class UndoJournal: @unchecked Sendable {
    @TaskLocal public static var current: UndoJournal?

    private let lock = NSLock()
    private var items: [TrashedItem] = []

    public init() {}

    public var trashed: [TrashedItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func record(_ item: TrashedItem) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    /// Moves `url` to the Trash and notes it in the current job's journal, if any.
    static func trash(_ url: URL, fileManager: FileManager = .default) throws {
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        if let resulting { current?.record(TrashedItem(original: url, inTrash: resulting as URL)) }
    }
}

/// What one finished job changed: enough to put things back.
public struct JobRecord: Sendable {
    public let title: String
    public let outputs: [URL]
    public let trashed: [TrashedItem]

    public init(title: String, outputs: [URL], trashed: [TrashedItem]) {
        self.title = title
        self.outputs = outputs
        self.trashed = trashed
    }

    public var isEmpty: Bool { outputs.isEmpty && trashed.isEmpty }
}

public enum Undo {
    public struct Report: Sendable {
        /// Results moved to the Trash.
        public var removed = 0
        /// Replaced files and originals put back.
        public var restored = 0
        public var problems: [String] = []
    }

    /// Moves the job's results to the Trash (recoverable, like everything Kumquat deletes), then puts back
    /// what the job trashed. Something that can't be put back is reported, never overwritten.
    public static func undo(_ record: JobRecord, fileManager: FileManager = .default) -> Report {
        var report = Report()
        for output in record.outputs where exists(output, fileManager) {
            do {
                try fileManager.trashItem(at: output, resultingItemURL: nil)
                report.removed += 1
            } catch {
                report.problems.append("\(output.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Newest first, so a file trashed twice ends up as it was before the job.
        for item in record.trashed.reversed() {
            let name = item.original.lastPathComponent
            guard exists(item.inTrash, fileManager) else {
                report.problems.append(L("\(name) is no longer in the Trash."))
                continue
            }
            guard !exists(item.original, fileManager) else {
                report.problems.append(L("\(name) wasn't put back: another file now has that name."))
                continue
            }
            do {
                try fileManager.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: item.inTrash, to: item.original)
                report.restored += 1
            } catch {
                report.problems.append("\(name): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// `fileExists` follows symlinks; a link (even a broken one) still occupies the name.
    private static func exists(_ url: URL, _ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

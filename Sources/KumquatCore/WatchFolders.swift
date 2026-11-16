import Foundation

// MARK: Watch folders

/// A folder whose new files are converted with a preset as soon as they finish arriving.
public struct WatchFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    /// `OutputPreset.id` to convert with.
    public var presetID: UUID
    public var isEnabled: Bool

    public init(id: UUID = UUID(), path: String, presetID: UUID, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.presetID = presetID
        self.isEnabled = isEnabled
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { url.lastPathComponent }

    /// The files among `urls` that `preset` can convert right now (installed engines, a different format).
    /// Results always have the preset's format, so they are never picked up again.
    public static func convertible(_ urls: [URL], with preset: OutputPreset, catalog: Catalog) -> [URL] {
        urls.filter { url in
            guard let item = catalog.presets([preset], for: [url]).first else { return false }
            return item.unavailableReason == nil
        }
    }
}

/// Picks out the files that arrived in a watched folder and have finished arriving.
///
/// A file counts as new when it was added to the folder after `since`; it is ready once its size is the same
/// on two scans in a row, so a copy or download in progress isn't converted half-written.
public struct WatchFolderTracker: Sendable {
    public struct Entry: Hashable, Sendable {
        public var url: URL
        public var size: Int64
        /// When the file was added to the folder (Finder's "Date Added").
        public var added: Date

        public init(url: URL, size: Int64, added: Date) {
            self.url = url
            self.size = size
            self.added = added
        }
    }

    /// Files added at or before this moment are left alone. Moves forward whenever nothing is waiting, so it can
    /// be saved and used after a relaunch to pick up files that arrived while Kumquat wasn't running.
    public private(set) var since: Date
    private var lastSizes: [String: Int64] = [:]
    private var handled: Set<String> = []

    public init(since: Date) {
        self.since = since
    }

    /// Files seen once and still being checked for a stable size; rescan soon while this is true.
    public var isWaiting: Bool { !lastSizes.isEmpty }

    /// Feeds one scan of the folder; returns the files that just became ready, each only once.
    public mutating func ready(_ entries: [Entry], scannedAt: Date) -> [URL] {
        var ready: [URL] = []
        var sizes: [String: Int64] = [:]
        for entry in entries {
            let key = entry.url.path
            guard entry.added > since, !handled.contains(key) else { continue }
            if let previous = lastSizes[key], previous == entry.size {
                handled.insert(key)
                // An empty file has nothing to convert (and is often a placeholder that's about to be replaced).
                if entry.size > 0 { ready.append(entry.url) }
            } else {
                sizes[key] = entry.size
            }
        }
        // Files that vanished between scans are dropped here too.
        lastSizes = sizes
        if lastSizes.isEmpty {
            since = max(since, scannedAt)
            // Anything at or before `since` is skipped by date now, so its name can be forgotten.
            let newer = Set(entries.filter { $0.added > since }.map(\.url.path))
            handled.formIntersection(newer)
        }
        return ready
    }

    /// Partial downloads and copies that are replaced by the real file when they finish.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    /// The folder's direct contents: regular files and packages (like Pages documents), but not hidden files,
    /// subfolders or partial downloads.
    public static func scan(_ folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .addedToDirectoryDateKey,
                                      .creationDateKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { url in
            guard !partialExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let size: Int64
            if values.isRegularFile == true {
                size = Int64(values.fileSize ?? 0)
            } else if values.isPackage == true {
                size = packageSize(url)
            } else {
                return nil
            }
            // Not every volume records the date added; a new copy's creation date is the next best thing.
            guard let added = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate else {
                return nil
            }
            return Entry(url: url, size: size, added: added)
        }
    }

    private static func packageSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

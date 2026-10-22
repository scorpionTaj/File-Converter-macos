import AppKit
import UniformTypeIdentifiers

/// Handles file-promise drags (Photos, Mail attachments, Safari images, …): items that only become real
/// files once the drop happens.
///
/// While the drag is in flight we only know the promised file *types*, so the wheel is built from
/// placeholder URLs carrying the right extension. On drop the files are received into a private inbox
/// under Caches, and results are saved to Downloads (or the custom folder) instead of next to them.
enum PromiseInbox {
    /// Fake folder for placeholder URLs. Never exists on disk.
    static let placeholderRoot = URL(fileURLWithPath: "/.kumquat-promised", isDirectory: true)

    static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Kumquat/Drops", isDirectory: true)
    }

    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.name = "Kumquat file promises"
        return queue
    }()

    static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func receivers(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    static func hasPromises(_ pasteboard: NSPasteboard) -> Bool {
        !receivers(on: pasteboard).isEmpty
    }

    /// One placeholder per promised file, e.g. `/.kumquat-promised/item-1.heic`.
    static func placeholders(for pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        for receiver in receivers(on: pasteboard) {
            let types = receiver.fileTypes.isEmpty ? [""] : receiver.fileTypes
            for type in types {
                let ext = UTType(type)?.preferredFilenameExtension ?? ""
                let name = "item-\(urls.count + 1)" + (ext.isEmpty ? "" : ".\(ext)")
                urls.append(placeholderRoot.appendingPathComponent(name))
            }
        }
        return urls
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        url.path.hasPrefix(placeholderRoot.path + "/")
    }

    /// Whether a real file lives in the inbox (results must not be saved next to it).
    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Receives every promised file on the pasteboard, then calls `completion` on the main actor.
    static func receive(from pasteboard: NSPasteboard, completion: @escaping @MainActor ([URL], String?) -> Void) {
        let promised = receivers(on: pasteboard)
        guard !promised.isEmpty else {
            Task { @MainActor in completion([], "Nothing was dropped.") }
            return
        }
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            Task { @MainActor in completion([], error.localizedDescription) }
            return
        }
        let expected = promised.reduce(0) { $0 + max($1.fileTypes.count, 1) }
        let collector = PromiseCollector(expected: expected, completion: completion)
        for receiver in promised {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                collector.add(error == nil ? url : nil, error: error)
            }
        }
        // Some sources report fewer files than promised; never hang the UI waiting for them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { collector.finish() }
    }

    /// Deletes drops older than a day.
    static func cleanUp(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: folder) }
        }
    }
}

/// Gathers asynchronously delivered promise files and reports once.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var errors: [String] = []
    private var delivered = 0
    private var finished = false
    private let expected: Int
    private let completion: @MainActor ([URL], String?) -> Void

    init(expected: Int, completion: @escaping @MainActor ([URL], String?) -> Void) {
        self.expected = expected
        self.completion = completion
    }

    func add(_ url: URL?, error: Error?) {
        lock.lock()
        delivered += 1
        if let url { urls.append(url) }
        if let error { errors.append(error.localizedDescription) }
        let done = delivered >= expected
        lock.unlock()
        if done { finish() }
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let message = result.isEmpty ? (errors.first ?? "The app didn't deliver the file.") : nil
        lock.unlock()
        let completion = self.completion
        Task { @MainActor in completion(result, message) }
    }
}

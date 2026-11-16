import Foundation
import KumquatCore

/// Watches the folders set up in Settings ▸ Presets and hands each file that finished arriving to `onReady`.
///
/// Each folder gets a kqueue source on the directory (fires when entries are added, removed or renamed) plus a
/// short poll while a file is still growing. Where each folder had got to is saved, so files added while
/// Kumquat wasn't running are converted at the next launch; a paused or newly added folder starts from now.
@MainActor
final class WatchFolderController {
    var onReady: ((WatchFolder, [URL]) -> Void)?

    private final class Watch {
        let folder: WatchFolder
        var tracker: WatchFolderTracker
        let source: DispatchSourceFileSystemObject
        var rescan: DispatchWorkItem?

        init(folder: WatchFolder, tracker: WatchFolderTracker, source: DispatchSourceFileSystemObject) {
            self.folder = folder
            self.tracker = tracker
            self.source = source
        }
    }

    private var watches: [UUID: Watch] = [:]
    private let defaults = UserDefaults.standard
    private static let checkpointsKey = "watchFolderCheckpoints"
    private static let pollInterval: TimeInterval = 1.5

    /// Folder id → `WatchFolderTracker.since`.
    private var checkpoints: [String: Date] {
        get { defaults.dictionary(forKey: Self.checkpointsKey) as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: Self.checkpointsKey) }
    }

    /// Starts, restarts or stops watchers to match `folders`; only enabled folders whose preset still exists run.
    func update(_ folders: [WatchFolder], presets: [OutputPreset]) {
        let presetIDs = Set(presets.map(\.id))
        let wanted = Dictionary(folders.filter { $0.isEnabled && presetIDs.contains($0.presetID) }.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        for (id, watch) in watches where wanted[id] != watch.folder {
            stop(id, forget: wanted[id]?.path != watch.folder.path)
        }
        // A paused or deleted folder starts from "now" when it comes back.
        checkpoints = checkpoints.filter { key, _ in UUID(uuidString: key).flatMap { wanted[$0] } != nil }
        for (id, folder) in wanted where watches[id] == nil {
            start(folder)
        }
    }

    private func start(_ folder: WatchFolder) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            AppLog.error("Watch folder \(folder.path) can't be opened; is it still there?")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: .main)
        let since = checkpoints[folder.id.uuidString] ?? Date()
        let watch = Watch(folder: folder, tracker: WatchFolderTracker(since: since), source: source)
        source.setEventHandler { [weak self, weak watch] in
            guard let self, let watch else { return }
            if !source.data.intersection([.delete, .rename]).isEmpty {
                AppLog.error("Watch folder \(folder.path) was moved or deleted; stopped watching it")
                self.stop(folder.id, forget: true)
                return
            }
            self.scan(watch)
        }
        source.setCancelHandler { close(descriptor) }
        watches[folder.id] = watch
        source.resume()
        AppLog.info("Watching \(folder.path)")
        // Catch up on files that arrived while Kumquat wasn't running.
        scan(watch)
    }

    private func stop(_ id: UUID, forget: Bool) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.rescan?.cancel()
        watch.source.cancel()
        if forget { checkpoints[id.uuidString] = nil }
    }

    func stopAll() {
        for id in Array(watches.keys) { stop(id, forget: false) }
    }

    private func scan(_ watch: Watch) {
        watch.rescan?.cancel()
        watch.rescan = nil
        let scannedAt = Date()
        let ready = watch.tracker.ready(WatchFolderTracker.scan(watch.folder.url), scannedAt: scannedAt)
        checkpoints[watch.folder.id.uuidString] = watch.tracker.since
        if watch.tracker.isWaiting {
            let item = DispatchWorkItem { [weak self, weak watch] in
                guard let self, let watch, self.watches[watch.folder.id] === watch else { return }
                self.scan(watch)
            }
            watch.rescan = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval, execute: item)
        }
        if !ready.isEmpty { onReady?(watch.folder, ready) }
    }
}

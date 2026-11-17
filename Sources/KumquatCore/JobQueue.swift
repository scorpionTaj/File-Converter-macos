import Foundation

/// One file (or one tool run) waiting in, running in or finished by the conversion queue.
public struct QueueItem: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting, running, done, failed(String), cancelled

        public var isFinished: Bool {
            switch self {
            case .waiting, .running: return false
            case .done, .failed, .cancelled: return true
            }
        }
    }

    public let id: UUID
    /// The drop (HUD job) this item belongs to; retried items move to a new job.
    public var job: Int
    public var title: String
    public var input: URL?
    public var state: State = .waiting
    public var progress: Double = 0
    public var outputs: [URL] = []
    /// Short result note ("Saved 38%").
    public var message: String?
    /// Problems with some of a tool's files while others succeeded.
    public var partialFailures: [String] = []

    public init(id: UUID = UUID(), job: Int, title: String, input: URL?) {
        self.id = id
        self.job = job
        self.title = title
        self.input = input
    }
}

/// The conversion queue's state: order, what may start next, pause/resume, reorder, retry and per-item
/// progress. A value type with no I/O, so every rule is unit-tested; the app owns the running tasks.
public struct JobQueue: Equatable, Sendable {
    public private(set) var items: [QueueItem] = []
    /// While paused nothing new starts; running items finish.
    public var isPaused = false
    /// Items that may run at once (Settings ▸ Quality ▸ Speed).
    public var maxRunning: Int

    public init(maxRunning: Int = 1) {
        self.maxRunning = max(1, maxRunning)
    }

    public func item(_ id: UUID) -> QueueItem? { items.first { $0.id == id } }

    public var running: [QueueItem] { items.filter { $0.state == .running } }
    public var waiting: [QueueItem] { items.filter { $0.state == .waiting } }
    public var failed: [QueueItem] { items.filter { if case .failed = $0.state { return true } else { return false } } }

    /// Overall progress of the unfinished work plus everything finished, for the menu bar (nil when idle).
    public var overallProgress: Double? {
        guard items.contains(where: { !$0.state.isFinished }) else { return nil }
        let active = items.filter { !$0.state.isFinished || $0.state == .done }
        return active.map { $0.state == .done ? 1 : $0.progress }.reduce(0, +) / Double(max(active.count, 1))
    }

    public mutating func add(_ newItems: [QueueItem]) {
        items += newItems
    }

    /// Waiting items to start now, in queue order, so that at most `maxRunning` run.
    public func nextToStart() -> [UUID] {
        guard !isPaused else { return [] }
        let free = maxRunning - running.count
        guard free > 0 else { return [] }
        return Array(waiting.prefix(free).map(\.id))
    }

    public mutating func markRunning(_ id: UUID) {
        update(id) { if $0.state == .waiting { $0.state = .running; $0.progress = 0 } }
    }

    /// Progress only moves forward while running (late reports from a cancelled task are ignored).
    public mutating func setProgress(_ id: UUID, _ fraction: Double) {
        update(id) { if $0.state == .running { $0.progress = max($0.progress, min(max(fraction, 0), 1)) } }
    }

    public mutating func finish(_ id: UUID, outputs: [URL], message: String? = nil, partialFailures: [String] = []) {
        update(id) {
            guard $0.state == .running else { return }
            $0.state = .done
            $0.progress = 1
            $0.outputs = outputs
            $0.message = message
            $0.partialFailures = partialFailures
        }
    }

    public mutating func fail(_ id: UUID, _ reason: String) {
        update(id) { if $0.state == .running { $0.state = .failed(reason) } }
    }

    /// Cancels a waiting or running item. Returns true when it was running, so its task must be stopped.
    @discardableResult
    public mutating func cancel(_ id: UUID) -> Bool {
        var wasRunning = false
        update(id) {
            guard !$0.state.isFinished else { return }
            wasRunning = $0.state == .running
            $0.state = .cancelled
        }
        return wasRunning
    }

    /// Cancels every unfinished item of `job`; returns the running ones to stop.
    public mutating func cancel(job: Int) -> [UUID] {
        items.filter { $0.job == job && !$0.state.isFinished }.map(\.id).filter { cancel($0) }
    }

    /// Puts a failed or cancelled item back in the queue under `job`. Returns false for other states.
    @discardableResult
    public mutating func retry(_ id: UUID, job: Int) -> Bool {
        var retried = false
        update(id) {
            switch $0.state {
            case .failed, .cancelled:
                $0.state = .waiting
                $0.progress = 0
                $0.outputs = []
                $0.message = nil
                $0.partialFailures = []
                $0.job = job
                retried = true
            default:
                break
            }
        }
        return retried
    }

    /// Moves items (List's onMove). Only order changes; running items keep running.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { items[$0] }
        var remaining = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertAt, 0), remaining.count))
        items = remaining
    }

    /// Moves a waiting item to the front of the waiting line, so it starts next.
    public mutating func moveToFront(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting else { return }
        let item = items.remove(at: index)
        let firstWaiting = items.firstIndex { $0.state == .waiting } ?? items.count
        items.insert(item, at: firstWaiting)
    }

    /// Removes finished items (done, failed, cancelled).
    public mutating func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    /// True once every item of `job` has finished.
    public func isFinished(job: Int) -> Bool {
        let members = items.filter { $0.job == job }
        return !members.isEmpty && members.allSatisfy(\.state.isFinished)
    }

    /// Results of a finished job, in queue order.
    public func results(job: Int) -> (outputs: [URL], failures: [String], messages: [String], cancelled: Int) {
        let members = items.filter { $0.job == job }
        var failures: [String] = []
        for item in members {
            failures += item.partialFailures
            if case .failed(let reason) = item.state {
                failures.append(members.count == 1 ? reason : "\(item.input?.lastPathComponent ?? item.title): \(reason)")
            }
        }
        return (members.flatMap(\.outputs), failures, members.compactMap(\.message),
                members.filter { $0.state == .cancelled }.count)
    }

    private mutating func update(_ id: UUID, _ change: (inout QueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

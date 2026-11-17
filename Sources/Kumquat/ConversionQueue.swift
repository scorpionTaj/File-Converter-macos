import AppKit
import SwiftUI
import KumquatCore

/// What one queued item produced.
struct QueueOutcome: Sendable {
    var outputs: [URL]
    var message: String? = nil
    /// A tool's files that failed while others succeeded.
    var failures: [String] = []
}

/// Work for one queue item, given a progress callback (0…1).
typealias QueueWork = @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> QueueOutcome

/// Runs every conversion and tool job through one queue (`JobQueue` holds the rules), so the Queue window
/// can pause, reorder, cancel and retry them and show each file's progress.
@MainActor
final class ConversionQueue: ObservableObject {
    @Published private(set) var state = JobQueue()

    /// A HUD job and undo journal for retried items: (title) -> (job, journal).
    var makeJob: ((String) -> (Int, UndoJournal))?
    /// A job's overall progress, for the HUD.
    var onJobProgress: ((Int, Double) -> Void)?
    /// Every item of a job has finished: (job, outputs, failures, message, all cancelled).
    var onJobFinished: ((Int, [URL], [String], String?, Bool) -> Void)?
    /// Overall progress for the menu bar; nil when idle.
    var onOverallProgress: ((Double?) -> Void)?

    private var work: [UUID: QueueWork] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var journals: [Int: UndoJournal] = [:]

    var hasUnfinishedWork: Bool { state.items.contains { !$0.state.isFinished } }

    var maxRunning: Int {
        get { state.maxRunning }
        set {
            state.maxRunning = max(1, newValue)
            pump()
        }
    }

    /// Adds a job's items; they start as slots free up, in queue order.
    func enqueue(job: Int, journal: UndoJournal, items: [(title: String, input: URL?, work: QueueWork)]) {
        journals[job] = journal
        let queued = items.map { QueueItem(job: job, title: $0.title, input: $0.input) }
        for (item, entry) in zip(queued, items) { work[item.id] = entry.work }
        state.add(queued)
        pump()
    }

    var isPaused: Bool {
        get { state.isPaused }
        set {
            state.isPaused = newValue
            pump()
        }
    }

    func cancel(job: Int) {
        state.cancel(job: job).forEach { tasks[$0]?.cancel() }
        checkFinished(job: job)
        pump()
    }

    func cancel(_ id: UUID) {
        guard let job = state.item(id)?.job else { return }
        if state.cancel(id) { tasks[id]?.cancel() }
        checkFinished(job: job)
        pump()
    }

    func retry(_ ids: [UUID]) {
        let retriable = ids.filter { id in
            switch state.item(id)?.state {
            case .failed, .cancelled: return work[id] != nil
            default: return false
            }
        }
        guard !retriable.isEmpty, let makeJob else { return }
        let first = state.item(retriable[0])?.title ?? ""
        let title = retriable.count == 1 ? L("Retry \(first)") : L("Retry \(retriable.count) files")
        let (job, journal) = makeJob(title)
        journals[job] = journal
        retriable.forEach { state.retry($0, job: job) }
        pump()
    }

    func retryAllFailed() { retry(state.failed.map(\.id)) }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        state.move(fromOffsets: source, toOffset: destination)
        pump()
    }

    func startNext(_ id: UUID) {
        state.moveToFront(id)
        pump()
    }

    func clearFinished() {
        let finished = state.items.filter(\.state.isFinished).map(\.id)
        state.clearFinished()
        finished.forEach { work[$0] = nil }
    }

    private func pump() {
        for id in state.nextToStart() {
            guard let run = work[id], let item = state.item(id) else { continue }
            state.markRunning(id)
            let journal = journals[item.job] ?? UndoJournal()
            tasks[id] = Task { [weak self] in
                let result: Result<QueueOutcome, Error>
                do {
                    let outcome = try await UndoJournal.$current.withValue(journal) {
                        try await run { fraction in
                            Task { @MainActor in self?.progress(id, fraction) }
                        }
                    }
                    result = .success(outcome)
                } catch {
                    result = .failure(error)
                }
                self?.complete(id, result)
            }
        }
        onOverallProgress?(state.overallProgress)
    }

    private func progress(_ id: UUID, _ fraction: Double) {
        state.setProgress(id, fraction)
        guard let job = state.item(id)?.job else { return }
        let members = state.items.filter { $0.job == job && $0.state != .cancelled }
        if !members.isEmpty {
            onJobProgress?(job, members.map { $0.state == .done ? 1 : $0.progress }.reduce(0, +) / Double(members.count))
        }
        onOverallProgress?(state.overallProgress)
    }

    private func complete(_ id: UUID, _ result: Result<QueueOutcome, Error>) {
        tasks[id] = nil
        switch result {
        case .success(let outcome):
            state.finish(id, outputs: outcome.outputs, message: outcome.message, partialFailures: outcome.failures)
        case .failure(let error) where error is CancellationError:
            state.cancel(id)
        case .failure(let error):
            state.fail(id, error.localizedDescription)
        }
        if let job = state.item(id)?.job { checkFinished(job: job) }
        pump()
    }

    private func checkFinished(job: Int) {
        guard state.isFinished(job: job), journals[job] != nil else { return }
        journals[job] = nil
        let results = state.results(job: job)
        let members = state.items.filter { $0.job == job }
        let message = results.messages.isEmpty ? nil
            : results.messages.count == 1 ? results.messages[0] : results.messages.joined(separator: " · ")
        onJobFinished?(job, results.outputs, results.failures, message, results.cancelled == members.count)
        onOverallProgress?(state.overallProgress)
    }
}

// MARK: - Window

@MainActor
final class QueueWindowController {
    static let shared = QueueWindowController()
    private var window: NSWindow?

    func show(queue: ConversionQueue) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = L("Kumquat Queue")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 460, height: 260)
            window.contentViewController = NSHostingController(rootView: QueueView(queue: queue))
            window.setContentSize(NSSize(width: 640, height: 460))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct QueueView: View {
    @ObservedObject var queue: ConversionQueue

    var body: some View {
        let state = queue.state
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    queue.isPaused.toggle()
                } label: {
                    Label(state.isPaused ? "Resume" : "Pause", systemImage: state.isPaused ? "play.fill" : "pause.fill")
                }
                .help(state.isPaused ? L("Start waiting files again") : L("Finish what's running, then wait"))
                Button {
                    queue.retryAllFailed()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
                .disabled(state.failed.isEmpty)
                Button {
                    queue.clearFinished()
                } label: {
                    Label("Clear Finished", systemImage: "xmark.circle")
                }
                .disabled(!state.items.contains { $0.state.isFinished })
                Spacer()
                Text(summary(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if state.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Nothing in the queue").foregroundStyle(.secondary)
                    Text("Conversions and tools show here while they run. Drag waiting files to change their order.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.items) { item in
                        QueueRow(item: item, queue: queue)
                    }
                    .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, minHeight: 260)
    }

    private func summary(_ state: JobQueue) -> String {
        var parts: [String] = []
        if state.isPaused { parts.append("Paused") }
        if !state.running.isEmpty { parts.append("\(state.running.count) running") }
        if !state.waiting.isEmpty { parts.append("\(state.waiting.count) waiting") }
        if !state.failed.isEmpty { parts.append("\(state.failed.count) failed") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let queue: ConversionQueue

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running:
                    ProgressView(value: item.progress).progressViewStyle(.linear)
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                case .done:
                    Text(item.message ?? (item.outputs.count == 1 ? item.outputs[0].lastPathComponent : "\(item.outputs.count) files"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .waiting:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 2)
        .contextMenu {
            if item.state == .waiting { Button("Start Next") { queue.startNext(item.id) } }
            if !item.state.isFinished { Button("Cancel") { queue.cancel(item.id) } }
            if case .failed = item.state { Button("Retry") { queue.retry([item.id]) } }
            if item.state == .cancelled { Button("Retry") { queue.retry([item.id]) } }
            if !item.outputs.isEmpty { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) } }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.state {
        case .waiting, .running:
            Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Cancel")
        case .failed, .cancelled:
            Button { queue.retry([item.id]) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Retry")
        case .done:
            if !item.outputs.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
    }
}

import AppKit

/// Watches for file drags anywhere on screen and reports when a modifier key is tapped mid-drag.
///
/// No Accessibility or Input Monitoring permission is needed: global *mouse* monitors are allowed for
/// every app, and while a drag is active the modifier state is polled with `NSEvent.modifierFlags`.
@MainActor
final class DragMonitor: NSObject {
    var isEnabled = true
    /// Called when a modifier is newly pressed during a file drag.
    var onModifierPressed: ((NSEvent.ModifierFlags, [URL]) -> Void)?
    /// Called once the mouse button is released.
    var onDragEnded: (() -> Void)?

    private(set) var currentURLs: [URL] = []
    private var monitor: Any?
    private var pollTimer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var lastChangeCount: Int
    private var previousFlags: NSEvent.ModifierFlags = []
    private static let watchedFlags: [NSEvent.ModifierFlags] = [.shift, .command, .control, .option]

    override init() {
        lastChangeCount = dragPasteboard.changeCount
        super.init()
    }

    var isDragging: Bool { pollTimer != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.mouseDragged() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endSession()
    }

    private func mouseDragged() {
        guard isEnabled, pollTimer == nil else { return }
        let changeCount = dragPasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        var urls = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            // Photos, Mail, Safari… promise files instead of handing over URLs.
            urls = PromiseInbox.placeholders(for: dragPasteboard)
        }
        guard !urls.isEmpty else { return }
        currentURLs = urls
        // Keys already held when the drag started (e.g. ⌘ to move in Finder) don't count as a tap.
        previousFlags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func poll() {
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            endSession()
            onDragEnded?()
            return
        }
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        let pressed = flags.subtracting(previousFlags)
        previousFlags = flags
        for flag in Self.watchedFlags where pressed.contains(flag) {
            onModifierPressed?(flag, currentURLs)
        }
    }

    private func endSession() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastChangeCount = dragPasteboard.changeCount
    }
}

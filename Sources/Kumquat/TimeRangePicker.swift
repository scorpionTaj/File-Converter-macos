import AppKit
import AVFoundation
import AVKit
import KumquatCore

/// A player with AVKit's trimming scrubber (the same one QuickTime uses) for choosing part of a clip.
/// Produces a `TimeRange` spec ("12.400-18.000") for Trim and GIF from Clip. Files AVFoundation can't
/// play (MKV, WebM…) fall back to typing the range.
@MainActor
final class TimeRangeWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [TimeRangeWindowController] = []

    private let playerView = AVPlayerView()
    private let player: AVPlayer
    private let onDone: (String) -> Void
    private var statusObservation: NSKeyValueObservation?
    private var finished = false

    /// Shows the scrubber for `url`, or calls `fallback` when the file can't be played here.
    static func present(url: URL, title: String, onDone: @escaping (String) -> Void, fallback: @escaping () -> Void) {
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard playable else {
                fallback()
                return
            }
            let controller = TimeRangeWindowController(url: url, asset: asset, title: title, onDone: onDone, fallback: fallback)
            open.append(controller)
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    private init(url: URL, asset: AVURLAsset, title: String, onDone: @escaping (String) -> Void, fallback: @escaping () -> Void) {
        self.onDone = onDone
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "\(title.replacingOccurrences(of: "…", with: "")) — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 300)
        super.init(window: window)
        window.delegate = self

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true
        playerView.setAccessibilityLabel(L("Drag the yellow handles to choose the part to keep"))
        window.contentView = playerView
        window.center()

        // Trimming can only start once the item is ready.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: self.beginTrimming()
                case .failed:
                    self.finish(nil)
                    fallback()
                default: break
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func beginTrimming() {
        guard statusObservation != nil, playerView.canBeginTrimming else { return }
        statusObservation = nil
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard result == .okButton, let item = self.player.currentItem else {
                    self.finish(nil)
                    return
                }
                self.finish(Self.spec(start: item.reversePlaybackEndTime, end: item.forwardPlaybackEndTime,
                                      duration: item.duration))
            }
        }
    }

    /// "start-end" in seconds; an untouched handle means "from the start" / "to the end".
    static func spec(start: CMTime, end: CMTime, duration: CMTime) -> String {
        let from = start.isNumeric ? max(0, start.seconds) : 0
        var to: Double? = end.isNumeric ? end.seconds : nil
        if let value = to, duration.isNumeric, value >= duration.seconds - 0.01 { to = nil }
        return TimeRange(start: from, end: to).spec
    }

    private func finish(_ spec: String?) {
        guard !finished else { return }
        finished = true
        player.pause()
        window?.close()
        if let spec { onDone(spec) }
    }

    func windowWillClose(_ notification: Notification) {
        finished = true
        player.pause()
        statusObservation = nil
        Self.open.removeAll { $0 === self }
    }
}

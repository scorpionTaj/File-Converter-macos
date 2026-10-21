#if os(macOS)
import AppKit
import KumquatCore

/// Menu bar item: enable/disable, open files without dragging, recent results, settings.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Kumquat — drop files here, or drag a file and tap a key"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            // Files dropped on the menu bar icon open the click-driven wheel.
            let dropView = StatusDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onClick = { [weak self] in self?.statusItem.button?.performClick(nil) }
            dropView.onDrop = { [weak self] urls in self?.showWheelBelowIcon(for: urls) }
            dropView.onDropFailed = { [weak app] message in app?.hud.failure("Couldn't receive the file", detail: message) }
            button.addSubview(dropView)
        }
    }

    private func showWheelBelowIcon(for urls: [URL]) {
        guard let app else { return }
        var point = NSEvent.mouseLocation
        if let frame = statusItem.button?.window?.frame {
            point = NSPoint(x: frame.midX, y: frame.minY - 240)
        }
        app.showWheel(for: urls, at: point)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let app else { return }
        let settings = app.settings

        let header = NSMenuItem(title: "Drag a file, then tap \(settings.convertKey.symbol) \(settings.toolsKey.symbol) \(settings.actionsKey.symbol)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = settings.isEnabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Convert Files…", action: #selector(openFiles), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if app.recentOutputs.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        }
        for url in app.recentOutputs {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            recentMenu.addItem(item)
        }
        if !app.recentOutputs.isEmpty {
            recentMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Recent", action: #selector(clearRecents), keyEquivalent: "")
            clear.target = self
            recentMenu.addItem(clear)
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "How to Use Kumquat", action: #selector(showWelcome), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        let log = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kumquat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        guard let app else { return }
        app.setEnabled(!app.settings.isEnabled)
    }

    @objc private func openFiles() {
        app?.openFilesWithWheel()
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func clearRecents() {
        app?.clearRecents()
    }

    @objc private func showLog() {
        let url = AppLog.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            AppLog.info("Log opened")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showWelcome() {
        guard let app else { return }
        WindowManager.shared.showWelcome(app: app)
    }

    @objc private func showSettings() {
        guard let app else { return }
        WindowManager.shared.showSettings(app: app)
    }
}

/// Transparent overlay on the status item button that accepts file (and file-promise) drops
/// and forwards clicks to the button so the menu still opens.
final class StatusDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onDropFailed: ((String) -> Void)?
    var onClick: (() -> Void)?
    private var isTargeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL] + PromiseInbox.pasteboardTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard isTargeted else { return }
        NSColor.systemOrange.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted = true
        return RadialMenuView.acceptedOperation(for: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            Task { @MainActor [weak self] in self?.onDrop?(urls) }
            return true
        }
        guard PromiseInbox.hasPromises(pasteboard) else { return false }
        PromiseInbox.receive(from: pasteboard) { [weak self] received, message in
            if received.isEmpty {
                self?.onDropFailed?(message ?? "The file couldn't be received.")
            } else {
                self?.onDrop?(received)
            }
        }
        return true
    }
}

/// A kumquat slice drawn as a template image, so it adapts to light/dark menu bars.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY - 0.5)
            let radius: CGFloat = 6.8
            NSColor.black.set()
            let rind = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            rind.lineWidth = 1.6
            rind.stroke()
            for segment in 0..<6 {
                let angle = CGFloat(segment) * .pi / 3 + .pi / 6
                let spoke = NSBezierPath()
                spoke.move(to: center)
                spoke.line(to: NSPoint(x: center.x + cos(angle) * (radius - 2.2), y: center.y + sin(angle) * (radius - 2.2)))
                spoke.lineWidth = 1.1
                spoke.stroke()
            }
            let leaf = NSBezierPath(ovalIn: NSRect(x: center.x + 1.5, y: center.y + radius - 0.5, width: 5.5, height: 3))
            leaf.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
#endif

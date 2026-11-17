import AppKit
import KumquatCore

/// A small floating window that takes file drops and opens the click-driven wheel, for people who find
/// "drag, then tap a key" awkward on a trackpad. Drag its background to move it; right-click to hide it.
@MainActor
final class DropShelf: NSObject {
    var onDrop: (([URL], NSPoint) -> Void)?
    var onDropFailed: ((String) -> Void)?
    /// The user chose "Hide Shelf" on the shelf itself.
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    private static let size = NSSize(width: 96, height: 96)

    func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { panel = makePanel() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(origin: .zero, size: Self.size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: L("Drop files"))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        let drop = FileDropView(frame: frame)
        drop.autoresizingMask = [.width, .height]
        drop.highlightRadius = 18
        drop.toolTip = L("Drop files here to open Kumquat's wheel. Drag to move; right-click to hide.")
        drop.setAccessibilityElement(true)
        drop.setAccessibilityRole(.group)
        drop.setAccessibilityLabel(L("Kumquat drop shelf"))
        drop.onMouseDown = { [weak panel] event in panel?.performDrag(with: event) }
        drop.onRightMouseDown = { [weak self, weak drop] event in
            guard let self, let drop else { return }
            let menu = NSMenu()
            let hide = NSMenuItem(title: L("Hide Shelf"), action: #selector(self.hideFromMenu), keyEquivalent: "")
            hide.target = self
            menu.addItem(hide)
            NSMenu.popUpContextMenu(menu, with: event, for: drop)
        }
        drop.onDrop = { [weak self, weak panel] urls in
            guard let panel else { return }
            self?.onDrop?(urls, NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        }
        drop.onDropFailed = { [weak self] message in self?.onDropFailed?(message) }
        background.addSubview(drop)
        panel.contentView = background

        // Remembers where the user left it; starts at the right edge of the main screen.
        if !panel.setFrameUsingName("DropShelf"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - 24, y: screen.midY - Self.size.height / 2))
        }
        panel.setFrameAutosaveName("DropShelf")
        return panel
    }

    @objc private func hideFromMenu() {
        setVisible(false)
        onHide?()
    }
}

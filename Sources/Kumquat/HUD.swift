#if os(macOS)
import AppKit

/// Small toast in the top-right corner showing progress and results. Click it to reveal the output.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private var revealURLs: [URL] = []
    private var dismissTask: Task<Void, Never>?
    private var activeJob = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 66),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = ClickableEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 66))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.onClick = { [weak self] in self?.handleClick() }
        panel.contentView = background

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small

        for view in [iconView, titleLabel, detailLabel, progressBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])
    }

    /// Starts a job; returns its id for progress updates.
    @discardableResult
    func begin(_ title: String, detail: String = "Working…") -> Int {
        activeJob += 1
        dismissTask?.cancel()
        revealURLs = []
        iconView.image = symbol("arrow.triangle.2.circlepath", color: .systemOrange)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = true
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        present()
        return activeJob
    }

    func progress(_ fraction: Double, job: Int) {
        guard job == activeJob else { return }
        progressBar.doubleValue = fraction
    }

    func success(_ title: String, detail: String, reveal urls: [URL] = []) {
        finish(title: title, detail: detail, symbolName: "checkmark.circle.fill", color: .systemGreen, linger: 2.8)
        revealURLs = urls
    }

    func failure(_ title: String, detail: String, reveal urls: [URL] = []) {
        finish(title: title, detail: detail, symbolName: "xmark.octagon.fill", color: .systemRed, linger: 6)
        revealURLs = urls
    }

    /// Whether `job` is the most recently started job (older jobs finishing shouldn't hijack the HUD).
    func isCurrent(_ job: Int) -> Bool { job == activeJob }

    /// A quick notice. Doesn't start a job, so a conversion running in the background still reports its result.
    func info(_ title: String, detail: String) {
        finish(title: title, detail: detail, symbolName: "info.circle.fill", color: .systemOrange, linger: 2.5)
    }

    private func finish(title: String, detail: String, symbolName: String, color: NSColor, linger: Double) {
        iconView.image = symbol(symbolName, color: color)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = false
        progressBar.isHidden = true
        present()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12))
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.panel.orderOut(nil) }
        })
    }

    private func handleClick() {
        if !revealURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealURLs) }
        dismissTask?.cancel()
        dismiss()
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .tinted(color)
    }
}

final class ClickableEffectView: NSVisualEffectView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}
#endif

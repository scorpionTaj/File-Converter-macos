import AppKit

/// Small toast in the top-right corner showing progress and results. Click it to reveal the output.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    /// Solid themed backing drawn over the blur when a fixed theme is chosen.
    private let tintView = NSView()
    private let cancelButton = NSButton()
    private var revealURLs: [URL] = []
    /// Called with the job id when the user clicks the cancel button.
    var onCancel: ((Int) -> Void)?
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
        tintView.frame = background.bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        background.addSubview(tintView)

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

        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        cancelButton.isBordered = false
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.isHidden = true

        for view in [iconView, titleLabel, detailLabel, progressBar, cancelButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            cancelButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 18),
            cancelButton.heightAnchor.constraint(equalToConstant: 18),
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
        applyTheme()
        iconView.image = symbol("arrow.triangle.2.circlepath", color: theme.accent)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = true
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        cancelButton.isHidden = onCancel == nil
        present()
        return activeJob
    }

    func progress(_ fraction: Double, job: Int) {
        guard job == activeJob else { return }
        progressBar.doubleValue = fraction
    }

    func success(_ title: String, detail: String, reveal urls: [URL] = []) {
        let settings = SettingsStore.shared
        guard settings.hudShowsSuccess else {
            dismissTask?.cancel()
            if panel.isVisible { dismiss() }
            return
        }
        finish(title: title, detail: detail, symbolName: "checkmark.circle.fill", color: theme.success,
               linger: settings.hudDuration)
        revealURLs = urls
    }

    func failure(_ title: String, detail: String, reveal urls: [URL] = []) {
        let duration = SettingsStore.shared.hudDuration
        // Errors need time to read: at least six seconds, or until clicked.
        finish(title: title, detail: detail, symbolName: "xmark.octagon.fill", color: theme.failure,
               linger: duration == 0 ? 0 : max(duration, 6))
        revealURLs = urls
    }

    /// Whether `job` is the most recently started job (older jobs finishing shouldn't hijack the HUD).
    func isCurrent(_ job: Int) -> Bool { job == activeJob }

    /// A quick notice. Doesn't start a job, so a conversion running in the background still reports its result.
    func info(_ title: String, detail: String) {
        finish(title: title, detail: detail, symbolName: "info.circle.fill", color: theme.accent, linger: 2.5)
    }

    private var theme: Theme { SettingsStore.shared.resolvedTheme }

    /// Themes other than the adaptive default pin the HUD's appearance and tint it.
    private func applyTheme() {
        let theme = Theme.named(SettingsStore.shared.themeID)
        panel.appearance = theme.appearance
        titleLabel.textColor = theme.isDark == nil ? .labelColor : theme.text
        detailLabel.textColor = theme.isDark == nil ? .secondaryLabelColor : theme.secondaryText
        tintView.layer?.backgroundColor = theme.isDark == nil ? nil : theme.hub.withAlphaComponent(0.94).cgColor
    }

    private func finish(title: String, detail: String, symbolName: String, color: NSColor, linger: Double) {
        applyTheme()
        iconView.image = symbol(symbolName, color: color)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = false
        progressBar.isHidden = true
        cancelButton.isHidden = true
        present()
        dismissTask?.cancel()
        // 0 means "stay until clicked".
        guard linger > 0 else { return }
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
        let top = visible.maxY - size.height - 12, bottom = visible.minY + 16
        let left = visible.minX + 16, right = visible.maxX - size.width - 16
        let origin: NSPoint
        switch SettingsStore.shared.hudPosition {
        case .topRight: origin = NSPoint(x: right, y: top)
        case .topCenter: origin = NSPoint(x: visible.midX - size.width / 2, y: top)
        case .topLeft: origin = NSPoint(x: left, y: top)
        case .bottomRight: origin = NSPoint(x: right, y: bottom)
        case .bottomLeft: origin = NSPoint(x: left, y: bottom)
        }
        panel.setFrameOrigin(origin)
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

    @objc private func cancelPressed() {
        cancelButton.isHidden = true
        progressBar.isHidden = true
        detailLabel.isHidden = false
        detailLabel.stringValue = "Cancelling…"
        onCancel?(activeJob)
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

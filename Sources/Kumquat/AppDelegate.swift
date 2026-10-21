#if os(macOS)
import AppKit
import KumquatCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore.shared
    let hud = HUDController()
    private let dragMonitor = DragMonitor()
    private let wheel = RadialMenuController()
    private var statusBar: StatusBarController?
    private lazy var actions = FileActions(settings: settings, hud: hud)
    private(set) var recentOutputs: [URL] = []

    /// Rebuilt per use so changed tool paths in Settings apply immediately.
    var converter: Converter { Converter(tools: settings.toolLocator) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(app: self)

        dragMonitor.isEnabled = settings.isEnabled
        dragMonitor.onModifierPressed = { [weak self] flag, urls in
            self?.modifierPressed(flag, urls: urls)
        }
        dragMonitor.onDragEnded = { [weak self] in self?.wheel.dragEnded() }
        dragMonitor.start()

        wheel.onSelect = { [weak self] item, urls in self?.perform(item, urls: urls) }
        wheel.itemsProvider = { [weak self] mode, urls in self?.items(for: mode, urls: urls) ?? [] }

        if !settings.hasSeenWelcome {
            settings.hasSeenWelcome = true
            WindowManager.shared.showWelcome(app: self)
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        dragMonitor.isEnabled = enabled
        if !enabled { wheel.hide() }
    }

    // MARK: Wheel

    func items(for mode: WheelMode, urls: [URL]) -> [WheelItem] {
        converter.catalog().items(for: mode, inputs: urls)
    }

    private func modifierPressed(_ flag: NSEvent.ModifierFlags, urls: [URL]) {
        // Settings can toggle `isEnabled` directly, so check it here rather than only in the monitor.
        guard settings.isEnabled, let mode = settings.mode(for: flag) else { return }
        // Tapping the same key again closes the wheel.
        if wheel.isVisible, wheel.currentMode == mode {
            wheel.hide()
            return
        }
        let wheelItems = items(for: mode, urls: urls)
        guard !wheelItems.isEmpty else {
            hud.info("Nothing to \(mode.title.lowercased())", detail: "Kumquat has no \(mode.title.lowercased()) for this file type.")
            return
        }
        wheel.show(mode: mode, items: wheelItems, urls: urls, at: NSEvent.mouseLocation, interaction: .drag,
                   scale: CGFloat(settings.wheelScale))
    }

    /// "Convert File…" from the menu bar: pick files, then use the wheel with clicks.
    func openFilesWithWheel() {
        let urls = Prompt.chooseFiles()
        guard !urls.isEmpty else { return }
        let mode = WheelMode.allCases.first { !items(for: $0, urls: urls).isEmpty } ?? .actions
        let screen = NSScreen.main?.visibleFrame ?? .zero
        wheel.show(mode: mode, items: items(for: mode, urls: urls), urls: urls,
                   at: NSPoint(x: screen.midX, y: screen.midY), interaction: .click, scale: CGFloat(settings.wheelScale))
    }

    // MARK: Running

    func perform(_ item: WheelItem, urls: [URL]) {
        switch item.payload {
        case .action(let action):
            actions.perform(action, urls: urls)
        case .convert(let format):
            convert(urls, to: format)
        case .tool(let tool):
            run(tool, urls: urls)
        }
    }

    private func convert(_ dropped: [URL], to target: Format) {
        let urls = dropped.filter { FormatRegistry.format(for: $0) != target }
        guard !urls.isEmpty else {
            hud.info("Already \(target.shortName)", detail: "Nothing to convert.")
            return
        }
        let converter = self.converter
        let options = settings.options
        let title = urls.count == 1
            ? "\(urls[0].lastPathComponent) → \(target.shortName)"
            : "\(urls.count) files → \(target.shortName)"
        let job = hud.begin(title)
        Task {
            var outputs: [URL] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                do {
                    let output = try await converter.convert(url, to: target, options: options) { [weak self] fraction in
                        Task { @MainActor in self?.hud.progress((Double(index) + fraction) / Double(urls.count), job: job) }
                    }
                    outputs.append(output)
                } catch {
                    failures.append(urls.count == 1 ? error.localizedDescription : "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            finish(outputs: outputs, failures: failures, message: nil)
        }
    }

    private func run(_ tool: ToolID, urls: [URL]) {
        var parameter: String?
        if let input = tool.input {
            switch input {
            case .password(let prompt): parameter = Prompt.ask(title: tool.title, message: prompt, secure: true)
            case .text(let prompt): parameter = Prompt.ask(title: tool.title, message: prompt, secure: false)
            }
            guard parameter != nil else { return }
        }
        let toolParameter = parameter
        let converter = self.converter
        let options = settings.options
        let job = hud.begin(tool.title, detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        Task {
            do {
                let outcome = try await converter.run(tool, inputs: urls, parameter: toolParameter, options: options) { [weak self] fraction in
                    Task { @MainActor in self?.hud.progress(fraction, job: job) }
                }
                if let text = outcome.clipboardText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                finish(outputs: outcome.outputs, failures: [], message: outcome.message)
            } catch {
                finish(outputs: [], failures: [error.localizedDescription], message: nil)
            }
        }
    }

    private func finish(outputs: [URL], failures: [String], message: String?) {
        if !outputs.isEmpty {
            recentOutputs = Array((outputs + recentOutputs).prefix(12))
            if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
        if failures.isEmpty {
            let detail = message ?? (outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files saved")
            hud.success(outputs.isEmpty ? "Done" : "Saved", detail: detail, reveal: outputs)
            if settings.playSound { NSSound(named: "Glass")?.play() }
        } else if outputs.isEmpty {
            hud.failure("Couldn't finish", detail: failures.joined(separator: "\n"))
            if settings.playSound { NSSound(named: "Basso")?.play() }
        } else {
            hud.failure("\(outputs.count) saved, \(failures.count) failed", detail: failures.joined(separator: "\n"))
        }
    }
}
#endif

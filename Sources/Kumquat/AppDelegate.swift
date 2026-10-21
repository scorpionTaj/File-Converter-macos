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
    /// Per-file progress of the running batch, keyed by HUD job id.
    private var batchProgress: [Int: [Double]] = [:]

    /// Files converted at the same time in a batch.
    static let batchConcurrency = 3

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
        wheel.onDropFailed = { [weak self] message in self?.hud.failure("Couldn't receive the file", detail: message) }
        wheel.itemsProvider = { [weak self] mode, urls in self?.items(for: mode, urls: urls) ?? [] }

        // Finder ▸ Services ▸ "Open in Kumquat".
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        PromiseInbox.cleanUp()

        if !settings.hasSeenWelcome {
            settings.hasSeenWelcome = true
            WindowManager.shared.showWelcome(app: self)
        }
    }

    /// "Open With ▸ Kumquat", `open -a Kumquat file`, or files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        showWheel(for: urls.filter(\.isFileURL), at: NSEvent.mouseLocation)
    }

    /// Services menu entry declared in Info.plist (`NSMessage = openFiles`).
    @objc func openFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Select one or more files first." as NSString
            return
        }
        showWheel(for: urls, at: NSEvent.mouseLocation)
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

    /// Shows the click-driven wheel for files that arrived without a drag (menu, Services, Open With, menu-bar drop).
    func showWheel(for urls: [URL], at point: NSPoint) {
        guard !urls.isEmpty else { return }
        let mode = WheelMode.allCases.first { !items(for: $0, urls: urls).isEmpty } ?? .actions
        wheel.show(mode: mode, items: items(for: mode, urls: urls), urls: urls, at: point, interaction: .click,
                   scale: CGFloat(settings.wheelScale))
    }

    /// "Convert Files…" from the menu bar.
    func openFilesWithWheel() {
        let urls = Prompt.chooseFiles()
        let screen = NSScreen.main?.visibleFrame ?? .zero
        showWheel(for: urls, at: NSPoint(x: screen.midX, y: screen.midY))
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

    /// Options for this drop. Files received from a promise live in a cache folder, so their results go to
    /// Downloads unless the user picked a custom folder.
    func options(for urls: [URL]) -> ConversionOptions {
        var options = settings.options
        if urls.contains(where: PromiseInbox.contains), options.outputLocation == .besideOriginal {
            options.outputLocation = .downloads
        }
        return options
    }

    private func convert(_ dropped: [URL], to target: Format) {
        let urls = dropped.filter { FormatRegistry.format(for: $0) != target }
        guard !urls.isEmpty else {
            hud.info("Already \(target.shortName)", detail: "Nothing to convert.")
            return
        }
        let converter = self.converter
        let jobOptions = options(for: urls)
        let title = urls.count == 1
            ? "\(urls[0].lastPathComponent) → \(target.shortName)"
            : "\(urls.count) files → \(target.shortName)"
        let job = hud.begin(title)
        batchProgress[job] = Array(repeating: 0, count: urls.count)

        Task {
            var outputs: [(Int, URL)] = []
            var failures: [String] = []
            await withTaskGroup(of: (Int, URL?, String?).self) { group in
                var next = 0
                func enqueue() {
                    guard next < urls.count else { return }
                    let index = next
                    next += 1
                    group.addTask {
                        do {
                            let output = try await converter.convert(urls[index], to: target, options: jobOptions) { [weak self] fraction in
                                Task { @MainActor in self?.updateBatch(job: job, index: index, fraction: fraction) }
                            }
                            return (index, output, nil)
                        } catch {
                            let name = urls[index].lastPathComponent
                            return (index, nil, urls.count == 1 ? error.localizedDescription : "\(name): \(error.localizedDescription)")
                        }
                    }
                }
                for _ in 0..<min(Self.batchConcurrency, urls.count) { enqueue() }
                while let result = await group.next() {
                    let (index, output, failure) = result
                    if let output { outputs.append((index, output)) }
                    if let failure { failures.append(failure) }
                    updateBatch(job: job, index: index, fraction: 1)
                    enqueue()
                }
            }
            batchProgress[job] = nil
            finish(outputs: outputs.sorted { $0.0 < $1.0 }.map(\.1), failures: failures, message: nil, job: job)
        }
    }

    private func updateBatch(job: Int, index: Int, fraction: Double) {
        guard var fractions = batchProgress[job], index < fractions.count else { return }
        fractions[index] = max(fractions[index], min(fraction, 1))
        batchProgress[job] = fractions
        hud.progress(fractions.reduce(0, +) / Double(fractions.count), job: job)
    }

    private func run(_ tool: ToolID, urls: [URL]) {
        if tool == .imageAnnotate, let url = urls.first {
            let directory = OutputNamer.destinationDirectory(for: url, location: options(for: urls).outputLocation)
            AnnotationWindowController.present(url: url, outputDirectory: directory, hud: hud) { [weak self] saved in
                self?.recordOutputs([saved])
            }
            return
        }

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
        let jobOptions = options(for: urls)
        let job = hud.begin(tool.title, detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        Task {
            do {
                let outcome = try await converter.run(tool, inputs: urls, parameter: toolParameter, options: jobOptions) { [weak self] fraction in
                    Task { @MainActor in self?.hud.progress(fraction, job: job) }
                }
                if let text = outcome.clipboardText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                finish(outputs: outcome.outputs, failures: outcome.failures, message: outcome.message, job: job)
            } catch {
                finish(outputs: [], failures: [error.localizedDescription], message: nil, job: job)
            }
        }
    }

    private func recordOutputs(_ outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        recentOutputs = Array((outputs + recentOutputs.filter { !outputs.contains($0) }).prefix(12))
        if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    private func finish(outputs: [URL], failures: [String], message: String?, job: Int) {
        recordOutputs(outputs)
        // A newer job owns the HUD; don't replace its progress with this result.
        guard hud.isCurrent(job) else { return }
        if failures.isEmpty {
            let detail = message ?? (outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files saved")
            hud.success(outputs.isEmpty ? "Done" : "Saved", detail: detail, reveal: outputs)
            if settings.playSound { NSSound(named: "Glass")?.play() }
        } else if outputs.isEmpty {
            hud.failure("Couldn't finish", detail: failures.joined(separator: "\n"))
            if settings.playSound { NSSound(named: "Basso")?.play() }
        } else {
            hud.failure("\(outputs.count) saved, \(failures.count) failed", detail: failures.joined(separator: "\n"), reveal: outputs)
        }
    }
}
#endif

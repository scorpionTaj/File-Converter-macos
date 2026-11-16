import AppKit
import Combine
import KumquatCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore.shared
    let hud = HUDController()
    private let dragMonitor = DragMonitor()
    private let wheel = RadialMenuController()
    private var statusBar: StatusBarController?
    private lazy var actions = FileActions(settings: settings, hud: hud)
    private lazy var finderHotKey = GlobalHotKey { [weak self] in self?.showWheelForFinderSelection() }
    private var finderShortcutObserver: AnyCancellable?
    /// Per-file progress of the running batch, keyed by HUD job id.
    private var batchProgress: [Int: [Double]] = [:]
    /// Running jobs, so the HUD's cancel button can stop them.
    private var jobTasks: [Int: Task<Void, Never>] = [:]
    private var cancelledJobs: Set<Int> = []

    /// Recent results that still exist, newest first.
    var recentOutputs: [URL] {
        settings.recentPaths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clearRecents() { settings.recentPaths = [] }

    var hasRunningJobs: Bool { !jobTasks.isEmpty }

    /// Rebuilt per use so changed tool paths in Settings apply immediately.
    var converter: Converter { Converter(tools: settings.toolLocator) }

    /// Puts `kumquat-cli` on the PATH whenever Kumquat runs from Applications (not from the disk image,
    /// whose path disappears on eject). Silent: Settings ▸ Advanced offers a password-backed install.
    private func linkCommandLineTool() {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app", ApplicationsMover.isInstalled(bundle) else { return }
        do {
            if let link = try CommandLineTool.install(app: bundle) {
                AppLog.info("kumquat-cli available at \(link.path)")
            }
        } catch {
            AppLog.error("Couldn't link kumquat-cli: \(error.localizedDescription)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Kumquat at a time: a second copy would add a second menu-bar icon and double every wheel.
        if let identifier = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0 != NSRunningApplication.current }) {
            AppLog.info("Another Kumquat is already running (pid \(running.processIdentifier)); quitting this one.")
            running.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        AppLog.info("Kumquat \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") started")

        let crashedLastTime = CrashReporter.noteLaunch()
        statusBar = StatusBarController(app: self)
        hud.onCancel = { [weak self] job in self?.cancel(job: job) }
        UpdateController.shared.hud = hud
        if crashedLastTime {
            AppLog.error("The previous run ended unexpectedly")
            // After launch settles, so the alert doesn't race the welcome window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { CrashReporter.offerReportAfterCrash() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { UpdateController.shared.checkAutomaticallyIfDue() }
        }
        EngineMonitor.shared.refresh()

        dragMonitor.isEnabled = settings.isEnabled
        dragMonitor.onModifierPressed = { [weak self] flag, urls in
            self?.modifierPressed(flag, urls: urls)
        }
        dragMonitor.onDragEnded = { [weak self] in self?.wheel.dragEnded() }
        dragMonitor.start()

        wheel.onSelect = { [weak self] item, urls in self?.perform(item, urls: urls) }
        wheel.onDropFailed = { [weak self] message in
            AppLog.error("Drop failed: \(message)")
            self?.hud.failure("Couldn't receive the file", detail: message)
        }
        wheel.itemsProvider = { [weak self] mode, urls in self?.items(for: mode, urls: urls) ?? [] }

        // Finder ▸ Services ▸ "Open in Kumquat".
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        PromiseInbox.cleanUp()
        linkCommandLineTool()
        // Publishes the current value first, then every change made in Settings.
        finderShortcutObserver = settings.$finderShortcut.sink { [weak self] in self?.registerFinderShortcut($0) }

        if !settings.hasSeenWelcome {
            settings.hasSeenWelcome = true
            WindowManager.shared.showWelcome(app: self)
        }

        // Ask after the menu-bar icon is up, so the prompt doesn't appear out of nowhere.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            ApplicationsMover.offerIfNeeded(settings: settings)
        }
    }

    private func cancel(job: Int) {
        guard let task = jobTasks[job] else { return }
        cancelledJobs.insert(job)
        task.cancel()
        AppLog.info("Job \(job) cancelled")
    }

    /// "Open With ▸ Kumquat", `open -a Kumquat file`, or files dropped on the app icon.
    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.noteCleanExit()
    }

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
        wheel.show(mode: mode, items: wheelItems, urls: urls, at: wheelPoint(), interaction: .drag,
                   scale: CGFloat(settings.wheelScale))
    }

    /// Where a drag-summoned wheel opens: under the pointer, or the centre of the pointer's screen.
    private func wheelPoint() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        guard settings.wheelPosition == .screenCenter,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return mouse
        }
        return NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    }

    /// Shows the click-driven wheel for files that arrived without a drag (menu, Services, Open With, menu-bar drop).
    func showWheel(for urls: [URL], at point: NSPoint) {
        guard !urls.isEmpty else { return }
        let mode = WheelMode.allCases.first { !items(for: $0, urls: urls).isEmpty } ?? .actions
        wheel.show(mode: mode, items: items(for: mode, urls: urls), urls: urls, at: point, interaction: .click,
                   scale: CGFloat(settings.wheelScale))
    }

    private func registerFinderShortcut(_ shortcut: FinderShortcut) {
        finderHotKey.unregister()
        guard let key = shortcut.carbonKey else { return }
        if !finderHotKey.register(code: key.code, modifiers: key.modifiers) {
            AppLog.error("Couldn't register \(shortcut.title); another app may own it")
            hud.info("\(shortcut.title) is taken", detail: "Another app uses it. Pick a different shortcut in Settings ▸ General.")
        }
    }

    /// The global shortcut: the wheel for whatever is selected in Finder, no drag needed.
    func showWheelForFinderSelection() {
        guard settings.isEnabled else { return }
        switch FinderSelection.urls() {
        case .success(let urls) where !urls.isEmpty:
            showWheel(for: urls, at: wheelPoint())
        case .success:
            hud.info("Nothing selected in Finder", detail: "Select files in Finder, then press \(settings.finderShortcut.title).")
        case .failure(let error):
            AppLog.error("Finder selection: \(error.localizedDescription)")
            hud.failure("Couldn't read the Finder selection", detail: error.localizedDescription)
        }
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
        let concurrency = settings.parallelJobs
        let title = urls.count == 1
            ? "\(urls[0].lastPathComponent) → \(target.shortName)"
            : "\(urls.count) files → \(target.shortName)"
        let job = hud.begin(title)
        batchProgress[job] = Array(repeating: 0, count: urls.count)

        jobTasks[job] = Task {
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
                for _ in 0..<min(concurrency, urls.count) { enqueue() }
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
        let overall = fractions.reduce(0, +) / Double(fractions.count)
        hud.progress(overall, job: job)
        statusBar?.showProgress(overall)
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
        let concurrency = settings.parallelJobs
        let jobOptions = options(for: urls)
        let job = hud.begin(tool.title, detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        jobTasks[job] = Task {
            do {
                let outcome = try await converter.run(tool, inputs: urls, parameter: toolParameter, options: jobOptions,
                                                      concurrency: concurrency) { [weak self] fraction in
                    Task { @MainActor in
                        self?.hud.progress(fraction, job: job)
                        self?.statusBar?.showProgress(fraction)
                    }
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
        let paths = outputs.map(\.path)
        settings.recentPaths = Array((paths + settings.recentPaths.filter { !paths.contains($0) }).prefix(settings.recentLimit))
        if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    private func finish(outputs: [URL], failures: [String], message: String?, job: Int) {
        jobTasks[job] = nil
        if jobTasks.isEmpty { statusBar?.showProgress(nil) }
        recordOutputs(outputs)
        failures.forEach { AppLog.error($0) }
        if cancelledJobs.remove(job) != nil {
            if hud.isCurrent(job) {
                hud.info("Cancelled", detail: outputs.isEmpty ? "Nothing was saved." : "\(outputs.count) file(s) finished before cancelling.")
            }
            return
        }
        // A newer job owns the HUD; don't replace its progress with this result.
        guard hud.isCurrent(job) else { return }
        if failures.isEmpty {
            let detail = message ?? (outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files saved")
            hud.success(outputs.isEmpty ? "Done" : "Saved", detail: detail, reveal: outputs)
            settings.play(settings.successSound)
        } else if outputs.isEmpty {
            hud.failure("Couldn't finish", detail: failures.joined(separator: "\n"))
            settings.play(settings.failureSound)
        } else {
            hud.failure("\(outputs.count) saved, \(failures.count) failed", detail: failures.joined(separator: "\n"), reveal: outputs)
        }
    }
}

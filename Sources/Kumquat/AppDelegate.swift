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
    private let shelf = DropShelf()
    private let watchFolders = WatchFolderController()
    private var integrationObservers: [AnyCancellable] = []
    /// What running jobs move to the Trash, when they started and what they're called, for undo and notifications.
    private var jobJournals: [Int: UndoJournal] = [:]
    private var jobStarts: [Int: (title: String, date: Date)] = [:]
    /// Finished jobs that can be undone, oldest first.
    private var undoHistory: [(job: Int, record: JobRecord)] = []
    /// Every conversion and tool job runs through this queue (Queue window: pause, reorder, retry).
    let queue = ConversionQueue()
    private var cancelledJobs: Set<Int> = []

    /// Recent results that still exist, newest first.
    var recentOutputs: [URL] {
        settings.recentPaths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clearRecents() { settings.recentPaths = [] }

    var hasRunningJobs: Bool { queue.hasUnfinishedWork }

    /// Rebuilt per use so changed tool paths in Settings apply immediately.
    var converter: Converter { Converter(tools: settings.toolLocator, recipes: RecipeLibrary.shared.recipes) }

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
        setUpQueue()
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
        wheel.onTogglePin = { [weak self] item, mode, urls in self?.togglePin(item, mode: mode, urls: urls) ?? [] }

        // Finder ▸ Services ▸ "Open in Kumquat".
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        PromiseInbox.cleanUp()
        JobNotifier.shared.configure()
        JobNotifier.shared.onUndo = { [weak self] job in self?.undo(job: job) }
        linkCommandLineTool()
        // Publishes the current value first, then every change made in Settings.
        finderShortcutObserver = settings.$finderShortcut.sink { [weak self] in self?.registerFinderShortcut($0) }

        shelf.onDrop = { [weak self] urls, point in self?.showWheel(for: urls, at: point) }
        shelf.onDropFailed = { [weak self] message in self?.hud.failure("Couldn't receive the file", detail: message) }
        shelf.onHide = { [weak self] in self?.settings.showShelf = false }
        integrationObservers.append(settings.$showShelf.sink { [weak self] in self?.shelf.setVisible($0) })
        watchFolders.onReady = { [weak self] folder, urls in self?.convertArrivals(urls, in: folder) }
        integrationObservers.append(settings.$watchFolders.combineLatest(settings.$presets).sink { [weak self] folders, presets in
            self?.watchFolders.update(folders, presets: presets)
        })

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
        cancelledJobs.insert(job)
        queue.cancel(job: job)
        AppLog.info("Job \(job) cancelled")
    }

    /// Connects the queue to the HUD, menu bar, undo and notifications.
    private func setUpQueue() {
        queue.makeJob = { [weak self] title in
            guard let self else { return (0, UndoJournal()) }
            let job = self.hud.begin(title)
            return (job, self.beginJob(job, title: title))
        }
        queue.onJobProgress = { [weak self] job, fraction in self?.hud.progress(fraction, job: job) }
        queue.onOverallProgress = { [weak self] fraction in self?.statusBar?.showProgress(fraction) }
        queue.onJobFinished = { [weak self] job, outputs, failures, message, allCancelled in
            if allCancelled { self?.cancelledJobs.insert(job) }
            self?.finish(outputs: outputs, failures: failures, message: message, job: job)
        }
    }

    func showQueue() {
        QueueWindowController.shared.show(queue: queue)
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

    /// Wheel items in the user's order: pinned, then recently used, then the usual order. Presets lead the
    /// Convert wheel's usual order.
    func items(for mode: WheelMode, urls: [URL]) -> [WheelItem] {
        let catalog = converter.catalog()
        var items = catalog.items(for: mode, inputs: urls)
        if mode == .convert { items = catalog.presets(settings.presets, for: urls) + items }
        return settings.wheelPreferences.ordered(items, source: WheelPreferences.sourceKey(for: urls))
    }

    private func togglePin(_ item: WheelItem, mode: WheelMode, urls: [URL]) -> [WheelItem] {
        settings.wheelPreferences.togglePin(item.id, source: WheelPreferences.sourceKey(for: urls))
        return items(for: mode, urls: urls)
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
        settings.wheelPreferences.noteUsed(item.id, source: WheelPreferences.sourceKey(for: urls))
        switch item.payload {
        case .action(let action):
            actions.perform(action, urls: urls)
        case .convert(let format):
            // ⌥ while choosing a format (or the setting) shows the options first.
            let askForOptions = settings.askBeforeConverting || NSEvent.modifierFlags.contains(.option)
            convert(urls, to: format, askForOptions: askForOptions)
        case .preset(let preset):
            guard let format = preset.targetFormat else { return }
            convert(urls, to: format, overrides: preset.overrides, title: preset.name)
        case .tool(let tool):
            run(tool, urls: urls)
        }
    }

    /// Options for a job about to start: asks for the folder when set to "Ask each time" (nil if cancelled)
    /// and names the batch subfolder for multi-file jobs. Unattended jobs (watch folders) never ask; with
    /// "Ask each time" their results go next to the originals.
    private func prepareJobOptions(for urls: [URL], separateResults: Bool, unattended: Bool = false) -> ConversionOptions? {
        var options = options(for: urls)
        if settings.outputMode == .ask, !unattended {
            guard let folder = Prompt.chooseFolder(title: "Save results to") else { return nil }
            options.outputLocation = .folder(folder.path)
            // A folder chosen for this job wins over the per-kind folders.
            options.kindFolders = [:]
        }
        if settings.batchSubfolders, separateResults, urls.count > 1 {
            options.batchSubfolder = FileNameTemplate.render("Kumquat {date} {time}", name: "Kumquat", format: "")
        }
        return options
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

    /// Converts with the remembered choices for `target`, then `overrides` (a preset), then the options sheet.
    private func convert(_ dropped: [URL], to target: Format, overrides: OptionOverrides? = nil,
                         askForOptions: Bool = false, title presetName: String? = nil, unattended: Bool = false) {
        let urls = dropped.filter { FormatRegistry.format(for: $0) != target }
        guard !urls.isEmpty else {
            hud.info("Already \(target.shortName)", detail: "Nothing to convert.")
            return
        }
        var extra = settings.formatDefaults[target.id] ?? OptionOverrides()
        if let overrides { extra = extra.merged(with: overrides) }
        if askForOptions {
            var current = options(for: urls)
            extra.apply(to: &current, target: target)
            guard let choice = OptionsSheet.ask(target: target, sources: urls.compactMap(FormatRegistry.format(for:)),
                                                options: current, fileCount: urls.count) else { return }
            if choice.remember {
                var remembered = choice.overrides
                remembered.pdfPages = nil // page lists belong to one file
                settings.formatDefaults[target.id] = (settings.formatDefaults[target.id] ?? OptionOverrides()).merged(with: remembered)
            }
            extra = extra.merged(with: choice.overrides)
        }
        guard var prepared = prepareJobOptions(for: urls, separateResults: true, unattended: unattended) else { return }
        extra.apply(to: &prepared, target: target)
        let jobOptions = prepared
        let converter = self.converter
        let label = presetName ?? target.shortName
        let title = urls.count == 1
            ? "\(urls[0].lastPathComponent) → \(label)"
            : "\(urls.count) files → \(label)"
        let job = hud.begin(title)
        let journal = beginJob(job, title: title)
        // One queue item per file, so each can be reordered, cancelled or retried in the Queue window.
        queue.maxRunning = settings.parallelJobs
        queue.enqueue(job: job, journal: journal, items: urls.map { url in
            (title: "\(url.lastPathComponent) → \(label)", input: url, work: { progress in
                QueueOutcome(outputs: [try await converter.convert(url, to: target, options: jobOptions, progress: progress)])
            })
        })
    }

    /// Files that finished arriving in a watch folder: converted with the folder's preset, no questions asked.
    private func convertArrivals(_ urls: [URL], in folder: WatchFolder) {
        guard let preset = settings.presets.first(where: { $0.id == folder.presetID }),
              let format = preset.targetFormat else { return }
        let files = WatchFolder.convertible(urls, with: preset, catalog: converter.catalog())
        guard !files.isEmpty else { return }
        AppLog.info("Watch folder \(folder.path): \(files.count) new file(s) → \(preset.name)")
        convert(files, to: format, overrides: preset.overrides, title: "\(preset.name) · \(folder.name)", unattended: true)
    }

    private func run(_ tool: ToolID, urls: [URL]) {
        if tool == .imageAnnotate || tool == .pdfAnnotate, let url = urls.first {
            let directory = OutputNamer.destinationDirectory(for: url, location: options(for: urls).outputLocation)
            let onSaved: (URL) -> Void = { [weak self] saved in self?.recordOutputs([saved]) }
            if tool == .pdfAnnotate {
                PDFAnnotationWindowController.present(url: url, outputDirectory: directory, hud: hud, onSaved: onSaved)
            } else {
                AnnotationWindowController.present(url: url, outputDirectory: directory, hud: hud, onSaved: onSaved)
            }
            return
        }

        var parameter: String?
        if let input = tool.input {
            switch input {
            case .password(let prompt): parameter = Prompt.ask(title: tool.title, message: prompt, secure: true)
            case .text(let prompt):
                parameter = Prompt.ask(title: tool.title, message: prompt, secure: false)
            case .timeRange(let prompt):
                // One clip: scrub and drag the trim handles. Several, or a format AVFoundation can't play: type it.
                let ask = { [weak self] in
                    guard let range = Prompt.ask(title: tool.title, message: prompt, secure: false) else { return }
                    self?.start(tool, urls: urls, parameter: range)
                }
                if urls.count == 1 {
                    TimeRangeWindowController.present(url: urls[0], title: tool.title, onDone: { [weak self] range in
                        self?.start(tool, urls: urls, parameter: range)
                    }, fallback: ask)
                } else {
                    ask()
                }
                return
            case .pages(let prompt):
                // One PDF: arrange thumbnails. Several: the same page order applies to each, typed.
                if urls.count == 1 {
                    PageArrangerWindowController.present(url: urls[0], hud: hud) { [weak self] spec in
                        self?.start(tool, urls: urls, parameter: spec)
                    }
                    return
                }
                parameter = Prompt.ask(title: tool.title, message: prompt, secure: false)
            }
            guard parameter != nil else { return }
        }
        start(tool, urls: urls, parameter: parameter)
    }

    /// Runs a tool in the background once its input (if any) is known.
    private func start(_ tool: ToolID, urls: [URL], parameter: String?) {
        let toolParameter = parameter
        let converter = self.converter
        let concurrency = settings.parallelJobs
        guard let jobOptions = prepareJobOptions(for: urls, separateResults: !tool.combinesInputs) else { return }
        let job = hud.begin(tool.title, detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        let title = urls.count == 1 ? "\(tool.title) \(urls[0].lastPathComponent)" : "\(tool.title) (\(urls.count) files)"
        let journal = beginJob(job, title: title)
        // One queue item for the whole tool run; the tool works through its files `concurrency` at a time.
        queue.maxRunning = settings.parallelJobs
        queue.enqueue(job: job, journal: journal, items: [(title: title, input: urls.first, work: { progress in
            let outcome = try await converter.run(tool, inputs: urls, parameter: toolParameter, options: jobOptions,
                                                  concurrency: concurrency, progress: progress)
            if let text = outcome.clipboardText {
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            return QueueOutcome(outputs: outcome.outputs, message: outcome.message, failures: outcome.failures)
        })])
    }

    private func beginJob(_ job: Int, title: String) -> UndoJournal {
        let journal = UndoJournal()
        jobJournals[job] = journal
        jobStarts[job] = (title, Date())
        return journal
    }

    /// "Undo <last job>" for the menu bar; nil when there's nothing to undo.
    var undoTitle: String? { undoHistory.last.map { "Undo \($0.record.title)" } }

    /// Moves a finished job's results to the Trash and puts back the files it replaced or trashed.
    /// `job` nil undoes the most recent job.
    func undo(job: Int? = nil) {
        let index = job.map { job in undoHistory.lastIndex { $0.job == job } } ?? undoHistory.indices.last
        guard let index else {
            hud.info("Nothing to undo", detail: "That job was already undone, or it's older than the last 10 jobs.")
            return
        }
        let record = undoHistory.remove(at: index).record
        let report = Undo.undo(record)
        let undone = Set(record.outputs.map(\.path))
        settings.recentPaths.removeAll { undone.contains($0) }
        var summary: [String] = []
        if report.removed > 0 { summary.append("\(report.removed) result\(report.removed == 1 ? "" : "s") moved to the Trash") }
        if report.restored > 0 { summary.append("\(report.restored) file\(report.restored == 1 ? "" : "s") put back") }
        AppLog.info("Undid \(record.title): \(summary.joined(separator: ", ")); problems: \(report.problems.count)")
        report.problems.forEach { AppLog.error("Undo: \($0)") }
        if report.problems.isEmpty {
            hud.success("Undone", detail: summary.isEmpty ? record.title : summary.joined(separator: ", "))
        } else {
            hud.failure("Partly undone", detail: (summary + report.problems).joined(separator: "\n"))
        }
    }

    private func recordOutputs(_ outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        let paths = outputs.map(\.path)
        settings.recentPaths = Array((paths + settings.recentPaths.filter { !paths.contains($0) }).prefix(settings.recentLimit))
        if settings.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    private func finish(outputs: [URL], failures: [String], message: String?, job: Int) {
        recordOutputs(outputs)
        failures.forEach { AppLog.error($0) }
        let start = jobStarts.removeValue(forKey: job)
        let record = JobRecord(title: start?.title ?? "Last job", outputs: outputs,
                               trashed: jobJournals.removeValue(forKey: job)?.trashed ?? [])
        if !record.isEmpty {
            undoHistory.append((job, record))
            if undoHistory.count > 10 { undoHistory.removeFirst(undoHistory.count - 10) }
        }
        if cancelledJobs.remove(job) != nil {
            if hud.isCurrent(job) {
                hud.info("Cancelled", detail: outputs.isEmpty ? "Nothing was saved." : "\(outputs.count) file(s) finished before cancelling.")
            }
            return
        }
        if let start, settings.notifyWhenDone.shouldNotify(after: Date().timeIntervalSince(start.date)),
           !(outputs.isEmpty && failures.isEmpty && message == nil) {
            let headline = failures.isEmpty ? "Done: \(start.title)"
                : outputs.isEmpty ? "Couldn't finish: \(start.title)" : "Partly done: \(start.title)"
            let body = failures.isEmpty
                ? message ?? (outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files saved")
                : failures.joined(separator: "\n")
            JobNotifier.shared.notify(title: headline, body: body, outputs: outputs, job: job, undoable: !record.isEmpty)
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

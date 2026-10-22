import AppKit
import SwiftUI
import KumquatCore

/// Hosts the SwiftUI Settings and Welcome windows (Kumquat has no SwiftUI App lifecycle).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func showSettings(app: AppDelegate) {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Kumquat Settings", size: NSSize(width: 620, height: 600),
                                        view: SettingsView(settings: app.settings,
                                                           isBusy: { [weak app] in app?.hasRunningJobs ?? false }))
        }
        present(settingsWindow)
    }

    func showWelcome(app: AppDelegate) {
        if welcomeWindow == nil {
            welcomeWindow = makeWindow(title: "Welcome to Kumquat", size: NSSize(width: 520, height: 620),
                                       view: WelcomeView(settings: app.settings,
                                                         openSettings: { [weak self, weak app] in
                                                             guard let app else { return }
                                                             self?.welcomeWindow?.close()
                                                             self?.showSettings(app: app)
                                                         },
                                                         close: { [weak self] in self?.welcomeWindow?.close() }))
        }
        present(welcomeWindow)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, view: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: () -> Bool

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            OutputSettings(settings: settings)
                .tabItem { Label("Output", systemImage: "folder") }
            ConversionSettings(settings: settings)
                .tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
            AppearanceSettings(settings: settings)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            EngineSettings(settings: settings)
                .tabItem { Label("Engines", systemImage: "shippingbox") }
            AdvancedSettings(settings: settings, isBusy: isBusy)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(12)
        .frame(width: 620, height: 600)
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Wheels") {
                Toggle("Kumquat is enabled", isOn: $settings.isEnabled)
                keyPicker("Convert wheel", selection: $settings.convertKey)
                keyPicker("Tools wheel", selection: $settings.toolsKey)
                keyPicker("Actions wheel", selection: $settings.actionsKey)
                Picker("Open the wheel", selection: $settings.wheelPosition) {
                    ForEach(WheelPosition.allCases) { Text($0.title).tag($0) }
                }
                Text("Start dragging a file, then tap the key. Drop the file on a segment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notices") {
                Picker("Position", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker("Keep results on screen", selection: $settings.hudDuration) {
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("Until clicked").tag(0.0)
                }
                Toggle("Show a notice when a job succeeds", isOn: $settings.hudShowsSuccess)
                Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
            }
            Section("Sounds") {
                Toggle("Play sounds", isOn: $settings.playSound)
                soundPicker("Success", selection: $settings.successSound)
                soundPicker("Failure", selection: $settings.failureSound)
            }
            Section("Menu bar") {
                Picker("Icon", selection: $settings.menuBarIcon) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: StatusIcon.make(style))
                        }
                        .tag(style)
                    }
                }
                Toggle("Show progress next to the icon", isOn: $settings.menuBarProgress)
                Picker("Recent results", selection: $settings.recentLimit) {
                    ForEach([5, 10, 15, 25, 50], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("System") {
                Toggle("Offer to move Kumquat to Applications", isOn: $settings.offerMoveToApplications)
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                        set: { settings.launchAtLogin = $0 }))
                Picker("Terminal app", selection: $settings.terminalBundleID) {
                    Text("Terminal").tag("com.apple.Terminal")
                    Text("iTerm2").tag("com.googlecode.iterm2")
                    Text("Warp").tag("dev.warp.Warp-Stable")
                    Text("Ghostty").tag("com.mitchellh.ghostty")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func soundPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!settings.playSound)
        .onChange(of: selection.wrappedValue) { name in
            if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() }
        }
    }

    private func keyPicker(_ title: String, selection: Binding<ModifierKey>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
        }
    }
}

struct OutputSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Location") {
                Picker("Save results", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                }
                if settings.outputMode == .custom {
                    HStack {
                        TextField("Folder", text: $settings.customFolder)
                        Button("Choose…") {
                            if let url = Prompt.chooseFolder(title: "Save results to") { settings.customFolder = url.path }
                        }
                    }
                }
            }
            Section {
                TextField("Name", text: $settings.fileNameTemplate, prompt: Text(FileNameTemplate.default))
                HStack(spacing: 6) {
                    ForEach(FileNameTemplate.tokens, id: \.token) { item in
                        Button(item.token) { settings.fileNameTemplate += item.token }
                            .help(item.meaning)
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Reset") { settings.fileNameTemplate = FileNameTemplate.default }
                        .controlSize(.small)
                        .disabled(settings.fileNameTemplate == FileNameTemplate.default)
                }
                LabeledContent("Example") {
                    Text(FileNameTemplate.render(settings.fileNameTemplate, name: "IMG_0042", format: "JPG") + ".jpg")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("File names")
            } footer: {
                Text("Used for conversions. Tools keep names like “IMG_0042 (compressed)”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When a file with that name exists") {
                Picker("Existing file", selection: $settings.conflictPolicy) {
                    Text("Keep both (add a number)").tag(ConflictPolicy.keepBoth)
                    Text("Replace (old file goes to the Trash)").tag(ConflictPolicy.replace)
                    Text("Skip").tag(ConflictPolicy.skip)
                }
            }
            Section {
                Picker("After saving", selection: $settings.originalsPolicy) {
                    Text("Keep the original").tag(OriginalsPolicy.keep)
                    Text("Move the original to the Trash").tag(OriginalsPolicy.trash)
                }
                Toggle("Give results the original's file dates", isOn: $settings.preserveFileDates)
            } header: {
                Text("Originals")
            } footer: {
                Text("Merging, zipping and other tools that combine files never trash the originals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Photo & media metadata", selection: $settings.metadataPolicy) {
                    Text("Keep (camera, date, location)").tag(MetadataPolicy.keep)
                    Text("Remove location only").tag(MetadataPolicy.removeLocation)
                    Text("Remove all").tag(MetadataPolicy.removeAll)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Applies to image, audio and video conversions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ConversionSettings: View {
    @ObservedObject var settings: SettingsStore

    private static let imageSizes = [0, 4096, 3840, 2560, 2048, 1920, 1600, 1280, 1024, 800]
    private static let videoHeights = [0, 2160, 1440, 1080, 720, 480]
    private static let frameRates = [0, 60, 30, 24]
    private static let presets = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]

    var body: some View {
        Form {
            Section("Images") {
                Slider(value: $settings.imageQuality, in: 0.4...1, step: 0.05) {
                    Text("Default quality: \(Int(settings.imageQuality * 100))%")
                }
                FormatQualityRow(title: "JPEG", value: $settings.jpegQuality, fallback: settings.imageQuality)
                FormatQualityRow(title: "HEIC", value: $settings.heicQuality, fallback: settings.imageQuality)
                FormatQualityRow(title: "WebP", value: $settings.webpQuality, fallback: settings.imageQuality)
                FormatQualityRow(title: "AVIF", value: $settings.avifQuality, fallback: settings.imageQuality)
                Picker("Maximum size", selection: $settings.maxImageDimension) {
                    ForEach(Self.imageSizes, id: \.self) { Text($0 == 0 ? "Original" : "\($0) px longest side").tag($0) }
                }
                Stepper("PDF page render: \(settings.pdfDPI) dpi", value: $settings.pdfDPI, in: 72...600, step: 24)
            }
            Section {
                Stepper("H.264 quality (CRF): \(settings.videoCRF)", value: $settings.videoCRF, in: 14...36)
                Picker("Encoder", selection: $settings.videoEncoder) {
                    Text("Automatic").tag(VideoEncoderPreference.automatic)
                    Text("Hardware (fast)").tag(VideoEncoderPreference.hardware)
                    Text("Software (smallest files)").tag(VideoEncoderPreference.software)
                }
                Picker("Speed", selection: $settings.videoPreset) {
                    ForEach(Self.presets, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .disabled(settings.videoEncoder == .hardware)
                Picker("Maximum resolution", selection: $settings.maxVideoHeight) {
                    ForEach(Self.videoHeights, id: \.self) { Text($0 == 0 ? "Original" : "\($0)p").tag($0) }
                }
                Picker("Maximum frame rate", selection: $settings.maxFrameRate) {
                    ForEach(Self.frameRates, id: \.self) { Text($0 == 0 ? "Original" : "\($0) fps").tag($0) }
                }
                Toggle("Remove audio", isOn: $settings.removeAudio)
            } header: {
                Text("Video")
            } footer: {
                Text("Lower CRF is better quality and bigger files: 18 is visually lossless, 23 the default, 28 small. Slower speeds make smaller files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Picker("Lossy bitrate", selection: $settings.audioBitrate) {
                    ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Sample rate", selection: $settings.audioSampleRate) {
                    Text("Original").tag(0)
                    Text("44.1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                }
                Picker("Channels", selection: $settings.audioChannels) {
                    Text("Original").tag(0)
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                }
                Toggle("Normalise loudness (−16 LUFS)", isOn: $settings.normalizeAudio)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Use the default" or a format's own quality slider.
struct FormatQualityRow: View {
    let title: String
    @Binding var value: Double
    let fallback: Double

    var body: some View {
        let custom = (0...1).contains(value)
        VStack(alignment: .leading, spacing: 4) {
            Toggle("\(title): \(custom ? "\(Int(value * 100))%" : "default")",
                   isOn: Binding(get: { custom }, set: { value = $0 ? fallback : -1 }))
            if custom {
                Slider(value: $value, in: 0.3...1, step: 0.05)
            }
        }
    }
}

struct AdvancedSettings: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: () -> Bool
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Stepper("Convert \(settings.parallelJobs) file\(settings.parallelJobs == 1 ? "" : "s") at a time",
                        value: $settings.parallelJobs, in: 1...8)
            } header: {
                Text("Batches")
            } footer: {
                Text("More is faster on Apple silicon but uses more memory. Video conversions already use every core.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
                Toggle("Include pre-releases", isOn: $settings.includePrereleases)
                HStack {
                    Button("Check Now") { UpdateController.shared.check(userInitiated: true) }
                    if let last = settings.lastUpdateCheck {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Kumquat asks GitHub for new releases once a day. Nothing else is sent. Updates download as a disk image; drag Kumquat to Applications to install.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                HStack {
                    Button("Open Log") { Self.openLog() }
                    Button("Report a Problem…") { CrashReporter.reportProblem() }
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.diagnostics(), forType: .string)
                        status = "Diagnostics copied. Paste them into a GitHub issue."
                    }
                    Button("Clear Temporary Files") {
                        guard !isBusy() else {
                            status = "Wait for running conversions to finish first."
                            return
                        }
                        status = Self.clearTemporaryFiles()
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Reset") {
                Button("Reset All Settings…", role: .destructive) { confirmReset() }
            }
        }
        .formStyle(.grouped)
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all Kumquat settings?"
        alert.informativeText = "Keys, quality, output, theme and recent files go back to their defaults. Kumquat will relaunch."
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.resetAll()
        AppLog.info("Settings reset")
        ApplicationsMover.relaunch(Bundle.main.bundleURL, eject: nil)
    }

    static func openLog() {
        let url = AppLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    /// Removes leftovers of interrupted jobs from the temporary folder.
    static func clearTemporaryFiles() -> String {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Kumquat", isDirectory: true)
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        var bytes: Int64 = 0
        var removed = 0
        for item in items {
            bytes += Self.size(of: item)
            if (try? fm.removeItem(at: item)) != nil { removed += 1 }
        }
        guard removed > 0 else { return "Nothing to clear." }
        return "Removed \(removed) item\(removed == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
    }

    private static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    @MainActor
    static func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var architecture = "x86_64"
        #if arch(arm64)
        architecture = "arm64"
        #endif
        var lines = [
            "Kumquat \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)",
            "",
            "Helpers:",
        ]
        for dependency in Dependency.allCases {
            let status = EngineMonitor.shared.status(of: dependency)
            let detail = status?.path.map { "\($0) \(status?.version ?? "")" } ?? "not found"
            lines.append("- \(dependency.displayName): \(detail)")
        }
        let options = SettingsStore.shared.options
        lines += [
            "",
            "Options: template \(options.fileNameTemplate), conflict \(options.conflictPolicy.rawValue), originals \(options.originals.rawValue), metadata \(options.metadata.rawValue), encoder \(options.videoEncoder.rawValue), parallel \(SettingsStore.shared.parallelJobs)",
        ]
        return lines.joined(separator: "\n")
    }
}

struct EngineSettings: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor = EngineMonitor.shared

    var body: some View {
        Form {
            Section {
                ForEach(Dependency.allCases, id: \.self) { dependency in
                    DependencyRow(dependency: dependency, status: monitor.status(of: dependency))
                }
            } header: {
                HStack {
                    Text("Optional helpers")
                    Spacer()
                    if monitor.isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    } else if let checked = monitor.lastChecked {
                        Text("Checked \(checked.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                    }
                    Button("Re-check") { monitor.refresh() }
                        .disabled(monitor.isChecking)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
            Section("Custom paths (leave empty to auto-detect)") {
                pathField("ffmpeg", text: $settings.ffmpegPath, tool: "ffmpeg", prompt: "/opt/homebrew/bin/ffmpeg")
                pathField("soffice", text: $settings.sofficePath, tool: "soffice",
                          prompt: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
                pathField("pandoc", text: $settings.pandocPath, tool: "pandoc", prompt: "/opt/homebrew/bin/pandoc")
            }
        }
        .formStyle(.grouped)
        .onAppear { monitor.refresh() }
        // Re-detect after a custom path is edited.
        .onChange(of: settings.ffmpegPath) { _ in monitor.refresh() }
        .onChange(of: settings.sofficePath) { _ in monitor.refresh() }
        .onChange(of: settings.pandocPath) { _ in monitor.refresh() }
    }

    private func pathField(_ title: String, text: Binding<String>, tool: String, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField(title, text: text, prompt: Text(prompt))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
                    if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
                }
            }
            if settings.toolLocator.overrideIsInvalid(tool) {
                Label("Not an executable file — auto-detection is used instead.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct DependencyRow: View {
    let dependency: Dependency
    let status: DependencyStatus?

    var body: some View {
        let installed = status?.isInstalled ?? false
        HStack(alignment: .top, spacing: 10) {
            Group {
                if status == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(installed ? Color.green : Color.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dependency.displayName).fontWeight(.medium)
                    if let version = status?.version {
                        Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(dependency.purpose).font(.caption).foregroundStyle(.secondary)
                if let path = status?.path {
                    Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                } else if status != nil {
                    Text(dependency.installHint).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Spacer()
            if status != nil, !installed {
                Button(dependency.appStoreURL == nil ? "Install" : "App Store") {
                    HelperInstaller.install(dependency)
                }
                .help(dependency.installHint)
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        let converter = Converter()
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Kumquat").font(.largeTitle.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("\(converter.graph.conversionCount(engines: converter.availableEngines)) conversions · \(ToolID.allCases.count) tools · \(ActionID.allCases.count) actions")
            Text("Free and open source (MIT). Everything runs on your Mac — files are never uploaded.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/scorpionTaj/File-Converter-macos", destination: URL(string: "https://github.com/scorpionTaj/File-Converter-macos")!)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor = EngineMonitor.shared
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text("Welcome to Kumquat").font(.title.bold())
                    Text("Convert, edit and share files without leaving Finder.").foregroundStyle(.secondary)
                }
            }
            Text("Start dragging any file, then tap a key:").font(.headline)
            step(settings.convertKey, "Convert", "Pick an output format — HEIC → JPG, MOV → MP4, DOCX → PDF…")
            step(settings.toolsKey, "Tools", "Compress, resize, rotate, remove backgrounds, merge or redact PDFs…")
            step(settings.actionsKey, "Actions", "AirDrop, Float on top, Copy, Move, Copy Path, open in Terminal.")
            Text("Drop the file on a segment. Results are saved next to the original — your file is never changed or uploaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("No drag? Drop files on the menu-bar icon, use Finder ▸ right-click ▸ Services ▸ Open in Kumquat, or Open With ▸ Kumquat. Photos, Mail and Safari drags work too.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Text("Optional helpers unlock more formats:").font(.headline)
            ForEach([Dependency.ffmpeg, .libreOffice, .pandoc], id: \.self) { dependency in
                DependencyRow(dependency: dependency, status: monitor.status(of: dependency))
            }
            Spacer()
            HStack {
                Text("Kumquat lives in the menu bar.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…", action: openSettings)
                Button("Get Started", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 620)
        .onAppear { monitor.refresh() }
    }

    private func step(_ key: ModifierKey, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key.symbol)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

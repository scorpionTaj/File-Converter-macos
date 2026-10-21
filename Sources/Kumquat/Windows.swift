#if os(macOS)
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
            settingsWindow = makeWindow(title: "Kumquat Settings", size: NSSize(width: 560, height: 520),
                                        view: SettingsView(settings: app.settings))
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

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ConversionSettings(settings: settings)
                .tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
            EngineSettings(settings: settings)
                .tabItem { Label("Engines", systemImage: "shippingbox") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(12)
        .frame(width: 560, height: 520)
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
                Slider(value: $settings.wheelScale, in: 0.8...1.3, step: 0.05) {
                    Text("Wheel size")
                }
                Text("Start dragging a file, then tap the key. Drop the file on a segment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Results") {
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
                Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
                Toggle("Play a sound when done", isOn: $settings.playSound)
            }
            Section("System") {
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

    private func keyPicker(_ title: String, selection: Binding<ModifierKey>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierKey.allCases) { Text($0.title).tag($0) }
        }
    }
}

struct ConversionSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Images") {
                Slider(value: $settings.imageQuality, in: 0.4...1, step: 0.05) {
                    Text("JPEG / HEIC / WebP quality: \(Int(settings.imageQuality * 100))%")
                }
                Stepper("PDF page render: \(settings.pdfDPI) dpi", value: $settings.pdfDPI, in: 72...600, step: 24)
            }
            Section("Video") {
                Stepper("H.264 quality (CRF): \(settings.videoCRF)", value: $settings.videoCRF, in: 14...36)
                Text("Lower is better quality and bigger files. 18 is visually lossless, 23 is the default, 28 is small.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Audio") {
                Picker("Lossy bitrate", selection: $settings.audioBitrate) {
                    ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct EngineSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var refresh = 0

    var body: some View {
        let locator = settings.toolLocator
        Form {
            Section("Optional helpers") {
                ForEach(Dependency.allCases, id: \.self) { dependency in
                    DependencyRow(dependency: dependency, installed: locator.isAvailable(dependency))
                }
                Button("Re-check") { refresh += 1 }
            }
            Section("Custom paths (leave empty to auto-detect)") {
                TextField("ffmpeg", text: $settings.ffmpegPath, prompt: Text("/opt/homebrew/bin/ffmpeg"))
                TextField("soffice", text: $settings.sofficePath, prompt: Text("/Applications/LibreOffice.app/Contents/MacOS/soffice"))
                TextField("pandoc", text: $settings.pandocPath, prompt: Text("/opt/homebrew/bin/pandoc"))
            }
        }
        .formStyle(.grouped)
        .id(refresh)
    }
}

struct DependencyRow: View {
    let dependency: Dependency
    let installed: Bool

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(installed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.displayName).fontWeight(.medium)
                Text(dependency.purpose).font(.caption).foregroundStyle(.secondary)
                if !installed {
                    Text(dependency.installHint).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Spacer()
            if !installed, dependency.installHint.hasPrefix("brew") {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dependency.installHint, forType: .string)
                }
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
            let locator = settings.toolLocator
            ForEach([Dependency.ffmpeg, .libreOffice, .pandoc], id: \.self) { dependency in
                DependencyRow(dependency: dependency, installed: locator.isAvailable(dependency))
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
#endif

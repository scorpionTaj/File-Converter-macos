#if os(macOS)
import AppKit
import KumquatCore

/// Detects optional helpers off the main thread and publishes the result to Settings and the Welcome window.
@MainActor
final class EngineMonitor: ObservableObject {
    static let shared = EngineMonitor()

    @Published private(set) var statuses: [DependencyStatus] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?

    private var checkTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private init() {
        // Helpers are often installed while Kumquat is running; re-check whenever the user comes back.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { _ in
            Task { @MainActor in EngineMonitor.shared.refresh() }
        }
    }

    func status(of dependency: Dependency) -> DependencyStatus? {
        statuses.first { $0.dependency == dependency }
    }

    /// Re-detects every helper. Also clears cached FFmpeg encoder lists so a newly installed build is used.
    func refresh() {
        checkTask?.cancel()
        isChecking = true
        MediaEngine.resetCaches()
        let locator = SettingsStore.shared.toolLocator
        checkTask = Task {
            let started = Date()
            let results = await Task.detached(priority: .userInitiated) { await locator.statuses() }.value
            // Keep the spinner up briefly so the user can see a check happened.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.4 { try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            statuses = results
            lastChecked = Date()
            isChecking = false
        }
    }
}

/// Installs a Homebrew helper in a visible Terminal window, so the user sees progress and can enter a password.
enum HelperInstaller {
    static var homebrew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    static func install(_ dependency: Dependency) {
        if let store = dependency.appStoreURL {
            NSWorkspace.shared.open(store)
            return
        }
        guard let package = dependency.brewPackage else { return }
        guard let brew = homebrew else {
            let alert = NSAlert()
            alert.messageText = "Homebrew isn't installed"
            alert.informativeText = "Kumquat installs helpers with Homebrew, the free macOS package manager. Install it from brew.sh, then try again."
            alert.addButton(withTitle: "Open brew.sh")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "https://brew.sh") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let script = """
        #!/bin/bash
        clear
        echo "Kumquat is installing \(dependency.displayName) with Homebrew…"
        echo
        "\(brew.path)" install \(package)
        status=$?
        echo
        if [ $status -eq 0 ]; then echo "✓ Done. Switch back to Kumquat — it re-checks automatically."; else echo "✗ Homebrew reported an error (exit $status)."; fi
        echo "You can close this window."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-install-\(dependency.rawValue).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            AppLog.error("Couldn't start the installer for \(dependency.displayName): \(error.localizedDescription)")
        }
    }
}
#endif

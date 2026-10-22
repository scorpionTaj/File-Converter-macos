import AppKit

/// Offers to move Kumquat into Applications when it's launched from the disk image, Downloads or elsewhere,
/// then relaunches the installed copy (and ejects the disk image).
@MainActor
enum ApplicationsMover {
    static func offerIfNeeded(settings: SettingsStore) {
        guard settings.offerMoveToApplications else { return }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        // Only real app bundles (not `swift run`), and not when already installed.
        guard bundle.pathExtension == "app", !isInstalled(bundle) else { return }

        let fromDiskImage = bundle.path.hasPrefix("/Volumes/")
        let alert = NSAlert()
        alert.messageText = "Move Kumquat to your Applications folder?"
        alert.informativeText = fromDiskImage
            ? "Kumquat is running from the disk image. Moving it to Applications keeps it available after you eject the image and lets it open at login."
            : "Kumquat is running from \(bundle.deletingLastPathComponent().lastPathComponent). Applications is the right home for it, and Launch at Login works best from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.offerMoveToApplications = false }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try move(bundle, fromDiskImage: fromDiskImage)
        } catch {
            AppLog.error("Move to Applications failed: \(error.localizedDescription)")
            let failure = NSAlert(error: error)
            failure.messageText = "Kumquat couldn't be moved"
            failure.runModal()
        }
    }

    static func isInstalled(_ bundle: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/", "\(home)/Applications/"].contains { bundle.path.hasPrefix($0) }
    }

    private static func move(_ bundle: URL, fromDiskImage: Bool) throws {
        let fm = FileManager.default
        var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fm.isWritableFile(atPath: folder.path) {
            folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appendingPathComponent(bundle.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            // An older Kumquat: put it in the Trash rather than deleting it outright.
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        if fromDiskImage {
            try fm.copyItem(at: bundle, to: destination)
        } else {
            try fm.moveItem(at: bundle, to: destination)
        }
        AppLog.info("Moved to \(destination.path)")

        let volume = fromDiskImage ? diskImageVolume(of: bundle) : nil
        relaunch(destination, eject: volume)
    }

    /// "/Volumes/Kumquat/Kumquat.app" → "/Volumes/Kumquat".
    private static func diskImageVolume(of bundle: URL) -> URL? {
        let parts = bundle.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(parts[2])", isDirectory: true)
    }

    /// Waits for this process to exit, opens the installed copy, then ejects the image.
    static func relaunch(_ app: URL, eject volume: URL?) {
        let script = #"""
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        /usr/bin/open "$2"
        if [ -n "$3" ]; then /usr/bin/hdiutil detach "$3" -quiet || true; fi
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "kumquat-relaunch", "\(ProcessInfo.processInfo.processIdentifier)",
                             app.path, volume?.path ?? ""]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            AppLog.error("Relaunch failed: \(error.localizedDescription)")
            NSWorkspace.shared.activateFileViewerSelecting([app])
        }
    }
}

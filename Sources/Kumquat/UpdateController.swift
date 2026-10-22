import AppKit
import KumquatCore

/// "Check for Updates…": compares the running version with GitHub releases and downloads the new disk image.
/// Works with ad-hoc signed builds; installing is the usual drag to Applications.
@MainActor
final class UpdateController {
    static let shared = UpdateController()
    weak var hud: HUDController?
    private(set) var isChecking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// At most once a day, when automatic checks are on.
    func checkAutomaticallyIfDue() {
        let settings = SettingsStore.shared
        guard settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        let settings = SettingsStore.shared
        let current = currentVersion
        let includePrereleases = settings.includePrereleases
        Task { [self] in
            defer { isChecking = false }
            do {
                let releases = try await UpdateChecker.fetchReleases()
                settings.lastUpdateCheck = Date()
                guard let release = UpdateChecker.newest(in: releases, than: current, includePrereleases: includePrereleases) else {
                    if userInitiated {
                        inform("Kumquat is up to date", "You have the newest version, \(current).")
                    }
                    return
                }
                // A version the user skipped is only offered again when they ask.
                if !userInitiated, settings.skippedVersion == release.tagName { return }
                offer(release, current: current)
            } catch {
                AppLog.error("Update check failed: \(error.localizedDescription)")
                if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private func offer(_ release: ReleaseInfo, current: String) {
        let version = release.version?.description ?? release.tagName
        let alert = NSAlert()
        alert.messageText = "Kumquat \(version) is available"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The install footer added by the release workflow isn't news.
        if let footer = notes.range(of: "\n---") { notes = String(notes[..<footer.lowerBound]) }
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        alert.informativeText = "You have \(current).\n\n\(notes)"
        alert.addButton(withTitle: release.diskImage == nil ? "View Release" : "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let image = release.diskImage {
                download(image, version: version, fallback: release.htmlURL)
            } else {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .alertThirdButtonReturn:
            SettingsStore.shared.skippedVersion = release.tagName
        default:
            break
        }
    }

    private func download(_ asset: ReleaseInfo.Asset, version: String, fallback: URL) {
        let job = hud?.begin("Downloading Kumquat \(version)", detail: asset.name)
        Task { [self] in
            do {
                let (temporary, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateChecker.CheckError.unreachable((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let destination = OutputNamer.uniqueURL(in: downloads, fileName: asset.name)
                try FileManager.default.moveItem(at: temporary, to: destination)
                if let job { hud?.progress(1, job: job) }
                hud?.success("Update downloaded", detail: destination.lastPathComponent, reveal: [destination])
                AppLog.info("Downloaded update \(version) to \(destination.path)")
                NSWorkspace.shared.open(destination)
                finishInstall(version: version)
            } catch {
                AppLog.error("Update download failed: \(error.localizedDescription)")
                hud?.failure("Download failed", detail: "Opening the release page instead.")
                NSWorkspace.shared.open(fallback)
            }
        }
    }

    private func finishInstall(version: String) {
        let alert = NSAlert()
        alert.messageText = "Install Kumquat \(version)"
        alert.informativeText = "The disk image is open. Quit Kumquat, drag the new Kumquat onto Applications and choose Replace, then open it again."
        alert.addButton(withTitle: "Quit Kumquat")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Notices when the previous run ended in a crash and helps report problems on GitHub.
@MainActor
enum CrashReporter {
    private static var wroteMarker = false
    static let issuesURL = "https://github.com/scorpionTaj/File-Converter-macos/issues/new"

    private static var markerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kumquat", isDirectory: true)
            .appendingPathComponent("running")
    }

    /// Call once launch succeeded. Returns true when the last run didn't quit normally.
    static func noteLaunch() -> Bool {
        let fm = FileManager.default
        let crashed = fm.fileExists(atPath: markerURL.path)
        try? fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        wroteMarker = (try? Data().write(to: markerURL)) != nil
        return crashed
    }

    /// Call when quitting normally. Only the instance that wrote the marker removes it.
    static func noteCleanExit() {
        guard wroteMarker else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Newest macOS crash report for Kumquat, if any.
    static func latestCrashReport() -> URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let reports = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return reports
            .filter { $0.lastPathComponent.hasPrefix("Kumquat") && ["ips", "crash", "hang"].contains($0.pathExtension) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func offerReportAfterCrash() {
        let report = latestCrashReport()
        let alert = NSAlert()
        alert.messageText = "Kumquat quit unexpectedly last time"
        alert.informativeText = "Reporting it helps fix the problem. A GitHub issue opens in your browser with details about your Mac and Kumquat's log; nothing is sent until you submit it."
        alert.addButton(withTitle: "Report…")
        alert.addButton(withTitle: "Not Now")
        if report != nil { alert.addButton(withTitle: "Show Crash Report") }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            reportProblem(title: "Crash report", crashReport: report)
        case .alertThirdButtonReturn:
            if let report { NSWorkspace.shared.activateFileViewerSelecting([report]) }
        default:
            break
        }
    }

    /// Opens a prefilled GitHub issue with diagnostics and the end of the log.
    static func reportProblem(title: String = "", crashReport: URL? = nil) {
        var body = "**What happened?**\n\n\n**Steps to reproduce**\n\n\n<details><summary>Diagnostics</summary>\n\n```\n"
        body += AdvancedSettings.diagnostics()
        body += "\n```\n\n**Recent log**\n\n```\n\(recentLog(lines: 30))\n```\n</details>\n"
        if let crashReport {
            body += "\nCrash report: `\(crashReport.lastPathComponent)` (please attach it from ~/Library/Logs/DiagnosticReports)\n"
        }
        // Browsers and GitHub reject very long URLs.
        if body.count > 6000 { body = String(body.prefix(6000)) + "\n…\n```\n</details>" }
        var components = URLComponents(string: issuesURL)!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    static func recentLog(lines: Int) -> String {
        guard let text = try? String(contentsOf: AppLog.fileURL, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

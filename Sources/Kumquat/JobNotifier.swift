import AppKit
import KumquatCore
@preconcurrency import UserNotifications

/// When finished jobs post a macOS notification.
enum NotificationPolicy: String, CaseIterable, Identifiable {
    case never, longJobs, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return L("Never")
        case .longJobs: return L("For jobs over 10 seconds")
        case .always: return L("Always")
        }
    }

    func shouldNotify(after duration: TimeInterval) -> Bool {
        switch self {
        case .never: return false
        case .longJobs: return duration >= 10
        case .always: return true
        }
    }
}

/// Posts "job finished" notifications with Show in Finder / Open / Undo buttons.
@MainActor
final class JobNotifier: NSObject {
    static let shared = JobNotifier()

    /// Called with the job number when the notification's Undo button is clicked.
    var onUndo: ((Int) -> Void)?

    private enum Action {
        static let reveal = "reveal", open = "open", undo = "undo"
    }
    private enum Category {
        static let plain = "job", undoable = "job-undoable"
    }

    /// UserNotifications needs a real app bundle; `swift run` builds have none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let reveal = UNNotificationAction(identifier: Action.reveal, title: L("Show in Finder"))
        let open = UNNotificationAction(identifier: Action.open, title: L("Open"))
        let undo = UNNotificationAction(identifier: Action.undo, title: L("Undo"), options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.plain, actions: [reveal, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.undoable, actions: [reveal, open, undo], intentIdentifiers: []),
        ])
    }

    func notify(title: String, body: String, outputs: [URL], job: Int, undoable: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = undoable ? Category.undoable : Category.plain
        content.userInfo = ["job": job, "paths": outputs.map(\.path)]
        let request = UNNotificationRequest(identifier: "kumquat-job-\(job)", content: content, trigger: nil)
        // Asks for permission the first time only; macOS remembers the answer.
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error { AppLog.error("Notification permission: \(error.localizedDescription)") }
            guard granted else { return }
            center.add(request) { error in
                if let error { AppLog.error("Notification failed: \(error.localizedDescription)") }
            }
        }
    }

    fileprivate func handle(action: String, job: Int?, paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        switch action {
        case Action.undo:
            if let job { onUndo?(job) }
        case Action.open:
            urls.forEach { NSWorkspace.shared.open($0) }
        default:
            // "Show in Finder" or a click on the notification itself.
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }
}

extension JobNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let job = info["job"] as? Int
        let paths = info["paths"] as? [String] ?? []
        Task { @MainActor in JobNotifier.shared.handle(action: action, job: job, paths: paths) }
        completionHandler()
    }

    /// Show the banner even while Kumquat is the active app (it is, right after using the wheel).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

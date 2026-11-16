import AppKit
import UniformTypeIdentifiers

// Finder Quick Action ("Open in Kumquat") and Share extension. Both hand the chosen files to Kumquat, which
// opens its wheel for them, so the conversion runs in the app with its settings, engines and notices.
//
// The same binary goes into both .appex bundles (scripts/build-app.sh); each Info.plist names its principal
// class. The executable's entry point is NSExtensionMain (see Package.swift), so the top-level code below never
// runs; it only exists because SwiftPM expects an executable target to have a main.swift.

/// Collects the file URLs from an extension request, opens them in Kumquat and finishes the request.
enum KumquatHandoff {
    /// The Kumquat.app that contains this extension (…/Kumquat.app/Contents/PlugIns/X.appex).
    static var appURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func fileURLs(in context: NSExtensionContext?, completion: @escaping ([URL]) -> Void) {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            // Finder registers the file's own type (public.jpeg, …) or public.file-url; both load as a file URL.
            guard let type = provider.registeredTypeIdentifiers.first(where: { $0 == UTType.fileURL.identifier })
                    ?? provider.registeredTypeIdentifiers.first else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else { return }
                lock.lock()
                found.append((index, url))
                lock.unlock()
            }
        }
        group.notify(queue: .main) { completion(found.sorted { $0.0 < $1.0 }.map(\.1)) }
    }

    /// Opens `urls` in Kumquat; calls back with an error message, or nil when it worked.
    static func open(_ urls: [URL], completion: @escaping (String?) -> Void) {
        guard !urls.isEmpty else {
            completion("Kumquat works with files. Share the file itself, for example from Finder.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error?.localizedDescription) }
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "io.github.scorpiontaj.kumquat.extension", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Finder ▸ Quick Actions ▸ Open in Kumquat (and the Finder preview pane). No interface of its own.
@objc(KumquatActionHandler)
final class KumquatActionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        KumquatHandoff.fileURLs(in: context) { urls in
            KumquatHandoff.open(urls) { error in
                if let error {
                    context.cancelRequest(withError: KumquatHandoff.failure(error))
                } else {
                    context.completeRequest(returningItems: nil)
                }
            }
        }
    }
}

/// Share ▸ Kumquat. Shows nothing when it works; shows why when it can't.
@objc(KumquatShareViewController)
final class KumquatShareViewController: NSViewController {
    private let message = NSTextField(wrappingLabelWithString: "Opening in Kumquat…")

    override func loadView() {
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\r"
        let stack = NSStackView(views: [message, close])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        message.preferredMaxLayoutWidth = 268
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 110)
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        KumquatHandoff.fileURLs(in: extensionContext) { [weak self] urls in
            KumquatHandoff.open(urls) { error in
                guard let self else { return }
                if let error {
                    self.message.stringValue = error
                } else {
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            }
        }
    }

    @objc private func closeSheet() {
        extensionContext?.cancelRequest(withError: KumquatHandoff.failure("Cancelled"))
    }
}

_ = KumquatHandoff.self

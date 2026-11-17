import AppKit
import KumquatCore
import Quartz

/// The Actions wheel: AirDrop, Float, Copy, Move, Copy To, Copy Path, Terminal.
@MainActor
final class FileActions {
    private let settings: SettingsStore
    private let hud: HUDController
    private var floatWindows: [FloatWindowController] = []

    init(settings: SettingsStore, hud: HUDController) {
        self.settings = settings
        self.hud = hud
    }

    func perform(_ action: ActionID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop:
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                hud.failure(L("AirDrop unavailable"), detail: L("Turn on Wi-Fi and Bluetooth, then try again."))
                return
            }
            service.perform(withItems: urls)

        case .float:
            for url in urls.prefix(6) {
                let controller = FloatWindowController(url: url)
                controller.onClose = { [weak self, weak controller] in
                    self?.floatWindows.removeAll { $0 === controller }
                }
                floatWindows.append(controller)
                controller.show()
            }

        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            hud.info(L("Copied"), detail: urls.count == 1 ? urls[0].lastPathComponent : L("\(urls.count) items"))

        case .move, .copyTo:
            let isMove = action == .move
            guard let folder = Prompt.chooseFolder(title: isMove ? L("Move to") : L("Copy to")) else { return }
            var results: [URL] = []
            do {
                for url in urls {
                    let destination = OutputNamer.uniqueURL(in: folder, fileName: url.lastPathComponent)
                    if isMove {
                        try FileManager.default.moveItem(at: url, to: destination)
                    } else {
                        try FileManager.default.copyItem(at: url, to: destination)
                    }
                    results.append(destination)
                }
                hud.success(isMove ? L("Moved") : L("Copied"), detail: L("\(results.count) item(s) to \(folder.lastPathComponent)"), reveal: results)
            } catch {
                hud.failure(isMove ? L("Move failed") : L("Copy failed"), detail: error.localizedDescription)
            }

        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            hud.info(L("Path copied"), detail: urls.count == 1 ? urls[0].path : L("\(urls.count) paths"))

        case .terminal:
            var isDirectory: ObjCBool = false
            let first = urls[0]
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
            let folder = isDirectory.boolValue ? first : first.deletingLastPathComponent()
            let workspace = NSWorkspace.shared
            let terminal = workspace.urlForApplication(withBundleIdentifier: settings.terminalBundleID)
                ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            guard let terminal else {
                hud.failure(L("Terminal not found"), detail: settings.terminalBundleID)
                return
            }
            workspace.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("Kumquat: couldn't open Terminal: \(error.localizedDescription)") }
            }
        }
    }
}

/// An always-on-top Quick Look preview of a file ("Float").
@MainActor
final class FloatWindowController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    var onClose: (() -> Void)?

    init(url: URL) {
        var size = NSSize(width: 480, height: 360)
        if let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 {
            let scale = min(520 / image.size.width, 520 / image.size.height, 1)
            size = NSSize(width: max(image.size.width * scale, 160), height: max(image.size.height * scale, 120))
        }
        window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        if let preview = QLPreviewView(frame: NSRect(origin: .zero, size: size), style: .normal) {
            preview.autoresizingMask = [.width, .height]
            preview.previewItem = url as NSURL
            window.contentView = preview
        }
        let mouse = NSEvent.mouseLocation
        window.setFrameTopLeftPoint(NSPoint(x: mouse.x - size.width / 2, y: mouse.y + size.height / 2))
    }

    func show() {
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Modal prompts. Kumquat is a background app, so it activates itself first.
@MainActor
enum Prompt {
    static func ask(title: String, message: String, secure: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        let frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let field: NSTextField = secure ? NSSecureTextField(frame: frame) : NSTextField(frame: frame)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func chooseFolder(title: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = title.replacingOccurrences(of: " to", with: "")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFiles() -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L("Choose files for Kumquat")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}

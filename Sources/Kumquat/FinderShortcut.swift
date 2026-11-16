import AppKit
import Carbon.HIToolbox

/// System-wide shortcut that opens the wheel for the files selected in Finder.
enum FinderShortcut: String, CaseIterable, Identifiable {
    case off, controlOptionK, optionCommandK, controlShiftK

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .controlOptionK: return "⌃⌥K"
        case .optionCommandK: return "⌥⌘K"
        case .controlShiftK: return "⌃⇧K"
        }
    }

    /// Carbon virtual key code and modifier mask.
    var carbonKey: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: return nil
        case .controlOptionK: return (UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey))
        case .optionCommandK: return (UInt32(kVK_ANSI_K), UInt32(optionKey | cmdKey))
        case .controlShiftK: return (UInt32(kVK_ANSI_K), UInt32(controlKey | shiftKey))
        }
    }
}

/// One system-wide hotkey through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: @MainActor () -> Void

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// False when the combination couldn't be registered (another app owns it).
    @discardableResult
    func register(code: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let action = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress
                DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
                return noErr
            }, 1, &event, context, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4B4D_5154), id: 1) // "KMQT"
        return RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// The items selected in the frontmost Finder window (or on the desktop).
@MainActor
enum FinderSelection {
    enum Failure: LocalizedError {
        case notAllowed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                return "Allow Kumquat to control Finder in System Settings ▸ Privacy & Security ▸ Automation."
            case .failed(let message):
                return message
            }
        }
    }

    private static let script = """
    tell application "Finder"
        set chosen to selection as alias list
        set paths to ""
        repeat with anItem in chosen
            set paths to paths & POSIX path of anItem & linefeed
        end repeat
        return paths
    end tell
    """

    static func urls() -> Result<[URL], Failure> {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            let code = error?[NSAppleScript.errorNumber] as? Int
            // -1743: the user hasn't allowed (or denied) Automation for Finder.
            if code == -1743 { return .failure(.notAllowed) }
            return .failure(.failed(error?[NSAppleScript.errorMessage] as? String ?? "Finder didn't answer."))
        }
        let urls = (output.stringValue ?? "")
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)).standardizedFileURL }
        return .success(urls)
    }
}

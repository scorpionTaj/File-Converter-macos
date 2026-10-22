import AppKit
import KumquatCore
import ServiceManagement

/// Modifier key that summons a wheel while dragging.
enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option, none

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .none: return nil
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .none: return "—"
        }
    }

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .none: return "Off"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case beside, downloads, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beside: return "Next to the original"
        case .downloads: return "Downloads folder"
        case .custom: return "Custom folder"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "enabled") } }
    @Published var convertKey: ModifierKey { didSet { defaults.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolsKey: ModifierKey { didSet { defaults.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var actionsKey: ModifierKey { didSet { defaults.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: "revealInFinder") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var wheelScale: Double { didSet { defaults.set(wheelScale, forKey: "wheelScale") } }
    @Published var imageQuality: Double { didSet { defaults.set(imageQuality, forKey: "imageQuality") } }
    @Published var videoCRF: Int { didSet { defaults.set(videoCRF, forKey: "videoCRF") } }
    @Published var audioBitrate: Int { didSet { defaults.set(audioBitrate, forKey: "audioBitrate") } }
    @Published var pdfDPI: Int { didSet { defaults.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var customFolder: String { didSet { defaults.set(customFolder, forKey: "customFolder") } }
    @Published var terminalBundleID: String { didSet { defaults.set(terminalBundleID, forKey: "terminalBundleID") } }
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    @Published var sofficePath: String { didSet { defaults.set(sofficePath, forKey: "sofficePath") } }
    @Published var pandocPath: String { didSet { defaults.set(pandocPath, forKey: "pandocPath") } }
    @Published var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var themeID: String { didSet { defaults.set(themeID, forKey: "themeID") } }
    @Published var offerMoveToApplications: Bool { didSet { defaults.set(offerMoveToApplications, forKey: "offerMoveToApplications") } }
    /// Most recent results (paths), newest first; survives relaunches.
    @Published var recentPaths: [String] { didSet { defaults.set(recentPaths, forKey: "recentPaths") } }

    private init() {
        // Local copy: the helpers below must not capture `self` before every property is set.
        let defaults = UserDefaults.standard
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) as? Double ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }

        isEnabled = bool("enabled", true)
        convertKey = ModifierKey(rawValue: string("convertKey", "")) ?? .shift
        toolsKey = ModifierKey(rawValue: string("toolsKey", "")) ?? .command
        actionsKey = ModifierKey(rawValue: string("actionsKey", "")) ?? .control
        revealInFinder = bool("revealInFinder", false)
        playSound = bool("playSound", true)
        wheelScale = double("wheelScale", 1.0)
        imageQuality = double("imageQuality", 0.85)
        videoCRF = int("videoCRF", 23)
        audioBitrate = int("audioBitrate", 192)
        pdfDPI = int("pdfDPI", 200)
        outputMode = OutputMode(rawValue: string("outputMode", "")) ?? .beside
        customFolder = string("customFolder", "")
        terminalBundleID = string("terminalBundleID", "com.apple.Terminal")
        ffmpegPath = string("ffmpegPath", "")
        sofficePath = string("sofficePath", "")
        pandocPath = string("pandocPath", "")
        hasSeenWelcome = bool("hasSeenWelcome", false)
        themeID = string("themeID", "kumquat")
        offerMoveToApplications = bool("offerMoveToApplications", true)
        recentPaths = defaults.stringArray(forKey: "recentPaths") ?? []
    }

    func mode(for flag: NSEvent.ModifierFlags) -> WheelMode? {
        if convertKey.flag == flag { return .convert }
        if toolsKey.flag == flag { return .tools }
        if actionsKey.flag == flag { return .actions }
        return nil
    }

    func key(for mode: WheelMode) -> ModifierKey {
        switch mode {
        case .convert: return convertKey
        case .tools: return toolsKey
        case .actions: return actionsKey
        }
    }

    var options: ConversionOptions {
        var options = ConversionOptions()
        options.imageQuality = imageQuality
        options.videoCRF = videoCRF
        options.audioBitrateKbps = audioBitrate
        options.pdfRenderDPI = Double(pdfDPI)
        switch outputMode {
        case .beside: options.outputLocation = .besideOriginal
        case .downloads: options.outputLocation = .downloads
        case .custom: options.outputLocation = customFolder.isEmpty ? .besideOriginal : .folder(customFolder)
        }
        return options
    }

    var toolLocator: ToolLocator {
        ToolLocator(overrides: [
            "ffmpeg": ffmpegPath,
            "ffprobe": ffmpegPath.isEmpty ? "" : (ffmpegPath as NSString).deletingLastPathComponent + "/ffprobe",
            "soffice": sofficePath,
            "pandoc": pandocPath,
        ])
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Kumquat: launch at login failed: \(error.localizedDescription)")
            }
        }
    }
}

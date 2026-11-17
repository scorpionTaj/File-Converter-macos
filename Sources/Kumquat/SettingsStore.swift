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
        case .none: return L("Off")
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case beside, downloads, custom, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beside: return L("Next to the original")
        case .downloads: return L("Downloads folder")
        case .custom: return L("Custom folder")
        case .ask: return L("Ask each time")
        }
    }
}

/// Corner of the screen the progress/result notice appears in.
enum HUDPosition: String, CaseIterable, Identifiable {
    case topRight, topCenter, topLeft, bottomRight, bottomLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topRight: return L("Top right")
        case .topCenter: return L("Top centre")
        case .topLeft: return L("Top left")
        case .bottomRight: return L("Bottom right")
        case .bottomLeft: return L("Bottom left")
        }
    }
}

enum WheelPosition: String, CaseIterable, Identifiable {
    case cursor, screenCenter
    var id: String { rawValue }
    var title: String { self == .cursor ? L("Under the pointer") : L("Centre of the screen") }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case kumquat, arrows, wand, document
    var id: String { rawValue }
    var title: String {
        switch self {
        case .kumquat: return L("Kumquat")
        case .arrows: return L("Arrows")
        case .wand: return L("Magic wand")
        case .document: return L("Document")
        }
    }
    /// SF Symbol, or nil for the drawn kumquat.
    var symbolName: String? {
        switch self {
        case .kumquat: return nil
        case .arrows: return "arrow.triangle.2.circlepath"
        case .wand: return "wand.and.stars"
        case .document: return "doc.on.doc"
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
    @Published var finderShortcut: FinderShortcut { didSet { defaults.set(finderShortcut.rawValue, forKey: "finderShortcut") } }
    @Published var toolsKey: ModifierKey { didSet { defaults.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var actionsKey: ModifierKey { didSet { defaults.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: "revealInFinder") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var wheelScale: Double { didSet { defaults.set(wheelScale, forKey: "wheelScale") } }
    @Published var imageQuality: Double { didSet { defaults.set(imageQuality, forKey: "imageQuality") } }
    @Published var videoCRF: Int { didSet { defaults.set(videoCRF, forKey: "videoCRF") } }
    @Published var audioBitrate: Int { didSet { defaults.set(audioBitrate, forKey: "audioBitrate") } }
    @Published var pdfDPI: Int { didSet { defaults.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var pdfCompression: PDFCompression { didSet { defaults.set(pdfCompression.rawValue, forKey: "pdfCompression") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var customFolder: String { didSet { defaults.set(customFolder, forKey: "customFolder") } }
    /// Multi-file jobs save into a dated subfolder.
    @Published var batchSubfolders: Bool { didSet { defaults.set(batchSubfolders, forKey: "batchSubfolders") } }
    /// FileKind raw value → folder for results of that kind.
    @Published var kindFolders: [String: String] { didSet { defaults.set(kindFolders, forKey: "kindFolders") } }
    @Published var wheelPreferences: WheelPreferences { didSet { store(wheelPreferences, "wheelPreferences") } }
    @Published var presets: [OutputPreset] { didSet { store(presets, "presets") } }
    /// Folders whose new files are converted with a preset.
    @Published var watchFolders: [WatchFolder] { didSet { store(watchFolders, "watchFolders") } }
    /// The floating drop shelf is on screen.
    @Published var showShelf: Bool { didSet { defaults.set(showShelf, forKey: "showShelf") } }
    /// Why the last launch-at-login change failed, for Settings ▸ General.
    @Published var launchAtLoginError: String?
    /// Format id → choices remembered from the options sheet, applied to every conversion to that format.
    @Published var formatDefaults: [String: OptionOverrides] { didSet { store(formatDefaults, "formatDefaults") } }
    @Published var askBeforeConverting: Bool { didSet { defaults.set(askBeforeConverting, forKey: "askBeforeConverting") } }
    @Published var terminalBundleID: String { didSet { defaults.set(terminalBundleID, forKey: "terminalBundleID") } }
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    @Published var sofficePath: String { didSet { defaults.set(sofficePath, forKey: "sofficePath") } }
    @Published var pandocPath: String { didSet { defaults.set(pandocPath, forKey: "pandocPath") } }
    @Published var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var themeID: String { didSet { defaults.set(themeID, forKey: "themeID") } }
    @Published var offerMoveToApplications: Bool { didSet { defaults.set(offerMoveToApplications, forKey: "offerMoveToApplications") } }
    @Published var fileNameTemplate: String { didSet { defaults.set(fileNameTemplate, forKey: "fileNameTemplate") } }
    @Published var conflictPolicy: ConflictPolicy { didSet { defaults.set(conflictPolicy.rawValue, forKey: "conflictPolicy") } }
    @Published var originalsPolicy: OriginalsPolicy { didSet { defaults.set(originalsPolicy.rawValue, forKey: "originalsPolicy") } }
    @Published var metadataPolicy: MetadataPolicy { didSet { defaults.set(metadataPolicy.rawValue, forKey: "metadataPolicy") } }
    @Published var preserveFileDates: Bool { didSet { defaults.set(preserveFileDates, forKey: "preserveFileDates") } }
    /// Per-format quality; values outside 0...1 (the default -1) mean "use `imageQuality`".
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: "jpegQuality") } }
    @Published var heicQuality: Double { didSet { defaults.set(heicQuality, forKey: "heicQuality") } }
    @Published var webpQuality: Double { didSet { defaults.set(webpQuality, forKey: "webpQuality") } }
    @Published var avifQuality: Double { didSet { defaults.set(avifQuality, forKey: "avifQuality") } }
    @Published var maxImageDimension: Int { didSet { defaults.set(maxImageDimension, forKey: "maxImageDimension") } }
    @Published var videoPreset: String { didSet { defaults.set(videoPreset, forKey: "videoPreset") } }
    @Published var videoEncoder: VideoEncoderPreference { didSet { defaults.set(videoEncoder.rawValue, forKey: "videoEncoder") } }
    @Published var maxVideoHeight: Int { didSet { defaults.set(maxVideoHeight, forKey: "maxVideoHeight") } }
    @Published var maxFrameRate: Int { didSet { defaults.set(maxFrameRate, forKey: "maxFrameRate") } }
    @Published var removeAudio: Bool { didSet { defaults.set(removeAudio, forKey: "removeAudio") } }
    @Published var audioSampleRate: Int { didSet { defaults.set(audioSampleRate, forKey: "audioSampleRate") } }
    @Published var audioChannels: Int { didSet { defaults.set(audioChannels, forKey: "audioChannels") } }
    @Published var normalizeAudio: Bool { didSet { defaults.set(normalizeAudio, forKey: "normalizeAudio") } }
    @Published var themeFollowsSystem: Bool { didSet { defaults.set(themeFollowsSystem, forKey: "themeFollowsSystem") } }
    @Published var lightThemeID: String { didSet { defaults.set(lightThemeID, forKey: "lightThemeID") } }
    @Published var darkThemeID: String { didSet { defaults.set(darkThemeID, forKey: "darkThemeID") } }
    /// User-made and imported themes.
    @Published var customThemes: [ThemeSpec] {
        didSet {
            defaults.set(try? JSONEncoder().encode(customThemes), forKey: "customThemes")
            Theme.custom = customThemes.map(Theme.fromSpec)
        }
    }
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    @Published var includePrereleases: Bool { didSet { defaults.set(includePrereleases, forKey: "includePrereleases") } }
    @Published var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    /// Release tag the user chose to skip.
    @Published var skippedVersion: String { didSet { defaults.set(skippedVersion, forKey: "skippedVersion") } }
    @Published var hudPosition: HUDPosition { didSet { defaults.set(hudPosition.rawValue, forKey: "hudPosition") } }
    /// Seconds a result stays on screen; 0 keeps it until clicked.
    @Published var hudDuration: Double { didSet { defaults.set(hudDuration, forKey: "hudDuration") } }
    @Published var notifyWhenDone: NotificationPolicy { didSet { defaults.set(notifyWhenDone.rawValue, forKey: "notifyWhenDone") } }
    /// Show a notice for successful jobs (errors are always shown).
    @Published var hudShowsSuccess: Bool { didSet { defaults.set(hudShowsSuccess, forKey: "hudShowsSuccess") } }
    /// System sound names; empty means silent.
    @Published var successSound: String { didSet { defaults.set(successSound, forKey: "successSound") } }
    @Published var failureSound: String { didSet { defaults.set(failureSound, forKey: "failureSound") } }
    @Published var wheelPosition: WheelPosition { didSet { defaults.set(wheelPosition.rawValue, forKey: "wheelPosition") } }
    @Published var menuBarIcon: MenuBarIconStyle { didSet { defaults.set(menuBarIcon.rawValue, forKey: "menuBarIcon") } }
    /// Percentage next to the menu bar icon while a job runs.
    @Published var menuBarProgress: Bool { didSet { defaults.set(menuBarProgress, forKey: "menuBarProgress") } }
    @Published var recentLimit: Int { didSet { defaults.set(recentLimit, forKey: "recentLimit") } }
    /// Files converted at the same time in a batch.
    @Published var parallelJobs: Int { didSet { defaults.set(parallelJobs, forKey: "parallelJobs") } }
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
        finderShortcut = FinderShortcut(rawValue: string("finderShortcut", "")) ?? .controlOptionK
        toolsKey = ModifierKey(rawValue: string("toolsKey", "")) ?? .command
        actionsKey = ModifierKey(rawValue: string("actionsKey", "")) ?? .control
        revealInFinder = bool("revealInFinder", false)
        playSound = bool("playSound", true)
        wheelScale = double("wheelScale", 1.0)
        imageQuality = double("imageQuality", 0.85)
        videoCRF = int("videoCRF", 23)
        audioBitrate = int("audioBitrate", 192)
        pdfDPI = int("pdfDPI", 200)
        pdfCompression = PDFCompression(rawValue: string("pdfCompression", "")) ?? .balanced
        outputMode = OutputMode(rawValue: string("outputMode", "")) ?? .beside
        customFolder = string("customFolder", "")
        batchSubfolders = bool("batchSubfolders", false)
        kindFolders = defaults.dictionary(forKey: "kindFolders") as? [String: String] ?? [:]
        wheelPreferences = Self.load(WheelPreferences.self, "wheelPreferences", from: defaults) ?? WheelPreferences()
        presets = Self.load([OutputPreset].self, "presets", from: defaults) ?? []
        watchFolders = Self.load([WatchFolder].self, "watchFolders", from: defaults) ?? []
        showShelf = bool("showShelf", false)
        formatDefaults = Self.load([String: OptionOverrides].self, "formatDefaults", from: defaults) ?? [:]
        askBeforeConverting = bool("askBeforeConverting", false)
        terminalBundleID = string("terminalBundleID", "com.apple.Terminal")
        ffmpegPath = string("ffmpegPath", "")
        sofficePath = string("sofficePath", "")
        pandocPath = string("pandocPath", "")
        hasSeenWelcome = bool("hasSeenWelcome", false)
        themeID = string("themeID", "kumquat")
        offerMoveToApplications = bool("offerMoveToApplications", true)
        fileNameTemplate = string("fileNameTemplate", FileNameTemplate.default)
        conflictPolicy = ConflictPolicy(rawValue: string("conflictPolicy", "")) ?? .keepBoth
        originalsPolicy = OriginalsPolicy(rawValue: string("originalsPolicy", "")) ?? .keep
        metadataPolicy = MetadataPolicy(rawValue: string("metadataPolicy", "")) ?? .keep
        preserveFileDates = bool("preserveFileDates", false)
        jpegQuality = double("jpegQuality", -1)
        heicQuality = double("heicQuality", -1)
        webpQuality = double("webpQuality", -1)
        avifQuality = double("avifQuality", -1)
        maxImageDimension = int("maxImageDimension", 0)
        videoPreset = string("videoPreset", "medium")
        videoEncoder = VideoEncoderPreference(rawValue: string("videoEncoder", "")) ?? .automatic
        maxVideoHeight = int("maxVideoHeight", 0)
        maxFrameRate = int("maxFrameRate", 0)
        removeAudio = bool("removeAudio", false)
        audioSampleRate = int("audioSampleRate", 0)
        audioChannels = int("audioChannels", 0)
        normalizeAudio = bool("normalizeAudio", false)
        parallelJobs = min(max(int("parallelJobs", 3), 1), 8)
        themeFollowsSystem = bool("themeFollowsSystem", false)
        lightThemeID = string("lightThemeID", "catppuccin-latte")
        darkThemeID = string("darkThemeID", "catppuccin-mocha")
        let storedThemes = defaults.data(forKey: "customThemes").flatMap { try? JSONDecoder().decode([ThemeSpec].self, from: $0) } ?? []
        customThemes = storedThemes
        Theme.custom = storedThemes.map(Theme.fromSpec)
        checkForUpdates = bool("checkForUpdates", true)
        includePrereleases = bool("includePrereleases", false)
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        skippedVersion = string("skippedVersion", "")
        hudPosition = HUDPosition(rawValue: string("hudPosition", "")) ?? .topRight
        hudDuration = double("hudDuration", 3)
        notifyWhenDone = NotificationPolicy(rawValue: string("notifyWhenDone", "")) ?? .longJobs
        hudShowsSuccess = bool("hudShowsSuccess", true)
        successSound = string("successSound", "Glass")
        failureSound = string("failureSound", "Basso")
        wheelPosition = WheelPosition(rawValue: string("wheelPosition", "")) ?? .cursor
        menuBarIcon = MenuBarIconStyle(rawValue: string("menuBarIcon", "")) ?? .kumquat
        menuBarProgress = bool("menuBarProgress", true)
        recentLimit = min(max(int("recentLimit", 15), 5), 50)
        recentPaths = defaults.stringArray(forKey: "recentPaths") ?? []
    }

    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
                               "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    /// Plays a system sound by name if sounds are on.
    func play(_ name: String) {
        guard playSound, !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Adds a theme, or replaces the one with the same id.
    func saveCustomTheme(_ spec: ThemeSpec) {
        if let index = customThemes.firstIndex(where: { $0.id == spec.id }) {
            customThemes[index] = spec
        } else {
            customThemes.append(spec)
        }
    }

    func deleteCustomTheme(id: String) {
        customThemes.removeAll { $0.id == id }
        if themeID == id { themeID = Theme.kumquat.id }
        if lightThemeID == id { lightThemeID = Theme.kumquatLight.id }
        if darkThemeID == id { darkThemeID = Theme.kumquatDark.id }
    }

    private func store<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, from defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Forgets every preference (recent files included). Takes effect after a relaunch.
    func resetAll() {
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
        }
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
        options.pdfCompression = pdfCompression
        for (format, value) in [(Format.jpg, jpegQuality), (Format.heic, heicQuality), (Format.webp, webpQuality), (Format.avif, avifQuality)]
        where (0...1).contains(value) {
            options.formatQuality[format.id] = value
        }
        options.maxImageDimension = maxImageDimension
        options.videoPreset = videoPreset
        options.videoEncoder = videoEncoder
        options.maxVideoHeight = maxVideoHeight
        options.maxFrameRate = maxFrameRate
        options.removeAudio = removeAudio
        options.audioSampleRate = audioSampleRate
        options.audioChannels = audioChannels
        options.normalizeAudio = normalizeAudio
        options.fileNameTemplate = fileNameTemplate
        options.conflictPolicy = conflictPolicy
        options.originals = originalsPolicy
        options.metadata = metadataPolicy
        options.preserveFileDates = preserveFileDates
        switch outputMode {
        case .beside: options.outputLocation = .besideOriginal
        case .downloads: options.outputLocation = .downloads
        case .custom: options.outputLocation = customFolder.isEmpty ? .besideOriginal : .folder(customFolder)
        // The app asks for a folder before the job starts and replaces this.
        case .ask: options.outputLocation = .besideOriginal
        }
        options.kindFolders = kindFolders.filter { !$0.value.isEmpty }
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

    /// On, or waiting for the user to allow it in System Settings ▸ General ▸ Login Items.
    var launchAtLogin: Bool {
        get { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                AppLog.error("Launch at login: \(error.localizedDescription)")
                let path = Bundle.main.bundleURL.path
                launchAtLoginError = path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
                    ? L("Move Kumquat to Applications first, then turn this on.")
                    : error.localizedDescription
            }
        }
    }

    /// macOS turned launch at login off until the user allows it.
    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}

/// Kumquat's own language, overriding the Mac's. It's the same per-app preference System Settings ▸ General ▸
/// Language & Region ▸ Applications changes, and like every app, Kumquat picks it up when it launches.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", en, fr, es, de, ar

    var id: String { rawValue }

    /// Each language in its own words, so people can find theirs whatever Kumquat is showing.
    var title: String {
        switch self {
        case .system: return L("Same as the Mac")
        case .en: return "English"
        case .fr: return "Français"
        case .es: return "Español"
        case .de: return "Deutsch"
        case .ar: return "العربية"
        }
    }

    private static let key = "AppleLanguages"

    /// The language chosen for Kumquat (not the Mac's list, which `UserDefaults` would also return).
    static var chosen: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// What was chosen when Kumquat launched, i.e. what it's showing now.
    static let atLaunch = chosen

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }
}

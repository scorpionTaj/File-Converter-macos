import AppKit
import SwiftUI
import KumquatCore

/// The pages of the Settings window, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, wheels, notifications
    case output, quality, presets, watchFolders
    case appearance
    case engines, recipes
    case advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .wheels: return L("Wheels")
        case .notifications: return L("Notifications")
        case .output: return L("Output")
        case .quality: return L("Quality")
        case .presets: return L("Presets")
        case .watchFolders: return L("Watch Folders")
        case .appearance: return L("Appearance")
        case .engines: return L("Engines")
        case .recipes: return L("Recipes")
        case .advanced: return L("Advanced")
        case .about: return L("About")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return L("Turn Kumquat on or off, its language, start at login, and the drop shelf.")
        case .wheels: return L("Which key opens which wheel, and what comes first on it.")
        case .notifications: return L("Progress popups, finished-job notifications, sounds and the menu bar.")
        case .output: return L("Where results are saved, how they're named, and what happens to originals.")
        case .quality: return L("Image, PDF, video and audio quality, and how many files run at once.")
        case .presets: return L("Saved conversions that appear as one-tap slices on the Convert wheel.")
        case .watchFolders: return L("Folders whose new files are converted automatically with a preset.")
        case .appearance: return L("Colours for the wheels, the progress popup and the editors.")
        case .engines: return L("Optional helpers such as FFmpeg, LibreOffice and Pandoc.")
        case .recipes: return L("Your own conversions, run from JSON files in the recipes folder.")
        case .advanced: return L("Command line tool, updates, troubleshooting and reset.")
        case .about: return L("Version and project information.")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .wheels: return "circle.circle.fill"
        case .notifications: return "bell.badge.fill"
        case .output: return "folder.fill"
        case .quality: return "slider.horizontal.3"
        case .presets: return "star.fill"
        case .watchFolders: return "eye.fill"
        case .appearance: return "paintpalette.fill"
        case .engines: return "shippingbox.fill"
        case .recipes: return "terminal.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .wheels: return .orange
        case .notifications: return .red
        case .output: return .blue
        case .quality: return .teal
        case .presets: return .yellow
        case .watchFolders: return .indigo
        case .appearance: return .pink
        case .engines: return .brown
        case .recipes: return .green
        case .advanced: return Color(nsColor: .darkGray)
        case .about: return .cyan
        }
    }

    /// Sidebar groups.
    static let groups: [(title: String, pages: [SettingsPage])] = [
        (L("Kumquat"), [.general, .wheels, .notifications]),
        (L("Files"), [.output, .quality, .presets, .watchFolders]),
        (L("Look"), [.appearance]),
        (L("Extend"), [.engines, .recipes]),
        ("", [.advanced, .about]),
    ]
}

/// Settings: a sidebar of pages, like System Settings.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let isBusy: () -> Bool
    @State private var page: SettingsPage?

    init(settings: SettingsStore, isBusy: @escaping () -> Bool, page: SettingsPage = .general) {
        self.settings = settings
        self.isBusy = isBusy
        _page = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(SettingsPage.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.pages) { page in
                            SettingsSidebarRow(page: page).tag(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            let current = page ?? .general
            VStack(spacing: 0) {
                SettingsPageHeader(page: current)
                Divider()
                content(for: current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .id(current)
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    @ViewBuilder private func content(for page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettings(settings: settings, isBusy: isBusy)
        case .wheels: WheelSettings(settings: settings)
        case .notifications: NotificationSettings(settings: settings)
        case .output: OutputSettings(settings: settings)
        case .quality: ConversionSettings(settings: settings)
        case .presets: PresetsSettings(settings: settings)
        case .watchFolders: Form { WatchFoldersSection(settings: settings) }.formStyle(.grouped)
        case .appearance: AppearanceSettings(settings: settings)
        case .engines: EngineSettings(settings: settings)
        case .recipes: Form { RecipesSection() }.formStyle(.grouped)
        case .advanced: AdvancedSettings(settings: settings, isBusy: isBusy)
        case .about: AboutView()
        }
    }
}

/// A coloured icon tile, as in System Settings.
struct SettingsIcon: View {
    let page: SettingsPage
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(page.tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: page.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            SettingsIcon(page: page)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(page: page, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.title2.weight(.semibold))
                Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// Settings ▸ Wheels.
struct WheelSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                keyPicker("Convert wheel", selection: $settings.convertKey)
                keyPicker("Tools wheel", selection: $settings.toolsKey)
                keyPicker("Actions wheel", selection: $settings.actionsKey)
            } header: {
                Text("Keys")
            } footer: {
                Text("Start dragging a file, then tap the key. Drop the file on a segment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Open the wheel", selection: $settings.wheelPosition) {
                    ForEach(WheelPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker("Wheel for Finder selection", selection: $settings.finderShortcut) {
                    ForEach(FinderShortcut.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Opening")
            } footer: {
                Text("Select files in Finder and press the shortcut to open the wheel without dragging.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Recently used first", isOn: $settings.wheelPreferences.recentFirst)
                LabeledContent("Pinned slices") {
                    Button("Clear Pins") { settings.wheelPreferences.pinned = [:] }
                        .disabled(settings.wheelPreferences.pinned.isEmpty)
                }
            } header: {
                Text("Order")
            } footer: {
                Text("Right-click a slice on a clicked-open wheel to pin it to the front for that file type.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Settings ▸ Notifications.
struct NotificationSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Progress popup") {
                Picker("Position", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker("Keep results on screen", selection: $settings.hudDuration) {
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("Until clicked").tag(0.0)
                }
                Toggle("Show a notice when a job succeeds", isOn: $settings.hudShowsSuccess)
                Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
            }
            Section {
                Picker("Notify when a job finishes", selection: $settings.notifyWhenDone) {
                    ForEach(NotificationPolicy.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Finished-job notifications have Show in Finder, Open and Undo buttons.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sounds") {
                Toggle("Play sounds", isOn: $settings.playSound)
                soundPicker("Success", selection: $settings.successSound)
                soundPicker("Failure", selection: $settings.failureSound)
            }
            Section("Menu bar") {
                Picker("Icon", selection: $settings.menuBarIcon) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: StatusIcon.make(style))
                        }
                        .tag(style)
                    }
                }
                Toggle("Show progress next to the icon", isOn: $settings.menuBarProgress)
                Picker("Recent results", selection: $settings.recentLimit) {
                    ForEach([5, 10, 15, 25, 50], id: \.self) { Text("\($0)").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func soundPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!settings.playSound)
        .onChange(of: selection.wrappedValue) { name in
            if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() }
        }
    }
}

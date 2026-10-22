import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KumquatCore

/// Colours for the wheel, the HUD and the annotation editor.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    /// Light themes draw on light surfaces; dark ones on dark. `nil` follows the system (Kumquat default).
    let isDark: Bool?
    let segment: NSColor
    let hub: NSColor
    let stroke: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let accent: NSColor
    let accentText: NSColor
    let success: NSColor
    let failure: NSColor
    let canvas: NSColor

    static func == (lhs: Theme, rhs: Theme) -> Bool { lhs.id == rhs.id }

    /// Theme resolved for an appearance: the Kumquat default adapts to light/dark mode.
    func resolved(dark systemIsDark: Bool) -> Theme {
        guard isDark == nil else { return self }
        return systemIsDark ? Theme.kumquatDark : Theme.kumquatLight
    }

    var appearance: NSAppearance? {
        guard let isDark else { return nil }
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    static let all: [Theme] = [
        .kumquat,
        .catppuccinLatte, .catppuccinFrappe, .catppuccinMacchiato, .catppuccinMocha,
        .dracula, .monokai, .nord, .gruvbox, .tokyoNight, .oneDark, .rosePine,
        .solarizedLight, .solarizedDark,
    ]

    /// Themes the user made or imported; kept in sync by `SettingsStore`.
    static var custom: [Theme] = []

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? custom.first { $0.id == id } ?? .kumquat
    }

    static func fromSpec(_ spec: ThemeSpec) -> Theme {
        make(spec.id, spec.name, dark: spec.dark, segment: spec.segment, hub: spec.hub, stroke: spec.stroke,
             text: spec.text, secondary: spec.secondaryText, accent: spec.accent, accentText: spec.accentText,
             success: spec.success, failure: spec.failure, canvas: spec.canvas)
    }

    /// Editable copy of this theme's colours (the adaptive default uses its light or dark palette).
    func spec(id: String, name: String, dark systemIsDark: Bool) -> ThemeSpec {
        let theme = resolved(dark: systemIsDark)
        return ThemeSpec(id: id, name: name, dark: theme.isDark ?? systemIsDark,
                         segment: theme.segment.hexString, hub: theme.hub.hexString, stroke: theme.stroke.hexString,
                         text: theme.text.hexString, secondaryText: theme.secondaryText.hexString,
                         accent: theme.accent.hexString, accentText: theme.accentText.hexString,
                         success: theme.success.hexString, failure: theme.failure.hexString, canvas: theme.canvas.hexString)
    }

    // MARK: Palettes

    private static func make(_ id: String, _ name: String, dark: Bool, segment: String, hub: String, stroke: String,
                             text: String, secondary: String, accent: String, accentText: String,
                             success: String, failure: String, canvas: String) -> Theme {
        Theme(id: id, name: name, isDark: dark,
              segment: NSColor(hex: segment, alpha: 0.96), hub: NSColor(hex: hub, alpha: 0.98),
              stroke: NSColor(hex: stroke, alpha: 0.55), text: NSColor(hex: text), secondaryText: NSColor(hex: secondary),
              accent: NSColor(hex: accent), accentText: NSColor(hex: accentText),
              success: NSColor(hex: success), failure: NSColor(hex: failure), canvas: NSColor(hex: canvas))
    }

    static let kumquat = Theme(id: "kumquat", name: "Kumquat", isDark: nil,
                               segment: kumquatLight.segment, hub: kumquatLight.hub, stroke: kumquatLight.stroke,
                               text: kumquatLight.text, secondaryText: kumquatLight.secondaryText,
                               accent: kumquatLight.accent, accentText: kumquatLight.accentText,
                               success: kumquatLight.success, failure: kumquatLight.failure, canvas: kumquatLight.canvas)
    static let kumquatLight = make("kumquat-light", "Kumquat Light", dark: false, segment: "FAFAFA", hub: "FFFFFF",
                                   stroke: "D0D0D0", text: "1D1D1F", secondary: "6E6E73", accent: "FF8A00",
                                   accentText: "FFFFFF", success: "28A745", failure: "E5484D", canvas: "E8E8EA")
    static let kumquatDark = make("kumquat-dark", "Kumquat Dark", dark: true, segment: "222224", hub: "1A1A1C",
                                  stroke: "3A3A3C", text: "F5F5F7", secondary: "A1A1A6", accent: "FF9F0A",
                                  accentText: "FFFFFF", success: "32D74B", failure: "FF453A", canvas: "2A2A2C")

    static let catppuccinLatte = make("catppuccin-latte", "Catppuccin Latte", dark: false, segment: "E6E9EF", hub: "EFF1F5",
                                      stroke: "BCC0CC", text: "4C4F69", secondary: "6C6F85", accent: "8839EF",
                                      accentText: "EFF1F5", success: "40A02B", failure: "D20F39", canvas: "DCE0E8")
    static let catppuccinFrappe = make("catppuccin-frappe", "Catppuccin Frappé", dark: true, segment: "292C3C", hub: "303446",
                                       stroke: "51576D", text: "C6D0F5", secondary: "A5ADCE", accent: "CA9EE6",
                                       accentText: "232634", success: "A6D189", failure: "E78284", canvas: "232634")
    static let catppuccinMacchiato = make("catppuccin-macchiato", "Catppuccin Macchiato", dark: true, segment: "1E2030",
                                          hub: "24273A", stroke: "494D64", text: "CAD3F5", secondary: "A5ADCB",
                                          accent: "C6A0F6", accentText: "181926", success: "A6DA95", failure: "ED8796",
                                          canvas: "181926")
    static let catppuccinMocha = make("catppuccin-mocha", "Catppuccin Mocha", dark: true, segment: "181825", hub: "1E1E2E",
                                      stroke: "45475A", text: "CDD6F4", secondary: "A6ADC8", accent: "CBA6F7",
                                      accentText: "11111B", success: "A6E3A1", failure: "F38BA8", canvas: "11111B")
    static let dracula = make("dracula", "Dracula", dark: true, segment: "21222C", hub: "282A36", stroke: "44475A",
                              text: "F8F8F2", secondary: "6272A4", accent: "BD93F9", accentText: "282A36",
                              success: "50FA7B", failure: "FF5555", canvas: "191A21")
    static let monokai = make("monokai", "Monokai", dark: true, segment: "1E1F1C", hub: "272822", stroke: "49483E",
                              text: "F8F8F2", secondary: "75715E", accent: "FD971F", accentText: "272822",
                              success: "A6E22E", failure: "F92672", canvas: "1E1F1C")
    static let nord = make("nord", "Nord", dark: true, segment: "3B4252", hub: "2E3440", stroke: "4C566A",
                           text: "ECEFF4", secondary: "D8DEE9", accent: "88C0D0", accentText: "2E3440",
                           success: "A3BE8C", failure: "BF616A", canvas: "242933")
    static let gruvbox = make("gruvbox", "Gruvbox", dark: true, segment: "32302F", hub: "282828", stroke: "504945",
                              text: "EBDBB2", secondary: "A89984", accent: "FE8019", accentText: "282828",
                              success: "B8BB26", failure: "FB4934", canvas: "1D2021")
    static let tokyoNight = make("tokyo-night", "Tokyo Night", dark: true, segment: "16161E", hub: "1A1B26", stroke: "3B4261",
                                 text: "C0CAF5", secondary: "9AA5CE", accent: "7AA2F7", accentText: "1A1B26",
                                 success: "9ECE6A", failure: "F7768E", canvas: "16161E")
    static let oneDark = make("one-dark", "One Dark", dark: true, segment: "21252B", hub: "282C34", stroke: "3E4451",
                              text: "ABB2BF", secondary: "7F848E", accent: "61AFEF", accentText: "282C34",
                              success: "98C379", failure: "E06C75", canvas: "1E2227")
    static let rosePine = make("rose-pine", "Rosé Pine", dark: true, segment: "1F1D2E", hub: "191724", stroke: "403D52",
                               text: "E0DEF4", secondary: "908CAA", accent: "EBBCBA", accentText: "191724",
                               success: "9CCFD8", failure: "EB6F92", canvas: "191724")
    static let solarizedLight = make("solarized-light", "Solarized Light", dark: false, segment: "EEE8D5", hub: "FDF6E3",
                                     stroke: "D3CBB7", text: "586E75", secondary: "93A1A1", accent: "268BD2",
                                     accentText: "FDF6E3", success: "859900", failure: "DC322F", canvas: "EEE8D5")
    static let solarizedDark = make("solarized-dark", "Solarized Dark", dark: true, segment: "073642", hub: "002B36",
                                    stroke: "0F4C5C", text: "93A1A1", secondary: "839496", accent: "B58900",
                                    accentText: "002B36", success: "859900", failure: "DC322F", canvas: "002B36")
}

/// A user theme as stored in settings and in exported `.json` files. Colours are "RRGGBB" hex strings.
struct ThemeSpec: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var dark: Bool
    var segment: String
    var hub: String
    var stroke: String
    var text: String
    var secondaryText: String
    var accent: String
    var accentText: String
    var success: String
    var failure: String
    var canvas: String

    static func newID() -> String { "custom-\(UUID().uuidString.prefix(8).lowercased())" }

    /// Every colour is a 6-digit hex value.
    var isValid: Bool {
        [segment, hub, stroke, text, secondaryText, accent, accentText, success, failure, canvas].allSatisfy { value in
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            return hex.count == 6 && UInt64(hex, radix: 16) != nil
        }
    }
}

extension NSColor {
    /// "FF8A00" in sRGB.
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "000000" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    /// "FF8A00" / "#FF8A00".
    convenience init(hex: String, alpha: CGFloat = 1) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension SettingsStore {
    var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The chosen theme: the single theme, or the light/dark pair's member for the current appearance.
    var activeTheme: Theme {
        if themeFollowsSystem { return Theme.named(systemIsDark ? darkThemeID : lightThemeID) }
        return Theme.named(themeID)
    }

    /// Current theme resolved for the system appearance.
    var resolvedTheme: Theme { activeTheme.resolved(dark: systemIsDark) }
}

// MARK: - Settings UI

/// A miniature wheel drawn with a theme, for the theme picker.
struct ThemePreview: View {
    let theme: Theme
    let isSelected: Bool

    var body: some View {
        let resolved = theme.resolved(dark: theme.isDark ?? false)
        VStack(spacing: 6) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2 - 2
                let inner = outer * 0.42
                let count = 6
                for index in 0..<count {
                    let start = Angle.degrees(Double(index) * 60 - 90 + 2)
                    let end = Angle.degrees(Double(index + 1) * 60 - 90 - 2)
                    var path = Path()
                    path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
                    path.addArc(center: center, radius: inner + 2, startAngle: end, endAngle: start, clockwise: true)
                    path.closeSubpath()
                    context.fill(path, with: .color(Color(nsColor: index == 1 ? resolved.accent : resolved.segment)))
                    context.stroke(path, with: .color(Color(nsColor: resolved.stroke)), lineWidth: 0.5)
                }
                let hub = Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
                context.fill(hub, with: .color(Color(nsColor: resolved.hub)))
                context.stroke(hub, with: .color(Color(nsColor: resolved.accent)), lineWidth: 1.5)
            }
            .frame(width: 64, height: 64)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: resolved.canvas)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1))
            Text(theme.name).font(.caption).lineLimit(1)
        }
    }
}

struct AppearanceSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var editing: ThemeSpec?
    @State private var message: String?
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme").font(.headline)
                Text("Colours for the wheels, the progress popup and the annotation editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use different themes for Light and Dark mode", isOn: $settings.themeFollowsSystem)
                if settings.themeFollowsSystem {
                    HStack(spacing: 16) {
                        themeMenu("Light mode", selection: $settings.lightThemeID)
                        themeMenu("Dark mode", selection: $settings.darkThemeID)
                    }
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Theme.all + Theme.custom) { theme in
                        Button {
                            settings.themeID = theme.id
                            settings.themeFollowsSystem = false
                        } label: {
                            ThemePreview(theme: theme, isSelected: !settings.themeFollowsSystem && settings.themeID == theme.id)
                        }
                        .buttonStyle(.plain)
                        .help(theme.isDark == nil ? "\(theme.name) (follows light/dark mode)" : theme.name)
                        .contextMenu { contextMenu(for: theme) }
                    }
                }
                HStack {
                    Button("New Theme…") { duplicate(settings.activeTheme) }
                    Button("Import…") { importThemes() }
                    Spacer()
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Right-click a theme to duplicate, edit, export or delete it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Slider(value: $settings.wheelScale, in: 0.8...1.3, step: 0.05) {
                    Text("Wheel size")
                }
            }
            .padding(16)
        }
        .sheet(item: $editing) { spec in
            ThemeEditor(spec: spec) { saved in
                settings.saveCustomTheme(saved)
                settings.themeID = saved.id
                settings.themeFollowsSystem = false
                editing = nil
            } cancel: {
                editing = nil
            }
        }
    }

    private func themeMenu(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Theme.all + Theme.custom) { Text($0.name).tag($0.id) }
        }
    }

    @ViewBuilder
    private func contextMenu(for theme: Theme) -> some View {
        let isCustom = Theme.custom.contains(theme)
        Button("Duplicate…") { duplicate(theme) }
        if isCustom, let spec = settings.customThemes.first(where: { $0.id == theme.id }) {
            Button("Edit…") { editing = spec }
            Button("Export…") { export(spec) }
            Divider()
            Button("Delete", role: .destructive) { settings.deleteCustomTheme(id: spec.id) }
        }
    }

    private func duplicate(_ theme: Theme) {
        editing = theme.spec(id: ThemeSpec.newID(), name: "\(theme.name) Copy", dark: settings.systemIsDark)
    }

    private func export(_ spec: ThemeSpec) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(spec.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(spec).write(to: url)
            message = "Exported \(spec.name)."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func importThemes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var imported = 0
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoder = JSONDecoder()
            let specs = (try? decoder.decode([ThemeSpec].self, from: data))
                ?? (try? decoder.decode(ThemeSpec.self, from: data)).map { [$0] } ?? []
            for var spec in specs where spec.isValid {
                // Fresh ids, so importing twice or sharing between Macs never overwrites another theme.
                spec.id = ThemeSpec.newID()
                settings.saveCustomTheme(spec)
                imported += 1
            }
        }
        message = imported == 0 ? "No valid themes found." : "Imported \(imported) theme\(imported == 1 ? "" : "s")."
    }
}

/// Edits one custom theme's name, base appearance and colours, with a live preview.
struct ThemeEditor: View {
    @State var spec: ThemeSpec
    let save: (ThemeSpec) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Theme").font(.headline)
            HStack(alignment: .top, spacing: 20) {
                Form {
                    TextField("Name", text: $spec.name)
                    Toggle("Dark theme", isOn: $spec.dark)
                    colorRow("Segments", \.segment)
                    colorRow("Centre", \.hub)
                    colorRow("Outlines", \.stroke)
                    colorRow("Text", \.text)
                    colorRow("Secondary text", \.secondaryText)
                    colorRow("Accent", \.accent)
                    colorRow("Text on accent", \.accentText)
                    colorRow("Success", \.success)
                    colorRow("Failure", \.failure)
                    colorRow("Editor background", \.canvas)
                }
                .formStyle(.grouped)
                ThemePreview(theme: Theme.fromSpec(spec), isSelected: false)
                    .padding(.top, 12)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(spec) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(spec.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }

    private func colorRow(_ title: String, _ keyPath: WritableKeyPath<ThemeSpec, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(nsColor: NSColor(hex: spec[keyPath: keyPath])) },
            set: { spec[keyPath: keyPath] = NSColor($0).hexString }
        ), supportsOpacity: false)
    }
}

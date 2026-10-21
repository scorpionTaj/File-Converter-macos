#if os(macOS)
import AppKit
import SwiftUI
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

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .kumquat
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

extension NSColor {
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
    /// Current theme resolved for the system appearance.
    var resolvedTheme: Theme {
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Theme.named(themeID).resolved(dark: systemIsDark)
    }
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
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme").font(.headline)
                Text("Colours for the wheels, the progress popup and the annotation editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Theme.all) { theme in
                        Button {
                            settings.themeID = theme.id
                        } label: {
                            ThemePreview(theme: theme, isSelected: settings.themeID == theme.id)
                        }
                        .buttonStyle(.plain)
                        .help(theme.isDark == nil ? "\(theme.name) (follows light/dark mode)" : theme.name)
                    }
                }
                Divider()
                Slider(value: $settings.wheelScale, in: 0.8...1.3, step: 0.05) {
                    Text("Wheel size")
                }
            }
            .padding(16)
        }
    }
}
#endif

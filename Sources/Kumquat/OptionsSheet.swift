import AppKit
import SwiftUI
import KumquatCore

/// "Options before converting": a small form, prefilled with what the conversion would use, for the settings
/// that matter for the target format. Shown when ⌥ is held while choosing a format, or always if set.
@MainActor
enum OptionsSheet {
    struct Choice {
        var overrides: OptionOverrides
        var remember: Bool
    }

    /// Which fields apply to converting `sources` to `target`.
    struct Fields: OptionSet {
        let rawValue: Int
        static let quality = Fields(rawValue: 1)
        static let imageSize = Fields(rawValue: 2)
        static let video = Fields(rawValue: 4)
        static let audioBitrate = Fields(rawValue: 8)
        static let pdfPages = Fields(rawValue: 16)

        init(rawValue: Int) { self.rawValue = rawValue }

        init(target: Format, sources: [Format]) {
            var fields: Fields = []
            if [.jpg, .heic, .webp, .avif].contains(target) { fields.insert(.quality) }
            if target.kind == .image {
                fields.insert(.imageSize)
                if sources.contains(.pdf) { fields.insert(.pdfPages) }
            }
            if target.kind == .video { fields.formUnion([.video, .audioBitrate]) }
            if target.kind == .audio, ![.wav, .flac, .aiff].contains(target) { fields.insert(.audioBitrate) }
            self = fields
        }
    }

    final class Model: ObservableObject {
        @Published var quality: Double
        @Published var maxImageDimension: Int
        @Published var videoCRF: Int
        @Published var maxVideoHeight: Int
        @Published var removeAudio: Bool
        @Published var audioBitrate: Int
        @Published var pdfPages = ""
        @Published var remember = false
        let fields: Fields

        init(options: ConversionOptions, target: Format, fields: Fields) {
            quality = options.quality(for: target)
            maxImageDimension = options.maxImageDimension
            videoCRF = options.videoCRF
            maxVideoHeight = options.maxVideoHeight
            removeAudio = options.removeAudio
            audioBitrate = options.audioBitrateKbps
            self.fields = fields
        }

        var overrides: OptionOverrides {
            var result = OptionOverrides()
            if fields.contains(.quality) { result.quality = quality }
            if fields.contains(.imageSize) { result.maxImageDimension = maxImageDimension }
            if fields.contains(.video) {
                result.videoCRF = videoCRF
                result.maxVideoHeight = maxVideoHeight
                result.removeAudio = removeAudio
            }
            if fields.contains(.audioBitrate) { result.audioBitrateKbps = audioBitrate }
            let pages = pdfPages.trimmingCharacters(in: .whitespaces)
            if fields.contains(.pdfPages), !pages.isEmpty { result.pdfPages = pages }
            return result
        }
    }

    /// Nil when cancelled. With no fields to offer, converts straight away.
    static func ask(target: Format, sources: [Format], options: ConversionOptions, fileCount: Int) -> Choice? {
        let fields = Fields(target: target, sources: sources)
        guard !fields.isEmpty else { return Choice(overrides: OptionOverrides(), remember: false) }
        let model = Model(options: options, target: target, fields: fields)
        let form = NSHostingView(rootView: OptionsForm(model: model, target: target))
        form.frame = NSRect(origin: .zero, size: form.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Convert \(fileCount == 1 ? "1 file" : "\(fileCount) files") to \(target.shortName)"
        alert.informativeText = "These settings apply to this conversion."
        alert.accessoryView = form
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        if fields.contains(.pdfPages), !model.pdfPages.trimmingCharacters(in: .whitespaces).isEmpty,
           (try? PageRanges.parse(model.pdfPages, pageCount: 9_999)) == nil {
            let invalid = NSAlert()
            invalid.messageText = "“\(model.pdfPages)” isn't a page list"
            invalid.informativeText = "Use pages like 1, 3-5 or 2-."
            invalid.runModal()
            return nil
        }
        return Choice(overrides: model.overrides, remember: model.remember)
    }
}

private struct OptionsForm: View {
    @ObservedObject var model: OptionsSheet.Model
    let target: Format

    private static let sizes = [0, 4096, 3840, 2560, 2048, 1920, 1600, 1280, 1024, 800]
    private static let heights = [0, 2160, 1440, 1080, 720, 480]
    private static let bitrates = [96, 128, 160, 192, 256, 320]

    var body: some View {
        Form {
            if model.fields.contains(.quality) {
                Slider(value: $model.quality, in: 0.3...1, step: 0.05) {
                    Text("Quality: \(Int((model.quality * 100).rounded()))%")
                }
            }
            if model.fields.contains(.imageSize) {
                Picker("Maximum size", selection: $model.maxImageDimension) {
                    ForEach(Self.sizes, id: \.self) { Text($0 == 0 ? "Original" : "\($0) px").tag($0) }
                }
            }
            if model.fields.contains(.pdfPages) {
                TextField("PDF pages", text: $model.pdfPages, prompt: Text("All, or e.g. 1, 3-5"))
            }
            if model.fields.contains(.video) {
                Stepper("Quality (CRF): \(model.videoCRF)", value: $model.videoCRF, in: 14...36)
                Picker("Maximum resolution", selection: $model.maxVideoHeight) {
                    ForEach(Self.heights, id: \.self) { Text($0 == 0 ? "Original" : "\($0)p").tag($0) }
                }
                Toggle("Remove audio", isOn: $model.removeAudio)
            }
            if model.fields.contains(.audioBitrate) {
                Picker("Audio bitrate", selection: $model.audioBitrate) {
                    ForEach(Self.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
            Toggle("Remember for \(target.shortName)", isOn: $model.remember)
                .help("Use these settings for every conversion to \(target.shortName). Page ranges aren't remembered.")
        }
        .frame(width: 320)
        .padding(.vertical, 4)
    }
}

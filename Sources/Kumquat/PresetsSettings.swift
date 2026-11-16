import SwiftUI
import KumquatCore

/// Settings ▸ Presets: saved conversions shown as slices on the Convert wheel.
struct PresetsSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var editing: OutputPreset?

    var body: some View {
        Form {
            Section {
                if settings.presets.isEmpty {
                    Text("No presets yet.").foregroundStyle(.secondary)
                }
                ForEach(settings.presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = preset }
                        Button(role: .destructive) {
                            settings.presets.removeAll { $0.id == preset.id }
                        } label: { Image(systemName: "trash") }
                            .help("Delete \(preset.name)")
                    }
                }
                Button("Add Preset…") {
                    editing = OutputPreset(name: "Web image", target: Format.webp.id,
                                           overrides: OptionOverrides(quality: 0.8, maxImageDimension: 2048))
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("A preset is a format plus the settings to use, like “WebP 80%, 2048 px”. Presets appear first on the Convert wheel for files that can become their format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WatchFoldersSection(settings: settings)
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset) { saved in
                if let index = settings.presets.firstIndex(where: { $0.id == saved.id }) {
                    settings.presets[index] = saved
                } else {
                    settings.presets.append(saved)
                }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }
}

/// Folders whose new files are converted with a preset.
private struct WatchFoldersSection: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Section {
            if settings.watchFolders.isEmpty {
                Text("No watch folders yet.").foregroundStyle(.secondary)
            }
            ForEach($settings.watchFolders) { $folder in
                HStack {
                    Toggle("", isOn: $folder.isEnabled)
                        .labelsHidden()
                        .help(folder.isEnabled ? "Watching" : "Paused")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                        Text(status(of: folder)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Picker("", selection: $folder.presetID) {
                        if !settings.presets.contains(where: { $0.id == folder.presetID }) {
                            Text("Choose a preset").tag(folder.presetID)
                        }
                        ForEach(settings.presets) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                    } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    Button(role: .destructive) {
                        settings.watchFolders.removeAll { $0.id == folder.id }
                    } label: { Image(systemName: "trash") }
                        .help("Stop watching \(folder.name)")
                }
            }
            Button("Add Watch Folder…") {
                guard let preset = settings.presets.first,
                      let url = Prompt.chooseFolder(title: "Watch Folder") else { return }
                guard !settings.watchFolders.contains(where: { $0.path == url.path }) else { return }
                settings.watchFolders.append(WatchFolder(path: url.path, presetID: preset.id))
            }
            .disabled(settings.presets.isEmpty)
        } header: {
            Text("Watch folders")
        } footer: {
            Text(settings.presets.isEmpty
                 ? "Make a preset first: a watch folder converts every new file with one."
                 : "New files in a watch folder are converted with its preset while Kumquat runs, and files that arrived while it was closed are converted at the next launch. Files already there when you add the folder are left alone. Results follow your Output settings (“Ask each time” saves next to the file).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func status(of folder: WatchFolder) -> String {
        if !FileManager.default.fileExists(atPath: folder.path) { return "Folder not found: \(folder.path)" }
        if !settings.presets.contains(where: { $0.id == folder.presetID }) { return "Its preset was deleted; choose another" }
        return folder.path
    }
}

private struct PresetEditor: View {
    @State private var draft: OutputPreset
    let onSave: (OutputPreset) -> Void
    let onCancel: () -> Void

    private static let targets: [Format] = Format.imageOutputs + [.pdf] + Format.videoOutputs + Format.audioOutputs
    private static let sizes = [4096, 3840, 2560, 2048, 1920, 1600, 1280, 1024, 800]
    private static let heights = [2160, 1440, 1080, 720, 480]
    private static let bitrates = [96, 128, 160, 192, 256, 320]

    init(preset: OutputPreset, onSave: @escaping (OutputPreset) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: preset)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var target: Format? { draft.targetFormat }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: $draft.name)
                Picker("Format", selection: $draft.target) {
                    ForEach(Self.targets) { Text($0.name).tag($0.id) }
                }
                if let target, [.jpg, .heic, .webp, .avif].contains(target) {
                    optionalRow("Quality", \.quality, default: 0.8) { value in
                        Slider(value: value, in: 0.3...1, step: 0.05) { Text("\(Int((value.wrappedValue * 100).rounded()))%") }
                    }
                }
                if target?.kind == .image {
                    optionalRow("Maximum size", \.maxImageDimension, default: 2048) { value in
                        Picker("", selection: value) { ForEach(Self.sizes, id: \.self) { Text("\($0) px").tag($0) } }
                    }
                }
                if target?.kind == .video {
                    optionalRow("Quality (CRF)", \.videoCRF, default: 23) { value in
                        Stepper("\(value.wrappedValue)", value: value, in: 14...36)
                    }
                    optionalRow("Maximum resolution", \.maxVideoHeight, default: 1080) { value in
                        Picker("", selection: value) { ForEach(Self.heights, id: \.self) { Text("\($0)p").tag($0) } }
                    }
                    optionalRow("Remove audio", \.removeAudio, default: true) { _ in EmptyView() }
                }
                if target?.kind == .video || target?.kind == .audio {
                    optionalRow("Audio bitrate", \.audioBitrateKbps, default: 160) { value in
                        Picker("", selection: value) { ForEach(Self.bitrates, id: \.self) { Text("\($0) kbps").tag($0) } }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(cleaned) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 440)
    }

    /// Drops settings that don't apply to the chosen format (e.g. quality after switching to PNG).
    private var cleaned: OutputPreset {
        var preset = draft
        preset.name = preset.name.trimmingCharacters(in: .whitespaces)
        let kind = target?.kind
        if let target, ![.jpg, .heic, .webp, .avif].contains(target) { preset.overrides.quality = nil }
        if kind != .image { preset.overrides.maxImageDimension = nil }
        if kind != .video {
            preset.overrides.videoCRF = nil
            preset.overrides.maxVideoHeight = nil
            preset.overrides.removeAudio = nil
        }
        if kind != .video, kind != .audio { preset.overrides.audioBitrateKbps = nil }
        preset.overrides.pdfPages = nil
        return preset
    }

    /// A checkbox that turns a setting on (using `default`) or back to "use my usual setting", plus its control.
    private func optionalRow<Value, Control: View>(_ title: String, _ keyPath: WritableKeyPath<OptionOverrides, Value?>,
                                                   default fallback: Value,
                                                   @ViewBuilder control: (Binding<Value>) -> Control) -> some View {
        let isOn = Binding<Bool>(
            get: { draft.overrides[keyPath: keyPath] != nil },
            set: { draft.overrides[keyPath: keyPath] = $0 ? fallback : nil })
        let value = Binding<Value>(
            get: { draft.overrides[keyPath: keyPath] ?? fallback },
            set: { draft.overrides[keyPath: keyPath] = $0 })
        return HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            if isOn.wrappedValue { control(value).labelsHidden().frame(maxWidth: 200) }
        }
    }
}

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import KumquatCore

/// Page thumbnails to drag into a new order, turn and drop. Produces a `PageArrangement` spec, which the
/// app runs through the normal "Arrange Pages" tool, so the CLI and the window save the same way.
@MainActor
final class PageArrangerWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PageArrangerWindowController] = []
    private let onDone: (String) -> Void

    static func present(url: URL, hud: HUDController, onDone: @escaping (String) -> Void) {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            hud.failure(L("Couldn't open the PDF"), detail: L("\(url.lastPathComponent) is unreadable or password-protected."))
            return
        }
        guard document.pageCount > 0 else {
            hud.failure(L("Nothing to arrange"), detail: L("The PDF has no pages."))
            return
        }
        let controller = PageArrangerWindowController(url: url, document: document, onDone: onDone)
        open.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL, document: PDFDocument, onDone: @escaping (String) -> Void) {
        self.onDone = onDone
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Arrange Pages — \(url.lastPathComponent)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        let model = PageArrangerModel(document: document)
        window.contentViewController = NSHostingController(rootView: PageArrangerView(
            model: model,
            cancel: { [weak self] in self?.window?.close() },
            save: { [weak self] spec in
                self?.window?.close()
                self?.onDone(spec)
            }))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

@MainActor
final class PageArrangerModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let page: Int
        var rotation: Int
        let thumbnail: NSImage

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id && lhs.rotation == rhs.rotation }
    }

    @Published var items: [Item]
    @Published var selection: Set<Item.ID> = []
    var dragging: Item.ID?
    let pageCount: Int

    init(document: PDFDocument) {
        pageCount = document.pageCount
        items = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return Item(page: index, rotation: 0, thumbnail: page.thumbnail(of: NSSize(width: 180, height: 180), for: .cropBox))
        }
    }

    var entries: [PageArrangement.Entry] { items.map { PageArrangement.Entry(page: $0.page, rotation: $0.rotation) } }
    var spec: String { PageArrangement.format(entries) }
    var isUnchanged: Bool { entries == (0..<pageCount).map { PageArrangement.Entry(page: $0) } }

    func select(_ id: Item.ID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    /// Selected pages, or every page when nothing is selected.
    private var targets: Set<Item.ID> { selection.isEmpty ? Set(items.map(\.id)) : selection }

    func rotate(by degrees: Int) {
        let targets = self.targets
        for index in items.indices where targets.contains(items[index].id) {
            items[index].rotation = ((items[index].rotation + degrees) % 360 + 360) % 360
        }
    }

    func deleteSelected() {
        guard !selection.isEmpty, selection.count < items.count else { NSSound.beep(); return }
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    func reverse() { items.reverse() }

    func reset() {
        items.sort { $0.page < $1.page }
        for index in items.indices { items[index].rotation = 0 }
    }

    func move(_ id: Item.ID, before target: Item.ID) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}

struct PageArrangerView: View {
    @ObservedObject var model: PageArrangerModel
    let cancel: () -> Void
    let save: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.rotate(by: 270) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    .keyboardShortcut("[", modifiers: .command)
                Button { model.rotate(by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                    .keyboardShortcut("]", modifiers: .command)
                Button { model.deleteSelected() } label: { Label("Remove", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selection.isEmpty)
                Button { model.reverse() } label: { Label("Reverse", systemImage: "arrow.left.arrow.right") }
                Button { model.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                Spacer()
                Text(model.selection.isEmpty ? L("Drag pages to reorder · ⌘-click to select several")
                     : "\(model.selection.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { position, item in
                        PageThumbnail(item: item, position: position + 1, selected: model.selection.contains(item.id))
                            .onTapGesture { model.select(item.id, extend: NSEvent.modifierFlags.contains(.command)) }
                            .onDrag {
                                model.dragging = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: PageDropDelegate(target: item.id, model: model))
                    }
                }
                .padding(16)
                .animation(.default, value: model.items)
            }
            Divider()
            HStack {
                Text("\(model.items.count) of \(model.pageCount) pages")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Copy") { save(model.spec) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isUnchanged || model.items.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct PageThumbnail: View {
    let item: PageArrangerModel.Item
    let position: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(Double(item.rotation)))
                .frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            Text(item.page + 1 == position ? "\(position)" : L("\(position) (was \(item.page + 1))"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.rotation == 0 ? L("Page \(item.page + 1), position \(position)")
                            : L("Page \(item.page + 1), position \(position), turned \(item.rotation)°"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: PageArrangerModel.Item.ID
    let model: PageArrangerModel

    func dropEntered(info: DropInfo) {
        guard let dragging = model.dragging else { return }
        model.move(dragging, before: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.dragging = nil
        return true
    }
}

import AppKit
import PDFKit
import KumquatCore

/// Marks up a PDF with standard annotations (highlight, underline, strike-out, text, notes, boxes, freehand)
/// and saves them as a copy: "report (annotated).pdf". The original is never changed.
@MainActor
final class PDFAnnotationWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [PDFAnnotationWindowController] = []
    /// Segment 0 selects text and scrolls without marking; the rest are `PDFMarkup.Kind`s.
    private static let tools: [PDFMarkup.Kind?] = [nil] + PDFMarkup.Kind.allCases

    private let sourceURL: URL
    private let outputDirectory: URL
    private let hud: HUDController
    private let onSaved: (URL) -> Void
    private let pdfView = MarkupPDFView()
    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private let undoButton = NSButton()

    static func present(url: URL, outputDirectory: URL, hud: HUDController, onSaved: @escaping (URL) -> Void) {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            hud.failure(L("Couldn't open the PDF"), detail: L("\(url.lastPathComponent) is unreadable or password-protected. Use Tools → Unlock first."))
            return
        }
        let editor = PDFAnnotationWindowController(url: url, document: document, outputDirectory: outputDirectory,
                                                   hud: hud, onSaved: onSaved)
        openEditors.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL, document: PDFDocument, outputDirectory: URL, hud: HUDController, onSaved: @escaping (URL) -> Void) {
        sourceURL = url
        self.outputDirectory = outputDirectory
        self.hud = hud
        self.onSaved = onSaved
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Annotate — \(url.lastPathComponent)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 420)
        super.init(window: window)
        window.delegate = self
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.onChange = { [weak self] in self?.refreshButtons() }
        pdfView.askForText = { title in Prompt.ask(title: title, message: "", secure: false) }
        buildInterface(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        toolPicker.segmentCount = Self.tools.count
        toolPicker.trackingMode = .selectOne
        for (index, tool) in Self.tools.enumerated() {
            let title = tool?.title ?? L("Select")
            toolPicker.setImage(NSImage(systemSymbolName: Self.symbol(for: tool), accessibilityDescription: title), forSegment: index)
            toolPicker.setToolTip(Self.hint(for: tool), forSegment: index)
            toolPicker.setWidth(34, forSegment: index)
        }
        toolPicker.selectedSegment = 1
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.toolTip = L("Colour")

        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("Undo"))
        undoButton.bezelStyle = .texturedRounded
        undoButton.toolTip = L("Undo (⌘Z)")
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        undoButton.target = self
        undoButton.action = #selector(undo)

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("Save Copy"), target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.bezelColor = .systemOrange

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [toolPicker, colorWell, undoButton, spacer, cancel, save])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.alignment = .centerY

        for view in [stack, pdfView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 48),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            pdfView.topAnchor.constraint(equalTo: stack.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        toolChanged()
    }

    private static func symbol(for tool: PDFMarkup.Kind?) -> String {
        switch tool {
        case nil: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .text: return "textformat"
        case .note: return "note.text"
        case .rectangle: return "rectangle"
        case .ink: return "scribble"
        }
    }

    private static func hint(for tool: PDFMarkup.Kind?) -> String {
        guard let tool else { return L("Select text and scroll without marking") }
        if tool.marksSelection { return L("\(tool.title): select text to mark it") }
        switch tool {
        case .text, .note: return L("\(tool.title): click where it goes")
        default: return L("\(tool.title): drag on the page")
        }
    }

    private func refreshButtons() {
        undoButton.isEnabled = !pdfView.markups.isEmpty
    }

    @objc private func toolChanged() {
        let tool = Self.tools[max(0, toolPicker.selectedSegment)]
        pdfView.tool = tool
        colorWell.color = tool == .highlight ? NSColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
            : tool == .note ? NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)
            : NSColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        colorChanged()
    }

    @objc private func colorChanged() {
        let color = colorWell.color.usingColorSpace(.sRGB) ?? colorWell.color
        pdfView.color = [color.redComponent, color.greenComponent, color.blueComponent, 1]
    }

    @objc private func undo() { pdfView.undo() }

    @objc private func cancel() {
        if !pdfView.markups.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Discard your annotations?")
            alert.addButton(withTitle: L("Discard"))
            alert.addButton(withTitle: L("Keep Editing"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        window?.close()
    }

    @objc private func save() {
        let markups = pdfView.markups.map(\.markup)
        guard !markups.isEmpty else {
            NSSound.beep()
            return
        }
        let destination = OutputNamer.uniqueURL(in: outputDirectory,
                                                baseName: "\(FormatRegistry.baseName(of: sourceURL)) (annotated)",
                                                extension: "pdf")
        do {
            // Applied to a fresh copy of the original, so only the marks made here are added.
            try PDFEngine.annotate(sourceURL, markups: markups, output: destination)
            hud.success(L("Saved"), detail: destination.lastPathComponent, reveal: [destination])
            onSaved(destination)
            window?.close()
        } catch {
            hud.failure(L("Couldn't save"), detail: error.localizedDescription)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
    }
}

/// A PDF view that turns selections, clicks and drags into `PDFMarkup`s and shows them as they're made.
@MainActor
final class MarkupPDFView: PDFView {
    var tool: PDFMarkup.Kind?
    var color: [CGFloat] = [1, 0.85, 0, 1]
    var onChange: (() -> Void)?
    var askForText: ((String) -> String?)?
    private(set) var markups: [(markup: PDFMarkup, annotation: PDFAnnotation, page: PDFPage)] = []
    private var dragStart: (page: PDFPage, point: CGPoint)?
    private var stroke: [CGPoint] = []
    private var preview: (annotation: PDFAnnotation, page: PDFPage)?

    private var drawsByDragging: Bool { tool == .rectangle || tool == .ink }

    func undo() {
        guard let last = markups.popLast() else { NSSound.beep(); return }
        last.page.removeAnnotation(last.annotation)
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            undo()
        } else {
            super.keyDown(with: event)
        }
    }

    private func location(of event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        guard let tool, !tool.marksSelection, let start = location(of: event) else {
            super.mouseDown(with: event)
            return
        }
        switch tool {
        case .text, .note:
            guard let text = askForText?(tool == .text ? L("Text to add") : L("Note")), !text.isEmpty else { return }
            let size = tool == .text ? Self.textSize(text) : CGSize(width: 20, height: 20)
            let rect = CGRect(origin: CGPoint(x: start.point.x, y: start.point.y - size.height), size: size)
            add(PDFMarkup(page: index(of: start.page), kind: tool, rects: [rect], text: text, color: color), on: start.page)
        default:
            dragStart = start
            stroke = [start.point]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawsByDragging, let start = dragStart, let current = location(of: event), current.page == start.page else {
            super.mouseDragged(with: event)
            return
        }
        stroke.append(current.point)
        showPreview(markup(from: start, to: current.point), on: start.page)
    }

    override func mouseUp(with event: NSEvent) {
        if let tool, tool.marksSelection {
            super.mouseUp(with: event)
            markSelection(as: tool)
            return
        }
        guard drawsByDragging, let start = dragStart else {
            super.mouseUp(with: event)
            return
        }
        clearPreview()
        let end = location(of: event).flatMap { $0.page == start.page ? $0.point : nil } ?? stroke.last ?? start.point
        let markup = markup(from: start, to: end)
        dragStart = nil
        stroke = []
        guard markup.bounds.width > 2 || markup.bounds.height > 2 else { return }
        add(markup, on: start.page)
    }

    private func markup(from start: (page: PDFPage, point: CGPoint), to end: CGPoint) -> PDFMarkup {
        let page = index(of: start.page)
        if tool == .ink { return PDFMarkup(page: page, kind: .ink, strokes: [stroke], color: color) }
        let rect = CGRect(x: min(start.point.x, end.x), y: min(start.point.y, end.y),
                          width: abs(end.x - start.point.x), height: abs(end.y - start.point.y))
        return PDFMarkup(page: page, kind: .rectangle, rects: [rect], color: color)
    }

    /// One markup per page the selection touches, one rectangle per selected line.
    private func markSelection(as kind: PDFMarkup.Kind) {
        guard let selection = currentSelection, !(selection.string ?? "").isEmpty else { return }
        for page in selection.pages {
            let rects = selection.selectionsByLine()
                .filter { $0.pages.contains(page) }
                .map { $0.bounds(for: page) }
                .filter { !$0.isEmpty }
            guard !rects.isEmpty else { continue }
            add(PDFMarkup(page: index(of: page), kind: kind, rects: rects, color: color), on: page)
        }
        clearSelection()
    }

    private func add(_ markup: PDFMarkup, on page: PDFPage) {
        let annotation = markup.annotation()
        page.addAnnotation(annotation)
        markups.append((markup, annotation, page))
        onChange?()
    }

    private func showPreview(_ markup: PDFMarkup, on page: PDFPage) {
        clearPreview()
        let annotation = markup.annotation()
        page.addAnnotation(annotation)
        preview = (annotation, page)
    }

    private func clearPreview() {
        if let preview { preview.page.removeAnnotation(preview.annotation) }
        preview = nil
    }

    private func index(of page: PDFPage) -> Int {
        document?.index(for: page) ?? 0
    }

    private static func textSize(_ text: String) -> CGSize {
        let font = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width) + 12, height: ceil(size.height) + 8)
    }
}

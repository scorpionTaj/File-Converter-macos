import AppKit
import KumquatCore

enum AnnotationTool: Int, CaseIterable {
    case pen, arrow, rectangle, ellipse, highlight, text, pixelate, crop

    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "square.grid.3x3.fill"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .pixelate: return "Pixelate (hides content permanently)"
        case .crop: return "Crop"
        }
    }
}

/// Window for marking up one image. The result is saved as a copy: "photo (annotated).jpg".
@MainActor
final class AnnotationWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [AnnotationWindowController] = []

    private let sourceURL: URL
    private let outputDirectory: URL
    private let image: CGImage
    private let hud: HUDController
    private let onSaved: (URL) -> Void
    private let canvas: AnnotationCanvas
    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    static func present(url: URL, outputDirectory: URL, hud: HUDController, onSaved: @escaping (URL) -> Void) {
        Task { @MainActor in
            do {
                let image = try await ImageEngine.loadImage(at: url)
                let editor = AnnotationWindowController(url: url, image: image, outputDirectory: outputDirectory,
                                                        hud: hud, onSaved: onSaved)
                openEditors.append(editor)
                NSApp.activate(ignoringOtherApps: true)
                editor.showWindow(nil)
                editor.window?.makeKeyAndOrderFront(nil)
                editor.window?.makeFirstResponder(editor.canvas)
            } catch {
                hud.failure("Couldn't open the image", detail: error.localizedDescription)
            }
        }
    }

    private init(url: URL, image: CGImage, outputDirectory: URL, hud: HUDController, onSaved: @escaping (URL) -> Void) {
        self.sourceURL = url
        self.image = image
        self.outputDirectory = outputDirectory
        self.hud = hud
        self.onSaved = onSaved
        self.canvas = AnnotationCanvas(image: image)

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let toolbarHeight: CGFloat = 48
        let fit = min(visible.width * 0.8 / CGFloat(image.width), (visible.height * 0.8 - toolbarHeight) / CGFloat(image.height), 1)
        let size = NSSize(width: max(CGFloat(image.width) * fit + 32, 720),
                          height: max(CGFloat(image.height) * fit + 32 + toolbarHeight, 480))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Annotate — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window, toolbarHeight: toolbarHeight)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface(in window: NSWindow, toolbarHeight: CGFloat) {
        let content = NSView()
        window.contentView = content

        toolPicker.segmentCount = AnnotationTool.allCases.count
        toolPicker.trackingMode = .selectOne
        for tool in AnnotationTool.allCases {
            toolPicker.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue)
            toolPicker.setToolTip(tool.title, forSegment: tool.rawValue)
            toolPicker.setWidth(34, forSegment: tool.rawValue)
        }
        toolPicker.selectedSegment = AnnotationTool.arrow.rawValue
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)

        colorWell.color = NSColor(red: 0.96, green: 0.22, blue: 0.20, alpha: 1)
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.toolTip = "Colour"

        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.toolTip = "Line width / text size"

        configure(undoButton, symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)", action: #selector(undo))
        configure(redoButton, symbol: "arrow.uturn.forward", tip: "Redo (⇧⌘Z)", action: #selector(redo))

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save Copy", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.bezelColor = .systemOrange

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [toolPicker, colorWell, widthSlider, undoButton, redoButton, spacer, cancel, save])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.alignment = .centerY

        canvas.onChange = { [weak self] in self?.refreshButtons() }
        for view in [stack, canvas] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: toolbarHeight),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            widthSlider.widthAnchor.constraint(equalToConstant: 110),
            canvas.topAnchor.constraint(equalTo: stack.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        refreshButtons()
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    private func refreshButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool(rawValue: toolPicker.selectedSegment) ?? .arrow
        if canvas.tool == .highlight {
            colorWell.color = NSColor(red: 1, green: 0.84, blue: 0, alpha: 1)
            colorChanged()
        }
    }

    @objc private func colorChanged() {
        let color = colorWell.color.usingColorSpace(.sRGB) ?? colorWell.color
        canvas.color = AnnotationColor(red: Double(color.redComponent), green: Double(color.greenComponent),
                                       blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
    }

    @objc private func widthChanged() {
        canvas.lineWidth = CGFloat(widthSlider.doubleValue)
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }

    @objc private func cancel() {
        if canvas.hasChanges {
            let alert = NSAlert()
            alert.messageText = "Discard your annotations?"
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        window?.close()
    }

    @objc private func save() {
        canvas.commitText()
        guard canvas.hasChanges else {
            NSSound.beep()
            return
        }
        let annotations = canvas.annotations
        let crop = canvas.crop
        let format = ImageEngine.editableFormat(for: sourceURL)
        let destination = OutputNamer.uniqueURL(in: outputDirectory,
                                                baseName: "\(FormatRegistry.baseName(of: sourceURL)) (annotated)",
                                                extension: format.fileExtension)
        let image = self.image
        Task { @MainActor in
            do {
                let rendered = try AnnotationRenderer.render(image, annotations: annotations, crop: crop)
                try await ImageEngine.save(rendered, to: destination, format: format)
                hud.success("Saved", detail: destination.lastPathComponent, reveal: [destination])
                onSaved(destination)
                window?.close()
            } catch {
                hud.failure("Couldn't save", detail: error.localizedDescription)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeAll { $0 === self }
    }
}

/// Shows the image and turns mouse gestures into annotations (stored in image pixel coordinates).
@MainActor
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let image: CGImage
    var tool: AnnotationTool = .arrow { didSet { commitText() } }
    var color = AnnotationColor.red
    /// On-screen points; converted to image pixels when a mark is made.
    var lineWidth: CGFloat = 4
    var onChange: (() -> Void)?

    private(set) var annotations: [Annotation] = []
    private(set) var crop: CGRect?
    /// Undo history entries: either an annotation or a crop change.
    private enum Edit { case annotation(Annotation), crop(old: CGRect?, new: CGRect?) }
    private var history: [Edit] = []
    private var redoStack: [Edit] = []
    private var draft: Annotation?
    private var draftCrop: CGRect?
    private var dragStart: CGPoint?
    private var penPoints: [CGPoint] = []
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasChanges: Bool { !annotations.isEmpty || crop != nil }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Geometry

    private var imageRect: CGRect {
        let area = bounds.insetBy(dx: 16, dy: 16)
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var scale: CGFloat { max(imageRect.width / CGFloat(image.width), 0.0001) }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let x = (min(max(point.x, rect.minX), rect.maxX) - rect.minX) / scale
        let y = (min(max(point.y, rect.minY), rect.maxY) - rect.minY) / scale
        return CGPoint(x: x, y: y)
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
    }

    private var imageLineWidth: CGFloat { lineWidth / scale }
    private var textSize: CGFloat { (lineWidth * 3 + 12) / scale }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = SettingsStore.shared.resolvedTheme
        (theme.isDark ?? true ? theme.canvas : theme.canvas.blended(withFraction: 0.15, of: .black) ?? theme.canvas).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: imageBounds)
        AnnotationRenderer.draw(annotations + (draft.map { [$0] } ?? []), base: image, in: context)

        if let cropRect = draftCrop ?? crop {
            context.setFillColor(CGColor(gray: 0, alpha: 0.55))
            context.addRect(imageBounds)
            context.addRect(cropRect)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(1.5 / scale)
            context.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
            context.stroke(cropRect)
        }
        context.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let point = imagePoint(event)
        switch tool {
        case .text:
            beginText(at: point)
        case .pen:
            penPoints = [point]
            draft = Annotation(.pen(penPoints), color: color, lineWidth: imageLineWidth)
        default:
            dragStart = point
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        if tool == .pen {
            penPoints.append(point)
            draft = Annotation(.pen(penPoints), color: color, lineWidth: imageLineWidth)
        } else if let start = dragStart {
            let rect = Self.rect(start, point)
            switch tool {
            case .arrow: draft = Annotation(.arrow(from: start, to: point), color: color, lineWidth: imageLineWidth)
            case .rectangle: draft = Annotation(.rectangle(rect), color: color, lineWidth: imageLineWidth)
            case .ellipse: draft = Annotation(.ellipse(rect), color: color, lineWidth: imageLineWidth)
            case .highlight: draft = Annotation(.highlight(rect), color: color, lineWidth: imageLineWidth)
            case .pixelate: draft = Annotation(.pixelate(rect), color: color, lineWidth: imageLineWidth)
            case .crop: draftCrop = rect
            case .pen, .text: break
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draft = nil
            draftCrop = nil
            dragStart = nil
            penPoints = []
            needsDisplay = true
        }
        if tool == .crop {
            if let rect = draftCrop, rect.width * scale > 8, rect.height * scale > 8 {
                apply(.crop(old: crop, new: rect))
            }
            return
        }
        guard let mark = draft, isMeaningful(mark) else { return }
        apply(.annotation(mark))
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        let minimum = 4 / scale
        switch annotation.shape {
        case .pen(let points): return !points.isEmpty
        case .arrow(let from, let to): return hypot(to.x - from.x, to.y - from.y) > minimum
        case .rectangle(let r), .ellipse(let r), .highlight(let r), .pixelate(let r): return r.width > minimum && r.height > minimum
        case .text(let string, _, _): return !string.isEmpty
        }
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let fontSize = textSize * scale
        let origin = viewPoint(point)
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y - fontSize * 0.35, width: 280, height: fontSize * 1.5))
        field.font = NSFont(name: "Helvetica-Bold", size: fontSize) ?? .boldSystemFont(ofSize: fontSize)
        field.textColor = NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        field.backgroundColor = NSColor(white: 1, alpha: 0.85)
        field.isBordered = true
        field.focusRingType = .none
        field.placeholderString = "Type, then press Return"
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldDone)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = point
    }

    @objc private func textFieldDone() {
        commitText()
        window?.makeFirstResponder(self)
    }

    func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        textField = nil
        textOrigin = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        guard !text.isEmpty else { return }
        apply(.annotation(Annotation(.text(text, origin: origin, fontSize: textSize), color: color, lineWidth: imageLineWidth)))
    }

    // MARK: History

    private func apply(_ edit: Edit) {
        perform(edit)
        history.append(edit)
        redoStack.removeAll()
        onChange?()
    }

    private func perform(_ edit: Edit) {
        switch edit {
        case .annotation(let annotation): annotations.append(annotation)
        case .crop(_, let new): crop = new
        }
        needsDisplay = true
    }

    func undo() {
        commitText()
        guard let edit = history.popLast() else { return }
        switch edit {
        case .annotation: annotations.removeLast()
        case .crop(let old, _): crop = old
        }
        redoStack.append(edit)
        needsDisplay = true
        onChange?()
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        perform(edit)
        history.append(edit)
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            flags.contains(.shift) ? redo() : undo()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            undo()
        } else if let tool = AnnotationTool.allCases.first(where: { String($0.rawValue + 1) == event.charactersIgnoringModifiers }) {
            // 1–8 pick tools.
            self.tool = tool
            (window?.windowController as? AnnotationWindowController)?.selectTool(tool)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension AnnotationWindowController {
    func selectTool(_ tool: AnnotationTool) {
        // Reflect keyboard tool changes in the toolbar.
        if let picker = window?.contentView?.subviews
            .compactMap({ $0 as? NSStackView }).first?.arrangedSubviews
            .compactMap({ $0 as? NSSegmentedControl }).first {
            picker.selectedSegment = tool.rawValue
        }
    }
}

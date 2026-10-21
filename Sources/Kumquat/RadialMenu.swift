#if os(macOS)
import AppKit
import KumquatCore

/// Transparent, non-activating panel that hosts the wheel around the cursor.
final class RadialMenuPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the wheel and acts as the drop target for the drag that summoned it.
@MainActor
final class RadialMenuView: NSView {
    enum Interaction { case drag, click }

    struct Ring {
        let range: Range<Int>
        let inner: CGFloat
        let outer: CGFloat
    }

    var items: [WheelItem] = [] { didSet { rings = Self.layout(count: items.count); hovered = nil; needsDisplay = true } }
    var mode: WheelMode = .convert { didSet { needsDisplay = true } }
    var urls: [URL] = []
    var interaction: Interaction = .drag
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    var onSelect: ((WheelItem, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    /// Click on the hub in click mode: switch to the next wheel.
    var onCycleMode: (() -> Void)?
    private(set) var isPerformingDrop = false

    private var rings: [Ring] = []
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    static let hubRadius: CGFloat = 56
    static let outerRadius: CGFloat = 214

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func layout(count: Int) -> [Ring] {
        guard count > 0 else { return [] }
        if count <= 10 { return [Ring(range: 0..<count, inner: 62, outer: 168)] }
        let innerCount = min(8, (count + 1) / 2)
        return [Ring(range: 0..<innerCount, inner: 62, outer: 138),
                Ring(range: innerCount..<count, inner: 142, outer: outerRadius)]
    }

    private var hub: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Item index under a point, measuring angles clockwise from 12 o'clock.
    func index(at point: CGPoint) -> Int? {
        let dx = point.x - hub.x, dy = point.y - hub.y
        let distance = hypot(dx, dy) / scale
        for ring in rings where distance >= ring.inner - 2 && distance <= ring.outer + 6 {
            let count = ring.range.count
            let step = 360.0 / Double(count)
            var angle = 90 - atan2(Double(dy), Double(dx)) * 180 / .pi
            angle = angle.truncatingRemainder(dividingBy: 360)
            if angle < 0 { angle += 360 }
            let slot = Int(((angle + step / 2) / step).rounded(.down)) % count
            return ring.range.lowerBound + slot
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return }
        let accent = NSColor.systemOrange
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = isDark ? NSColor(white: 0.13, alpha: 0.94) : NSColor(white: 0.98, alpha: 0.95)
        let stroke = isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10)
        let textColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)

        for ring in rings {
            let count = ring.range.count
            let step = 360.0 / Double(count)
            let gap = count > 1 ? min(1.2, step * 0.04) : 0
            for slot in 0..<count {
                let index = ring.range.lowerBound + slot
                let item = items[index]
                let center = 90 - Double(slot) * step
                let start = CGFloat(center + step / 2 - gap), end = CGFloat(center - step / 2 + gap)
                let path = NSBezierPath()
                path.appendArc(withCenter: hub, radius: ring.outer * scale, startAngle: start, endAngle: end, clockwise: true)
                path.appendArc(withCenter: hub, radius: ring.inner * scale, startAngle: end, endAngle: start, clockwise: false)
                path.close()

                let isHovered = hovered == index
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                (isHovered && item.isAvailable ? accent : base).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()

                let radians = center * .pi / 180
                let radius = (ring.inner + ring.outer) / 2 * scale
                let labelCenter = CGPoint(x: hub.x + CGFloat(cos(radians)) * radius, y: hub.y + CGFloat(sin(radians)) * radius)
                var color = isHovered && item.isAvailable ? NSColor.white : textColor
                if !item.isAvailable { color = color.withAlphaComponent(0.35) }
                drawLabel(for: item, at: labelCenter, color: color, compact: ring.outer - ring.inner < 90)
            }
        }
        drawHub(base: base, stroke: stroke, textColor: textColor, accent: accent, shadow: shadow)
    }

    private func drawLabel(for item: WheelItem, at point: CGPoint, color: NSColor, compact: Bool) {
        let fontSize: CGFloat = (compact ? 10 : 11) * scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
        let title = NSAttributedString(string: item.title, attributes: attributes)
        let titleSize = title.size()
        let symbolSize: CGFloat = (compact ? 14 : 17) * scale
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
        if let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
            .withSymbolConfiguration(configuration) {
            let tinted = symbol.tinted(color)
            let size = tinted.size
            tinted.draw(in: NSRect(x: point.x - size.width / 2, y: point.y + 1, width: size.width, height: size.height))
            title.draw(at: NSPoint(x: point.x - titleSize.width / 2, y: point.y - titleSize.height - 1))
        } else {
            title.draw(at: NSPoint(x: point.x - titleSize.width / 2, y: point.y - titleSize.height / 2))
        }
    }

    private func drawHub(base: NSColor, stroke: NSColor, textColor: NSColor, accent: NSColor, shadow: NSShadow) {
        let radius = Self.hubRadius * scale
        let circle = NSBezierPath(ovalIn: NSRect(x: hub.x - radius, y: hub.y - radius, width: radius * 2, height: radius * 2))
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        base.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        accent.withAlphaComponent(0.8).setStroke()
        circle.lineWidth = 2
        circle.stroke()

        let headline: String
        let detail: String
        if let hovered, hovered < items.count {
            let item = items[hovered]
            headline = item.title
            detail = item.unavailableReason ?? item.detail
        } else {
            headline = mode.title
            detail = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        }
        let width = radius * 1.7
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let headlineText = NSAttributedString(string: headline, attributes: [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: .bold),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])
        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.alignment = .center
        detailParagraph.lineBreakMode = .byWordWrapping
        let detailText = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 9 * scale),
            .foregroundColor: textColor.withAlphaComponent(0.7),
            .paragraphStyle: detailParagraph,
        ])
        headlineText.draw(in: NSRect(x: hub.x - width / 2, y: hub.y + 2 * scale, width: width, height: 18 * scale))
        detailText.draw(with: NSRect(x: hub.x - width / 2, y: hub.y - 34 * scale, width: width, height: 34 * scale),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if interaction == .click {
            let hint = NSAttributedString(string: "click to switch", attributes: [
                .font: NSFont.systemFont(ofSize: 8 * scale),
                .foregroundColor: textColor.withAlphaComponent(0.45),
                .paragraphStyle: paragraph,
            ])
            hint.draw(in: NSRect(x: hub.x - width / 2, y: hub.y + 20 * scale, width: width, height: 12 * scale))
        }
    }

    // MARK: Drag destination

    private func readURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls?.isEmpty ?? true) ? self.urls : urls!
    }

    private func dragOperation(at location: NSPoint) -> NSDragOperation {
        hovered = index(at: convert(location, from: nil))
        guard let hovered, items[hovered].isAvailable else { return [] }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(at: sender.draggingLocation)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(at: sender.draggingLocation)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovered = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let hovered else { return false }
        return items[hovered].isAvailable
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let hovered, items[hovered].isAvailable else { return false }
        let item = items[hovered]
        let dropped = readURLs(sender)
        isPerformingDrop = true
        // Run after the drag session finishes so prompts and panels don't block the source app.
        Task { @MainActor [weak self] in
            self?.isPerformingDrop = false
            self?.onSelect?(item, dropped)
        }
        return true
    }

    // MARK: Click mode

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard interaction == .click else { return }
        hovered = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if interaction == .click { hovered = nil }
    }

    override func mouseUp(with event: NSEvent) {
        guard interaction == .click else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - hub.x, point.y - hub.y) <= Self.hubRadius * scale {
            onCycleMode?()
            return
        }
        guard let slot = self.index(at: point) else {
            onCancel?()
            return
        }
        let item = items[slot]
        guard item.isAvailable else { NSSound.beep(); return }
        onSelect?(item, urls)
    }
}

/// Owns the wheel panel's lifecycle.
@MainActor
final class RadialMenuController {
    private let panel = RadialMenuPanel()
    private let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 460, height: 460))
    private var outsideClickMonitor: Any?
    private var hideTask: Task<Void, Never>?

    var onSelect: ((WheelItem, [URL]) -> Void)?
    /// Supplies items when the user cycles wheels in click mode.
    var itemsProvider: ((WheelMode, [URL]) -> [WheelItem])?

    private(set) var currentMode: WheelMode?
    var isVisible: Bool { panel.isVisible }

    init() {
        panel.contentView = view
        view.onSelect = { [weak self] item, urls in
            self?.hide()
            self?.onSelect?(item, urls)
        }
        view.onCancel = { [weak self] in self?.hide() }
        view.onCycleMode = { [weak self] in self?.cycleMode() }
    }

    func show(mode: WheelMode, items: [WheelItem], urls: [URL], at point: NSPoint,
              interaction: RadialMenuView.Interaction, scale: CGFloat) {
        hideTask?.cancel()
        currentMode = mode
        view.scale = scale
        view.mode = mode
        view.urls = urls
        view.interaction = interaction
        view.items = items

        let side = (RadialMenuView.outerRadius + 24) * 2 * scale
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - side / 2, y: point.y - side / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - side)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - side)
        }
        let frame = NSRect(origin: origin, size: NSSize(width: side, height: side))
        if !panel.isVisible {
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.panel.animator().alphaValue = 1
            }
        } else if interaction == .click {
            panel.setFrame(frame, display: true)
        }
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.needsDisplay = true

        if interaction == .click, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }

    func cycleMode() {
        guard let current = currentMode, let provider = itemsProvider else { return }
        let all = WheelMode.allCases
        var next = current
        for _ in all {
            next = all[(all.firstIndex(of: next)! + 1) % all.count]
            let items = provider(next, view.urls)
            if !items.isEmpty {
                currentMode = next
                view.mode = next
                view.items = items
                return
            }
        }
    }

    /// The drag ended. Give a drop on the wheel a moment to be delivered before hiding.
    func dragEnded() {
        guard view.interaction == .drag else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, !self.view.isPerformingDrop else { return }
            self.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        currentMode = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

extension NSImage {
    /// Copy of a template image filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
#endif

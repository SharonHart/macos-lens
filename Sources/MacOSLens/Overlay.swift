import AppKit
import LensCore

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen, image: CGImage, mode: CaptureMode,
         submit: @escaping (CGImage, CaptureMode) -> Void, cancel: @escaping () -> Void,
         failure: @escaping (Error) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .black
        let overlay = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image,
                                  mode: mode, submit: submit, cancel: cancel, failure: failure)
        contentView = overlay
        makeFirstResponder(overlay)
    }
}

final class OverlayView: NSView {
    override var acceptsFirstResponder: Bool { true }
    private let image: CGImage
    private var mode: CaptureMode
    private let submit: (CGImage, CaptureMode) -> Void
    private let cancel: () -> Void
    private let failure: (Error) -> Void
    private var selection: CGRect?
    private var start: CGPoint?
    private var points: [CGPoint] = []
    private var freehand = false
    private var resizingCorner: Int?
    private var fixedCorner: CGPoint?
    private var tracking: NSTrackingArea?
    private var hint: String?

    init(frame: NSRect, image: CGImage, mode: CaptureMode,
         submit: @escaping (CGImage, CaptureMode) -> Void, cancel: @escaping () -> Void,
         failure: @escaping (Error) -> Void) {
        self.image = image
        self.mode = mode
        self.submit = submit
        self.cancel = cancel
        self.failure = failure
        super.init(frame: frame)
        let strip = NSVisualEffectView(frame: NSRect(x: 20, y: frame.height - 76, width: 610, height: 52))
        strip.material = .hudWindow
        strip.blendingMode = .withinWindow
        strip.state = .active
        strip.wantsLayer = true
        strip.layer?.cornerRadius = 14
        strip.autoresizingMask = [.minYMargin]
        addSubview(strip)
        let modes = NSSegmentedControl(labels: ["Visual search", "Text OCR"], trackingMode: .selectOne,
                                      target: self, action: #selector(changeMode(_:)))
        modes.frame = NSRect(x: 12, y: 12, width: 220, height: 28)
        modes.selectedSegment = mode == .search ? 0 : 1
        strip.addSubview(modes)
        let shape = NSButton(checkboxWithTitle: "Draw / circle", target: self, action: #selector(changeShape(_:)))
        shape.frame = NSRect(x: 244, y: 12, width: 140, height: 28)
        strip.addSubview(shape)
        let whole = NSButton(title: "Whole display", target: self, action: #selector(wholeDisplay))
        whole.frame = NSRect(x: 386, y: 12, width: 128, height: 28)
        strip.addSubview(whole)
        let close = NSButton(title: "Cancel", target: self, action: #selector(closeOverlay))
        close.frame = NSRect(x: 516, y: 12, width: 82, height: 28)
        strip.addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func closeOverlay() { cancel() }
    @objc private func changeMode(_ sender: NSSegmentedControl) { mode = sender.selectedSegment == 0 ? .search : .text }
    @objc private func changeShape(_ sender: NSButton) { freehand = sender.state == .on }
    @objc private func wholeDisplay() { selection = bounds; complete() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { window?.makeKey(); NSCursor.crosshair.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.43).cgColor)
        context.addRect(bounds)
        if let selection { context.addRect(selection) }
        context.drawPath(using: .eoFill)
        context.restoreGState()
        if let selection {
            NSColor.white.setStroke()
            let path = NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8)
            path.lineWidth = 2
            path.stroke()
            NSColor.white.setFill()
            for corner in corners(selection) {
                NSBezierPath(ovalIn: NSRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)).fill()
            }
        }
        if points.count > 1 {
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = 4
            path.lineCapStyle = .round
            NSColor.systemCyan.setStroke()
            path.stroke()
        }
        let gradient = NSGradient(colors: [.systemBlue, .systemPurple, .systemPink, .systemOrange])!
        gradient.draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 5)), angle: 0)
        gradient.draw(in: NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 5, width: bounds.width, height: 5)), angle: 0)
        gradient.draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 5, height: bounds.height)), angle: 90)
        gradient.draw(in: NSBezierPath(rect: NSRect(x: bounds.width - 5, y: 0, width: 5, height: bounds.height)), angle: 90)
        let instruction = hint ?? "Drag or draw to select · Release to \(mode == .search ? "search" : "read text") · " +
                                  "Hold Option to adjust · Return confirms · Esc cancels"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: hint == nil ? NSColor.white : NSColor.systemYellow,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let size = (instruction as NSString).size(withAttributes: attributes)
        (instruction as NSString).draw(at: NSPoint(x: max(16, (bounds.width - size.width) / 2), y: 24),
                                      withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        start = point
        points = [point]
        hint = nil
        resizingCorner = nil
        fixedCorner = nil
        if let selection, let index = corners(selection).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 14 }) {
            resizingCorner = index
            fixedCorner = corners(selection)[(index + 2) % 4]
        } else {
            selection = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: min(max(raw.x, bounds.minX), bounds.maxX),
                            y: min(max(raw.y, bounds.minY), bounds.maxY))
        if let fixedCorner {
            selection = Selection.rectangle(from: fixedCorner, to: point, in: bounds)
        } else if freehand {
            points.append(point)
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            selection = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .intersection(bounds)
        } else {
            selection = Selection.rectangle(from: start, to: point, in: bounds)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event)
        start = nil
        points.removeAll()
        needsDisplay = true
        guard resizingCorner == nil else { return }
        guard Selection.isUsable(selection) else {
            selection = nil
            showSelectionHint()
            return
        }
        if !event.modifierFlags.contains(.option) { complete() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel() }
        else if event.keyCode == 36 || event.keyCode == 76 { complete() }
        else { super.keyDown(with: event) }
    }

    private func complete() {
        guard let selection, Selection.isUsable(selection) else { showSelectionHint(); return }
        do { submit(try Selection.crop(image, region: selection, bounds: bounds), mode) }
        catch { failure(error) }
    }

    private func showSelectionHint() {
        hint = "Drag or draw around an area to select it · Esc cancels"
        needsDisplay = true
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}

import AppKit
import LensCore

struct OverlayActions {
    var began: (OverlayView) -> Void = { _ in }
    var changed: (OverlayView, Bool) -> Void = { _, _ in }
    var text: (OverlayView) -> Void = { _ in }
    var panelVisibility: (OverlayView, Bool) -> Void = { _, _ in }
    var cancel: () -> Void = {}
}

final class OverlayWindow: NSWindow {
    let overlay: OverlayView
    private let escape: () -> Void
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen, overlay: OverlayView, escape: @escaping () -> Void) {
        self.overlay = overlay
        self.escape = escape
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        contentView = overlay
        makeFirstResponder(overlay)
    }

    // Escape cancels even while the results page has keyboard focus.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 { escape(); return }
        super.sendEvent(event)
    }
}

final class OverlayView: NSView {
    override var acceptsFirstResponder: Bool { true }
    let image: CGImage
    let displayIndex: Int
    let mode: CaptureMode
    let panel: ResultsPanel?
    private(set) var panelCollapsed: Bool
    private(set) var freehand = false
    private let topInset: CGFloat
    private let actions: OverlayActions
    private var panelWidth: CGFloat = 440
    private var unit: CGRect?
    private var drag: SelectionDrag?
    private var dragStart = CGPoint.zero
    private var dragStartRect = CGRect.null
    private var startUnit: CGRect?
    private var points: [CGPoint] = []
    private var warning: String?
    private var activity: String?
    private let toolbar = NSVisualEffectView()
    let hintLabel = NSTextField(labelWithString: "")
    private var resultsButton: NSButton?
    private var toolbarWidth: CGFloat = 0
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: CGImage, displayIndex: Int, mode: CaptureMode, topInset: CGFloat = 0,
         selected: Bool, showsPanel: Bool, panelCollapsed: Bool = false, actions: OverlayActions) {
        self.image = image
        self.displayIndex = displayIndex
        self.mode = mode
        self.topInset = max(0, topInset)
        self.actions = actions
        self.panelCollapsed = panelCollapsed
        panel = showsPanel ? ResultsPanel(frame: .zero) : nil
        unit = selected ? SelectionEditor.whole : nil
        super.init(frame: frame)
        buildToolbar()
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.lineBreakMode = .byTruncatingTail
        addSubview(hintLabel)
        if let panel {
            addSubview(panel)
            panel.onHide = { [weak self] in self?.setPanelCollapsed(true) }
            panel.onResize = { [weak self] width, _ in self?.resizePanel(to: width) }
        }
        updateHint()
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        addSubview(toolbar)
        var x: CGFloat = 10
        @discardableResult
        func add(_ title: String, _ action: Selector, _ width: CGFloat, _ tip: String) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = NSRect(x: x, y: 8, width: width, height: 28)
            button.toolTip = tip
            toolbar.addSubview(button)
            x += width + 6
            return button
        }
        add("Full screen", #selector(selectWholeDisplay), 104, "Select this whole display")
        add("Draw", #selector(toggleDraw(_:)), 72, "Circle or scribble around an area instead of dragging a rectangle")
            .setButtonType(.pushOnPushOff)
        add("Text (OCR)", #selector(readText), 104, "Recognize text in the selected area on this Mac")
        add("Search now", #selector(searchNow), 104, "Search the selected area now (Return)")
        if panel != nil {
            resultsButton = add(panelCollapsed ? "Show results" : "Hide results", #selector(togglePanel), 116,
                                "Show or hide the Google Lens results panel")
        }
        add("Cancel", #selector(cancelOverlay), 76, "Close and return to the previous app (Esc)")
        toolbarWidth = x + 4
    }

    // MARK: Geometry

    private var bandTop: CGFloat { bounds.height - topInset }

    var toolbarFrame: CGRect { CGRect(x: 16, y: bandTop - 54, width: toolbarWidth, height: 44) }

    var panelFrame: CGRect? {
        guard panel != nil, !panelCollapsed else { return nil }
        let width = min(max(panelWidth, 320), max(320, bounds.width * 0.6))
        return CGRect(x: bounds.maxX - width - 12, y: 12, width: width, height: max(0, bandTop - 24))
    }

    private var canvasArea: CGRect {
        let right = (panelFrame?.minX ?? bounds.maxX) - 16
        return CGRect(x: 16, y: 16, width: max(1, right - 16), height: max(1, toolbarFrame.minY - 16 - 16))
    }

    /// Where the screenshot is drawn: the whole display, squeezed to the left of the results panel.
    var canvas: CGRect { SelectionEditor.fit(CGSize(width: image.width, height: image.height), in: canvasArea) }

    var hasSelection: Bool { unit != nil }
    var selection: CGRect? { unit.map { SelectionEditor.view($0, in: canvas) } }

    /// The selected image pixels; independent of the panel width, so resizing the panel never re-uploads.
    var pixelRect: CGRect? {
        guard let unit, Selection.isUsable(selection) else { return nil }
        return SelectionEditor.pixels(forUnit: unit, width: image.width, height: image.height)
    }

    var searchKey: String? {
        pixelRect.map { "\(displayIndex):\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
    }

    func crop() throws -> CGImage {
        guard let pixels = pixelRect, let crop = image.cropping(to: pixels) else {
            throw LensError.message("Select an area at least \(Int(Selection.minimumSide)) points wide and high.")
        }
        return crop
    }

    func clearSelection() {
        guard unit != nil else { return }
        unit = nil
        updateHint()
        needsDisplay = true
    }

    func showWarning(_ text: String?) {
        warning = text
        updateHint()
    }

    func setActivity(_ text: String?) {
        activity = text
        updateHint()
    }

    func setPanelCollapsed(_ collapsed: Bool) {
        guard panel != nil, collapsed != panelCollapsed else { return }
        panelCollapsed = collapsed
        resultsButton?.title = collapsed ? "Show results" : "Hide results"
        needsLayout = true
        needsDisplay = true
        actions.panelVisibility(self, !collapsed)
    }

    private func resizePanel(to width: CGFloat) {
        panelWidth = min(max(width, 320), max(320, bounds.width * 0.6))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        toolbar.frame = toolbarFrame
        let hintX = toolbarFrame.maxX + 14
        let hintWidth = canvasArea.maxX - hintX
        hintLabel.frame = NSRect(x: hintX, y: toolbarFrame.minY + 13, width: max(0, hintWidth), height: 18)
        hintLabel.isHidden = hintWidth < 120
        if let panel {
            panel.isHidden = panelCollapsed
            if let frame = panelFrame { panel.frame = frame }
        }
    }

    // MARK: Toolbar

    @objc func selectWholeDisplay() {
        actions.began(self)
        unit = SelectionEditor.whole
        warning = nil
        updateHint()
        needsDisplay = true
        actions.changed(self, false)
    }

    @objc private func toggleDraw(_ sender: NSButton) {
        freehand = sender.state == .on
        updateHint()
    }

    @objc func readText() { actions.text(self) }
    @objc func searchNow() { actions.changed(self, true) }
    @objc private func togglePanel() { setPanelCollapsed(!panelCollapsed) }
    @objc private func cancelOverlay() { actions.cancel() }

    private var isWhole: Bool { (unit?.width ?? 0) > 0.999 && (unit?.height ?? 0) > 0.999 }

    private func updateHint() {
        let returnAction = mode == .text ? "Return reads text" : "Return searches now"
        let instructions: String
        if !hasSelection {
            instructions = "Drag on this display to select an area · Esc cancels"
        } else if freehand {
            instructions = "Circle or scribble around what you want · drag the white handles to adjust · Esc cancels"
        } else if isWhole {
            instructions = "Drag the white edges or corners to resize, or drag across the screen for a new area · " +
                           "\(returnAction) · Esc cancels"
        } else {
            instructions = "Drag handles to resize · drag inside to move · drag outside for a new area · " +
                           "\(returnAction) · Esc cancels"
        }
        hintLabel.stringValue = [activity, warning, instructions].compactMap { $0 }.joined(separator: " · ")
        hintLabel.toolTip = hintLabel.stringValue
        hintLabel.textColor = warning != nil ? .systemYellow : activity != nil ? .systemTeal : .white
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        bounds.fill()
        let canvas = self.canvas
        let gradient = NSGradient(colors: [.systemBlue, .systemPurple, .systemPink, .systemOrange])!
        gradient.draw(in: NSBezierPath(roundedRect: canvas.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6), angle: 30)
        context.interpolationQuality = .high
        context.draw(image, in: canvas)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.addRect(canvas)
        if let selection { context.addRect(selection) }
        context.drawPath(using: .eoFill)
        context.restoreGState()
        if let selection {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            border.stroke()
            drawHandles(selection)
        }
        if points.count > 1 {
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.systemCyan.setStroke()
            path.stroke()
        }
    }

    private func drawHandles(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 4
        shadow.set()
        let arm = min(26, rect.width / 3, rect.height / 3)
        let bar = min(30, rect.width / 4, rect.height / 4)
        let path = NSBezierPath()
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.maxX, rect.maxY, -1.0, -1.0), (rect.minX, rect.maxY, 1.0, -1.0)] {
            path.move(to: NSPoint(x: x + dx * arm, y: y))
            path.line(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x, y: y + dy * arm))
        }
        path.move(to: NSPoint(x: rect.midX - bar / 2, y: rect.minY))
        path.line(to: NSPoint(x: rect.midX + bar / 2, y: rect.minY))
        path.move(to: NSPoint(x: rect.midX - bar / 2, y: rect.maxY))
        path.line(to: NSPoint(x: rect.midX + bar / 2, y: rect.maxY))
        path.move(to: NSPoint(x: rect.minX, y: rect.midY - bar / 2))
        path.line(to: NSPoint(x: rect.minX, y: rect.midY + bar / 2))
        path.move(to: NSPoint(x: rect.maxX, y: rect.midY - bar / 2))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY + bar / 2))
        NSColor.white.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse and keyboard

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                          .inVisibleRect], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at point: CGPoint) {
        guard drag == nil else { return }
        if let hit = hitTest(convert(point, to: superview)), hit !== self { return }
        guard canvas.insetBy(dx: -SelectionEditor.tolerance, dy: -SelectionEditor.tolerance).contains(point) else {
            NSCursor.arrow.set()
            return
        }
        cursor(for: SelectionEditor.target(at: point, selection: selection, bounds: canvas, freehand: freehand)).set()
    }

    private func cursor(for target: SelectionDrag) -> NSCursor {
        switch target {
        case .move: return .openHand
        case .draw: return .crosshair
        case .resize(let handle):
            if #available(macOS 15, *) {
                let positions: [SelectionHandle: NSCursor.FrameResizePosition] = [
                    .top: .top, .left: .left, .bottom: .bottom, .right: .right, .topLeft: .topLeft,
                    .topRight: .topRight, .bottomLeft: .bottomLeft, .bottomRight: .bottomRight
                ]
                return .frameResize(position: positions[handle]!, directions: .all)
            }
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let canvas = self.canvas
        let target = SelectionEditor.target(at: point, selection: selection, bounds: canvas, freehand: freehand)
        drag = target
        dragStart = target == .draw ? clamp(point, to: canvas) : point
        dragStartRect = selection ?? .null
        startUnit = unit
        points = [dragStart]
        warning = nil
        if target == .move { NSCursor.closedHand.set() }
        actions.began(self)
        updateHint()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let canvas = self.canvas
        let delta = CGVector(dx: raw.x - dragStart.x, dy: raw.y - dragStart.y)
        let rect: CGRect
        switch drag {
        case .resize(let handle):
            rect = SelectionEditor.resize(dragStartRect, handle: handle, by: delta, in: canvas)
        case .move:
            rect = SelectionEditor.move(dragStartRect, by: delta, in: canvas)
        case .draw:
            let point = clamp(raw, to: canvas)
            if freehand {
                points.append(point)
                let xs = points.map(\.x)
                let ys = points.map(\.y)
                rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            } else {
                rect = Selection.rectangle(from: dragStart, to: point, in: canvas)
            }
        }
        guard !rect.isNull else { return }
        unit = SelectionEditor.unit(rect, in: canvas)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = drag else { return }
        mouseDragged(with: event)
        drag = nil
        points.removeAll()
        if !Selection.isUsable(selection) {
            unit = startUnit
            if finished == .draw {
                warning = "Drag across an area to select it, or drag the white handles to adjust the selection"
            }
        }
        updateHint()
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        if unit != nil { actions.changed(self, false) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: actions.cancel()
        case 36, 76: mode == .text ? readText() : searchNow()
        default: super.keyDown(with: event)
        }
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
}

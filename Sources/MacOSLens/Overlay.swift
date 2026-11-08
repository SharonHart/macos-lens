import AppKit
import LensCore
import QuartzCore

struct OverlayActions {
    var began: (OverlayView) -> Void = { _ in }
    var changed: (OverlayView, Bool) -> Void = { _, _ in }
    var text: (OverlayView) -> Void = { _ in }
    var translate: (OverlayView) -> Void = { _ in }
    var refine: (OverlayView, String) -> Void = { _, _ in }
    var panelVisibility: (OverlayView, Bool) -> Void = { _, _ in }
    var cancel: () -> Void = {}
}

/// A borderless, transparent window exactly covering one display, so the frozen screenshot looks like the screen itself.
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        contentView = overlay
        makeFirstResponder(overlay)
    }

    // Escape cancels even while the results page or the search field has keyboard focus.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 { escape(); return }
        super.sendEvent(event)
    }

    // The app has no Edit menu, so the usual editing shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // Text fields and the results page handle the standard editing actions themselves.
        if let responder = firstResponder as? NSView, !(responder is OverlayView) {
            let actions: [String: String] = ["a": "selectAll:", "c": "copy:", "v": "paste:", "x": "cut:",
                                             "z": flags.contains(.shift) ? "redo:" : "undo:"]
            if let name = actions[key], NSApp.sendAction(Selector(name), to: nil, from: self) { return true }
        }
        switch key {
        case "a" where firstResponder is OverlayView:
            overlay.selectWholeScreen()
            return true
        case "w", ".":
            escape()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// The full-screen Circle to Search surface for one display: the frozen screenshot drawn 1:1, an edge glow, white
/// ink for circling, corner brackets for the selection, and (on the active display) the floating controls.
final class OverlayView: NSView {
    /// Turned off by the offscreen checks so geometry is final immediately.
    static var animates = true

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    let image: CGImage
    let displayIndex: Int
    let mode: CaptureMode
    let panel: ResultsPanel?
    let hasControls: Bool
    private let topInset: CGFloat
    private let actions: OverlayActions

    private enum Area: Equatable { case none, screen, unit(CGRect) }
    private var area: Area
    private(set) var viewport = Viewport()

    // Stage layers.
    private let stage = StageView()
    private let screenshotLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let wideGlow = GlowLayer(depth: 120)
    private let thinGlow = GlowLayer(depth: 18)
    private let inkLayer = CAShapeLayer()
    private let bracketLayer = CAShapeLayer()

    // Floating controls.
    let bar = FloatingCard(radius: 26)
    let field = NSTextField(string: "")
    let lensButton = NSButton()
    let textButton = NSButton()
    let translateCard = FloatingCard(radius: 26)
    let translateButton = NSButton()
    let closeCard = FloatingCard(radius: 18)
    let closeButton = NSButton()
    let toast = Toast()

    // Results sheet.
    private(set) var panelShown = false
    private(set) var panelExpanded = false
    private(set) var panelDockedLeft = false
    private var panelWidth: CGFloat = 440
    private var panelAnimating = false
    private var panelDragX: CGFloat?

    // Interaction.
    private var drag: SelectionDrag?
    private var dragStart = CGPoint.zero
    private var dragStartRect = CGRect.null
    private var startArea: Area = .none
    private var points: [CGPoint] = []
    private var tapGeneration = 0
    private var warning: String?
    private var activity: String?
    private var hint: String?
    private var busy = false
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: CGImage, displayIndex: Int, mode: CaptureMode, topInset: CGFloat = 0,
         selected: Bool, controls: Bool, actions: OverlayActions) {
        self.image = image
        self.displayIndex = displayIndex
        self.mode = mode
        self.topInset = max(0, topInset)
        self.actions = actions
        hasControls = controls
        panel = controls ? ResultsPanel(frame: .zero) : nil
        area = selected ? .screen : .none
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        buildStage()
        if controls { buildControls() }
        if controls {
            hint = mode == .text ? "Circle the text to read, then press Return" :
                "Circle, highlight, scribble or tap what you want to search"
        }
        updateToast()
        updateStage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    private func buildStage() {
        stage.frame = bounds
        stage.autoresizingMask = [.width, .height]
        addSubview(stage)
        let root = stage.layer!
        screenshotLayer.contents = image
        screenshotLayer.contentsGravity = .resize
        screenshotLayer.magnificationFilter = .linear
        screenshotLayer.minificationFilter = .trilinear
        root.addSublayer(screenshotLayer)
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.2).cgColor
        root.addSublayer(dimLayer)
        root.addSublayer(wideGlow)
        root.addSublayer(thinGlow)
        inkLayer.fillColor = nil
        inkLayer.strokeColor = NSColor.white.cgColor
        inkLayer.lineWidth = 7
        inkLayer.lineCap = .round
        inkLayer.lineJoin = .round
        inkLayer.shadowColor = NSColor.white.cgColor
        inkLayer.shadowOpacity = 0.9
        inkLayer.shadowRadius = 8
        inkLayer.shadowOffset = .zero
        root.addSublayer(inkLayer)
        bracketLayer.fillColor = nil
        bracketLayer.strokeColor = NSColor.white.cgColor
        bracketLayer.lineWidth = 5
        bracketLayer.lineCap = .round
        bracketLayer.lineJoin = .round
        bracketLayer.shadowColor = NSColor.black.cgColor
        bracketLayer.shadowOpacity = 0.35
        bracketLayer.shadowRadius = 3
        bracketLayer.shadowOffset = .zero
        root.addSublayer(bracketLayer)
        for layer in root.sublayers ?? [] { layer.actions = Self.noActions }
        wideGlow.opacity = 0
        thinGlow.opacity = 0.8
    }

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "contents": NSNull(),
        "opacity": NSNull(), "hidden": NSNull(), "transform": NSNull()
    ]

    private func symbolButton(_ button: NSButton, _ symbol: String, fallback: String, size: CGFloat,
                              tint: NSColor = .labelColor, label: String, action: Selector) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ??
            NSImage(systemSymbolName: fallback, accessibilityDescription: label)
        button.image = image?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = tint
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    private func buildControls() {
        symbolButton(lensButton, "camera.viewfinder", fallback: "viewfinder", size: 19,
                     tint: NSColor(srgbRed: 0.259, green: 0.522, blue: 0.957, alpha: 1),
                     label: mode == .text ? "Read text in the selection" : "Search the selection now (Return)",
                     action: #selector(lensPressed))
        symbolButton(textButton, "text.viewfinder", fallback: "doc.text.viewfinder", size: 17,
                     label: "Select text in the selection (on this Mac)", action: #selector(readText))
        field.placeholderString = "Add to your search"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.sendsActionOnEndEditing = false
        field.target = self
        field.action = #selector(fieldSubmitted)
        field.setAccessibilityLabel("Add to your search")
        for view in [lensButton, field, textButton] { bar.content.addSubview(view) }
        addSubview(bar)

        symbolButton(translateButton, "translate", fallback: "character.bubble", size: 19,
                     label: "Translate text in the selection", action: #selector(translate))
        translateCard.content.addSubview(translateButton)
        addSubview(translateCard)

        symbolButton(closeButton, "xmark", fallback: "xmark.circle", size: 14, label: "Close (Esc)",
                     action: #selector(cancelOverlay))
        closeCard.content.addSubview(closeButton)
        addSubview(closeCard)

        if let panel {
            panel.isHidden = true
            panel.onHide = { [weak self] in self?.hidePanel(byUser: true) }
            panel.onExpand = { [weak self] in self?.togglePanelExpanded() }
            panel.onResize = { [weak self] width, _ in self?.resizePanel(to: width) }
            panel.onMove = { [weak self] dx, finished in self?.movePanel(by: dx, finished: finished) }
            addSubview(panel)
        }
        addSubview(toast)
    }

    // MARK: Geometry

    /// The screenshot's frame: exactly the display at 1x zoom, larger when pinch-zoomed.
    var canvas: CGRect { viewport.canvas(in: bounds) }

    var barFrame: CGRect {
        let width = min(560, max(240, bounds.width - 2 * 24 - 64))
        let x = (bounds.midX - (width + 64) / 2).rounded()
        return CGRect(x: x, y: 24, width: width, height: 52)
    }

    var translateFrame: CGRect { CGRect(x: barFrame.maxX + 12, y: barFrame.minY, width: 52, height: 52) }
    var closeFrame: CGRect { CGRect(x: 24, y: bounds.maxY - topInset - 20 - 36, width: 36, height: 36) }

    /// Where the results sheet sits when shown.
    var panelFrame: CGRect {
        let maxWidth = max(360, bounds.width * 0.75 - 40)
        let width = panelExpanded ? max(min(panelWidth, maxWidth), (bounds.width * 0.66).rounded())
                                  : min(max(panelWidth, 360), maxWidth)
        let x = panelDockedLeft ? bounds.minX + 20 : bounds.maxX - width - 20
        let bottom = barFrame.maxY + 12
        let top = panelDockedLeft ? closeFrame.minY - 12 : bounds.maxY - topInset - 16
        return CGRect(x: x, y: bottom, width: width, height: max(200, top - bottom))
    }

    private var hiddenPanelFrame: CGRect {
        let frame = panelFrame
        return frame.offsetBy(dx: panelDockedLeft ? -(frame.maxX + 40) : bounds.maxX - frame.minX + 40, dy: 0)
    }

    var hasSelection: Bool { area != .none }
    /// True while the selection is the whole visible screen (the default), drawn as brackets with no dimming.
    var isWhole: Bool { area == .screen }

    /// The selection in view coordinates.
    var selection: CGRect? {
        switch area {
        case .none: return nil
        case .screen: return bounds
        case .unit(let unit): return SelectionEditor.view(unit, in: canvas)
        }
    }

    private var unit: CGRect? {
        switch area {
        case .none: return nil
        case .screen: return SelectionEditor.unit(bounds, in: canvas)
        case .unit(let unit): return unit
        }
    }

    /// The selected screenshot pixels. Selections are kept relative to the screenshot, so zooming and panning
    /// never change which pixels a selection crops.
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

    var bracketFrame: CGRect? {
        guard let selection else { return nil }
        return isWhole ? bounds.insetBy(dx: 10, dy: 10) : selection
    }

    var isDimmed: Bool { !dimLayer.isHidden }
    /// The glowing ink stroke currently drawn, if any.
    var inkBounds: CGRect? { inkLayer.path.flatMap { $0.isEmpty ? nil : $0.boundingBoxOfPath } }
    var toastText: String { toast.label.stringValue }
    var refinement: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Layout

    override func layout() {
        super.layout()
        if hasControls {
            bar.frame = barFrame
            let size = barFrame.size
            lensButton.frame = NSRect(x: 10, y: (size.height - 36) / 2, width: 36, height: 36)
            textButton.frame = NSRect(x: size.width - 46, y: (size.height - 36) / 2, width: 36, height: 36)
            field.frame = NSRect(x: 54, y: (size.height - 22) / 2, width: size.width - 108, height: 22)
            translateCard.frame = translateFrame
            translateButton.frame = translateCard.bounds
            closeCard.frame = closeFrame
            closeButton.frame = closeCard.bounds
            layoutToast()
            if let panel, panelShown, !panelAnimating, panelDragX == nil { panel.frame = panelFrame }
            panel?.dockedLeft = panelDockedLeft
        }
        updateStage()
        thinGlow.resize(to: bounds)
        wideGlow.resize(to: bounds)
    }

    private func layoutToast() {
        let width = min(520, toast.fittingWidth + 36, bounds.width - 160)
        toast.frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: bounds.maxY - topInset - 12 - 34,
                             width: width, height: 34)
    }

    private func updateStage() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        screenshotLayer.frame = canvas
        let full = CGPath(rect: bounds, transform: nil)
        if let selection, !isWhole, drag != .draw {
            let path = CGMutablePath()
            path.addPath(full)
            path.addPath(Self.roundedPath(selection))
            dimLayer.path = path
            dimLayer.isHidden = false
        } else {
            dimLayer.isHidden = true
        }
        if let frame = bracketFrame, drag != .draw {
            bracketLayer.path = Self.bracketPath(frame)
            bracketLayer.isHidden = false
        } else {
            bracketLayer.isHidden = true
        }
        CATransaction.commit()
    }

    static func bracketMetrics(_ rect: CGRect) -> (arm: CGFloat, radius: CGFloat) {
        let arm = min(34, max(6, min(rect.width, rect.height) * 0.35))
        return (arm, min(14, arm * 0.6))
    }

    /// Four rounded corner brackets with a fixed element count so the path can animate between selections.
    static func bracketPath(_ rect: CGRect) -> CGPath {
        let (arm, radius) = bracketMetrics(rect)
        let path = CGMutablePath()
        for (x, y, dx, dy) in [(rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0),
                               (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.minY, 1.0, 1.0)] {
            path.move(to: CGPoint(x: x, y: y + dy * arm))
            path.addLine(to: CGPoint(x: x, y: y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: x + dx * radius, y: y), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * arm, y: y))
        }
        return path
    }

    private static func roundedPath(_ rect: CGRect) -> CGPath {
        let radius = min(bracketMetrics(rect).radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func inkPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in points.indices.dropFirst() {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points.last!)
        return path
    }

    // MARK: Animation

    private var reduceMotion: Bool {
        !Self.animates || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Android-style activation: a Google-coloured glow sweeps in from the screen edges, then settles to a thin rim.
    func playIntro() {
        guard !reduceMotion else { return }
        let wide = CAKeyframeAnimation(keyPath: "opacity")
        wide.values = [0, 0.85, 0.7, 0]
        wide.keyTimes = [0, 0.25, 0.55, 1]
        wide.duration = 1.4
        wideGlow.add(wide, forKey: "intro")
        let thin = CABasicAnimation(keyPath: "opacity")
        thin.fromValue = 0
        thin.toValue = thinGlow.opacity
        thin.duration = 0.7
        thin.beginTime = CACurrentMediaTime() + 0.25
        thin.fillMode = .backwards
        thinGlow.add(thin, forKey: "intro")
        wideGlow.spin(duration: 1.6)
        thinGlow.spin(duration: 1.6)
        if let frame = bracketFrame {
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = Self.bracketPath(frame.insetBy(dx: 26, dy: 26))
            grow.duration = 0.45
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bracketLayer.add(grow, forKey: "intro")
        }
    }

    /// Ink fades and the selection appears as brackets, like Android's circle morphing into the selected area.
    private func morph(from rect: CGRect) {
        updateStage()
        guard !reduceMotion, let frame = bracketFrame else {
            inkLayer.path = nil
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.drag == nil else { return }
            self.inkLayer.path = nil
        }
        inkLayer.opacity = 0
        inkLayer.add(fade, forKey: "fade")
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = Self.bracketPath(rect.insetBy(dx: -14, dy: -14))
        grow.toValue = Self.bracketPath(frame)
        grow.duration = 0.22
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bracketLayer.add(grow, forKey: "morph")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.18
        bracketLayer.add(appear, forKey: "appear")
        dimLayer.add(appear, forKey: "appear")
        CATransaction.commit()
    }

    /// Brackets breathe while the selection is being uploaded.
    func setBusy(_ busy: Bool) {
        guard busy != self.busy else { return }
        self.busy = busy
        if busy && !reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.45
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            bracketLayer.add(pulse, forKey: "pulse")
        } else {
            bracketLayer.removeAnimation(forKey: "pulse")
        }
    }

    private func animate(_ duration: TimeInterval, _ changes: @escaping () -> Void,
                         completion: (() -> Void)? = nil) {
        guard !reduceMotion else {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            changes()
            NSAnimationContext.endGrouping()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }

    // MARK: Results sheet

    /// Slides the results sheet in from the side, like Android's results sheet.
    func revealPanel() {
        guard let panel, !panelShown else { return }
        if let left = sideRevealingSelection() {
            panelDockedLeft = left
            panel.dockedLeft = left
        }
        panelShown = true
        panel.isHidden = false
        panel.alphaValue = 1
        panel.frame = reduceMotion ? panelFrame : hiddenPanelFrame
        panelAnimating = true
        animate(0.28, { panel.animator().frame = self.panelFrame }) { [weak self] in
            self?.panelAnimating = false
            self?.needsLayout = true
        }
    }

    func hidePanel(byUser: Bool = false) {
        guard let panel, panelShown else { return }
        panelShown = false
        panelAnimating = true
        animate(0.24, { panel.animator().frame = self.hiddenPanelFrame }) { [weak self] in
            guard let self else { return }
            self.panelAnimating = false
            if !self.panelShown { panel.isHidden = true }
        }
        if byUser { actions.panelVisibility(self, false) }
    }

    private func togglePanelExpanded() {
        panelExpanded.toggle()
        panel?.expanded = panelExpanded
        guard let panel, panelShown else { return }
        panelAnimating = true
        animate(0.22, { panel.animator().frame = self.panelFrame }) { [weak self] in
            self?.panelAnimating = false
            self?.needsLayout = true
        }
    }

    private func resizePanel(to width: CGFloat) {
        panelExpanded = false
        panel?.expanded = false
        panelWidth = min(max(width, 360), max(360, bounds.width * 0.75 - 40))
        needsLayout = true
    }

    /// Dragging the sheet's header moves it sideways; releasing docks it to the nearer side of the screen.
    private func movePanel(by dx: CGFloat, finished: Bool) {
        guard let panel, panelShown else { return }
        if !finished {
            let x = (panelDragX ?? panel.frame.minX) + dx
            panelDragX = min(max(x, bounds.minX), bounds.maxX - panel.frame.width)
            panel.setFrameOrigin(NSPoint(x: panelDragX!, y: panel.frame.minY))
            return
        }
        panelDragX = nil
        dockPanel(left: panel.frame.midX < bounds.midX)
    }

    func dockPanel(left: Bool) {
        panelDockedLeft = left
        panel?.dockedLeft = left
        guard let panel, panelShown else { return }
        panelAnimating = true
        animate(0.22, { panel.animator().frame = self.panelFrame }) { [weak self] in
            self?.panelAnimating = false
            self?.needsLayout = true
        }
    }

    /// Moves the sheet to the other side when it covers a smaller selection that would fit there.
    private func keepSelectionVisible() {
        guard panelShown, let left = sideRevealingSelection() else { return }
        dockPanel(left: left)
    }

    /// The other side, when docking the sheet there would cover less of a smaller selection; nil to stay put.
    private func sideRevealingSelection() -> Bool? {
        guard !isWhole, let selection else { return nil }
        let current = panelDockedLeft
        defer { panelDockedLeft = current }
        func covered(dockedLeft: Bool) -> CGFloat {
            panelDockedLeft = dockedLeft
            let overlap = panelFrame.intersection(selection)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let here = covered(dockedLeft: current)
        guard here > 0, covered(dockedLeft: !current) < here else { return nil }
        return !current
    }

    /// While a selection is drawn or adjusted, the controls fade and the sheet lets the screenshot show through.
    private func setDragging(_ dragging: Bool) {
        panel?.passThrough = dragging
        let controls: [NSView] = [bar, translateCard, closeCard]
        animate(0.15, {
            self.panel?.animator().alphaValue = dragging ? 0.25 : 1
            for view in controls where view.superview != nil { view.animator().alphaValue = dragging ? 0.45 : 1 }
        })
    }

    // MARK: Messages

    func showWarning(_ text: String?) {
        warning = text
        updateToast()
    }

    func setActivity(_ text: String?) {
        activity = text
        updateToast()
    }

    private func updateToast() {
        let text = warning ?? activity ?? hint
        toast.set(text, warning: warning != nil, busy: warning == nil && activity != nil)
        guard hasControls else { return }
        layoutToast()
        animate(0.2, { self.toast.animator().alphaValue = text == nil ? 0 : 1 })
    }

    // MARK: Commands

    func clearSelection() {
        guard area != .none else { return }
        area = .none
        updateStage()
    }

    /// Selects everything on this screen again (Command-A), resetting zoom.
    @objc func selectWholeScreen() {
        actions.began(self)
        viewport.reset()
        area = .screen
        warning = nil
        hint = nil
        updateToast()
        updateStage()
        actions.changed(self, false)
    }

    @objc func searchNow() {
        hint = nil
        updateToast()
        actions.changed(self, true)
    }

    @objc private func lensPressed() { mode == .text ? readText() : searchNow() }
    @objc func readText() { actions.text(self) }
    @objc func translate() { actions.translate(self) }
    @objc func cancelOverlay() { actions.cancel() }

    /// Return in the search bar refines the visual search with the typed words (multisearch).
    @objc func fieldSubmitted() {
        hint = nil
        updateToast()
        window?.makeFirstResponder(self)
        actions.refine(self, refinement)
    }

    // MARK: Zoom and pan

    func zoom(by factor: CGFloat, at point: CGPoint) {
        viewport.zoom(by: factor, at: point, in: bounds)
        viewportChanged()
    }

    func pan(by delta: CGVector) {
        viewport.pan(by: delta, in: bounds)
        viewportChanged()
    }

    private func viewportChanged() {
        tapGeneration += 1
        updateStage()
        // The default selection follows what is visible, so a zoomed screen is searched once the gesture pauses.
        guard isWhole else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(visibleAreaSettled), object: nil)
        perform(#selector(visibleAreaSettled), with: nil, afterDelay: 0.35)
    }

    @objc private func visibleAreaSettled() {
        guard isWhole else { return }
        actions.changed(self, false)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if viewport.isZoomed {
            viewport.reset()
            viewportChanged()
        } else {
            zoom(by: 2, at: point)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(event.scrollingDeltaY * scale * 0.01), at: point)
        } else if viewport.isZoomed {
            pan(by: CGVector(dx: event.scrollingDeltaX * scale, dy: -event.scrollingDeltaY * scale))
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Mouse

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

    /// The rect used for grabbing: the default whole-screen selection is grabbed at its visible brackets.
    private var grabTarget: (selection: CGRect?, limit: CGRect) {
        if isWhole, let frame = bracketFrame { return (frame, frame) }
        return (selection, canvas)
    }

    func target(at point: CGPoint) -> SelectionDrag {
        let grab = grabTarget
        return SelectionEditor.target(at: point, selection: grab.selection, bounds: grab.limit)
    }

    private func updateCursor(at point: CGPoint) {
        guard drag == nil else { return }
        if let hit = hitTest(convert(point, to: superview)), hit !== self { return }
        cursor(for: target(at: point)).set()
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
        let target = target(at: point)
        drag = target
        startArea = area
        dragStart = point
        dragStartRect = isWhole ? bounds : selection ?? .null
        warning = nil
        hint = nil
        tapGeneration += 1
        updateToast()
        if target == .move { NSCursor.closedHand.set() }
        if target == .draw {
            points = [clamp(point, to: bounds)]
            inkLayer.removeAllAnimations()
            inkLayer.opacity = 1
            inkLayer.path = Self.inkPath(points)
        }
        actions.began(self)
        setDragging(true)
        updateStage()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let delta = CGVector(dx: raw.x - dragStart.x, dy: raw.y - dragStart.y)
        switch drag {
        case .resize(let handle):
            setRect(SelectionEditor.resize(dragStartRect, handle: handle, by: delta, in: canvas))
        case .move:
            setRect(SelectionEditor.move(dragStartRect, by: delta, in: canvas))
        case .draw:
            points.append(clamp(raw, to: bounds))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkLayer.path = Self.inkPath(points)
            CATransaction.commit()
        }
    }

    private func setRect(_ rect: CGRect) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        area = .unit(SelectionEditor.unit(rect, in: canvas))
        updateStage()
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = drag else { return }
        if finished != .draw { mouseDragged(with: event) }
        else { points.append(clamp(convert(event.locationInWindow, from: nil), to: bounds)) }
        drag = nil
        setDragging(false)
        defer { updateCursor(at: convert(event.locationInWindow, from: nil)) }
        if finished == .draw {
            let stroke = points
            points.removeAll()
            if SelectionEditor.isTap(stroke) {
                selectTapped(at: stroke[0])
                return
            }
            let rect = SelectionEditor.strokeBounds(stroke, in: bounds)
            guard Selection.isUsable(rect) else {
                area = startArea
                inkLayer.path = nil
                updateStage()
                return
            }
            area = .unit(SelectionEditor.unit(rect, in: canvas))
            morph(from: rect)
        } else if !Selection.isUsable(selection) {
            area = startArea
        }
        normalizeWhole()
        updateStage()
        keepSelectionVisible()
        if area != startArea || finished == .draw { actions.changed(self, false) }
    }

    /// A selection dragged back out to the screen edges becomes the default whole-screen selection again.
    private func normalizeWhole() {
        guard case .unit = area, !viewport.isZoomed, let selection,
              abs(selection.minX - bounds.minX) < 1, abs(selection.minY - bounds.minY) < 1,
              abs(selection.maxX - bounds.maxX) < 1, abs(selection.maxY - bounds.maxY) < 1 else { return }
        area = .screen
    }

    /// A tap selects the line of text or the object under it, found locally with Apple Vision.
    private func selectTapped(at point: CGPoint) {
        tapGeneration += 1
        let generation = tapGeneration
        let canvas = self.canvas
        let bounds = self.bounds
        let region = CGRect(x: point.x - 240, y: point.y - 160, width: 480, height: 320).intersection(bounds)
        let finish: ([CGRect], [CGRect]) -> Void = { [weak self] text, objects in
            guard let self, generation == self.tapGeneration else { return }
            let rect = SelectionEditor.tapSelection(at: point, textLines: text, objects: objects, in: bounds)
            self.area = .unit(SelectionEditor.unit(rect, in: canvas))
            self.setActivity(nil)
            self.morph(from: rect)
            self.keepSelectionVisible()
            self.actions.changed(self, false)
        }
        guard let pixels = Selection.pixels(for: region, in: canvas, width: image.width, height: image.height),
              let crop = image.cropping(to: pixels) else {
            finish([], [])
            return
        }
        let width = image.width, height = image.height
        Task.detached(priority: .userInitiated) {
            let found = (try? OCR.tapCandidates(crop)) ?? (text: [], objects: [])
            func views(_ boxes: [CGRect]) -> [CGRect] {
                boxes.map {
                    SelectionEditor.view(SelectionEditor.unit(forNormalized: $0, inPixels: pixels, width: width,
                                                              height: height), in: canvas)
                }
            }
            let text = views(found.text), objects = views(found.objects)
            await MainActor.run { finish(text, objects) }
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: actions.cancel()
        case 36, 76: mode == .text ? readText() : searchNow()
        default:
            // Typing anywhere goes to the search bar, as on Android.
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if hasControls, flags.isEmpty, let characters = event.characters,
               let scalar = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
               scalar.value < 0xF700 {
                window?.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.insertText(characters, replacementRange: field.currentEditor()?.selectedRange ?? NSRange(location: NSNotFound, length: 0))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
}

/// Hosts the screenshot layers. It never takes mouse events, so they reach the overlay underneath.
final class StageView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A rotating Google-coloured conic gradient, visible only in a soft band along the screen edges.
final class GlowLayer: CALayer {
    private let gradient = CAGradientLayer()
    private let ring = CALayer()
    private let depth: CGFloat
    private var size = CGSize.zero

    init(depth: CGFloat) {
        self.depth = depth
        super.init()
        gradient.type = .conic
        let hexes: [Int] = [0x4285F4, 0xEA4335, 0xFBBC05, 0x34A853, 0x4285F4]
        gradient.colors = hexes.map { (hex: Int) -> CGColor in
            let red = CGFloat((hex >> 16) & 0xFF) / 255
            let green = CGFloat((hex >> 8) & 0xFF) / 255
            let blue = CGFloat(hex & 0xFF) / 255
            return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        addSublayer(gradient)
        mask = ring
        actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        gradient.actions = ["transform": NSNull(), "bounds": NSNull(), "position": NSNull()]
        ring.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) {
        depth = (layer as? GlowLayer)?.depth ?? 0
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func resize(to bounds: CGRect) {
        guard bounds.size != size, bounds.width > 0, bounds.height > 0 else { return }
        size = bounds.size
        frame = bounds
        ring.frame = CGRect(origin: .zero, size: bounds.size)
        ring.contents = Self.ringImage(size: bounds.size, depth: depth)
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
    }

    func spin(duration: CFTimeInterval) {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = -Double.pi / 2
        spin.toValue = 0
        spin.duration = duration
        spin.timingFunction = CAMediaTimingFunction(name: .easeOut)
        gradient.add(spin, forKey: "spin")
    }

    /// Opaque at the screen edge, fading to clear `depth` points inside, drawn at half resolution.
    private static func ringImage(size: CGSize, depth: CGFloat) -> CGImage? {
        let scale: CGFloat = 0.5
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(origin: .zero, size: size)
        let steps = 28
        let band = depth / CGFloat(steps)
        for step in 0..<steps {
            let t = (CGFloat(step) + 0.5) / CGFloat(steps)
            let inset = t * depth
            let edge = rect.insetBy(dx: inset, dy: inset)
            guard edge.width > 0, edge.height > 0 else { break }
            let radius = min(max(4, 18 - inset), edge.width / 2, edge.height / 2)
            context.setStrokeColor(CGColor(gray: 1, alpha: pow(1 - t, 2.2)))
            context.setLineWidth(band * 1.15)
            context.addPath(CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        }
        return context.makeImage()
    }
}

/// A rounded, translucent floating surface with a soft shadow that keeps clicks from reaching the screenshot.
class FloatingCard: NSView {
    let content = NSVisualEffectView()
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        content.material = .popover
        content.blendingMode = .withinWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        content.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: min(radius, bounds.height / 2),
                                   cornerHeight: min(radius, bounds.height / 2), transform: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// A small status pill at the top of the screen; purely informational, so clicks pass through it.
final class Toast: FloatingCard {
    let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()

    init() {
        super.init(radius: 17)
        alphaValue = 0
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemYellow
        for view in [label, spinner, icon] { content.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingWidth: CGFloat { label.intrinsicContentSize.width + (spinner.isHidden && icon.isHidden ? 0 : 24) }

    func set(_ text: String?, warning: Bool, busy: Bool) {
        label.stringValue = text ?? ""
        label.toolTip = text
        icon.isHidden = !warning
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let accessory = !spinner.isHidden || !icon.isHidden
        let x: CGFloat = accessory ? 34 : 14
        label.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: max(0, bounds.width - x - 14), height: 18)
        spinner.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        icon.frame = spinner.frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

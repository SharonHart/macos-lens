import AppKit
import LensCore
import QuartzCore

/// Text actions that send the selected words to Google, after consent.
enum TextCommand: Equatable {
    case search
    case translateWeb
}

/// Recognized paragraphs to translate in place, with the languages chosen in the translate bar.
struct TranslationRequest: Equatable {
    var blocks: [String]
    var source: String?
    var target: String
    /// The selected (or all) text, for the consented Google Translate fallback.
    var text: String
}

struct OverlayActions {
    var began: (OverlayView) -> Void = { _ in }
    var changed: (OverlayView, Bool) -> Void = { _, _ in }
    var modeChanged: (OverlayView, CaptureMode) -> Void = { _, _ in }
    var textCommand: (OverlayView, TextCommand, String) -> Void = { _, _, _ in }
    var quick: (OverlayView, TextQuickAction) -> Void = { _, _ in }
    var translate: (OverlayView, TranslationRequest) -> Void = { _, _ in }
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
            if overlay.mode == .text { overlay.selectAllText() } else { overlay.selectWholeScreen() }
            return true
        case "c" where firstResponder is OverlayView && overlay.mode == .text:
            overlay.copyText()
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
    private(set) var mode: CaptureMode
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
    private let bracketLayer = OutlineLayer(width: 7, haloWidth: 11)
    private let borderLayer = OutlineLayer(width: 2, haloWidth: 5)
    private let markLayer = OutlineLayer(width: 5, haloWidth: 9)
    let textSurface = TextSurface()
    static let dimAlpha: CGFloat = 0.35

    // Floating controls.
    let bar = FloatingCard(radius: 26)
    let field = NSTextField(string: "")
    let lensButton = NSButton()
    let modeControl = NSSegmentedControl()
    let textLabel = NSTextField(labelWithString: "Select text · stays on this Mac")
    let translateCard = FloatingCard(radius: 26)
    let translateButton = NSButton()
    let closeCard = FloatingCard(radius: 18)
    let closeButton = NSButton()
    let toast = Toast()
    let actionChip = ActionChip()
    let translateBar = TranslateBar()
    let selectTextChip = FloatingCard(radius: 18)
    private(set) var selectTextButton: ChipButton?

    // Text mode. The checks swap these for a private pasteboard, a silent speaker and their own settings.
    static var defaults = UserDefaults.standard
    static var pasteboard = NSPasteboard.general
    static var speaker: Speaker = SystemSpeaker()
    static var recognizer: @Sendable (CGImage) throws -> [RecognizedLine] = { try OCR.recognizeWords($0) }
    private(set) var textLayout: TextLayout?
    private(set) var textRange: TextRange?
    private(set) var recognizing = false
    private var recognitionWaiters: [() -> Void] = []
    private enum TextDrag { case select(anchor: Int), handle(fixed: Int, lift: CGFloat), ink }
    private var textDrag: TextDrag?
    private(set) var translatedLines: [String]?
    private(set) var showOriginal = false
    private(set) var translating = false
    private var notice: String?
    private var noticeGeneration = 0

    // Results sheet.
    private(set) var panelShown = false
    private(set) var panelExpanded = false
    private(set) var panelDockedLeft = false
    private var panelWidth: CGFloat = PanelSizing.minimum
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
        panelWidth = PanelSizing.width(stored: Self.defaults.object(forKey: PanelSizing.defaultsKey) as? Double,
                                       screenWidth: frame.width)
        buildStage()
        if controls { buildControls() }
        buildTextControls()
        addSubview(toast)
        if controls { hint = "Circle, highlight, scribble or tap what you want to search" }
        if mode == .text { setMode(.text, notify: false) }
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
        root.addSublayer(textSurface)
        dimLayer.fillColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
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
        root.addSublayer(borderLayer)
        root.addSublayer(markLayer)
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
                              weight: NSFont.Weight = .medium, tint: NSColor = .labelColor, label: String,
                              action: Selector) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ??
            NSImage(systemSymbolName: fallback, accessibilityDescription: label)
        button.image = image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
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
        symbolButton(lensButton, "camera.viewfinder", fallback: "viewfinder", size: 23, weight: .heavy,
                     tint: googleBlue, label: "Search the selection now (Return)", action: #selector(lensPressed))
        modeControl.segmentCount = 2
        modeControl.trackingMode = .selectOne
        modeControl.segmentStyle = .capsule
        for (index, (label, symbol, tip)) in [("Search", "magnifyingglass", "Search what you circle with Google Lens"),
                                              ("Text", "text.viewfinder", "Select text on the screen, on this Mac")]
            .enumerated() {
            modeControl.setLabel(label, forSegment: index)
            modeControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)), forSegment: index)
            modeControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
            modeControl.setWidth(78, forSegment: index)
            modeControl.setToolTip(tip, forSegment: index)
        }
        modeControl.selectedSegment = mode == .text ? 1 : 0
        modeControl.target = self
        modeControl.action = #selector(modeControlChanged)
        modeControl.setAccessibilityLabel("Search or select text")
        textLabel.font = .systemFont(ofSize: 14)
        textLabel.textColor = .secondaryLabelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isHidden = true
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
        for view in [lensButton, field, textLabel, modeControl] { bar.content.addSubview(view) }
        addSubview(bar)

        symbolButton(translateButton, "translate", fallback: "character.bubble", size: 19,
                     label: "Translate the text on screen, in place", action: #selector(translate))
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
            panel.onResize = { [weak self] width, finished in self?.resizePanel(to: width, finished: finished) }
            panel.onMove = { [weak self] dx, finished in self?.movePanel(by: dx, finished: finished) }
            addSubview(panel)
        }
    }

    /// Text mode works on every display, so its menus are built even where the search bar is not.
    private func buildTextControls() {
        translateBar.isHidden = true
        translateBar.onChange = { [weak self] in
            guard let self, self.translatedLines != nil || self.translating else { return }
            self.requestTranslation()
        }
        translateBar.onShowOriginal = { [weak self] in self?.setShowOriginal($0) }
        translateBar.onClose = { [weak self] in self?.endTranslation() }
        addSubview(translateBar)
        selectTextChip.isHidden = true
        addSubview(selectTextChip)
        actionChip.isHidden = true
        addSubview(actionChip)
    }

    // MARK: Geometry

    /// The screenshot's frame: exactly the display at 1x zoom, larger when pinch-zoomed.
    var canvas: CGRect { viewport.canvas(in: bounds) }

    var barFrame: CGRect {
        let width = min(640, max(320, bounds.width - 2 * 24 - 64))
        let x = (bounds.midX - (width + 64) / 2).rounded()
        return CGRect(x: x, y: 24, width: width, height: 52)
    }

    var translateFrame: CGRect { CGRect(x: barFrame.maxX + 12, y: barFrame.minY, width: 52, height: 52) }
    var closeFrame: CGRect { CGRect(x: 24, y: bounds.maxY - topInset - 20 - 36, width: 36, height: 36) }

    /// Where the results sheet sits when shown.
    var panelFrame: CGRect {
        let fitted = PanelSizing.clamp(panelWidth, screenWidth: bounds.width)
        let width = panelExpanded ? max(fitted, (bounds.width * 0.66).rounded()) : fitted
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
    /// The continuous border currently drawn around the selection or the area being drawn, if any.
    var outlineFrame: CGRect? { borderLayer.isHidden ? nil : borderLayer.path?.boundingBoxOfPath }
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
            lensButton.frame = NSRect(x: 8, y: (size.height - 40) / 2, width: 40, height: 40)
            modeControl.frame = NSRect(x: size.width - 172, y: (size.height - 28) / 2, width: 162, height: 28)
            field.frame = NSRect(x: 56, y: (size.height - 22) / 2, width: size.width - 56 - 184, height: 22)
            textLabel.frame = field.frame
            translateCard.frame = translateFrame
            translateButton.frame = translateCard.bounds
            closeCard.frame = closeFrame
            closeButton.frame = closeCard.bounds
            layoutToast()
            if let panel, panelShown, !panelAnimating, panelDragX == nil { panel.frame = panelFrame }
            panel?.dockedLeft = panelDockedLeft
        }
        translateBar.frame = translateBarFrame
        updateStage()
        layoutChip()
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
        let searching = mode == .search
        for layer in [bracketLayer, borderLayer, markLayer] { layer.frame = bounds }
        if searching, let selection, !isWhole, drag != .draw {
            let path = CGMutablePath()
            path.addPath(full)
            path.addPath(Self.roundedPath(selection))
            dimLayer.path = path
            dimLayer.isHidden = false
        } else {
            dimLayer.isHidden = true
        }
        if searching, let frame = bracketFrame, drag != .draw {
            bracketLayer.path = Self.bracketPath(frame)
            bracketLayer.isHidden = false
        } else {
            bracketLayer.isHidden = true
        }
        // A thin continuous border, live while a new area is drawn, so the selection shows on any background.
        if searching, drag == .draw, points.count > 1 {
            borderLayer.path = Self.roundedPath(SelectionEditor.strokeBounds(points, in: bounds))
            borderLayer.isHidden = false
        } else if searching, let selection, !isWhole {
            borderLayer.path = Self.roundedPath(selection)
            borderLayer.isHidden = false
        } else {
            borderLayer.isHidden = true
        }
        if searching, let selection, !isWhole, drag != .draw {
            markLayer.path = Self.markPath(selection)
            markLayer.isHidden = false
        } else {
            markLayer.isHidden = true
        }
        updateTextSurface()
        CATransaction.commit()
    }

    static func bracketMetrics(_ rect: CGRect) -> (arm: CGFloat, radius: CGFloat) {
        let arm = min(48, max(8, min(rect.width, rect.height) * 0.35))
        return (arm, min(16, arm * 0.5))
    }

    /// Short grab marks at the middle of each edge, where the edge handles are.
    static func markPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let across = min(28, rect.width * 0.18), up = min(28, rect.height * 0.18)
        for y in [rect.minY, rect.maxY] {
            path.move(to: CGPoint(x: rect.midX - across / 2, y: y))
            path.addLine(to: CGPoint(x: rect.midX + across / 2, y: y))
        }
        for x in [rect.minX, rect.maxX] {
            path.move(to: CGPoint(x: x, y: rect.midY - up / 2))
            path.addLine(to: CGPoint(x: x, y: rect.midY + up / 2))
        }
        return path
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

    static func roundedPath(_ rect: CGRect) -> CGPath {
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
            bracketLayer.animatePath(grow, forKey: "intro")
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
        bracketLayer.animatePath(grow, forKey: "morph")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.18
        bracketLayer.add(appear, forKey: "appear")
        dimLayer.add(appear, forKey: "appear")
        borderLayer.add(appear, forKey: "appear")
        markLayer.add(appear, forKey: "appear")
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

    /// Dragging the sheet's edge resizes it; the width is remembered for the next activation.
    private func resizePanel(to width: CGFloat, finished: Bool) {
        panelExpanded = false
        panel?.expanded = false
        panelWidth = PanelSizing.clamp(width, screenWidth: bounds.width)
        if finished { Self.defaults.set(Double(panelWidth), forKey: PanelSizing.defaultsKey) }
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
        let working = mode != .text ? nil : recognizing ? "Finding text…" : translating ? "Translating…" : nil
        let text = warning ?? notice ?? working ?? activity ?? hint
        toast.set(text, warning: warning != nil,
                  busy: warning == nil && notice == nil && (working != nil || activity != nil))
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
        hideSelectTextChip()
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

    @objc private func lensPressed() { mode == .text ? searchSelectedText() : searchNow() }
    /// Translate draws the translation over the recognized text in place, like Lens.
    @objc func translate() { beginTranslation() }
    @objc private func modeControlChanged() { setMode(modeControl.selectedSegment == 1 ? .text : .search) }
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
        layoutChip()
        if !selectTextChip.isHidden { updateSelectTextChip() }
        // The default selection follows what is visible, so a zoomed screen is searched once the gesture pauses.
        guard isWhole, mode == .search else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(visibleAreaSettled), object: nil)
        perform(#selector(visibleAreaSettled), with: nil, afterDelay: 0.35)
    }

    @objc private func visibleAreaSettled() {
        guard isWhole, mode == .search else { return }
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
        return SelectionEditor.target(at: point, selection: grab.selection, bounds: grab.limit, tolerance: 18)
    }

    private func updateCursor(at point: CGPoint) {
        guard drag == nil, textDrag == nil else { return }
        if let hit = hitTest(convert(point, to: superview)), hit !== self { return }
        if mode == .text {
            textCursor(at: point).set()
            return
        }
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
        if mode == .text {
            textMouseDown(event, at: point)
            return
        }
        hideSelectTextChip()
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
        let raw = convert(event.locationInWindow, from: nil)
        if mode == .text {
            textMouseDragged(raw)
            return
        }
        guard let drag else { return }
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
            updateStage()
        }
    }

    private func setRect(_ rect: CGRect) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        area = .unit(SelectionEditor.unit(rect, in: canvas))
        updateStage()
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .text {
            textMouseUp(convert(event.locationInWindow, from: nil))
            return
        }
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
        updateSelectTextChip()
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
            self.updateSelectTextChip()
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
        if mode == .text {
            if event.keyCode == 53 { actions.cancel() } else { super.keyDown(with: event) }
            return
        }
        switch event.keyCode {
        case 53: actions.cancel()
        case 36, 76: searchNow()
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

// MARK: - Text mode

/// Selecting text on the frozen screen, as Lens's Text option does: every word recognized with Apple Vision on this
/// Mac, selected by clicking or dragging like a text cursor, with Android-style handles and a floating action menu.
/// The screenshot never leaves this Mac in Text mode; only text the user chooses to search or translate is sent.
extension OverlayView {
    static let textHint = "Click a word or drag across text · on this Mac"

    /// Switches between visual search and selecting text, keeping the same screenshot and zoom.
    func setMode(_ newMode: CaptureMode, range: TextRange? = nil, notify: Bool = true) {
        let changed = newMode != mode
        mode = newMode
        drag = nil
        textDrag = nil
        points.removeAll()
        inkLayer.path = nil
        hideSelectTextChip()
        if hasControls {
            modeControl.selectedSegment = newMode == .text ? 1 : 0
            field.isHidden = newMode == .text
            textLabel.isHidden = newMode != .text
            lensButton.toolTip = newMode == .text ? "Search the selected text with Google" :
                "Search the selection now (Return)"
            if newMode == .text, window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(self) }
        }
        warning = nil
        if newMode == .text {
            activity = nil
            textRange = range
            hint = nil
            ensureRecognized { [weak self] in
                guard let self, self.mode == .text else { return }
                if let range, self.textRange == nil { self.textRange = range }
                self.textChanged(dragging: false)
            }
        } else {
            stopSpeaking()
            if translatedLines != nil || translating { endTranslation() }
            textRange = nil
            notice = nil
            if hasControls && isWhole { hint = "Circle, highlight, scribble or tap what you want to search" }
            actionChip.isHidden = true
        }
        if newMode == .text, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if changed && notify { actions.modeChanged(self, newMode) }
        updateTextLabel()
        updateToast()
        updateStage()
        needsLayout = true
    }

    /// Recognizes the whole frozen display once, off the main thread; later callers wait for the same result.
    func ensureRecognized(_ then: @escaping () -> Void) {
        if textLayout != nil {
            then()
            return
        }
        recognitionWaiters.append(then)
        guard !recognizing else { return }
        recognizing = true
        updateToast()
        updateStage()
        let image = self.image
        let recognizer = Self.recognizer
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let finish: (Result<[RecognizedLine], Error>) -> Void = { [weak self] result in
            self?.finishRecognition(result, aspect: aspect)
        }
        Task.detached(priority: .userInitiated) {
            let result = Result { try recognizer(image) }
            await MainActor.run { finish(result) }
        }
    }

    private func finishRecognition(_ result: Result<[RecognizedLine], Error>, aspect: CGFloat) {
        recognizing = false
        switch result {
        case .success(let lines):
            textLayout = TextLayout(lines: lines, aspect: aspect)
        case .failure(let error):
            textLayout = .empty
            if mode == .text { warning = "Couldn't read text on this screen: \(error.localizedDescription)" }
        }
        let waiters = recognitionWaiters
        recognitionWaiters.removeAll()
        waiters.forEach { $0() }
        if mode == .text, warning == nil, textRange == nil, hasControls {
            hint = textLayout?.isEmpty == false ? Self.textHint : nil
            if textLayout?.isEmpty != false { warning = "No text found on this screen" }
        }
        updateToast()
        updateStage()
    }

    // MARK: Drawing

    func updateTextSurface() {
        let surface = textSurface
        surface.frame = bounds
        surface.isHidden = mode != .text
        guard mode == .text else {
            surface.dim.removeAnimation(forKey: "shimmer")
            return
        }
        let canvas = self.canvas
        let layout = textLayout ?? .empty
        let translated = translatedLines != nil && !showOriginal
        surface.translation.frame = canvas
        surface.translation.isHidden = !translated || surface.translation.contents == nil
        let dim = CGMutablePath()
        dim.addRect(bounds)
        let lineBoxes = layout.lines.map { SelectionEditor.view($0.box, in: canvas).insetBy(dx: -2, dy: -2) }
        for rect in Self.merged(lineBoxes) {
            dim.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        }
        surface.dim.path = dim
        if recognizing && !reduceMotion {
            if surface.dim.animation(forKey: "shimmer") == nil {
                let shimmer = CABasicAnimation(keyPath: "opacity")
                shimmer.fromValue = 1
                shimmer.toValue = 0.4
                shimmer.duration = 0.7
                shimmer.autoreverses = true
                shimmer.repeatCount = .infinity
                surface.dim.add(shimmer, forKey: "shimmer")
            }
        } else {
            surface.dim.removeAnimation(forKey: "shimmer")
        }
        let words = CGMutablePath()
        if !translated {
            for index in layout.words.indices {
                let box = layout.view(index, in: canvas).insetBy(dx: -1, dy: -1)
                words.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            }
        }
        surface.words.path = words
        let selection = CGMutablePath()
        let handles = CGMutablePath()
        if let range = textRange, !layout.isEmpty {
            for rect in selectionRects(range, layout: layout) {
                let radius = min(5, rect.height / 3)
                selection.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            if let ends = layout.handlePoints(for: range, canvas: canvas) {
                let first = layout.view(range.lower, in: canvas), last = layout.view(range.upper, in: canvas)
                handles.addPath(TextSurface.handlePath(start: (ends.start, first.maxY), end: (ends.end, last.maxY)))
            }
        }
        surface.selection.path = selection
        surface.handles.path = handles
    }

    /// Highlight rectangles merged per line; whole lines when the translation covers the original words.
    private func selectionRects(_ range: TextRange, layout: TextLayout) -> [CGRect] {
        guard translatedLines != nil && !showOriginal else { return layout.lineRects(for: range, canvas: canvas) }
        return touchedLines(range, layout: layout).map {
            SelectionEditor.view(layout.lines[$0].box, in: canvas).insetBy(dx: -2, dy: -2)
        }
    }

    private func touchedLines(_ range: TextRange, layout: TextLayout) -> [Int] {
        let upper = min(range.upper, layout.words.count - 1)
        guard range.lower <= upper else { return [] }
        var lines: [Int] = []
        for index in range.lower...upper where lines.last != layout.words[index].line {
            lines.append(layout.words[index].line)
        }
        return lines
    }

    /// Overlapping rectangles joined, so the even-odd dim never darkens where two line holes overlap.
    static func merged(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects {
            var current = rect
            while let index = result.firstIndex(where: { $0.intersects(current) }) {
                current = current.union(result.remove(at: index))
            }
            result.append(current)
        }
        return result
    }

    // MARK: Text

    /// The selected text as shown: the translation when it covers the original, otherwise the recognized words with
    /// their line and paragraph breaks.
    var selectedText: String {
        guard let range = textRange else { return "" }
        return shownText(range)
    }

    /// Everything readable on this screen, as shown.
    var allShownText: String {
        guard let all = textLayout?.all else { return "" }
        return shownText(all)
    }

    private func shownText(_ range: TextRange) -> String {
        guard let layout = textLayout, !layout.isEmpty else { return "" }
        guard let lines = translatedLines, !showOriginal else { return layout.text(for: range) }
        var text = ""
        var previous: Int?
        for line in touchedLines(range, layout: layout) {
            if let previous { text += layout.lines[previous].block == layout.lines[line].block ? "\n" : "\n\n" }
            text += lines[line]
            previous = line
        }
        return text
    }

    private func updateTextLabel() {
        guard hasControls else { return }
        guard mode == .text, let range = textRange, let layout = textLayout, !layout.isEmpty else {
            textLabel.stringValue = translatedLines != nil ? "Translated on this Mac · select text to copy or listen" :
                "Select text · stays on this Mac"
            return
        }
        let count = range.upper - range.lower + 1
        textLabel.stringValue = count == 1 ? "1 word selected" : "\(count) words selected"
    }

    // MARK: Commands

    func selectAllText() {
        guard mode == .text else { return }
        ensureRecognized { [weak self] in
            guard let self, self.mode == .text, let all = self.textLayout?.all else { return }
            self.textRange = all
            self.textChanged(dragging: false)
        }
    }

    /// Copies the selection, or all text when nothing is selected, keeping its line breaks. The overlay stays open.
    @objc func copyText() {
        guard mode == .text else { return }
        let text = textRange != nil ? selectedText : allShownText
        guard !text.isEmpty else {
            flash("No text to copy")
            return
        }
        let board = Self.pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
        flash(textRange == nil ? "Copied all text" : "Copied")
    }

    func searchSelectedText() {
        let text = (textRange != nil ? selectedText : "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            flash("Select some text to search")
            return
        }
        actions.textCommand(self, .search, text)
    }

    func toggleListen() {
        let speaker = Self.speaker
        if speaker.isSpeaking {
            speaker.stop()
            rebuildChip()
            return
        }
        let text = textRange != nil ? selectedText : allShownText
        let language = translatedLines != nil && !showOriginal ? translateBar.target : TextLanguage.detect(text)
        speaker.onFinish = { [weak self] in self?.rebuildChip() }
        if !speaker.speak(text, language: language) { flash("No text to read aloud") }
        rebuildChip()
    }

    func stopSpeaking() {
        if Self.speaker.isSpeaking { Self.speaker.stop() }
    }

    /// A short message such as "Copied" that fades by itself.
    func flash(_ text: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        notice = text
        updateToast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
            self.updateToast()
        }
    }

    var noticeText: String? { notice }

    // MARK: Action menu

    private func textChanged(dragging: Bool) {
        if textRange != nil {
            hint = nil
            if warning == "No text found on this screen" { warning = nil }
        }
        updateStage()
        updateTextLabel()
        if dragging { actionChip.isHidden = true } else { rebuildChip() }
        updateToast()
    }

    /// Copy, Select all, Listen, Translate and Search, then actions for anything detected in the selection.
    func rebuildChip() {
        guard mode == .text, let layout = textLayout, !layout.isEmpty, !recognizing, textDrag == nil else {
            actionChip.isHidden = true
            return
        }
        let speaking = Self.speaker.isSpeaking
        let translated = translatedLines != nil && !showOriginal
        let listen = ChipButton(speaking ? "Stop" : "Listen", symbol: speaking ? "stop.fill" : "speaker.wave.2") {
            [weak self] in self?.toggleListen()
        }
        let selectAll = ChipButton("Select all", symbol: "selection.pin.in.out") { [weak self] in self?.selectAllText() }
        let translate = ChipButton("Translate", symbol: "translate") { [weak self] in self?.beginTranslation() }
        var main: [ChipButton]
        var quick: [ChipButton] = []
        if let range = textRange {
            let copy = ChipButton("Copy", symbol: "doc.on.doc") { [weak self] in self?.copyText() }
            let search = ChipButton("Search", symbol: "magnifyingglass") { [weak self] in self?.searchSelectedText() }
            main = translated ? [copy, selectAll, listen, search] : [copy, selectAll, listen, translate, search]
            let original = layout.text(for: range)
            for action in DataDetection.actions(for: DataDetection.items(in: original), selectedText: original) {
                quick.append(ChipButton(action.title, symbol: action.symbol) { [weak self] in
                    guard let self else { return }
                    self.actions.quick(self, action)
                })
            }
        } else {
            let copyAll = ChipButton("Copy all text", symbol: "doc.on.doc") { [weak self] in self?.copyText() }
            main = translated || translating ? [copyAll, selectAll, listen] : [copyAll, selectAll, translate]
        }
        actionChip.set(groups: [main, quick])
        actionChip.isHidden = false
        layoutChip()
    }

    /// Next to the selection without covering it or its handles: above, else below, else above the search bar.
    func layoutChip() {
        guard !actionChip.isHidden else { return }
        let size = actionChip.preferredSize
        let gap: CGFloat = 12
        let floor = (hasControls ? barFrame.maxY : 12) + gap + (translateBar.isHidden ? 0 : 54)
        let ceiling = bounds.maxY - topInset - 12 - 34 - gap
        var origin: CGPoint
        if let layout = textLayout, let range = textRange, !layout.isEmpty {
            var covered = selectionRects(range, layout: layout).reduce(CGRect.null) { $0.union($1) }
            if let ends = layout.handlePoints(for: range, canvas: canvas) {
                for point in [ends.start, ends.end] {
                    let knob = TextSurface.knobCenter(point)
                    covered = covered.union(CGRect(x: knob.x - 10, y: knob.y - 10, width: 20, height: 20))
                }
            }
            origin = CGPoint(x: covered.midX - size.width / 2, y: covered.maxY + gap)
            if origin.y + size.height > ceiling {
                origin.y = covered.minY - gap - size.height
                if origin.y < floor {
                    // No room above or below: sit beside the selection rather than on top of it.
                    let y = max(min(covered.midY - size.height / 2, ceiling - size.height), floor)
                    if covered.maxX + gap + size.width <= bounds.maxX - 12 {
                        origin = CGPoint(x: covered.maxX + gap, y: y)
                    } else if covered.minX - gap - size.width >= bounds.minX + 12 {
                        origin = CGPoint(x: covered.minX - gap - size.width, y: y)
                    } else {
                        origin.y = floor
                    }
                }
            }
        } else {
            origin = CGPoint(x: bounds.midX - size.width / 2, y: floor)
        }
        origin.x = min(max(origin.x, bounds.minX + 12), bounds.maxX - 12 - size.width)
        var frame = CGRect(origin: origin, size: size)
        if panelShown, let panel, !panel.isHidden, frame.intersects(panelFrame) {
            frame.origin.x = panelDockedLeft ? panelFrame.maxX + gap : panelFrame.minX - gap - size.width
            frame.origin.x = max(frame.origin.x, bounds.minX + 12)
        }
        actionChip.frame = frame.integral
    }

    // MARK: Mouse

    private func handleHit(at point: CGPoint) -> (fixed: Int, lift: CGFloat)? {
        guard let layout = textLayout, let range = textRange,
              let ends = layout.handlePoints(for: range, canvas: canvas) else { return nil }
        var best: (fixed: Int, lift: CGFloat, distance: CGFloat)?
        for (handle, fixed, moving) in [(ends.start, range.upper, range.lower), (ends.end, range.lower, range.upper)] {
            let knob = TextSurface.knobCenter(handle)
            let distance = hypot(point.x - knob.x, point.y - knob.y)
            guard distance <= 14, best.map({ distance < $0.distance }) ?? true else { continue }
            best = (fixed, layout.view(moving, in: canvas).midY - point.y, distance)
        }
        return best.map { ($0.fixed, $0.lift) }
    }

    func textCursor(at point: CGPoint) -> NSCursor {
        guard let layout = textLayout, !layout.isEmpty else { return .arrow }
        if handleHit(at: point) != nil { return .openHand }
        return layout.index(at: point, canvas: canvas) != nil ? .iBeam : .crosshair
    }

    func textMouseDown(_ event: NSEvent, at point: CGPoint) {
        guard let layout = textLayout, !layout.isEmpty else { return }
        warning = nil
        if let handle = handleHit(at: point) {
            textDrag = .handle(fixed: handle.fixed, lift: handle.lift)
            NSCursor.closedHand.set()
        } else if let index = layout.index(at: point, canvas: canvas) {
            if event.modifierFlags.contains(.shift), let range = textRange {
                textRange = TextRange(anchor: range.anchor, focus: index)
                textDrag = .select(anchor: range.anchor)
            } else if event.clickCount == 2 {
                textRange = layout.lineRange(containing: index)
                textDrag = nil
            } else if event.clickCount >= 3 {
                textRange = layout.blockRange(containing: index)
                textDrag = nil
            } else {
                textRange = TextRange(anchor: index, focus: index)
                textDrag = .select(anchor: index)
            }
        } else {
            // Circling or dragging a box over empty space selects the words inside, as in Search mode.
            textDrag = .ink
            points = [clamp(point, to: bounds)]
            inkLayer.removeAllAnimations()
            inkLayer.opacity = 1
            inkLayer.path = Self.inkPath(points)
        }
        stopSpeaking()
        textChanged(dragging: textDrag != nil)
    }

    func textMouseDragged(_ point: CGPoint) {
        guard let drag = textDrag, let layout = textLayout else { return }
        switch drag {
        case .select(let anchor):
            if let index = layout.nearestIndex(to: point, canvas: canvas) {
                textRange = TextRange(anchor: anchor, focus: index)
            }
        case .handle(let fixed, let lift):
            if let index = layout.nearestIndex(to: CGPoint(x: point.x, y: point.y + lift), canvas: canvas) {
                textRange = TextRange(anchor: fixed, focus: index)
            }
        case .ink:
            points.append(clamp(point, to: bounds))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkLayer.path = Self.inkPath(points)
            CATransaction.commit()
            textRange = layout.range(inside: SelectionEditor.strokeBounds(points, in: bounds), canvas: canvas)
        }
        textChanged(dragging: true)
    }

    func textMouseUp(_ point: CGPoint) {
        guard let drag = textDrag else {
            textChanged(dragging: false)
            return
        }
        textMouseDragged(point)
        textDrag = nil
        if case .ink = drag {
            let stroke = points
            points.removeAll()
            inkLayer.path = nil
            if SelectionEditor.isTap(stroke) { textRange = nil }
        }
        updateCursor(at: point)
        textChanged(dragging: false)
    }

    // MARK: Select text from Search mode

    /// After circling in Search mode, offers "Select text" when the area contains words, as Lens does.
    func updateSelectTextChip() {
        guard mode == .search, selection != nil, !isWhole else {
            hideSelectTextChip()
            return
        }
        ensureRecognized { [weak self] in
            guard let self, self.mode == .search, let layout = self.textLayout, let selection = self.selection,
                  !self.isWhole, self.drag == nil, layout.range(inside: selection, canvas: self.canvas) != nil else {
                self?.hideSelectTextChip()
                return
            }
            self.showSelectTextChip(near: selection)
        }
    }

    private func showSelectTextChip(near selection: CGRect) {
        let button: ChipButton
        if let existing = selectTextButton {
            button = existing
        } else {
            button = ChipButton("Select text", symbol: "text.viewfinder") { [weak self] in self?.selectTextFromSearch() }
            selectTextChip.content.addSubview(button)
            selectTextButton = button
        }
        let size = CGSize(width: button.preferredWidth + 12, height: 36)
        let floor = (hasControls ? barFrame.maxY : 12) + 10
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.minY - 14 - size.height)
        if origin.y < floor { origin.y = max(floor, selection.minY + 14) }
        origin.x = min(max(origin.x, bounds.minX + 12), bounds.maxX - 12 - size.width)
        var frame = CGRect(origin: origin, size: size)
        if panelShown, frame.intersects(panelFrame) {
            frame.origin.x = panelDockedLeft ? panelFrame.maxX + 12 : panelFrame.minX - 12 - size.width
        }
        selectTextChip.frame = frame.integral
        button.frame = NSRect(x: 6, y: 4, width: button.preferredWidth, height: 28)
        selectTextChip.isHidden = false
    }

    func hideSelectTextChip() { selectTextChip.isHidden = true }

    /// Switches to Text mode with the circled words already selected.
    @objc func selectTextFromSearch() {
        guard let layout = textLayout, let selection else { return }
        setMode(.text, range: layout.range(inside: selection, canvas: canvas))
    }

    // MARK: Translation

    var translateBarFrame: CGRect {
        let width = min(TranslateBar.preferredWidth, bounds.width - 48)
        let y = (hasControls ? barFrame.maxY : 12) + 10
        return CGRect(x: (bounds.midX - width / 2).rounded(), y: y, width: width, height: 44)
    }

    /// Translates the text on this screen in place, like Lens's Translate: on this Mac when Apple's translation is
    /// available, otherwise through Google Translate after consent.
    func beginTranslation() {
        if mode != .text { setMode(.text) }
        translateBar.isHidden = false
        translateBar.frame = translateBarFrame
        ensureRecognized { [weak self] in
            guard let self, self.mode == .text else { return }
            guard let layout = self.textLayout, !layout.isEmpty else {
                self.translateBar.isHidden = true
                self.flash("No text to translate on this screen")
                return
            }
            self.requestTranslation()
        }
    }

    /// The paragraphs on screen, each as flowing text, sent with the languages chosen in the translate bar.
    func requestTranslation() {
        guard let layout = textLayout, !layout.isEmpty else { return }
        let blocks = layout.blocks.map { block in
            layout.text(for: TextRange(anchor: layout.lines[block.lowerBound].words.lowerBound,
                                       focus: layout.lines[block.upperBound - 1].words.upperBound - 1), flowing: true)
        }
        let text = textRange.map { layout.text(for: $0) } ?? layout.allText
        noticeGeneration += 1
        notice = nil
        translating = true
        updateToast()
        rebuildChip()
        actions.translate(self, TranslationRequest(blocks: blocks, source: translateBar.source,
                                                   target: translateBar.target, text: text))
    }

    /// Draws one translated paragraph per recognized block over its original lines, on the sampled page colour.
    func applyTranslation(blocks translated: [String]) {
        guard let layout = textLayout, translated.count == layout.blocks.count else {
            translationFailed("The translation didn't match the text on screen.")
            return
        }
        var lines = Array(repeating: "", count: layout.lines.count)
        for (blockIndex, block) in layout.blocks.enumerated() {
            let lengths = block.map { lineIndex in
                layout.lines[lineIndex].words.reduce(0) { $0 + layout.words[$1].text.count + 1 }
            }
            let parts = TranslationLayout.distribute(translated[blockIndex], across: lengths)
            for (offset, lineIndex) in block.enumerated() where offset < parts.count { lines[lineIndex] = parts[offset] }
        }
        translatedLines = lines
        translating = false
        showOriginal = false
        translateBar.originalToggle.state = .off
        translateBar.isHidden = false
        textSurface.translation.contents = renderTranslation(lines, layout: layout)
        updateStage()
        updateTextLabel()
        rebuildChip()
        updateToast()
    }

    func translationFailed(_ message: String?) {
        translating = false
        if translatedLines == nil { translateBar.isHidden = true }
        if let message { warning = message }
        updateToast()
        rebuildChip()
        needsLayout = true
    }

    func setShowOriginal(_ on: Bool) {
        showOriginal = on
        translateBar.originalToggle.state = on ? .on : .off
        updateStage()
        rebuildChip()
    }

    func endTranslation() {
        translatedLines = nil
        translating = false
        showOriginal = false
        textSurface.translation.contents = nil
        translateBar.originalToggle.state = .off
        translateBar.isHidden = true
        updateStage()
        updateTextLabel()
        rebuildChip()
        updateToast()
        needsLayout = true
    }

    /// The translation drawn at the screenshot's pixel size: each line's box filled with the colour behind it and the
    /// translated words fitted to the box, in black or white for contrast.
    private func renderTranslation(_ lines: [String], layout: TextLayout) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, line) in layout.lines.enumerated() {
            let unit = line.box
            let rect = CGRect(x: unit.minX * CGFloat(width), y: unit.minY * CGFloat(height),
                              width: unit.width * CGFloat(width), height: unit.height * CGFloat(height))
                .insetBy(dx: -3, dy: -2)
            let sampled = SelectionEditor.pixels(forUnit: unit, width: width, height: height)
                .flatMap { ImageSampling.background(of: image, pixels: $0.insetBy(dx: -3, dy: -2)) }
            context.setFillColor((sampled?.color ?? .white).cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            let text = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = rect.insetBy(dx: 2, dy: 1)
            let size = TextFit.size(for: text, in: box.size, weight: .medium)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = TextScript.isRightToLeft(text) ? .right : .left
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: sampled?.isLight == false ? NSColor.white : NSColor.black,
                .paragraphStyle: style
            ])
            let measured = string.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin])
            string.draw(with: CGRect(x: box.minX, y: box.midY - measured.height / 2, width: box.width,
                                     height: measured.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        return context.makeImage()
    }
}

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
    /// The text selection settled; `search` asks for a Google search of exactly that text.
    var textChanged: (OverlayView, String, Bool) -> Void = { _, _, _ in }
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
            overlay.selectWholeScreen()
            return true
        case "c" where firstResponder is OverlayView && (overlay.hasTextSelection || overlay.translatedLines != nil):
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
/// ink for circling, a Google-gradient frame for the selection, and (on the active display) the floating controls.
/// Text and visual search share it: the screen's words are recognized on this Mac as soon as it opens, so a press on a
/// word, a highlight along a line or a circle around text selects text, and anything else searches what was chosen.
final class OverlayView: NSView {
    /// Turned off by the offscreen checks so geometry is final immediately.
    static var animates = true

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    let image: CGImage
    let displayIndex: Int
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
    let frameLayer = LensFrameLayer()
    let textSurface = TextSurface()
    static let dimAlpha: CGFloat = 0.35

    // Floating controls.
    let bar = FloatingCard(radius: 26)
    let field = NSTextField(string: "")
    let lensButton = NSButton()
    let translateCard = FloatingCard(radius: 26)
    let translateButton = NSButton()
    let closeCard = FloatingCard(radius: 18)
    let closeButton = NSButton()
    let toast = Toast()
    let actionChip = ActionChip()
    let translateBar = TranslateBar()
    let selectTextChip = FloatingCard(radius: 18)
    private(set) var selectTextButton: ChipButton?

    // Text. The checks swap these for a private pasteboard, a silent speaker and their own settings.
    static var defaults = UserDefaults.standard
    static var pasteboard = NSPasteboard.general
    static var speaker: Speaker = SystemSpeaker()
    static var recognizer: @Sendable (CGImage) throws -> [RecognizedLine] = { try OCR.recognizeWords($0) }
    private(set) var textLayout: TextLayout?
    private(set) var textRange: TextRange?
    private(set) var recognizing = false
    private var recognitionWaiters: [() -> Void] = []
    private enum TextDrag { case select(anchor: Int), handle(fixed: Int, lift: CGFloat), line(anchor: Int) }
    private var textDrag: TextDrag?
    private(set) var translatedLines: [String]?
    private(set) var showOriginal = false
    private(set) var translating = false
    private var notice: String?
    /// The user is waiting for the recognized text (select all, translate), so "Finding text…" is shown.
    private var textWanted = false
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
    /// How the stroke being drawn reads; once it bends it stays freehand ink for the rest of the drag.
    private var drawShape = SelectionEditor.DrawShape.undecided
    private var tapGeneration = 0
    private var warning: String?
    private var activity: String?
    private var hint: String?
    private var busy = false
    private var tracking: NSTrackingArea?

    static let hintText = "Circle, highlight or tap to search"
    static let wholeScreenHint = "Press Return to search the whole screen"

    /// The overlay opens with nothing selected, so nothing is searched until a gesture picks an area.
    /// `selectingAllText` selects every recognized word once the text is read, as the Select text shortcut does.
    init(frame: NSRect, image: CGImage, displayIndex: Int, topInset: CGFloat = 0, controls: Bool,
         selectingAllText: Bool = false, actions: OverlayActions) {
        self.image = image
        self.displayIndex = displayIndex
        self.topInset = max(0, topInset)
        self.actions = actions
        hasControls = controls
        panel = controls ? ResultsPanel(frame: .zero) : nil
        area = .none
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        panelWidth = PanelSizing.width(stored: Self.defaults.object(forKey: PanelSizing.defaultsKey) as? Double,
                                       screenWidth: frame.width)
        buildStage()
        if controls { buildControls() }
        buildTextControls()
        addSubview(toast)
        if controls { hint = Self.hintText }
        updateToast()
        updateStage()
        // Words are found on this Mac straight away, so presses can tell text from pictures; nothing is uploaded.
        if selectingAllText { selectAllText() } else { ensureRecognized {} }
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
        root.addSublayer(frameLayer)
        for layer in root.sublayers ?? [] where layer !== frameLayer { layer.actions = Self.noActions }
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
        imageButton(button, image?.withSymbolConfiguration(.init(pointSize: size, weight: weight)), tint: tint,
                    label: label, action: action)
    }

    private func imageButton(_ button: NSButton, _ image: NSImage?, tint: NSColor = .labelColor, label: String,
                             action: Selector) {
        button.image = image
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
        imageButton(lensButton, LensMark.image(size: 28), tint: googleBlue, label: "Search the selection now (Return)",
                    action: #selector(lensPressed))
        lensButton.imageScaling = .scaleNone
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
        for view in [lensButton, field] { bar.content.addSubview(view) }
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
            // Parked offscreen rather than hidden, so a page loading behind it is laid out at its real size.
            panel.alphaValue = 0
            panel.onHide = { [weak self] in self?.hidePanel(byUser: true) }
            panel.onExpand = { [weak self] in self?.togglePanelExpanded() }
            panel.onResize = { [weak self] width, finished in self?.resizePanel(to: width, finished: finished) }
            panel.onMove = { [weak self] dx, finished in self?.movePanel(by: dx, finished: finished) }
            addSubview(panel)
        }
    }

    /// Text works on every display, so its menus are built even where the search bar is not.
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
    /// True while the selection is the whole visible screen (Command-A), drawn as brackets with no dimming.
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
    /// The corner brackets currently drawn around the selection or the box being dragged, if any.
    var framedRect: CGRect? { frameLayer.rect }
    var hasTextSelection: Bool { textRange != nil }
    /// The glowing ink stroke currently drawn and visible, if any.
    var inkBounds: CGRect? {
        inkLayer.opacity > 0 ? inkLayer.path.flatMap { $0.isEmpty ? nil : $0.boundingBoxOfPath } : nil
    }
    var toastText: String { toast.label.stringValue }
    var refinement: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Layout

    override func layout() {
        super.layout()
        if hasControls {
            bar.frame = barFrame
            let size = barFrame.size
            lensButton.frame = NSRect(x: 8, y: (size.height - 40) / 2, width: 40, height: 40)
            field.frame = NSRect(x: 56, y: (size.height - 22) / 2, width: size.width - 56 - 16, height: 22)
            translateCard.frame = translateFrame
            translateButton.frame = translateCard.bounds
            closeCard.frame = closeFrame
            closeButton.frame = closeCard.bounds
            layoutToast()
            if panel != nil, !panelAnimating, panelDragX == nil { setPanelFrame(panelShown ? panelFrame : hiddenPanelFrame) }
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
        // A text selection shows its own highlight instead of the frame.
        let visual = textRange == nil
        frameLayer.frame = bounds
        if visual, let selection, !isWhole, drag != .draw {
            let path = CGMutablePath()
            path.addPath(full)
            path.addPath(Self.roundedPath(selection))
            dimLayer.path = path
            dimLayer.isHidden = false
        } else {
            dimLayer.isHidden = true
        }
        // A box being dragged is framed live; a circle or scribble shows only its ink until it is released.
        if visual, drag == .draw {
            if drawShape == .box, points.count > 1 {
                frameLayer.show(SelectionEditor.strokeBounds(points, in: bounds))
            } else {
                frameLayer.hide()
            }
        } else if visual, let frame = bracketFrame {
            frameLayer.show(frame)
        } else {
            frameLayer.hide()
        }
        updateTextSurface()
        CATransaction.commit()
    }

    static func bracketPath(_ rect: CGRect) -> CGPath { LensFrameLayer.bracketPath(rect) }
    static func roundedPath(_ rect: CGRect) -> CGPath { LensFrameLayer.roundedPath(rect) }

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
        if let frame = bracketFrame, frameLayer.rect != nil {
            frameLayer.animateBrackets(from: frame.insetBy(dx: 26, dy: 26), duration: 0.45)
        }
    }

    /// Ink fades and the selection appears framed, like Android's circle morphing into the selected area. A dragged
    /// box was framed all along, so its brackets stay put.
    private func morph(from rect: CGRect, boxed: Bool = false) {
        updateStage()
        if boxed { inkLayer.path = nil } else { fadeInk() }
        guard !reduceMotion, bracketFrame != nil else { return }
        CATransaction.begin()
        if !boxed, frameLayer.rect != nil {
            frameLayer.animateBrackets(from: rect.insetBy(dx: -14, dy: -14), duration: 0.22)
        }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.18
        dimLayer.add(appear, forKey: "appear")
        CATransaction.commit()
    }

    /// The frame breathes while the selection is being uploaded.
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
            frameLayer.add(pulse, forKey: "pulse")
        } else {
            frameLayer.removeAnimation(forKey: "pulse")
        }
    }

    private func animate(_ duration: TimeInterval, implicit: Bool = true, _ changes: @escaping () -> Void,
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
            context.allowsImplicitAnimation = implicit
            changes()
        }, completionHandler: completion)
    }

    /// Resizes the sheet at once and lays it out, so the results page is never stretched by an animation.
    private func setPanelFrame(_ frame: CGRect) {
        guard let panel, panel.frame != frame else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.frame = frame
        panel.layoutSubtreeIfNeeded()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    /// Slides the sheet to `frame`: its size changes at once and only its position animates.
    private func slidePanel(to frame: CGRect, duration: TimeInterval, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        if panel.frame.size != frame.size {
            setPanelFrame(CGRect(origin: CGPoint(x: panel.frame.minX, y: frame.minY), size: frame.size))
        }
        panelAnimating = true
        animate(duration, implicit: false, { panel.animator().setFrameOrigin(frame.origin) }) { [weak self] in
            self?.panelAnimating = false
            completion?()
            self?.needsLayout = true
        }
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
        setPanelFrame(reduceMotion ? panelFrame : hiddenPanelFrame)
        panel.alphaValue = 1
        slidePanel(to: panelFrame, duration: 0.28)
    }

    func hidePanel(byUser: Bool = false) {
        guard let panel, panelShown else { return }
        panelShown = false
        slidePanel(to: hiddenPanelFrame, duration: 0.24) { [weak self] in
            if self?.panelShown == false { panel.alphaValue = 0 }
        }
        if byUser { actions.panelVisibility(self, false) }
    }

    private func togglePanelExpanded() {
        panelExpanded.toggle()
        panel?.expanded = panelExpanded
        guard let panel, panelShown else { return }
        // The sheet's frame steps through the animation; its page is placed at each step without a layer animation.
        panelAnimating = true
        animate(0.22, implicit: false, { panel.animator().frame = self.panelFrame }) { [weak self] in
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
        guard panel != nil, panelShown else { return }
        slidePanel(to: panelFrame, duration: 0.22)
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
            self.panel?.animator().alphaValue = dragging ? 0.25 : (self.panelShown ? 1 : 0)
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
        let working = recognizing && textWanted ? "Finding text…" : translating ? "Translating…" : nil
        let text = warning ?? notice ?? working ?? activity ?? hint
        toast.set(text, warning: warning != nil,
                  busy: warning == nil && notice == nil && (working != nil || activity != nil))
        layoutToast()
        animate(0.2, { self.toast.animator().alphaValue = text == nil ? 0 : 1 })
    }

    // MARK: Commands

    func clearSelection() {
        clearTextSelection()
        hideSelectTextChip()
        guard area != .none else { return }
        area = .none
        updateStage()
    }

    /// Selects everything on this screen (Command-A), resetting zoom. Nothing is sent: the whole screen is searched
    /// only when the user presses Return or the Lens button.
    @objc func selectWholeScreen() {
        clearTextSelection()
        hideSelectTextChip()
        actions.began(self)
        actions.panelVisibility(self, false)
        viewport.reset()
        area = .screen
        warning = nil
        hint = hasControls ? Self.wholeScreenHint : nil
        updateToast()
        updateStage()
        updateSelectTextChip()
    }

    @objc func searchNow() {
        hint = nil
        updateToast()
        actions.changed(self, true)
    }

    @objc private func lensPressed() {
        if textRange != nil {
            searchSelectedText()
        } else if !hasSelection, !refinement.isEmpty {
            fieldSubmitted()
        } else {
            searchNow()
        }
    }
    /// Translate draws the translation over the recognized text in place, like Lens.
    @objc func translate() { beginTranslation() }
    @objc func cancelOverlay() { actions.cancel() }

    /// Return in the search bar refines the visual search with the typed words (multisearch), or searches the
    /// selected text together with them.
    @objc func fieldSubmitted() {
        hint = nil
        updateToast()
        window?.makeFirstResponder(self)
        if textRange != nil {
            let text = [selectedText, refinement].filter { !$0.isEmpty }.joined(separator: " ")
            if !text.isEmpty { actions.textCommand(self, .search, text) }
            return
        }
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

    func updateCursor(at point: CGPoint) {
        guard drag == nil, textDrag == nil else { return }
        if let hit = hitTest(convert(point, to: superview)), hit !== self { return }
        cursor(at: point).set()
    }

    /// An I-beam over recognized words, an open hand over text handles, otherwise the area's crosshair or grip.
    func cursor(at point: CGPoint) -> NSCursor {
        switch pressTarget(at: point) {
        case .handle: return .openHand
        case .text: return .iBeam
        case .region(let target): return cursor(for: target)
        }
    }

    /// What a press does, in this order: drag a text handle, resize a partial selection at its edges, select the word
    /// under it, or draw, move or resize the area.
    private enum PressTarget {
        case handle(fixed: Int, lift: CGFloat)
        case text(GestureClassifier.Press)
        case region(SelectionDrag)
    }

    private func pressTarget(at point: CGPoint, clickCount: Int = 1, shift: Bool = false) -> PressTarget {
        if textRange != nil, let handle = handleHit(at: point) { return .handle(fixed: handle.fixed, lift: handle.lift) }
        let region = textRange == nil ? target(at: point) : .draw
        if case .resize = region, !isWhole { return .region(region) }
        let press = GestureClassifier.press(at: point, layout: textLayout, canvas: canvas, clickCount: clickCount,
                                            shift: shift, current: textRange)
        return press == .visual ? .region(region) : .text(press)
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
        hideSelectTextChip()
        warning = nil
        hint = nil
        tapGeneration += 1
        stopSpeaking()
        startArea = area
        actions.began(self)
        switch pressTarget(at: point, clickCount: event.clickCount, shift: event.modifierFlags.contains(.shift)) {
        case .handle(let fixed, let lift):
            textDrag = .handle(fixed: fixed, lift: lift)
            NSCursor.closedHand.set()
            textChanged(dragging: true)
        case .text(let press):
            beginText(press, at: point)
        case .region(let target):
            beginRegion(target, at: point)
        }
    }

    /// A press on a word selects it and may go on to highlight along its line; double and triple clicks select the
    /// line and the paragraph, and Shift-click extends the selection.
    private func beginText(_ press: GestureClassifier.Press, at point: CGPoint) {
        switch press {
        case .word(let index):
            textRange = TextRange(anchor: index, focus: index)
            textDrag = .line(anchor: index)
            points = [clamp(point, to: bounds)]
        case .range(let range):
            textRange = range
            textDrag = nil
        case .extend(let range):
            textRange = range
            textDrag = .select(anchor: range.anchor)
        case .visual:
            return
        }
        textChanged(dragging: textDrag != nil)
    }

    /// A press off text leaves text selection and draws, moves or resizes the area to search.
    private func beginRegion(_ target: SelectionDrag, at point: CGPoint) {
        clearTextSelection()
        drag = target
        dragStart = point
        dragStartRect = isWhole ? bounds : selection ?? .null
        updateToast()
        if target == .move { NSCursor.closedHand.set() }
        if target == .draw {
            points = [clamp(point, to: bounds)]
            drawShape = .undecided
            inkLayer.removeAllAnimations()
            inkLayer.opacity = 1
            inkLayer.path = Self.inkPath(points)
        }
        setDragging(true)
        updateStage()
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        if let textDrag {
            dragText(textDrag, to: raw)
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
            if drawShape != .freehand { drawShape = SelectionEditor.drawShape(points) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkLayer.path = Self.inkPath(points)
            inkLayer.opacity = drawShape == .box ? 0 : 1
            CATransaction.commit()
            updateStage()
        }
    }

    private func dragText(_ textDrag: TextDrag, to point: CGPoint) {
        guard let layout = textLayout else { return }
        switch textDrag {
        case .select(let anchor):
            if let index = layout.nearestIndex(to: point, canvas: canvas) {
                textRange = TextRange(anchor: anchor, focus: index)
            }
        case .handle(let fixed, let lift):
            if let index = layout.nearestIndex(to: CGPoint(x: point.x, y: point.y + lift), canvas: canvas) {
                textRange = TextRange(anchor: fixed, focus: index)
            }
        case .line(let anchor):
            points.append(clamp(point, to: bounds))
            guard let range = GestureClassifier.lineDrag(from: anchor, to: point, layout: layout, canvas: canvas),
                  !GestureClassifier.encircles(points, anchor: anchor, layout: layout, canvas: canvas) else {
                becomeInk()
                return
            }
            textRange = range
        }
        textChanged(dragging: true)
    }

    /// A press that began on a word and left its line is circling instead: the stroke so far becomes ink.
    private func becomeInk() {
        let stroke = points
        clearTextSelection()
        points = stroke
        drag = .draw
        drawShape = SelectionEditor.drawShape(points)
        dragStart = stroke.first ?? .zero
        dragStartRect = isWhole ? bounds : selection ?? .null
        inkLayer.removeAllAnimations()
        inkLayer.opacity = drawShape == .box ? 0 : 1
        inkLayer.path = Self.inkPath(points)
        setDragging(true)
        updateStage()
    }

    private func setRect(_ rect: CGRect) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        area = .unit(SelectionEditor.unit(rect, in: canvas))
        updateStage()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let textDrag {
            dragText(textDrag, to: point)
            if self.textDrag != nil {
                self.textDrag = nil
                points.removeAll()
                updateCursor(at: point)
                textSettled()
                return
            }
        } else if drag == nil {
            // A double or triple click selected a line or paragraph.
            if textRange != nil { textSettled() }
            return
        }
        guard let finished = drag else { return }
        if finished != .draw { mouseDragged(with: event) } else { points.append(clamp(point, to: bounds)) }
        drag = nil
        setDragging(false)
        defer { updateCursor(at: point) }
        guard finished == .draw else {
            if !Selection.isUsable(selection) { area = startArea }
            normalizeWhole()
            updateStage()
            keepSelectionVisible()
            if area != startArea { actions.changed(self, false) }
            updateSelectTextChip()
            return
        }
        let stroke = points
        points.removeAll()
        if SelectionEditor.isTap(stroke) {
            selectTapped(at: stroke[0])
            return
        }
        // A highlight or underline along a line of text selects its words, as Lens does.
        if let layout = textLayout, let range = GestureClassifier.lineStroke(stroke, layout: layout, canvas: canvas) {
            area = startArea
            textRange = range
            fadeInk()
            updateStage()
            textSettled()
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
        morph(from: rect, boxed: drawShape == .box)
        normalizeWhole()
        updateStage()
        keepSelectionVisible()
        classifyRegion()
    }

    /// Whether a circled, scribbled or dragged area is text or a picture, decided on this Mac from the recognized words,
    /// the area's ink and Vision's salient objects: text is selected and searched as text, anything else is searched
    /// visually, offering "Select text" when it contains words. Until the screen's text is read, areas are visual.
    private func classifyRegion() {
        guard let unit, !isWhole, let selection, let layout = textLayout, !layout.isEmpty,
              layout.range(inside: selection, canvas: canvas) != nil else {
            actions.changed(self, false)
            updateSelectTextChip()
            return
        }
        let generation = tapGeneration
        let image = self.image
        let finish: (GestureClassifier.Region) -> Void = { [weak self] verdict in
            self?.applyRegion(verdict, generation: generation, unit: unit)
        }
        Task.detached(priority: .userInitiated) {
            let ink = InkMap(image: image, area: unit)
            var objects: [CGRect] = []
            if let pixels = SelectionEditor.pixels(forUnit: unit, width: image.width, height: image.height),
               let crop = image.cropping(to: pixels) {
                objects = ((try? OCR.salientObjects(crop)) ?? []).map {
                    SelectionEditor.unit(forNormalized: $0, inPixels: pixels, width: image.width, height: image.height)
                }
            }
            let verdict = GestureClassifier.region(unit: unit, layout: layout, ink: ink, objects: objects)
            await MainActor.run { finish(verdict) }
        }
    }

    private func applyRegion(_ verdict: GestureClassifier.Region, generation: Int, unit: CGRect) {
        guard generation == tapGeneration, drag == nil, textDrag == nil, textRange == nil, self.unit == unit else { return }
        switch verdict {
        case .text(let range):
            textRange = range
            updateStage()
            textSettled()
        case .visual:
            actions.changed(self, false)
            updateSelectTextChip()
        }
    }

    /// The ink fades out where it was drawn.
    private func fadeInk() {
        guard !reduceMotion, inkLayer.opacity > 0 else {
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
        CATransaction.commit()
    }

    /// A selection dragged out to the screen edges becomes the whole-screen selection.
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
        switch event.keyCode {
        case 53: actions.cancel()
        case 36, 76: lensPressed()
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

// MARK: - Text

/// Selecting text on the frozen screen in the same view as visual search, as Lens does: every word is recognized with
/// Apple Vision on this Mac when the overlay opens, then selected by clicking, highlighting or circling it, with
/// Android-style handles and a floating action menu. Recognition never uploads anything; only text the user selects
/// is searched (when visual search is allowed) or sent for translation.
extension OverlayView {
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
            if textWanted { warning = "Couldn't read text on this screen: \(error.localizedDescription)" }
        }
        let waiters = recognitionWaiters
        recognitionWaiters.removeAll()
        waiters.forEach { $0() }
        textWanted = false
        updateToast()
        updateStage()
        shimmerWords()
        updateSelectTextChip()
        if let window, window.isKeyWindow {
            updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    // MARK: Drawing

    func updateTextSurface() {
        let surface = textSurface
        surface.frame = bounds
        let canvas = self.canvas
        let layout = textLayout ?? .empty
        let translated = translatedLines != nil && !showOriginal
        surface.translation.frame = canvas
        surface.translation.isHidden = !translated || surface.translation.contents == nil
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

    /// The found words light up once and fade, so it's clear the screen's text can be selected; they are not marked
    /// permanently.
    private func shimmerWords() {
        guard !reduceMotion, textLayout?.isEmpty == false else { return }
        let shimmer = CAKeyframeAnimation(keyPath: "opacity")
        shimmer.values = [0, 0.9, 0]
        shimmer.keyTimes = [0, 0.35, 1]
        shimmer.duration = 0.9
        textSurface.words.add(shimmer, forKey: "shimmer")
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

    // MARK: Commands

    /// Selects every word on this screen, waiting for them to be recognized; nothing is searched.
    func selectAllText() {
        textWanted = true
        updateToast()
        ensureRecognized { [weak self] in
            guard let self, self.drag == nil else { return }
            guard let all = self.textLayout?.all else {
                self.flash("No text found on this screen")
                return
            }
            self.textDrag = nil
            self.textRange = all
            self.hideSelectTextChip()
            self.textChanged(dragging: false)
            self.actions.textChanged(self, self.selectedText, false)
        }
    }

    /// Leaves text selection for visual search.
    func clearTextSelection() {
        guard textRange != nil || textDrag != nil else { return }
        textRange = nil
        textDrag = nil
        stopSpeaking()
        rebuildChip()
        updateStage()
    }

    /// The text selection is final: its menu appears and its words are searched.
    private func textSettled() {
        hideSelectTextChip()
        textChanged(dragging: false)
        actions.textChanged(self, selectedText, true)
    }

    /// Copies the selection, or all text when nothing is selected, keeping its line breaks. The overlay stays open.
    @objc func copyText() {
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
        if dragging { actionChip.isHidden = true } else { rebuildChip() }
        updateToast()
    }

    /// Copy, Select all, Listen, Translate and Search, then actions for anything detected in the selection.
    func rebuildChip() {
        guard let layout = textLayout, !layout.isEmpty, !recognizing, textDrag == nil,
              textRange != nil || translatedLines != nil || translating else {
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
        if panelShown, let panel, panel.alphaValue > 0, frame.intersects(panelFrame) {
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

    // MARK: Select text from a visual search

    /// Offers the words of a visually searched area, as Lens does when its picture search wins: "Select text" for a
    /// circled area, "Select all text" for the whole screen. Hidden while text is selected or translated.
    func updateSelectTextChip() {
        guard textRange == nil, textDrag == nil, drag == nil, translatedLines == nil, !translating,
              let selection, let layout = textLayout,
              (isWhole ? layout.all : layout.range(inside: selection, canvas: canvas)) != nil else {
            hideSelectTextChip()
            return
        }
        showSelectTextChip(near: selection)
    }

    private func showSelectTextChip(near selection: CGRect) {
        let title = isWhole ? "Select all text" : "Select text"
        let button: ChipButton
        if let existing = selectTextButton, existing.title == title {
            button = existing
        } else {
            selectTextButton?.removeFromSuperview()
            button = ChipButton(title, symbol: "text.viewfinder") { [weak self] in self?.selectTextFromSearch() }
            selectTextChip.content.addSubview(button)
            selectTextButton = button
        }
        let size = CGSize(width: button.preferredWidth + 12, height: 36)
        let floor = (hasControls ? barFrame.maxY : 12) + 10
        var origin: CGPoint
        if isWhole {
            origin = CGPoint(x: bounds.midX - size.width / 2, y: floor)
        } else {
            origin = CGPoint(x: selection.midX - size.width / 2, y: selection.minY - 14 - size.height)
            if origin.y < floor { origin.y = max(floor, selection.minY + 14) }
        }
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

    /// Selects the words of the searched area: a circled area's words are searched as text, all text is not.
    @objc func selectTextFromSearch() {
        guard let layout = textLayout, let selection else { return }
        if isWhole {
            selectAllText()
            return
        }
        guard let range = layout.range(inside: selection, canvas: canvas) else { return }
        actions.began(self)
        textRange = range
        updateStage()
        textSettled()
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
        hideSelectTextChip()
        // The whole screen is translated, so a circled area gives way to the whole-screen frame.
        if case .unit = area, textRange == nil {
            area = .screen
            updateStage()
        }
        textWanted = true
        translateBar.isHidden = false
        translateBar.frame = translateBarFrame
        updateToast()
        ensureRecognized { [weak self] in
            guard let self else { return }
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
        rebuildChip()
        updateToast()
    }

    func translationFailed(_ message: String?) {
        translating = false
        if translatedLines == nil {
            translateBar.isHidden = true
            updateSelectTextChip()
        }
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
        rebuildChip()
        updateSelectTextChip()
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

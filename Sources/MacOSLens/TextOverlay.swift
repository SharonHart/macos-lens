import AppKit
import AVFoundation
import LensCore
import QuartzCore

/// LensCore's word range; the SDK also declares a `TextRange`.
typealias TextRange = LensCore.TextRange

let googleBlue = NSColor(srgbRed: 0.259, green: 0.522, blue: 0.957, alpha: 1)

private let quietActions: [String: CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "contents": NSNull(),
    "opacity": NSNull(), "hidden": NSNull(), "transform": NSNull(), "fillColor": NSNull()
]

private func srgb(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The selection framed the way Lens frames its preview: a rounded rectangle with a thin Google four-colour conic
/// gradient stroke and a soft outer glow in the same colours, gradient corner brackets and edge grips for resizing,
/// all over a thin dark halo so the frame stays visible on white pages.
final class LensFrameLayer: CALayer {
    static let googleHexes = [0x4285F4, 0xEA4335, 0xFBBC05, 0x34A853]
    static let cornerRadius: CGFloat = 14
    static let lineWidth: CGFloat = 3
    static let markWidth: CGFloat = 6
    static let haloWidth: CGFloat = 3
    /// Seconds per turn of the gradient.
    static let turn: CFTimeInterval = 6
    private static let rings: [(width: CGFloat, alpha: CGFloat)] = [(20, 0.10), (12, 0.16), (6, 0.30)]
    private static let margin: CGFloat = 30

    private let haloBorder = CAShapeLayer()
    private let haloBrackets = CAShapeLayer()
    private let haloGrips = CAShapeLayer()
    private let glow = CAGradientLayer()
    private let glowMask = CALayer()
    private let glowRings = rings.map { _ in CAShapeLayer() }
    private let gradient = CAGradientLayer()
    private let lineMask = CALayer()
    private let border = CAShapeLayer()
    private let brackets = CAShapeLayer()
    private let grips = CAShapeLayer()
    private var origin = CGPoint.zero

    /// The framed rectangle, nil while hidden.
    private(set) var rect: CGRect?
    /// True when the continuous border, its glow and the edge grips are drawn, as for a partial selection.
    private(set) var isFull = false
    /// The gradient turns slowly unless Reduce Motion is on.
    var spins = true {
        didSet { updateSpin() }
    }
    var isSpinning: Bool { gradient.animation(forKey: "spin") != nil }

    override init() {
        super.init()
        let colors = (Self.googleHexes + [Self.googleHexes[0]]).map(srgb)
        glow.mask = glowMask
        for ring in glowRings {
            ring.fillColor = nil
            glowMask.addSublayer(ring)
        }
        for layer in [haloBorder, haloBrackets, haloGrips, border, brackets, grips] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
        }
        for (layer, width) in [(haloBorder, Self.lineWidth), (haloBrackets, Self.markWidth),
                               (haloGrips, Self.markWidth)] {
            layer.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
            layer.lineWidth = width + 2 * Self.haloWidth
        }
        for (layer, width) in [(border, Self.lineWidth), (brackets, Self.markWidth), (grips, Self.markWidth)] {
            layer.strokeColor = NSColor.black.cgColor
            layer.lineWidth = width
            lineMask.addSublayer(layer)
        }
        gradient.mask = lineMask
        for layer in [glow, gradient] {
            layer.type = .conic
            layer.colors = colors
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 0.5, y: 0)
        }
        for layer in [glow, haloBorder, haloBrackets, haloGrips, gradient] { addSublayer(layer) }
        for layer in [self, glow, glowMask, gradient, lineMask, haloBorder, haloBrackets, haloGrips, border, brackets,
                      grips] + glowRings {
            layer.actions = quietActions
        }
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Frames `rect`; `full` adds the continuous border, its glow and the edge grips.
    func show(_ rect: CGRect, full: Bool) {
        let frame = rect.insetBy(dx: -Self.margin, dy: -Self.margin)
        self.rect = rect
        isFull = full
        origin = frame.origin
        for layer in [glow, gradient] { layer.frame = frame }
        for mask in [glowMask, lineMask] { mask.frame = CGRect(origin: .zero, size: frame.size) }
        for layer in glowRings + [border, brackets, grips] { layer.frame = glowMask.bounds }
        for layer in [haloBorder, haloBrackets, haloGrips] { layer.frame = bounds }
        let outline = full ? Self.roundedPath(rect) : nil
        let bracketPath = Self.bracketPath(rect)
        let gripPath = full ? Self.gripPath(rect) : nil
        haloBorder.path = outline
        haloBrackets.path = bracketPath
        haloGrips.path = gripPath
        border.path = local(outline)
        brackets.path = local(bracketPath)
        grips.path = local(gripPath)
        for (ring, spec) in zip(glowRings, Self.rings) {
            ring.lineWidth = spec.width
            ring.strokeColor = NSColor.white.withAlphaComponent(spec.alpha).cgColor
            ring.path = full ? local(Self.roundedPath(rect.insetBy(dx: -spec.width / 2, dy: -spec.width / 2),
                                                      radius: Self.radius(for: rect) + spec.width / 2)) : nil
        }
        glow.isHidden = !full
        isHidden = false
        updateSpin()
    }

    func hide() {
        isHidden = true
        rect = nil
        isFull = false
        updateSpin()
    }

    /// The brackets grow from `from` to the current frame, as the circle morphs into the selection.
    func animateBrackets(from: CGRect, duration: CFTimeInterval) {
        guard let rect else { return }
        for (layer, transform) in [(haloBrackets, false), (brackets, true)] {
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = transform ? local(Self.bracketPath(from)) : Self.bracketPath(from)
            grow.toValue = transform ? local(Self.bracketPath(rect)) : Self.bracketPath(rect)
            grow.duration = duration
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(grow, forKey: "grow")
        }
    }

    private func local(_ path: CGPath?) -> CGPath? {
        guard let path else { return nil }
        var transform = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        return path.copy(using: &transform)
    }

    private func updateSpin() {
        let wanted = spins && !isHidden
        guard wanted != isSpinning else { return }
        guard wanted else {
            gradient.removeAnimation(forKey: "spin")
            glow.removeAnimation(forKey: "spin")
            return
        }
        let steps = 48
        let spin = CAKeyframeAnimation(keyPath: "endPoint")
        spin.values = (0...steps).map { step -> NSValue in
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            return NSValue(point: NSPoint(x: 0.5 + 0.5 * sin(angle), y: 0.5 - 0.5 * cos(angle)))
        }
        spin.duration = Self.turn
        spin.repeatCount = .infinity
        spin.calculationMode = .linear
        gradient.add(spin, forKey: "spin")
        glow.add(spin, forKey: "spin")
    }

    // MARK: Paths

    static func radius(for rect: CGRect) -> CGFloat {
        max(0, min(cornerRadius, min(rect.width, rect.height) * 0.3))
    }

    static func armLength(for rect: CGRect) -> CGFloat {
        let side = min(rect.width, rect.height)
        return min(side / 2, max(radius(for: rect) + 8, min(46, side * 0.32)))
    }

    static func roundedPath(_ rect: CGRect, radius: CGFloat? = nil) -> CGPath {
        let radius = min(radius ?? self.radius(for: rect), rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Four corner brackets following the border's rounded corners, with a fixed element count so the path animates.
    static func bracketPath(_ rect: CGRect) -> CGPath {
        let arm = armLength(for: rect), radius = max(0.5, self.radius(for: rect))
        let path = CGMutablePath()
        for (x, y, dx, dy) in [(rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0),
                               (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.minY, 1.0, 1.0)] {
            path.move(to: CGPoint(x: x, y: y + dy * arm))
            path.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x + dx * arm, y: y), radius: radius)
            path.addLine(to: CGPoint(x: x + dx * arm, y: y))
        }
        return path
    }

    /// Short grips at the middle of each edge, where the edge handles are.
    static func gripPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let across = min(30, rect.width * 0.18), up = min(30, rect.height * 0.18)
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
}

/// Text drawing over the screenshot: in-place translations, a word highlight that shimmers once when text is found,
/// the Google-blue selection and its two round handles.
final class TextSurface: CALayer {
    let translation = CALayer()
    let words = CAShapeLayer()
    let selection = CAShapeLayer()
    let handles = CAShapeLayer()

    static let knobRadius: CGFloat = 7

    override init() {
        super.init()
        translation.contentsGravity = .resize
        translation.magnificationFilter = .linear
        translation.minificationFilter = .trilinear
        words.fillColor = NSColor.white.withAlphaComponent(0.22).cgColor
        words.strokeColor = googleBlue.withAlphaComponent(0.45).cgColor
        words.lineWidth = 1
        selection.fillColor = googleBlue.withAlphaComponent(0.35).cgColor
        handles.fillColor = googleBlue.cgColor
        handles.shadowColor = NSColor.black.cgColor
        handles.shadowOpacity = 0.3
        handles.shadowRadius = 2
        handles.shadowOffset = .zero
        words.opacity = 0
        for layer in [translation, words, selection, handles] {
            layer.actions = quietActions
            addSublayer(layer)
        }
        actions = quietActions
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in [words, selection, handles] { layer.frame = bounds }
    }

    /// Round knobs hanging below the start and end of the selection, like Android's text handles.
    static func handlePath(start: (point: CGPoint, top: CGFloat), end: (point: CGPoint, top: CGFloat)) -> CGPath {
        let path = CGMutablePath()
        for handle in [start, end] {
            let x = handle.point.x, bottom = handle.point.y
            path.addRect(CGRect(x: x - 1, y: bottom - 6, width: 2, height: handle.top - bottom + 6))
            path.addEllipse(in: CGRect(x: x - knobRadius, y: bottom - 6 - 2 * knobRadius,
                                       width: 2 * knobRadius, height: 2 * knobRadius))
        }
        return path
    }

    static func knobCenter(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: point.y - 6 - knobRadius) }
}

/// A pill-shaped button with a symbol and a title, used in the floating text action menu.
final class ChipButton: NSButton {
    private let handler: () -> Void
    private var hover: NSTrackingArea?

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = .labelColor
        setAccessibilityLabel(title)
        target = self
        action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 14
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredWidth: CGFloat { ceil(intrinsicContentSize.width) + 22 }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hover = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

/// The floating menu next to selected text: Copy, Select all, Listen, Translate and Search, then any quick actions
/// for detected emails, phone numbers, addresses, links, dates and tracking numbers.
final class ActionChip: FloatingCard {
    private(set) var rows: [[ChipButton]] = []
    private var separators: [NSBox] = []
    /// Rows after which a separator is drawn: the last row of each group except the final one.
    private var groupEnds: Set<Int> = []
    static let rowHeight: CGFloat = 30
    static let maximumWidth: CGFloat = 620

    init() { super.init(radius: 20) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var buttons: [ChipButton] { rows.flatMap { $0 } }

    /// Each group starts on a new row; a group wider than the menu wraps onto further rows.
    func set(groups: [[ChipButton]]) {
        for view in buttons { view.removeFromSuperview() }
        for view in separators { view.removeFromSuperview() }
        separators.removeAll()
        rows.removeAll()
        groupEnds.removeAll()
        for group in groups where !group.isEmpty {
            if !rows.isEmpty {
                groupEnds.insert(rows.count - 1)
                let line = NSBox()
                line.boxType = .separator
                separators.append(line)
                content.addSubview(line)
            }
            var row: [ChipButton] = []
            var width: CGFloat = 0
            for button in group {
                if !row.isEmpty && width + 2 + button.preferredWidth > Self.maximumWidth - 12 {
                    rows.append(row)
                    row = []
                    width = 0
                }
                width += (row.isEmpty ? 0 : 2) + button.preferredWidth
                row.append(button)
                content.addSubview(button)
            }
            rows.append(row)
        }
        needsLayout = true
    }

    var preferredSize: NSSize {
        let widths = rows.map { row in row.reduce(CGFloat(0)) { $0 + $1.preferredWidth } + CGFloat(row.count - 1) * 2 }
        let height = CGFloat(rows.count) * Self.rowHeight + CGFloat(separators.count) * 7 + 10
        return NSSize(width: (widths.max() ?? 0) + 12, height: height)
    }

    override func layout() {
        super.layout()
        var y = bounds.height - 5
        var separatorIndex = 0
        for (index, row) in rows.enumerated() {
            y -= Self.rowHeight
            var x: CGFloat = 6
            for button in row {
                button.frame = NSRect(x: x, y: y + 1, width: button.preferredWidth, height: Self.rowHeight - 2)
                x += button.preferredWidth + 2
            }
            if groupEnds.contains(index), separatorIndex < separators.count {
                y -= 7
                separators[separatorIndex].frame = NSRect(x: 10, y: y + 3, width: bounds.width - 20, height: 1)
                separatorIndex += 1
            }
        }
    }
}

/// The translate bar above the search bar: source and target languages, Show original and close.
final class TranslateBar: FloatingCard {
    let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let originalToggle = NSButton(checkboxWithTitle: "Show original", target: nil, action: nil)
    let closeButton = NSButton()
    private let arrow = NSImageView()
    private let icon = NSImageView()
    var onChange: (() -> Void)?
    var onShowOriginal: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    static let languages = ["en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl", "tr", "ar", "he",
                            "zh-Hans", "zh-Hant", "ja", "ko", "hi", "th", "vi", "id"]

    init() {
        super.init(radius: 20)
        icon.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translate")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = googleBlue
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "to")
        arrow.contentTintColor = .secondaryLabelColor
        let names = Self.languages.map { ($0, Self.name(of: $0)) }
        sourcePopup.addItem(withTitle: "Detect language")
        sourcePopup.lastItem?.representedObject = nil
        for (code, name) in names {
            sourcePopup.addItem(withTitle: name)
            sourcePopup.lastItem?.representedObject = code
        }
        let system = Self.systemLanguage
        var targets = Self.languages
        if let index = targets.firstIndex(of: system) { targets.remove(at: index) }
        targets.insert(system, at: 0)
        for code in targets {
            targetPopup.addItem(withTitle: Self.name(of: code))
            targetPopup.lastItem?.representedObject = code
        }
        for popup in [sourcePopup, targetPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12)
            popup.target = self
            popup.action = #selector(changed)
        }
        originalToggle.controlSize = .small
        originalToggle.font = .systemFont(ofSize: 12)
        originalToggle.target = self
        originalToggle.action = #selector(toggled)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop translating")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.toolTip = "Stop translating"
        closeButton.target = self
        closeButton.action = #selector(close)
        for view in [icon, sourcePopup, arrow, targetPopup, originalToggle, closeButton] { content.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var source: String? { sourcePopup.selectedItem?.representedObject as? String }
    var target: String { targetPopup.selectedItem?.representedObject as? String ?? Self.systemLanguage }
    static let preferredWidth: CGFloat = 520

    /// The user's first preferred language, reduced to a code the language menus offer.
    static var systemLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return preferred.contains("Hant") || preferred.hasSuffix("TW") ? "zh-Hant" : "zh-Hans" }
        if preferred.hasPrefix("iw") { return "he" }
        return String(preferred.prefix { $0 != "-" && $0 != "_" })
    }

    static func name(of code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized(with: Locale.current) ?? code
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 20) / 2, width: 20, height: 20)
        sourcePopup.frame = NSRect(x: 38, y: (h - 24) / 2, width: 150, height: 24)
        arrow.frame = NSRect(x: 192, y: (h - 16) / 2, width: 16, height: 16)
        targetPopup.frame = NSRect(x: 212, y: (h - 24) / 2, width: 150, height: 24)
        originalToggle.frame = NSRect(x: 372, y: (h - 20) / 2, width: 110, height: 20)
        closeButton.frame = NSRect(x: bounds.width - 32, y: (h - 24) / 2, width: 24, height: 24)
    }

    @objc private func changed() { onChange?() }
    @objc private func toggled() { onShowOriginal?(originalToggle.state == .on) }
    @objc private func close() { onClose?() }
}

/// Reads text aloud on this Mac. The checks replace it so nothing is spoken.
@MainActor
protocol Speaker: AnyObject {
    var isSpeaking: Bool { get }
    var onFinish: (() -> Void)? { get set }
    func speak(_ text: String, language: String?) -> Bool
    func stop()
}

final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let language, let voice = AVSpeechSynthesisVoice(language: language) { utterance.voice = voice }
        isSpeaking = true
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finished() {
        guard isSpeaking, !synthesizer.isSpeaking else { return }
        isSpeaking = false
        onFinish?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.onFinish?()
        }
    }
}

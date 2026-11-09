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

/// The selection framed the way Android's Circle to Search frames it: four thick, light corner brackets with flat
/// ends on a large radius, sitting just outside the selected area, with a faint dark halo so they stay legible on white
/// pages. There is no colour, no connecting border and no edge grip. Geometry comes from `SelectionBrackets`.
final class LensFrameLayer: CALayer {
    static let whiteness: CGFloat = 0.85
    static let shadowOpacity: Float = 0.2
    static let shadowRadius: CGFloat = 2

    private let brackets = CAShapeLayer()

    /// The framed rectangle, nil while hidden.
    private(set) var rect: CGRect?

    override init() {
        super.init()
        brackets.fillColor = nil
        brackets.strokeColor = NSColor.white.withAlphaComponent(Self.whiteness).cgColor
        brackets.lineCap = .butt
        brackets.lineJoin = .round
        brackets.shadowColor = NSColor.black.cgColor
        brackets.shadowOpacity = Self.shadowOpacity
        brackets.shadowRadius = Self.shadowRadius
        brackets.shadowOffset = .zero
        addSublayer(brackets)
        for layer in [self, brackets] { layer.actions = quietActions.merging(["lineWidth": NSNull()]) { $1 } }
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The stroke width currently drawn.
    var lineWidth: CGFloat { brackets.lineWidth }

    func show(_ rect: CGRect) {
        self.rect = rect
        let geometry = SelectionBrackets(around: rect)
        brackets.frame = bounds
        brackets.lineWidth = geometry.stroke
        brackets.path = Self.bracketPath(geometry)
        isHidden = false
    }

    func hide() {
        isHidden = true
        rect = nil
    }

    /// The brackets grow from `from` to the current frame, as the circle morphs into the selection.
    func animateBrackets(from: CGRect, duration: CFTimeInterval) {
        guard let rect else { return }
        let start = SelectionBrackets(around: from), end = SelectionBrackets(around: rect)
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = Self.bracketPath(start)
        grow.toValue = Self.bracketPath(end)
        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = start.stroke
        width.toValue = end.stroke
        let group = CAAnimationGroup()
        group.animations = [grow, width]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        brackets.add(group, forKey: "grow")
    }

    // MARK: Paths

    /// The undimmed selection: a rounded rect concentric with the brackets' arcs.
    static func roundedPath(_ rect: CGRect) -> CGPath {
        let radius = SelectionBrackets(around: rect).innerRadius
        return CGPath(roundedRect: rect.standardized, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func bracketPath(_ rect: CGRect) -> CGPath { bracketPath(SelectionBrackets(around: rect)) }

    /// Four quarter arcs, each with a short straight arm on both sides ending flat, with a fixed element count so the
    /// path animates.
    static func bracketPath(_ geometry: SelectionBrackets) -> CGPath {
        let path = CGMutablePath()
        let arm = geometry.arm
        for corner in geometry.corners {
            let p = corner.point
            path.move(to: CGPoint(x: p.x, y: p.y + corner.dy * arm))
            path.addArc(tangent1End: p, tangent2End: CGPoint(x: p.x + corner.dx * arm, y: p.y), radius: geometry.radius)
            path.addLine(to: CGPoint(x: p.x + corner.dx * arm, y: p.y))
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

/// A button with a symbol and a title, used in the floating text action menu. On macOS 26 it is the system's
/// accessory-bar button inside the menu's glass; before, a borderless pill with a hover highlight.
final class ChipButton: NSButton {
    private let handler: () -> Void
    private var hover: NSTrackingArea?
    private let liquid = Glass.isLiquid

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
        if liquid {
            Glass.inBar(self)
        } else {
            wantsLayer = true
            layer?.cornerRadius = 14
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The bezel brings its own padding on macOS 26.
    var preferredWidth: CGFloat { ceil(intrinsicContentSize.width) + (liquid ? 10 : 22) }

    /// Whether the button draws anything of its own beyond the system bezel.
    var hasCustomBackground: Bool { layer?.backgroundColor != nil || hover != nil }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !liquid else { return }
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hover = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !liquid else { return super.mouseEntered(with: event) }
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        guard !liquid else { return super.mouseExited(with: event) }
        layer?.backgroundColor = nil
    }
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
        Glass.circle(closeButton)
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

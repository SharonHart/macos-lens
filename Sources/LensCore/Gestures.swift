import CoreGraphics

/// Pinch zoom and two-finger pan of the frozen screenshot. The canvas is where the whole screenshot is drawn;
/// at zoom 1 it is exactly the view bounds, and it always covers the bounds so no border ever shows.
public struct Viewport: Equatable, Sendable {
    public static let maximumZoom: CGFloat = 8
    public private(set) var zoom: CGFloat = 1
    /// The canvas origin relative to the bounds origin; zero or negative.
    public private(set) var offset: CGPoint = .zero

    public init() {}

    public var isZoomed: Bool { zoom > 1.001 }

    public func canvas(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + offset.x, y: bounds.minY + offset.y,
               width: bounds.width * zoom, height: bounds.height * zoom)
    }

    /// Zooms by `factor`, keeping the screenshot point under `anchor` in place.
    public mutating func zoom(by factor: CGFloat, at anchor: CGPoint, in bounds: CGRect) {
        guard factor.isFinite, factor > 0, bounds.width > 0, bounds.height > 0 else { return }
        let canvas = canvas(in: bounds)
        let ux = (anchor.x - canvas.minX) / canvas.width
        let uy = (anchor.y - canvas.minY) / canvas.height
        zoom = min(max(zoom * factor, 1), Self.maximumZoom)
        offset = CGPoint(x: anchor.x - bounds.minX - ux * bounds.width * zoom,
                         y: anchor.y - bounds.minY - uy * bounds.height * zoom)
        clamp(in: bounds)
    }

    public mutating func pan(by delta: CGVector, in bounds: CGRect) {
        offset.x += delta.dx
        offset.y += delta.dy
        clamp(in: bounds)
    }

    public mutating func reset() {
        zoom = 1
        offset = .zero
    }

    private mutating func clamp(in bounds: CGRect) {
        offset.x = min(0, max(bounds.width * (1 - zoom), offset.x))
        offset.y = min(0, max(bounds.height * (1 - zoom), offset.y))
    }
}

public extension SelectionEditor {
    /// A press that barely moves is a tap, which selects the text or object under it.
    static func isTap(_ points: [CGPoint], tolerance: CGFloat = 6) -> Bool {
        guard let first = points.first else { return false }
        return points.allSatisfy { hypot($0.x - first.x, $0.y - first.y) <= tolerance }
    }

    /// How a stroke being drawn reads so far: a straight diagonal drag frames a box live, anything that bends is
    /// freehand ink (a circle, scribble or highlight), and a short or flat stroke is not decided yet.
    enum DrawShape: Equatable, Sendable { case undecided, box, freehand }

    static func drawShape(_ points: [CGPoint], minimumSide: CGFloat = 20, minimumLength: CGFloat = 64,
                          straightness: CGFloat = 0.04) -> DrawShape {
        guard let first = points.first, let last = points.last else { return .undecided }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let dx = last.x - first.x, dy = last.y - first.y, chord = hypot(dx, dy)
        let limit = max(3, chord * straightness)
        let bend = points.reduce(CGFloat(0)) { worst, point in
            let offset = chord > 0 ? abs((point.x - first.x) * dy - (point.y - first.y) * dx) / chord
                : hypot(point.x - first.x, point.y - first.y)
            return max(worst, offset)
        }
        if max(maxX - minX, maxY - minY) >= 24, bend > limit { return .freehand }
        return chord >= minimumLength && abs(dx) >= minimumSide && abs(dy) >= minimumSide ? .box : .undecided
    }

    /// The area a circle, highlight or scribble selects: its bounding box with a little room around the ink.
    /// Thin highlight strokes are thickened so they cover the line of text they were drawn across.
    static func strokeBounds(_ points: [CGPoint], padding: CGFloat = 6, minimumSide: CGFloat = 40,
                             in limit: CGRect) -> CGRect {
        guard let first = points.first, !limit.isNull, !limit.isEmpty else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -padding, dy: -padding)
        if rect.width < minimumSide { rect = rect.insetBy(dx: (rect.width - minimumSide) / 2, dy: 0) }
        if rect.height < minimumSide { rect = rect.insetBy(dx: 0, dy: (rect.height - minimumSide) / 2) }
        return fitting(rect, in: limit)
    }

    /// The selection for a tap: the text line under it, else the object under it, else a square around it.
    static func tapSelection(at point: CGPoint, textLines: [CGRect], objects: [CGRect], fallbackSide: CGFloat = 160,
                             padding: CGFloat = 6, in limit: CGRect) -> CGRect {
        func smallest(containing rects: [CGRect], reach: CGFloat) -> CGRect? {
            rects.filter { $0.insetBy(dx: -reach, dy: -reach).contains(point) }
                .min { $0.width * $0.height < $1.width * $1.height }
        }
        if let line = smallest(containing: textLines, reach: 4) {
            return fitting(line.insetBy(dx: -padding, dy: -padding), in: limit)
        }
        if let object = smallest(containing: objects, reach: 0) {
            return fitting(object.insetBy(dx: -padding, dy: -padding), in: limit)
        }
        return fitting(CGRect(x: point.x - fallbackSide / 2, y: point.y - fallbackSide / 2,
                              width: fallbackSide, height: fallbackSide), in: limit)
    }

    /// Converts a Vision bounding box (normalized, bottom-left origin) found in a crop of the screenshot into a
    /// unit selection of the whole screenshot (bottom-left origin).
    static func unit(forNormalized box: CGRect, inPixels crop: CGRect, width: Int, height: Int) -> CGRect {
        guard width > 0, height > 0 else { return .null }
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: (crop.minX + box.minX * crop.width) / w,
                      y: (h - crop.maxY + box.minY * crop.height) / h,
                      width: box.width * crop.width / w, height: box.height * crop.height / h)
    }

    /// Keeps a rect's size where possible and shifts it inside `limit`, shrinking it only if it is larger.
    static func fitting(_ rect: CGRect, in limit: CGRect) -> CGRect {
        let rect = rect.standardized
        let width = min(rect.width, limit.width), height = min(rect.height, limit.height)
        let x = min(max(rect.midX - width / 2, limit.minX), limit.maxX - width)
        let y = min(max(rect.midY - height / 2, limit.minY), limit.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Android's results sheet closes when it is dragged down. On a Mac the same gesture is a two-finger scroll that
/// pulls the content down (towards its top); it only counts when the content was already at its top when the
/// gesture began, and momentum and mouse wheels never dismiss.
public struct PullToDismiss: Sendable {
    public enum Phase: Sendable { case began, changed, ended, other }

    public let threshold: CGFloat
    public private(set) var distance: CGFloat = 0
    private var blocked = true
    private var fired = false

    public init(threshold: CGFloat) {
        self.threshold = threshold
    }

    /// Feeds one scroll event. `deltaY` is positive when the content is pulled down. Returns true once per
    /// gesture, when it should dismiss.
    public mutating func track(phase: Phase, momentum: Bool, deltaY: CGFloat, atTop: Bool) -> Bool {
        guard !momentum else { return false }
        switch phase {
        case .began:
            distance = 0
            fired = false
            blocked = !atTop
        case .changed:
            break
        case .ended, .other:
            blocked = true
            return false
        }
        if !atTop { blocked = true }
        guard !blocked, !fired else { return false }
        distance += deltaY
        if distance < -12 {
            blocked = true
            return false
        }
        guard distance >= threshold else { return false }
        fired = true
        return true
    }
}

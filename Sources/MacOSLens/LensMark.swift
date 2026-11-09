import AppKit

/// The app's mark: four rounded viewfinder corners around an original apple, a round fruit with a dip on top, a short
/// stem and one leaf, and no bite. It is drawn from vector paths at the scale it is shown at, so it stays crisp at any
/// size. Its images are templates and take the colour of the menu bar, button or image view that shows them.
enum LensMark {
    static let label = "macOS Lens"
    /// The menu-bar icon size: the full height available to a status item's image.
    static let menuBarSize: CGFloat = 18

    /// A square template image `size` points wide.
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// Stroke width and corner arm length, measured from the outer edge, in points for a mark `side` points wide
    /// shown at `scale` pixels per point. Both are whole pixels so straight edges land on pixel boundaries.
    static func metrics(side: CGFloat, scale: CGFloat) -> (stroke: CGFloat, arm: CGFloat) {
        func pixels(_ value: CGFloat) -> CGFloat { max(1, (value * scale).rounded()) / scale }
        return (pixels(side * 0.11), pixels(side * 0.34))
    }

    /// The apple's height as a share of the mark, including its stem and leaf.
    static let appleShare: CGFloat = 0.58

    private static func draw(in rect: NSRect) {
        let context = NSGraphicsContext.current?.cgContext
        let transform = context?.userSpaceToDeviceSpaceTransform ?? .identity
        let scale = max(1, hypot(transform.a, transform.b))
        let side = (min(rect.width, rect.height) * scale).rounded(.down) / scale
        var origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        if context != nil {
            let device = origin.applying(transform)
            origin = CGPoint(x: device.x.rounded(), y: device.y.rounded()).applying(transform.inverted())
        }
        NSColor.black.set()

        let (stroke, arm) = metrics(side: side, scale: scale)
        let inset = stroke / 2, reach = arm - inset
        let radius = min(side * 0.2, reach - inset)
        let low = inset, high = side - inset
        let corners = NSBezierPath()
        let ends: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(low, high, 1, -1), (high, high, -1, -1),
                                                            (high, low, -1, 1), (low, low, 1, 1)]
        for (x, y, dx, dy) in ends {
            corners.move(to: NSPoint(x: x, y: y + dy * reach))
            corners.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x + dx * reach, y: y), radius: radius)
            corners.line(to: NSPoint(x: x + dx * reach, y: y))
        }
        corners.lineWidth = stroke
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        corners.transform(using: AffineTransform(translationByX: origin.x, byY: origin.y))
        corners.stroke()

        // The apple is designed in a 100-unit box with y up and centred on (50, 47), so the fruit sits optically
        // centred. It is not pixel-snapped, so its body stays mirror-symmetric at every size.
        let unit = side * appleShare / 100
        var place = AffineTransform(translationByX: origin.x + side / 2 - 50 * unit, byY: origin.y + side / 2 - 47 * unit)
        place.scale(unit)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

        let body = NSBezierPath()
        body.move(to: point(50, 66))
        body.curve(to: point(74, 78), controlPoint1: point(56, 74), controlPoint2: point(64, 79))
        body.curve(to: point(96, 44), controlPoint1: point(90, 77), controlPoint2: point(98, 62))
        body.curve(to: point(68, 2), controlPoint1: point(94, 24), controlPoint2: point(82, 4))
        body.curve(to: point(50, 6), controlPoint1: point(60, 0), controlPoint2: point(56, 6))
        body.curve(to: point(32, 2), controlPoint1: point(44, 6), controlPoint2: point(40, 0))
        body.curve(to: point(4, 44), controlPoint1: point(18, 4), controlPoint2: point(6, 24))
        body.curve(to: point(26, 78), controlPoint1: point(2, 62), controlPoint2: point(10, 77))
        body.curve(to: point(50, 66), controlPoint1: point(36, 79), controlPoint2: point(44, 74))
        body.close()
        body.transform(using: place)
        body.fill()

        let stem = NSBezierPath()
        stem.move(to: point(50, 70))
        stem.curve(to: point(55, 93), controlPoint1: point(50, 80), controlPoint2: point(52, 88))
        stem.transform(using: place)
        stem.lineWidth = max(side * 0.07, 1 / scale)
        stem.lineCapStyle = .round
        stem.stroke()

        // One leaf, attached to the stem and pointing up and to the right.
        let base = point(55, 80), tip = point(87, 96)
        let along = CGVector(dx: tip.x - base.x, dy: tip.y - base.y)
        let length = hypot(along.dx, along.dy), width: CGFloat = 9.5
        let normal = CGVector(dx: -along.dy / length * width, dy: along.dx / length * width)
        func at(_ t: CGFloat, _ side: CGFloat) -> NSPoint {
            point(base.x + along.dx * t + normal.dx * side, base.y + along.dy * t + normal.dy * side)
        }
        let leaf = NSBezierPath()
        leaf.move(to: base)
        leaf.curve(to: tip, controlPoint1: at(0.25, 1), controlPoint2: at(0.7, 1))
        leaf.curve(to: base, controlPoint1: at(0.7, -1), controlPoint2: at(0.25, -1))
        leaf.close()
        leaf.transform(using: place)
        leaf.fill()
    }
}

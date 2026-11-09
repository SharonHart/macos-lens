import CoreGraphics

public enum SelectionHandle: CaseIterable, Sendable {
    // Corners come first so they win hit-testing over the edges they touch.
    case bottomLeft, bottomRight, topRight, topLeft, bottom, right, top, left

    var movesMinX: Bool { [.bottomLeft, .topLeft, .left].contains(self) }
    var movesMaxX: Bool { [.bottomRight, .topRight, .right].contains(self) }
    var movesMinY: Bool { [.bottomLeft, .bottomRight, .bottom].contains(self) }
    var movesMaxY: Bool { [.topLeft, .topRight, .top].contains(self) }
    public var isCorner: Bool { (movesMinX || movesMaxX) && (movesMinY || movesMaxY) }

    public func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesMinX ? rect.minX : movesMaxX ? rect.maxX : rect.midX,
                y: movesMinY ? rect.minY : movesMaxY ? rect.maxY : rect.midY)
    }
}

public enum SelectionDrag: Equatable, Sendable {
    case resize(SelectionHandle), move, draw
}

/// Geometry for the adjustable selection, in view coordinates with a bottom-left origin.
public enum SelectionEditor {
    public static let tolerance: CGFloat = 12
    public static let minimumHandleSide: CGFloat = 16

    public static func target(at point: CGPoint, selection: CGRect?, bounds: CGRect,
                              freehand: Bool = false, tolerance: CGFloat = tolerance) -> SelectionDrag {
        guard let rect = selection?.standardized, !rect.isNull, !rect.isEmpty else { return .draw }
        let reach = min(tolerance, max(4, min(rect.width, rect.height) / 4))
        for handle in SelectionHandle.allCases where handle.isCorner {
            let corner = handle.point(in: rect)
            if abs(point.x - corner.x) <= reach && abs(point.y - corner.y) <= reach { return .resize(handle) }
        }
        let alongX = point.x >= rect.minX - reach && point.x <= rect.maxX + reach
        let alongY = point.y >= rect.minY - reach && point.y <= rect.maxY + reach
        if alongY && abs(point.x - rect.minX) <= reach { return .resize(.left) }
        if alongY && abs(point.x - rect.maxX) <= reach { return .resize(.right) }
        if alongX && abs(point.y - rect.minY) <= reach { return .resize(.bottom) }
        if alongX && abs(point.y - rect.maxY) <= reach { return .resize(.top) }
        if freehand { return .draw }
        // A selection that already fills the canvas cannot move, so dragging inside it draws a new area.
        let movable = rect.width < bounds.width - 0.5 || rect.height < bounds.height - 0.5
        return movable && rect.contains(point) ? .move : .draw
    }

    public static func resize(_ rect: CGRect, handle: SelectionHandle, by delta: CGVector, in bounds: CGRect,
                              minimumSide: CGFloat = minimumHandleSide) -> CGRect {
        let rect = rect.standardized
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let side = min(minimumSide, bounds.width, bounds.height)
        if handle.movesMinX { minX = min(max(bounds.minX, minX + delta.dx), maxX - side) }
        if handle.movesMaxX { maxX = max(min(bounds.maxX, maxX + delta.dx), minX + side) }
        if handle.movesMinY { minY = min(max(bounds.minY, minY + delta.dy), maxY - side) }
        if handle.movesMaxY { maxY = max(min(bounds.maxY, maxY + delta.dy), minY + side) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func move(_ rect: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        let rect = rect.standardized
        let x = min(max(rect.minX + delta.dx, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.dy, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The largest rect with the image's aspect ratio, centred in `container`.
    public static func fit(_ size: CGSize, in container: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: container.midX - width / 2, y: container.midY - height / 2, width: width, height: height)
    }

    /// The default selection: the whole canvas, in unit coordinates.
    public static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func unit(_ rect: CGRect, in canvas: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .null }
        return CGRect(x: (rect.minX - canvas.minX) / canvas.width, y: (rect.minY - canvas.minY) / canvas.height,
                      width: rect.width / canvas.width, height: rect.height / canvas.height)
    }

    /// Image pixels (top-left origin) for a unit selection (bottom-left origin), snapping float noise so the
    /// same selection always yields the same pixels whatever size the canvas is drawn at.
    public static func pixels(forUnit unit: CGRect, width: Int, height: Int) -> CGRect? {
        let unit = unit.standardized
        guard !unit.isNull, width > 0, height > 0 else { return nil }
        func snap(_ value: CGFloat) -> CGFloat { abs(value - value.rounded()) < 0.01 ? value.rounded() : value }
        let w = CGFloat(width), h = CGFloat(height)
        let left = floor(snap(unit.minX * w))
        let top = floor(snap((1 - unit.maxY) * h))
        let right = ceil(snap(unit.maxX * w))
        let bottom = ceil(snap((1 - unit.minY) * h))
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    public static func view(_ unit: CGRect, in canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + unit.minX * canvas.width, y: canvas.minY + unit.minY * canvas.height,
               width: unit.width * canvas.width, height: unit.height * canvas.height)
    }
}

/// The Circle to Search corner brackets around a selection: four thick, flat-ended rounded L's that sit just outside
/// the selected area, sized from its shorter side. The selected area itself is undimmed as a concentric rounded rect.
public struct SelectionBrackets: Equatable, Sendable {
    /// Space between a bracket's inner edge and the selected area.
    public static let gap: CGFloat = 4

    public let selection: CGRect
    /// Stroke width: 6% of the shorter side, 5–8 pt.
    public let stroke: CGFloat
    /// Distance from a bracket's outer corner to the flat end of each arm: 28% of the shorter side, 20–48 pt,
    /// shortened on small selections so the two arms along an edge never meet.
    public let reach: CGFloat
    /// Centre-line radius of each bracket's quarter arc: 18% of the shorter side, 14–28 pt, leaving a short straight
    /// run before each flat end.
    public let radius: CGFloat

    public init(around selection: CGRect) {
        let rect = selection.standardized
        self.selection = rect
        let side = max(0, min(rect.width, rect.height))
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }
        stroke = clamp(side * 0.06, 5, 8)
        let outer = side + 2 * (Self.gap + stroke)
        reach = max(stroke, min(clamp(side * 0.28, 20, 48), outer / 2 - max(4, outer * 0.12)))
        radius = max(0.5, min(clamp(side * 0.18, 14, 28), (reach - stroke / 2) * 0.85))
    }

    /// How far the strokes' centre line sits outside the selection.
    public var outset: CGFloat { Self.gap + stroke / 2 }
    /// The rectangle the strokes are centred on.
    public var centreRect: CGRect { selection.insetBy(dx: -outset, dy: -outset) }
    /// Everything the brackets cover.
    public var outerRect: CGRect { selection.insetBy(dx: -(Self.gap + stroke), dy: -(Self.gap + stroke)) }
    /// Radius of the undimmed selection, concentric with the brackets' arcs.
    public var innerRadius: CGFloat {
        max(0, min(radius - outset, selection.width / 2, selection.height / 2))
    }

    /// Each corner as its sharp centre-line point and the directions its two arms run in, in `SelectionHandle` order.
    public var corners: [(handle: SelectionHandle, point: CGPoint, dx: CGFloat, dy: CGFloat)] {
        let rect = centreRect
        return [(.topLeft, CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (.topRight, CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY), -1, 1), (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY), 1, 1)]
    }

    /// Length of each arm along the centre line, from the sharp corner point to the flat end.
    public var arm: CGFloat { reach - stroke / 2 }

    /// The corner whose bracket is under `point`, within `slop` points of its stroke.
    public func corner(at point: CGPoint, slop: CGFloat = 10) -> SelectionHandle? {
        let width = stroke / 2 + slop
        for corner in corners {
            let end = CGPoint(x: corner.point.x + corner.dx * arm, y: corner.point.y + corner.dy * arm)
            let alongX = (min(corner.point.x, end.x) - width...max(corner.point.x, end.x) + width).contains(point.x)
            let alongY = (min(corner.point.y, end.y) - width...max(corner.point.y, end.y) + width).contains(point.y)
            if (alongX && abs(point.y - corner.point.y) <= width) || (alongY && abs(point.x - corner.point.x) <= width) {
                return corner.handle
            }
        }
        return nil
    }
}

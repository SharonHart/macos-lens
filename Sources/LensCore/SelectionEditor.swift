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
                              freehand: Bool = false) -> SelectionDrag {
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

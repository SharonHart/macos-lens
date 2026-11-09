import AppKit

/// A window's content laid out top to bottom in rows sized to their content at the current width. Wrapping text gets
/// the height its lines need and controls at least their fitting width, so nothing is clipped or truncated. A row
/// that is too narrow wraps onto further lines instead.
final class FormView: NSView {
    enum Width {
        /// The view's fitting width.
        case fit
        /// An equal share of the space the row leaves, but at least `min`, or the fitting width of a control.
        case fill(min: CGFloat? = nil)
        case fixed(CGFloat)
    }

    struct Item {
        let view: NSView
        let width: Width
        let height: CGFloat?

        static func item(_ view: NSView, _ width: Width = .fill(), height: CGFloat? = nil) -> Item {
            Item(view: view, width: width, height: height)
        }

        /// An empty view that takes up the rest of a row, to push the items after it to the trailing edge.
        static func spacer() -> Item { item(NSView(), .fill(min: 0), height: 0) }
    }

    private struct Row {
        let items: [Item]
        let gap: CGFloat
    }

    var margin: CGFloat = 24
    var spacing: CGFloat = 12
    private var rows: [Row] = []

    override var isFlipped: Bool { true }

    /// Adds a row `gap` points below the previous one.
    func add(_ items: Item..., gap: CGFloat = 12) {
        for item in items { addSubview(item.view) }
        rows.append(Row(items: items, gap: gap))
    }

    /// The width at which no row has to wrap and the filling items of each row get equal widths.
    var naturalWidth: CGFloat {
        rows.map { row in
            let filling = row.items.filter(Self.fills)
            let fixed = row.items.filter { !Self.fills($0) }.reduce(CGFloat(0)) { $0 + minimum($1) }
            return fixed + CGFloat(filling.count) * (filling.map(minimum).max() ?? 0) +
                spacing * CGFloat(max(row.items.count - 1, 0))
        }.max().map { $0 + 2 * margin } ?? 2 * margin
    }

    /// The narrowest width at which every item still fits, one per line.
    var minimumWidth: CGFloat {
        (rows.flatMap(\.items).map { item in
            (item.view as? FormView)?.minimumWidth ?? minimum(item)
        }.max() ?? 0) + 2 * margin
    }

    /// The views laid out by this form, including those of nested forms.
    var arrangedViews: [NSView] {
        rows.flatMap(\.items).flatMap { item in (item.view as? FormView)?.arrangedViews ?? [item.view] }
    }

    private static func fills(_ item: Item) -> Bool {
        if case .fill = item.width { return true }
        return false
    }

    /// Lays the rows out at `width` and returns the height they need.
    @discardableResult
    func place(width: CGFloat) -> CGFloat {
        let available = max(width - 2 * margin, 0)
        var y = margin
        for (index, row) in rows.enumerated() {
            if index > 0 { y += row.gap }
            for (offset, line) in lines(row.items, available).enumerated() {
                if offset > 0 { y += spacing / 2 }
                y += place(line, available, top: y)
            }
        }
        return ceil(y + margin)
    }

    /// Lays out at `width` (the current width by default) and resizes the window to fit, keeping its top edge.
    func fitWindow(width: CGFloat? = nil) {
        let width = width ?? bounds.width
        let height = place(width: width)
        guard let window else {
            setFrameSize(NSSize(width: width, height: height))
            return
        }
        window.contentMinSize = NSSize(width: minimumWidth, height: 0)
        let content = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible)
        place(width: bounds.width)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        place(width: bounds.width)
    }

    /// Lets the user drag the window's width, down to the narrowest layout, while its height follows the content.
    /// Zooming and full screen, which would bypass this, are turned off.
    func letUserResize(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
    }

    /// The height `view` needs at `width`.
    static func height(of view: NSView, width: CGFloat) -> CGFloat {
        if let form = view as? FormView { return form.place(width: width) }
        if let field = view as? NSTextField, let cell = field.cell, cell.wraps {
            let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            return ceil(cell.cellSize(forBounds: bounds).height)
        }
        return ceil(view.fittingSize.height)
    }

    private static func wraps(_ view: NSView) -> Bool { (view as? NSTextField)?.cell?.wraps == true }

    private func minimum(_ item: Item) -> CGFloat {
        switch item.width {
        case .fit: return ceil(item.view.fittingSize.width)
        case .fixed(let width): return width
        case .fill(let min):
            if let min { return min }
            if let form = item.view as? FormView { return form.naturalWidth }
            return Self.wraps(item.view) ? 0 : ceil(item.view.fittingSize.width)
        }
    }

    private func lines(_ items: [Item], _ available: CGFloat) -> [[Item]] {
        var lines: [[Item]] = [], line: [Item] = [], used: CGFloat = 0
        for item in items {
            let width = minimum(item)
            if !line.isEmpty, used + spacing + width > available {
                lines.append(line)
                line = []
                used = 0
            }
            used += (line.isEmpty ? 0 : spacing) + width
            line.append(item)
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Places one line of items at `top`, sharing the free space equally among the filling items, and returns its
    /// height. Items are centred vertically on the line.
    private func place(_ line: [Item], _ available: CGFloat, top: CGFloat) -> CGFloat {
        var widths = line.map(minimum)
        var filling = Set(line.indices.filter { Self.fills(line[$0]) })
        let fixed = line.indices.filter { !filling.contains($0) }.reduce(CGFloat(0)) { $0 + widths[$1] }
        var free = available - fixed - spacing * CGFloat(line.count - 1)
        // Items too wide for an equal share keep their minimum; the others split what is left.
        while !filling.isEmpty {
            let share = free / CGFloat(filling.count)
            let wide = filling.filter { widths[$0] > share }
            if wide.isEmpty {
                for index in filling { widths[index] = max(share, 0) }
                break
            }
            for index in wide {
                filling.remove(index)
                free -= widths[index]
            }
        }
        let heights = line.indices.map { line[$0].height ?? Self.height(of: line[$0].view, width: widths[$0]) }
        let lineHeight = heights.max() ?? 0
        var x = margin
        for index in line.indices {
            let view = line[index].view
            if let field = view as? NSTextField, Self.wraps(field) {
                // The width to wrap the text at, inside the 2 pt padding a label keeps on each side; its fitting
                // size adds that padding back.
                field.preferredMaxLayoutWidth = max(0, widths[index] - 4)
            }
            view.frame = NSRect(x: x, y: top + (lineHeight - heights[index]) / 2, width: widths[index],
                                height: heights[index]).integral
            x += widths[index] + spacing
        }
        return lineHeight
    }
}

extension FormView: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        let width = max(minimumWidth, proposed.width.rounded())
        return sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: place(width: width))).size
    }
}

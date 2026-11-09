import CoreGraphics

/// Where an area of the screenshot has ink — pixels that stand out from the area's background — on a coarse grid.
public struct InkMap: Equatable, Sendable {
    /// The unit rect of the screenshot (bottom-left origin) the grid covers.
    public let area: CGRect
    public let columns: Int
    public let rows: Int
    /// Row by row, starting with the bottom row.
    public let cells: [Bool]

    public init(area: CGRect, columns: Int, rows: Int, cells: [Bool]) {
        precondition(columns > 0 && rows > 0 && cells.count == columns * rows, "The ink grid doesn't match its size.")
        self.area = area
        self.columns = columns
        self.rows = rows
        self.cells = cells
    }

    /// The ink of `image` inside the unit rect `area`, sampled at most `maxSide` cells along the longer side. The
    /// background is the area's most common colour; cells that differ clearly from it are ink.
    public init?(image: CGImage, area unit: CGRect, maxSide: Int = 128) {
        guard let pixels = SelectionEditor.pixels(forUnit: unit, width: image.width, height: image.height),
              let crop = image.cropping(to: pixels), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, CGFloat(maxSide) / max(pixels.width, pixels.height))
        let columns = max(1, Int((pixels.width * scale).rounded())), rows = max(1, Int((pixels.height * scale).rounded()))
        var data = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }
        func bucket(_ offset: Int) -> Int {
            Int(data[offset] >> 4) << 8 | Int(data[offset + 1] >> 4) << 4 | Int(data[offset + 2] >> 4)
        }
        var counts: [Int: Int] = [:]
        for cell in 0..<(columns * rows) { counts[bucket(cell * 4), default: 0] += 1 }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        var sum = (0, 0, 0), members = 0
        for cell in 0..<(columns * rows) where bucket(cell * 4) == background {
            sum = (sum.0 + Int(data[cell * 4]), sum.1 + Int(data[cell * 4 + 1]), sum.2 + Int(data[cell * 4 + 2]))
            members += 1
        }
        let base = (sum.0 / members, sum.1 / members, sum.2 / members)
        var cells = [Bool](repeating: false, count: columns * rows)
        for y in 0..<rows {
            for x in 0..<columns {
                let offset = (y * columns + x) * 4
                let difference = abs(Int(data[offset]) - base.0) + abs(Int(data[offset + 1]) - base.1) +
                    abs(Int(data[offset + 2]) - base.2)
                // Bitmap rows run top to bottom; the grid runs bottom to top like unit rects.
                cells[(rows - 1 - y) * columns + x] = difference > 72
            }
        }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        self.init(area: CGRect(x: pixels.minX / width, y: 1 - pixels.maxY / height, width: pixels.width / width,
                               height: pixels.height / height),
                  columns: columns, rows: rows, cells: cells)
    }

    /// The unit rect of one cell.
    public func cell(column: Int, row: Int) -> CGRect {
        let width = area.width / CGFloat(columns), height = area.height / CGFloat(rows)
        return CGRect(x: area.minX + CGFloat(column) * width, y: area.minY + CGFloat(row) * height,
                      width: width, height: height)
    }

    /// Of the cells whose centre lies in `rect`: how many there are, how many are ink and how many of those lie on one
    /// of `boxes` (all unit rects).
    public func count(in rect: CGRect, on boxes: [CGRect]) -> (cells: Int, ink: Int, onBoxes: Int) {
        var result = (cells: 0, ink: 0, onBoxes: 0)
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = cell(column: column, row: row)
                let centre = CGPoint(x: cell.midX, y: cell.midY)
                guard rect.contains(centre) else { continue }
                result.cells += 1
                guard cells[row * columns + column] else { continue }
                result.ink += 1
                if boxes.contains(where: { $0.contains(centre) }) { result.onBoxes += 1 }
            }
        }
        return result
    }
}

/// Decides what a gesture on the frozen screen means, as Lens does in one view: pressing, highlighting or underlining
/// recognized text selects words, circling text selects its words, and anything else selects an area for visual
/// search. Geometry is in view coordinates for presses and strokes and unit rects of the screenshot for regions.
public enum GestureClassifier {
    /// A region whose ink is at least this share text selects its words, even beside a picture.
    public static let textShare: CGFloat = 0.5
    /// A salient object covering this share of a region, and mostly not text, makes the region a picture.
    public static let objectShare: CGFloat = 0.3
    /// Without a salient object, non-text ink covering this share of a region also makes it a picture.
    public static let pictureInk: CGFloat = 0.25
    /// A smaller salient object, mostly not text, still counts when it covers this share of a region and the region's
    /// ink is mostly not text: a photo beside a caption.
    public static let objectMinimum: CGFloat = 0.02

    public enum Press: Equatable, Sendable {
        /// One press on a word: it selects the word, and may become a highlight along its line or a circle.
        case word(Int)
        /// A double click selects the word's line, a triple click its paragraph.
        case range(TextRange)
        /// Shift-click extends the current text selection to the word.
        case extend(TextRange)
        /// Not on text, or the text isn't recognized yet: the press selects an area or object to search.
        case visual
    }

    /// `layout` is nil until the screen's text is recognized, so presses fall back to visual selection.
    public static func press(at point: CGPoint, layout: TextLayout?, canvas: CGRect, clickCount: Int = 1,
                             shift: Bool = false, current: TextRange? = nil) -> Press {
        guard let layout, let index = layout.index(at: point, canvas: canvas) else { return .visual }
        if shift, let current { return .extend(TextRange(anchor: current.anchor, focus: index)) }
        if clickCount == 2, let line = layout.lineRange(containing: index) { return .range(line) }
        if clickCount >= 3, let block = layout.blockRange(containing: index) { return .range(block) }
        return .word(index)
    }

    /// The words highlighted by dragging from `anchor` along its line, snapped to whole words in reading order; nil
    /// once the drag leaves the line's band, when it becomes a circle instead.
    public static func lineDrag(from anchor: Int, to point: CGPoint, layout: TextLayout, canvas: CGRect) -> TextRange? {
        guard layout.words.indices.contains(anchor) else { return nil }
        let line = layout.lines[layout.words[anchor].line]
        let band = SelectionEditor.view(line.box, in: canvas)
        let reach = max(4, band.height * 0.6)
        guard point.y >= band.minY - reach, point.y <= band.maxY + reach else { return nil }
        func gap(_ index: Int) -> (CGFloat, CGFloat) {
            let box = layout.view(index, in: canvas)
            let dx = point.x < box.minX ? box.minX - point.x : point.x > box.maxX ? point.x - box.maxX : 0
            return (dx, abs(point.x - box.midX))
        }
        let focus = line.words.min { gap($0) < gap($1) } ?? anchor
        return TextRange(anchor: anchor, focus: focus)
    }

    /// Whether a drag that began on word `anchor` is circling its line rather than highlighting along it: it has
    /// passed both above and below the line's words and turned back horizontally, so a snug circle around one line
    /// is still a circle.
    public static func encircles(_ points: [CGPoint], anchor: Int, layout: TextLayout, canvas: CGRect) -> Bool {
        guard points.count >= 3, layout.words.indices.contains(anchor) else { return false }
        let band = SelectionEditor.view(layout.lines[layout.words[anchor].line].box, in: canvas)
        let margin = max(2, band.height * 0.15)
        guard points.contains(where: { $0.y > band.maxY + margin }),
              points.contains(where: { $0.y < band.minY - margin }) else { return false }
        let turn = max(8, band.height * 0.5)
        var low = points[0].x, high = points[0].x
        var rightward = false, leftward = false
        for point in points.dropFirst() {
            if point.x - low >= turn { rightward = true }
            if high - point.x >= turn { leftward = true }
            low = min(low, point.x)
            high = max(high, point.x)
        }
        return rightward && leftward
    }

    /// The words along a highlight, underline or scribble stroke drawn over one line of text, snapped to whole words in
    /// the stroke's direction; nil when the stroke isn't flat and along a recognized line.
    public static func lineStroke(_ points: [CGPoint], layout: TextLayout, canvas: CGRect) -> TextRange? {
        guard points.count >= 2, !layout.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        var best: (words: [Int], hits: Int, distance: CGFloat)?
        for line in layout.lines where !line.words.isEmpty {
            let box = SelectionEditor.view(line.box, in: canvas)
            let reach = max(6, box.height * 0.9)
            guard bounds.width >= max(12, box.height * 1.5), bounds.width >= 2 * bounds.height,
                  bounds.height <= box.height + 2 * reach else { continue }
            let hits = points.filter { $0.y >= box.minY - reach && $0.y <= box.maxY + reach }.count
            guard CGFloat(hits) >= 0.85 * CGFloat(points.count) else { continue }
            var covered: CGFloat = 0
            let words = line.words.filter { index in
                let word = layout.view(index, in: canvas)
                let overlap = min(word.maxX, bounds.maxX) - max(word.minX, bounds.minX)
                guard overlap > 0, overlap >= 0.5 * min(word.width, bounds.width) else { return false }
                covered += overlap
                return true
            }
            guard !words.isEmpty, covered >= 0.5 * bounds.width else { continue }
            let distance = points.reduce(0) { $0 + abs($1.y - box.midY) } / CGFloat(points.count)
            if best == nil || hits > best!.hits || hits == best!.hits && distance < best!.distance {
                best = (words, hits, distance)
            }
        }
        guard let words = best?.words, let first = words.first, let last = words.last else { return nil }
        return points[0].x <= points[points.count - 1].x ? TextRange(anchor: first, focus: last)
                                                         : TextRange(anchor: last, focus: first)
    }

    public struct RegionEvidence: Equatable, Sendable {
        /// The words whose centre lies in the region, in reading order.
        public var range: TextRange?
        public var wordsInside: Int
        /// The share of the region's ink that lies on words; nil when the region is blank or there is no ink map.
        public var textInk: CGFloat?
        /// The share of the region covered by ink that isn't on words; nil without an ink map.
        public var otherInk: CGFloat?
        /// A large salient object in the region that is mostly not text, such as a photo.
        public var dominantObject: Bool
        /// A salient object in the region that is mostly not text, covering at least `objectMinimum` of it.
        public var salientObject: Bool = false
    }

    public enum Region: Equatable, Sendable {
        /// Mostly text: its words are selected.
        case text(TextRange)
        /// Searched visually; `selectText` offers its words when it contains any.
        case visual(selectText: Bool)
    }

    public static func evidence(unit region: CGRect, layout: TextLayout, ink: InkMap?,
                                objects: [CGRect]) -> RegionEvidence {
        let region = region.standardized
        var inside = 0
        var boxes: [CGRect] = []
        for word in layout.words {
            let box = word.box
            if region.contains(CGPoint(x: box.midX, y: box.midY)) { inside += 1 }
            // Letters reach a little beyond Vision's word boxes.
            if box.intersects(region) { boxes.append(box.insetBy(dx: -box.height * 0.2, dy: -box.height * 0.2)) }
        }
        var textInk: CGFloat?, otherInk: CGFloat?
        if let ink {
            let counts = ink.count(in: region, on: boxes)
            if counts.ink >= max(3, counts.cells / 200) { textInk = CGFloat(counts.onBoxes) / CGFloat(counts.ink) }
            otherInk = CGFloat(counts.ink - counts.onBoxes) / CGFloat(max(1, counts.cells))
        }
        let area = region.width * region.height
        func nonText(_ object: CGRect, share: CGFloat) -> Bool {
            let part = object.standardized.intersection(region)
            guard !part.isNull, area > 0, part.width * part.height >= share * area else { return false }
            if let ink {
                let counts = ink.count(in: part, on: boxes)
                return counts.ink >= 3 && CGFloat(counts.onBoxes) < 0.5 * CGFloat(counts.ink)
            }
            let covered = boxes.reduce(CGFloat(0)) { total, box in
                let shared = box.intersection(part)
                return total + (shared.isNull ? 0 : shared.width * shared.height)
            }
            return covered < 0.15 * part.width * part.height
        }
        return RegionEvidence(range: layout.range(inside: region, canvas: CGRect(x: 0, y: 0, width: 1, height: 1)),
                              wordsInside: inside, textInk: textInk, otherInk: otherInk,
                              dominantObject: objects.contains { nonText($0, share: objectShare) },
                              salientObject: objects.contains { nonText($0, share: objectMinimum) })
    }

    /// A circled, scribbled or dragged region that contains words selects them straight away, unless a picture
    /// dominates it: less than `textShare` of its ink is text, and it holds a salient non-text object or non-text ink
    /// covering `pictureInk` of it. Such a mixed region is searched visually and offers "Select text".
    public static func region(unit region: CGRect, layout: TextLayout?, ink: InkMap?, objects: [CGRect]) -> Region {
        guard let layout, !layout.isEmpty else { return .visual(selectText: false) }
        let evidence = evidence(unit: region, layout: layout, ink: ink, objects: objects)
        guard let range = evidence.range else { return .visual(selectText: false) }
        let picture = evidence.dominantObject || evidence.salientObject || (evidence.otherInk ?? 0) >= pictureInk
        if picture, (evidence.textInk ?? 1) < textShare { return .visual(selectText: true) }
        return .text(range)
    }
}

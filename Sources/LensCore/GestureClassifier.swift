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
    /// background is the area's most common colour plus up to two flat panels, such as a code block or a sidebar:
    /// colours covering at least a twentieth of the area, mostly in solid patches. Cells that differ clearly from
    /// every background are ink, except the blended seams where two backgrounds meet.
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
        let total = columns * rows
        let buckets = (0..<total).map { bucket($0 * 4) }
        var counts: [Int: Int] = [:], solid: [Int: Int] = [:]
        func neighbours(_ x: Int, _ y: Int, radius: Int) -> [Int] {
            var found: [Int] = []
            for ny in max(0, y - radius)...min(rows - 1, y + radius) {
                for nx in max(0, x - radius)...min(columns - 1, x + radius) { found.append(buckets[ny * columns + nx]) }
            }
            return found
        }
        for y in 0..<rows {
            for x in 0..<columns {
                let own = buckets[y * columns + x]
                counts[own, default: 0] += 1
                if neighbours(x, y, radius: 1).allSatisfy({ $0 == own }) { solid[own, default: 0] += 1 }
            }
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let panels = counts.filter {
            $0.key != background && $0.value * 20 >= total && (solid[$0.key] ?? 0) * 2 >= $0.value
        }.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        let backgrounds = [background] + panels
        let bases = backgrounds.map { key -> (Int, Int, Int) in
            var sum = (0, 0, 0), members = 0
            for cell in 0..<total where buckets[cell] == key {
                sum = (sum.0 + Int(data[cell * 4]), sum.1 + Int(data[cell * 4 + 1]), sum.2 + Int(data[cell * 4 + 2]))
                members += 1
            }
            return (sum.0 / members, sum.1 / members, sum.2 / members)
        }
        func difference(_ colour: (Int, Int, Int), _ base: (Int, Int, Int)) -> Int {
            abs(colour.0 - base.0) + abs(colour.1 - base.1) + abs(colour.2 - base.2)
        }
        // How far `colour` is from the nearest blend of two backgrounds.
        func blendDistance(_ colour: (Int, Int, Int), _ one: (Int, Int, Int), _ two: (Int, Int, Int)) -> Int {
            let d = (two.0 - one.0, two.1 - one.1, two.2 - one.2), c = (colour.0 - one.0, colour.1 - one.1, colour.2 - one.2)
            let length = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
            guard length > 0 else { return difference(colour, one) }
            let t = min(1, max(0, Double(c.0 * d.0 + c.1 * d.1 + c.2 * d.2) / Double(length)))
            let blend = (one.0 + Int(t * Double(d.0)), one.1 + Int(t * Double(d.1)), one.2 + Int(t * Double(d.2)))
            return difference(colour, blend)
        }
        var cells = [Bool](repeating: false, count: total)
        for y in 0..<rows {
            for x in 0..<columns {
                let offset = (y * columns + x) * 4
                let colour = (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
                var ink = bases.allSatisfy { difference(colour, $0) > 72 }
                if ink, bases.count > 1 {
                    let near = Set(neighbours(x, y, radius: 2)).compactMap { backgrounds.firstIndex(of: $0) }
                    ink = !near.contains { one in
                        near.contains { two in two > one && blendDistance(colour, bases[one], bases[two]) <= 72 }
                    }
                }
                // Bitmap rows run top to bottom; the grid runs bottom to top like unit rects.
                cells[(rows - 1 - y) * columns + x] = ink
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

/// Decides what a gesture on the frozen screen means. Visual search is the default: circling, boxing or scribbling
/// over an area searches it visually unless the area is plainly ordinary text (`PlainText`, `RegionEvidence`), and a
/// single press on a word selects it only when its line is such text with nothing else close around it. Logos,
/// wordmarks, packaging, signs, headlines, text on photos and short labels are therefore searched visually, offering
/// "Select text" when the area has words. Explicit text gestures always select text: highlighting or underlining
/// along a line, double and triple clicks, and Shift-click. Everything is decided on this Mac from Vision's recognized
/// lines, the screenshot's pixels and Vision's salient objects. Geometry is in view coordinates for presses and
/// strokes and unit rects of the screenshot for regions.
public enum GestureClassifier {
    // MARK: Plain text

    /// Lines whose box is this many screen points high read as UI, body or code text. Vision's line boxes run about
    /// 0.9–1.35 times the font size, so this is roughly 9–20 pt type; anything larger is a headline, sign or logo.
    public static let lineHeights: ClosedRange<CGFloat> = 6...28
    /// Lines turned further than this many degrees from horizontal are rotated or curved: on a photo, a sign or a
    /// package. Vision reports flat screen text within about 1°.
    public static let maximumTilt: CGFloat = 2.5
    /// Vision's confidence below this means the text was hard to read, as on photos and decorated type. Clear screen
    /// text, even in a stylized face, comes back at 1.
    public static let minimumConfidence: Float = 0.75
    /// Letters covering more of their line's box than this (`LineStyle.ink`), or with strokes thicker than
    /// `maximumStroke` of its height, are a heavy display face such as Impact or a Black weight. Regular and bold text
    /// faces measure about 0.15–0.29 and 0.10–0.20.
    public static let maximumInk: CGFloat = 0.30
    public static let maximumStroke: CGFloat = 0.22
    /// Less of a line's box than this in one colour (`LineStyle.background`) puts the line on a photo, a gradient or
    /// a pattern; text on a plain background leaves 0.6–0.8 of it.
    public static let minimumBackground: CGFloat = 0.55
    /// A line is distinctive text when its paragraph has at least this many words; one or two words on their own are
    /// a label, a logo or a sign.
    public static let minimumWords = 3
    /// A circled region needs `minimumWords` inside it unless it lies in running text: paragraphs with at least this
    /// many words, where circling a word or two still selects them.
    public static let runningText = 8
    /// At least this share of a region's words must be on plain lines, which tolerates one odd line in a long passage.
    public static let plainShare: CGFloat = 0.9
    /// The lines in a text region differ in height by at most this factor; a headline above body text doesn't.
    public static let maximumHeightSpread: CGFloat = 1.6
    /// At least this share of a text region's ink is on its words...
    public static let textShare: CGFloat = 0.8
    /// ...and ink that isn't on words covers at most this share of it: a rule, a bullet or a small icon, not a
    /// picture.
    public static let maximumOtherInk: CGFloat = 0.05
    /// Around a pressed line, a little more non-text ink is allowed, since the band is narrow: an icon beside a short
    /// label still makes it a visual press.
    public static let maximumOtherInkAroundLine: CGFloat = 0.08
    /// A salient object covering this share of a region, and mostly not text, makes the region a picture.
    public static let objectShare: CGFloat = 0.3
    /// A salient object covering only this share of a region, and mostly not text, is still a picture in it: a photo
    /// beside a caption or a product beside its label.
    public static let objectMinimum: CGFloat = 0.02

    /// Which recognized lines read as plain text: worked out once per screen, after recognition.
    public struct PlainText: Equatable, Sendable {
        /// Per line of the layout: UI, body or code text by its size, tilt, Vision's confidence, its weight and
        /// background, and the length of its paragraph.
        public var lines: [Bool]
        /// Per line: plain, with nothing but text close around it, so a single press on one of its words selects it.
        public var pressable: [Bool]

        public init(lines: [Bool], pressable: [Bool]) {
            self.lines = lines
            self.pressable = pressable
        }

        func line(_ index: Int) -> Bool { lines.indices.contains(index) && lines[index] }
        func pressable(_ index: Int) -> Bool { pressable.indices.contains(index) && pressable[index] }
    }

    /// Whether `line` is set like ordinary screen text: `lineHeights` points high on a screen `screenHeight` points
    /// high, within `maximumTilt` of horizontal and read with at least `minimumConfidence`.
    public static func reads(_ line: TextLine, screenHeight: CGFloat) -> Bool {
        lineHeights.contains(line.box.height * screenHeight) && abs(line.tilt) <= maximumTilt &&
            line.confidence >= minimumConfidence
    }

    /// Whether letters drawn like `style` are a regular or bold text face on a plain background.
    public static func regular(_ style: LineStyle) -> Bool {
        style.ink <= maximumInk && style.stroke <= maximumStroke && style.background >= minimumBackground
    }

    /// Which lines of `layout` are plain text on a screen `screenHeight` points high. With the screenshot, each
    /// line's weight and background are measured, and a line is pressable only when the band around it holds nothing
    /// but text; without it, only the recognized geometry counts.
    public static func plainText(layout: TextLayout, screenHeight: CGFloat, image: CGImage? = nil) -> PlainText {
        let blockWords = layout.blocks.map { block in block.reduce(0) { $0 + layout.lines[$1].words.count } }
        var lines: [Bool] = [], pressable: [Bool] = []
        for line in layout.lines {
            var plain = blockWords[line.block] >= minimumWords && reads(line, screenHeight: screenHeight)
            if plain, let image, let style = LineStyle.measure(image, box: line.box) { plain = regular(style) }
            lines.append(plain)
            guard plain, let image else {
                pressable.append(plain)
                continue
            }
            let band = line.box.insetBy(dx: -line.box.height * 0.75, dy: -line.box.height * 0.5)
            guard let ink = InkMap(image: image, area: band, maxSide: 96) else {
                pressable.append(true)
                continue
            }
            let boxes = layout.words.filter { $0.box.intersects(band) }.map(\.box).map {
                $0.insetBy(dx: -$0.height * 0.2, dy: -$0.height * 0.2)
            }
            let counts = ink.count(in: ink.area, on: boxes)
            let clear = counts.ink < 3 || CGFloat(counts.onBoxes) >= textShare * CGFloat(counts.ink) &&
                CGFloat(counts.ink - counts.onBoxes) <= maximumOtherInkAroundLine * CGFloat(max(1, counts.cells))
            pressable.append(clear)
        }
        return PlainText(lines: lines, pressable: pressable)
    }

    // MARK: Presses

    public enum Press: Equatable, Sendable {
        /// One press on a word of plain text: it selects the word, and may become a highlight along its line or a
        /// circle.
        case word(Int)
        /// A double click selects the word's line, a triple click its paragraph.
        case range(TextRange)
        /// Shift-click extends the current text selection to the word.
        case extend(TextRange)
        /// Not on plain text, or the text isn't recognized yet: the press selects an area or object to search.
        case visual
    }

    /// `layout` is nil until the screen's text is recognized, so presses fall back to visual selection. A single
    /// press on a word whose line isn't pressable in `plain` (in a logo, on a photo, in display type or a short
    /// label) is a visual press; without `plain`, every recognized word is pressable. Double and triple clicks and
    /// Shift-click select text on any line.
    public static func press(at point: CGPoint, layout: TextLayout?, canvas: CGRect, clickCount: Int = 1,
                             shift: Bool = false, current: TextRange? = nil, plain: PlainText? = nil) -> Press {
        guard let layout, let index = layout.index(at: point, canvas: canvas) else { return .visual }
        if shift, let current { return .extend(TextRange(anchor: current.anchor, focus: index)) }
        if clickCount == 2, let line = layout.lineRange(containing: index) { return .range(line) }
        if clickCount >= 3, let block = layout.blockRange(containing: index) { return .range(block) }
        if !shift, let plain, !plain.pressable(layout.words[index].line) { return .visual }
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

    // MARK: Regions

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
        /// Of the words inside, how many are on plain lines.
        public var plainWords: Int = 0
        /// The tallest plain line with words inside divided by the shortest.
        public var heightSpread: CGFloat = 1
        /// The words in the paragraphs the region reaches into.
        public var contextWords: Int = 0

        /// Whether the region is plainly ordinary text: its words are distinctive (`minimumWords` of them, or part
        /// of `runningText`), at least `plainShare` of them on plain lines, those lines of similar height, nearly all
        /// of its ink on words, and no picture in it.
        public var isPlainText: Bool {
            typealias Rules = GestureClassifier
            guard range != nil, wordsInside > 0,
                  wordsInside >= Rules.minimumWords || contextWords >= Rules.runningText,
                  CGFloat(plainWords) >= Rules.plainShare * CGFloat(wordsInside),
                  heightSpread <= Rules.maximumHeightSpread, !dominantObject, !salientObject else { return false }
            if let textInk, textInk < Rules.textShare { return false }
            if let otherInk, otherInk > Rules.maximumOtherInk { return false }
            return true
        }
    }

    public enum Region: Equatable, Sendable {
        /// Plainly ordinary text: its words are selected.
        case text(TextRange)
        /// Searched visually; `selectText` offers its words when it contains any.
        case visual(selectText: Bool)
    }

    /// What a circled, scribbled or dragged region holds. `plain` says which lines are plain text; without it, every
    /// line counts as plain and only the words, ink and objects decide.
    public static func evidence(unit region: CGRect, layout: TextLayout, ink: InkMap?, objects: [CGRect],
                                plain: PlainText? = nil) -> RegionEvidence {
        let region = region.standardized
        var inside = 0, plainWords = 0
        var boxes: [CGRect] = []
        var lines = Set<Int>(), plainLines = Set<Int>()
        for word in layout.words {
            let box = word.box
            if region.contains(CGPoint(x: box.midX, y: box.midY)) {
                inside += 1
                lines.insert(word.line)
                if plain?.line(word.line) ?? true {
                    plainWords += 1
                    plainLines.insert(word.line)
                }
            }
            // Letters reach a little beyond Vision's word boxes.
            if box.intersects(region) { boxes.append(box.insetBy(dx: -box.height * 0.2, dy: -box.height * 0.2)) }
        }
        let heights = plainLines.map { layout.lines[$0].box.height }
        let spread = (heights.max() ?? 1) / max(heights.min() ?? 1, .ulpOfOne)
        let blocks = Set(lines.map { layout.lines[$0].block })
        let contextWords = blocks.reduce(0) { total, block in
            total + layout.blocks[block].reduce(0) { $0 + layout.lines[$1].words.count }
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
                              salientObject: objects.contains { nonText($0, share: objectMinimum) },
                              plainWords: plainWords, heightSpread: spread, contextWords: contextWords)
    }

    /// A circled, scribbled or dragged region is searched visually, offering "Select text" when it contains words,
    /// unless it is plainly ordinary text (`RegionEvidence.isPlainText`); then its words are selected. `plain` comes
    /// from `plainText(layout:screenHeight:image:)` for the same layout.
    public static func region(unit region: CGRect, layout: TextLayout?, ink: InkMap?, objects: [CGRect],
                              plain: PlainText?) -> Region {
        guard let layout, !layout.isEmpty else { return .visual(selectText: false) }
        let evidence = evidence(unit: region, layout: layout, ink: ink, objects: objects, plain: plain)
        guard let range = evidence.range else { return .visual(selectText: false) }
        return evidence.isPlainText ? .text(range) : .visual(selectText: true)
    }
}

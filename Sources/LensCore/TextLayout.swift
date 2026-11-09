import CoreGraphics
import Foundation

/// One selectable piece of a recognized line: a word with any punctuation attached to it.
public struct TextUnit: Equatable, Sendable {
    public var text: String
    /// The whitespace that follows the unit on its line; empty for scripts written without spaces.
    public var separator: String
    /// Unit rect of the screenshot (bottom-left origin).
    public var box: CGRect

    public init(text: String, separator: String, box: CGRect) {
        self.text = text
        self.separator = separator
        self.box = box
    }
}

/// A line as Apple Vision recognizes it, with its word units.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect
    public var units: [TextUnit]

    public init(text: String, box: CGRect, units: [TextUnit]) {
        self.text = text
        self.box = box
        self.units = units
    }

    /// A line whose unit boxes are estimated from character positions, used for translated text and as a fallback
    /// when Vision has no box for a word.
    public static func estimated(text: String, box: CGRect) -> RecognizedLine {
        let splits = TextSplitter.units(of: text)
        let boxes = TextSplitter.estimatedBoxes(lineBox: box, text: text, ranges: splits.map(\.range),
                                                rightToLeft: TextScript.isRightToLeft(text))
        let units = zip(splits, boxes).map { TextUnit(text: String(text[$0.range]), separator: $0.separator, box: $1) }
        return RecognizedLine(text: text, box: box, units: units)
    }
}

public enum TextScript {
    /// Scripts written without spaces between words, so their units and lines join without spaces.
    public static func isSpaceless(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x30FF, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    /// True when most strongly directional letters are Hebrew or Arabic.
    public static func isRightToLeft(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isRightToLeft(scalar) { rtl += 1 } else { ltr += 1 }
        }
        return rtl > ltr
    }
}

public enum TextSplitter {
    /// Splits a line into word units the way a text cursor moves: punctuation stays with its word, whitespace becomes
    /// the separator, and Chinese, Japanese or Thai words become units without separators.
    public static func units(of text: String) -> [(range: Range<String.Index>, separator: String)] {
        var words: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in
            if text[range].contains(where: { !$0.isWhitespace }) { words.append(range) }
        }
        guard let firstText = text.firstIndex(where: { !$0.isWhitespace }),
              let lastText = text.lastIndex(where: { !$0.isWhitespace }) else { return [] }
        let end = text.index(after: lastText)
        guard !words.isEmpty else { return [(firstText..<end, "")] }
        var result: [(Range<String.Index>, String)] = []
        var start = min(firstText, words[0].lowerBound)
        for index in words.indices {
            guard index + 1 < words.count else {
                result.append((start..<max(end, words[index].upperBound), ""))
                break
            }
            let gap = words[index].upperBound..<words[index + 1].lowerBound
            if let space = text[gap].firstIndex(where: \.isWhitespace),
               let lastSpace = text[gap].lastIndex(where: \.isWhitespace) {
                result.append((start..<space, " "))
                start = text.index(after: lastSpace)
            } else {
                result.append((start..<words[index + 1].lowerBound, ""))
                start = words[index + 1].lowerBound
            }
        }
        return result
    }

    /// Vision's word boxes, with missing or whole-line boxes replaced by estimates and boxes Vision shares between
    /// neighbouring words (such as "555-1234") divided between them.
    public static func repairedBoxes(_ boxes: [CGRect?], lineBox: CGRect, text: String,
                                     ranges: [Range<String.Index>], rightToLeft: Bool) -> [CGRect] {
        let estimates = estimatedBoxes(lineBox: lineBox, text: text, ranges: ranges, rightToLeft: rightToLeft)
        let reach = lineBox.insetBy(dx: -lineBox.height, dy: -lineBox.height)
        var result: [CGRect?] = boxes.indices.map { index in
            guard let box = boxes[index]?.standardized, !box.isNull, box.width > 0, box.height > 0,
                  reach.contains(box), ranges.count == 1 || box.width < lineBox.width * 0.98 else { return nil }
            return box
        }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            let overlap = a.intersection(b)
            guard !overlap.isNull else { return false }
            return overlap.width * overlap.height > 0.9 * max(a.width * a.height, b.width * b.height)
        }
        var index = 0
        while index < result.count {
            guard let box = result[index] else { index += 1; continue }
            var end = index + 1
            while end < result.count, let next = result[end], same(box, next) { end += 1 }
            if end - index > 1 {
                let counts = ranges[index..<end].map { CGFloat(text.distance(from: $0.lowerBound, to: $0.upperBound)) }
                let total = max(1, counts.reduce(0, +))
                var start: CGFloat = 0
                for (offset, count) in counts.enumerated() {
                    let width = box.width * count / total
                    let x = rightToLeft ? box.maxX - start - width : box.minX + start
                    result[index + offset] = CGRect(x: x, y: box.minY, width: width, height: box.height)
                    start += width
                }
            }
            index = end
        }
        return result.indices.map { result[$0] ?? estimates[$0] }
    }

    /// Boxes spread across the line in proportion to character counts, from the right for right-to-left text.
    public static func estimatedBoxes(lineBox: CGRect, text: String, ranges: [Range<String.Index>],
                                      rightToLeft: Bool) -> [CGRect] {
        let total = max(1, text.count)
        return ranges.map { range in
            let start = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound)) / CGFloat(total)
            let width = CGFloat(text.distance(from: range.lowerBound, to: range.upperBound)) / CGFloat(total)
            let x = rightToLeft ? lineBox.maxX - (start + width) * lineBox.width : lineBox.minX + start * lineBox.width
            return CGRect(x: x, y: lineBox.minY, width: width * lineBox.width, height: lineBox.height)
        }
    }
}

/// A selection of words from `anchor` (where the press started) to `focus` (where it is now), in reading order.
public struct TextRange: Equatable, Sendable {
    public var anchor: Int
    public var focus: Int

    public init(anchor: Int, focus: Int) {
        self.anchor = anchor
        self.focus = focus
    }

    public var lower: Int { min(anchor, focus) }
    public var upper: Int { max(anchor, focus) }
    public var indices: ClosedRange<Int> { lower...upper }
    public func contains(_ index: Int) -> Bool { indices.contains(index) }
}

public struct TextWord: Equatable, Sendable {
    public let text: String
    public let separator: String
    public let box: CGRect
    public let line: Int
    public let block: Int
}

public struct TextLine: Equatable, Sendable {
    public let words: Range<Int>
    public let box: CGRect
    public let block: Int
    public let rightToLeft: Bool
}

/// Recognized text in reading order, with the geometry Lens-style text selection needs. Boxes are unit rects of the
/// screenshot (bottom-left origin); geometry helpers take the canvas the screenshot is drawn in.
public struct TextLayout: Equatable, Sendable {
    public let words: [TextWord]
    public let lines: [TextLine]
    public let blocks: [Range<Int>]

    public static let empty = TextLayout(lines: [])

    public var isEmpty: Bool { words.isEmpty }
    public var all: TextRange? { words.isEmpty ? nil : TextRange(anchor: 0, focus: words.count - 1) }

    /// `aspect` is the screenshot's width divided by its height, so distances compare like on screen.
    public init(lines recognized: [RecognizedLine], aspect: CGFloat = 1) {
        let input = recognized.filter { !$0.units.isEmpty && !$0.box.isNull && $0.box.width > 0 }
        func metric(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * aspect, y: box.minY, width: box.width * aspect, height: box.height)
        }
        let boxes = input.map { metric($0.box) }
        let rtl = input.map { TextScript.isRightToLeft($0.text) }

        // Lines that are stacked closely, overlap sideways and have similar heights form a block (paragraph).
        var parent = Array(input.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for a in input.indices {
            for b in input.indices where b > a {
                let one = boxes[a], two = boxes[b]
                let small = min(one.height, two.height), large = max(one.height, two.height)
                guard large < small * 1.6 else { continue }
                let verticalOverlap = min(one.maxY, two.maxY) - max(one.minY, two.minY)
                let horizontalOverlap = min(one.maxX, two.maxX) - max(one.minX, two.minX)
                let stacked = verticalOverlap < 0.3 * small && -verticalOverlap < 0.9 * small && horizontalOverlap > 0
                let sameRow = verticalOverlap > 0.6 * small && -horizontalOverlap < 0.8 * small
                if stacked || sameRow { parent[root(a)] = root(b) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in input.indices { groups[root(index), default: []].append(index) }

        func rows(_ members: [Int]) -> [[Int]] {
            let sorted = members.sorted { boxes[$0].maxY > boxes[$1].maxY }
            var rows: [[Int]] = []
            for index in sorted {
                if let first = rows.last?.first {
                    let one = boxes[first], two = boxes[index]
                    let overlap = min(one.maxY, two.maxY) - max(one.minY, two.minY)
                    if overlap >= 0.5 * min(one.height, two.height) { rows[rows.count - 1].append(index); continue }
                }
                rows.append([index])
            }
            return rows
        }
        struct Block { var lines: [Int]; var box: CGRect; var rightToLeft: Bool; var lineHeight: CGFloat }
        var built: [Block] = groups.values.map { members in
            let rightToLeft = members.filter { rtl[$0] }.count * 2 > members.count
            let ordered = rows(members).flatMap { row in
                row.sorted { rightToLeft ? boxes[$0].maxX > boxes[$1].maxX : boxes[$0].minX < boxes[$1].minX }
            }
            let box = ordered.map { boxes[$0] }.reduce(CGRect.null) { $0.union($1) }
            return Block(lines: ordered, box: box, rightToLeft: rightToLeft, lineHeight: boxes[ordered[0]].height)
        }
        // Blocks are read top to bottom; blocks whose tops line up are read across, right to left for RTL text.
        built.sort { $0.box.maxY > $1.box.maxY }
        var bands: [[Block]] = []
        for block in built {
            if let first = bands.last?.first, first.box.maxY - block.box.maxY < 0.5 * first.lineHeight {
                bands[bands.count - 1].append(block)
            } else {
                bands.append([block])
            }
        }
        let ordered = bands.flatMap { band -> [Block] in
            let rightToLeft = band.filter(\.rightToLeft).count * 2 > band.count
            return band.sorted { rightToLeft ? $0.box.maxX > $1.box.maxX : $0.box.minX < $1.box.minX }
        }

        var words: [TextWord] = []
        var lines: [TextLine] = []
        var blocks: [Range<Int>] = []
        for (blockIndex, block) in ordered.enumerated() {
            let firstLine = lines.count
            for lineIndex in block.lines {
                let line = input[lineIndex]
                let start = words.count
                for unit in line.units {
                    words.append(TextWord(text: unit.text, separator: unit.separator, box: unit.box,
                                          line: lines.count, block: blockIndex))
                }
                lines.append(TextLine(words: start..<words.count, box: line.box, block: blockIndex,
                                      rightToLeft: rtl[lineIndex]))
            }
            blocks.append(firstLine..<lines.count)
        }
        self.words = words
        self.lines = lines
        self.blocks = blocks
    }

    // MARK: Text

    /// The selected text in reading order. Words keep their own spacing (none for scripts written without spaces),
    /// each line ends with a line break and paragraphs are separated by a blank line, as Copy keeps them. `flowing`
    /// joins the lines of a paragraph instead, which reads and translates better.
    public func text(for range: TextRange, flowing: Bool = false) -> String {
        guard !words.isEmpty else { return "" }
        let lower = max(0, range.lower), upper = min(words.count - 1, range.upper)
        guard lower <= upper else { return "" }
        var text = ""
        for index in lower...upper {
            let word = words[index]
            text += word.text
            guard index < upper else { break }
            let next = words[index + 1]
            if next.line == word.line { text += word.separator }
            else if next.block != word.block { text += flowing ? "\n" : "\n\n" }
            else if flowing { text += joiner(after: word.text, before: next.text) }
            else { text += "\n" }
        }
        return text
    }

    public var allText: String { all.map { text(for: $0) } ?? "" }

    private func joiner(after: String, before: String) -> String {
        if let last = after.unicodeScalars.last, TextScript.isSpaceless(last) { return "" }
        if let first = before.unicodeScalars.first, TextScript.isSpaceless(first) { return "" }
        return " "
    }

    // MARK: Ranges

    public func lineRange(containing index: Int) -> TextRange? {
        guard words.indices.contains(index) else { return nil }
        let line = lines[words[index].line].words
        return TextRange(anchor: line.lowerBound, focus: line.upperBound - 1)
    }

    public func blockRange(containing index: Int) -> TextRange? {
        guard words.indices.contains(index) else { return nil }
        let block = blocks[words[index].block]
        return TextRange(anchor: lines[block.lowerBound].words.lowerBound, focus: lines[block.upperBound - 1].words.upperBound - 1)
    }

    /// The range from the first to the last word whose centre lies inside `rect`, as circling text selects it.
    public func range(inside rect: CGRect, canvas: CGRect) -> TextRange? {
        let inside = words.indices.filter {
            let box = view($0, in: canvas)
            return rect.contains(CGPoint(x: box.midX, y: box.midY))
        }
        guard let first = inside.first, let last = inside.last else { return nil }
        return TextRange(anchor: first, focus: last)
    }

    // MARK: Geometry

    public func view(_ index: Int, in canvas: CGRect) -> CGRect {
        SelectionEditor.view(words[index].box, in: canvas)
    }

    /// The word under `point`, allowing `tolerance` points around each word.
    public func index(at point: CGPoint, canvas: CGRect, tolerance: CGFloat = 4) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in words.indices {
            let box = view(index, in: canvas)
            guard box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
            let distance = hypot(point.x - box.midX, (point.y - box.midY) * 2)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// The word a text cursor would reach at `point`: on the nearest line, the word under or nearest to it.
    public func nearestIndex(to point: CGPoint, canvas: CGRect) -> Int? {
        guard !lines.isEmpty else { return nil }
        func distance(_ line: TextLine) -> (CGFloat, CGFloat) {
            let box = SelectionEditor.view(line.box, in: canvas)
            let dy = point.y < box.minY ? box.minY - point.y : point.y > box.maxY ? point.y - box.maxY : 0
            let dx = point.x < box.minX ? box.minX - point.x : point.x > box.maxX ? point.x - box.maxX : 0
            return (dy, dx)
        }
        let line = lines.min { a, b in
            let one = distance(a), two = distance(b)
            return one.0 != two.0 ? one.0 < two.0 : one.1 < two.1
        }!
        return line.words.min { a, b in
            let one = view(a, in: canvas), two = view(b, in: canvas)
            func dx(_ box: CGRect) -> CGFloat {
                point.x < box.minX ? box.minX - point.x : point.x > box.maxX ? point.x - box.maxX : 0
            }
            return dx(one) != dx(two) ? dx(one) < dx(two) : abs(point.x - one.midX) < abs(point.x - two.midX)
        }
    }

    /// One highlight per line touched by the selection, covering its selected words.
    public func lineRects(for range: TextRange, canvas: CGRect, padding: CGFloat = 2) -> [CGRect] {
        guard !words.isEmpty else { return [] }
        let lower = max(0, range.lower), upper = min(words.count - 1, range.upper)
        guard lower <= upper else { return [] }
        var rects: [Int: CGRect] = [:]
        var order: [Int] = []
        for index in lower...upper {
            let line = words[index].line
            if rects[line] == nil { order.append(line) }
            rects[line] = (rects[line] ?? .null).union(view(index, in: canvas))
        }
        return order.map { rects[$0]!.insetBy(dx: -padding, dy: -padding) }
    }

    /// Where the selection's start and end handles sit: at the leading edge of the first word and the trailing edge of
    /// the last, which are the right-hand sides in right-to-left lines.
    public func handlePoints(for range: TextRange, canvas: CGRect) -> (start: CGPoint, end: CGPoint)? {
        guard words.indices.contains(range.lower), words.indices.contains(range.upper) else { return nil }
        let first = view(range.lower, in: canvas), last = view(range.upper, in: canvas)
        let firstRTL = lines[words[range.lower].line].rightToLeft
        let lastRTL = lines[words[range.upper].line].rightToLeft
        return (CGPoint(x: firstRTL ? first.maxX : first.minX, y: first.minY),
                CGPoint(x: lastRTL ? last.minX : last.maxX, y: last.minY))
    }
}

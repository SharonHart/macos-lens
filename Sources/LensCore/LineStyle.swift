import CoreGraphics

/// How a recognized line's letters are drawn, measured from the screenshot's pixels inside the line's box. Ordinary
/// UI, body and code text sits on a plain background in strokes of a regular weight; logos, packaging, signs and
/// headlines are heavier, or sit on a photo or a gradient.
public struct LineStyle: Equatable, Sendable {
    /// The share of the box covered by letters.
    public var ink: CGFloat
    /// The letters' mean horizontal stroke width as a share of the box's height.
    public var stroke: CGFloat
    /// The share of the box in its most common colour, give or take a little: most of it behind plain text, little of
    /// it on a photo or a gradient.
    public var background: CGFloat

    public init(ink: CGFloat, stroke: CGFloat, background: CGFloat) {
        self.ink = ink
        self.stroke = stroke
        self.background = background
    }

    /// The style of the letters inside `box`, a unit rect of `image` with a bottom-left origin, sampled at most
    /// `maxHeight` pixels high; nil when the box is empty or holds no clear letters.
    public static func measure(_ image: CGImage, box: CGRect, maxHeight: Int = 48, maxWidth: Int = 1536) -> LineStyle? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width,
                            height: box.height * height).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixels.isNull, pixels.width >= 2, pixels.height >= 4, let crop = image.cropping(to: pixels),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, CGFloat(maxHeight) / pixels.height, CGFloat(maxWidth) / pixels.width)
        let columns = max(2, Int((pixels.width * scale).rounded())), rows = max(4, Int((pixels.height * scale).rounded()))
        var data = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }
        let count = columns * rows
        var buckets = [Int](repeating: 0, count: 4096)
        for pixel in 0..<count {
            let offset = pixel * 4
            buckets[Int(data[offset] >> 4) << 8 | Int(data[offset + 1] >> 4) << 4 | Int(data[offset + 2] >> 4)] += 1
        }
        guard let common = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else { return nil }
        var sum = (0, 0, 0)
        for pixel in 0..<count {
            let offset = pixel * 4
            guard Int(data[offset] >> 4) << 8 | Int(data[offset + 1] >> 4) << 4 | Int(data[offset + 2] >> 4) == common
            else { continue }
            sum = (sum.0 + Int(data[offset]), sum.1 + Int(data[offset + 1]), sum.2 + Int(data[offset + 2]))
        }
        let members = buckets[common]
        let base = (sum.0 / members, sum.1 / members, sum.2 / members)
        var difference = [Int](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 766)
        for pixel in 0..<count {
            let offset = pixel * 4
            let value = abs(Int(data[offset]) - base.0) + abs(Int(data[offset + 1]) - base.1) +
                abs(Int(data[offset + 2]) - base.2)
            difference[pixel] = value
            histogram[value] += 1
        }
        // The letters' contrast is what the strongest few percent of pixels reach; ink is at least half of it.
        var seen = 0, peak = 0
        for value in stride(from: 765, through: 0, by: -1) {
            seen += histogram[value]
            if seen * 50 >= count { peak = value; break }
        }
        guard peak >= 96 else { return nil }
        let threshold = peak / 2
        var ink = 0, runs = 0, plain = 0
        for row in 0..<rows {
            var inside = false
            for column in 0..<columns {
                let value = difference[row * columns + column]
                if value <= 36 { plain += 1 }
                let on = value >= threshold
                if on {
                    ink += 1
                    if !inside { runs += 1 }
                }
                inside = on
            }
        }
        guard runs > 0 else { return nil }
        return LineStyle(ink: CGFloat(ink) / CGFloat(count),
                         stroke: CGFloat(ink) / CGFloat(runs) / CGFloat(rows),
                         background: CGFloat(plain) / CGFloat(count))
    }
}

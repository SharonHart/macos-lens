import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Draws the app icon and the disk image's Finder window, and checks the result. It is compiled together with
/// Sources/MacOSLens/LensMark.swift, so the mark on the icon and disk image is the app's own and can't drift from it.
/// The disk image's volume icon is the app's AppIcon.icns.
///
///     dmg-art icon <out.iconset>                   the app icon, 16–512 pt at @1x and @2x, for iconutil
///     dmg-art render <out dir> <font.ttf>          background.png, background@2x.png, layout.json
///     dmg-art resolve <alias hex> <bookmark hex>   prints the paths the background alias and bookmark resolve to
///     dmg-art preview <dump.json> <mount> <dir>    light and dark previews of the window, and the volume's icon
@main
enum DMGArt {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch (args.first, args.count) {
            case ("icon", 2): try writeIconset(to: URL(fileURLWithPath: args[1]))
            case ("render", 3): try render(into: URL(fileURLWithPath: args[1]), font: URL(fileURLWithPath: args[2]))
            case ("resolve", 3): try resolve(aliasHex: args[1], bookmarkHex: args[2])
            case ("preview", 4):
                try preview(dump: URL(fileURLWithPath: args[1]), volume: args[2], into: URL(fileURLWithPath: args[3]))
            default: throw Failure("usage: dmg-art icon|render|resolve|preview …")
            }
        } catch {
            FileHandle.standardError.write(Data("dmg-art: \(error)\n".utf8))
            exit(1)
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Layout and colours

/// The window's layout in points from its top-left corner, the way Finder stores icon positions.
enum Layout {
    static let window = CGSize(width: 660, height: 400)
    static let iconSize: CGFloat = 128
    static let textSize: CGFloat = 13
    static let app = CGPoint(x: 170, y: 190)
    static let applications = CGPoint(x: 490, y: 190)
    static let wordmarkCentre: CGFloat = 72
    static let wordmarkSize: CGFloat = 34
    static let captionCentre: CGFloat = 346
    static let captionSize: CGFloat = 16
    static let caption = "Drag to Applications to install"
    /// Finder draws icon labels black in light mode and white in dark mode, whatever the background. Between these
    /// lines the background is one flat colour that keeps both at 4.5:1 or better.
    static let labelBand: ClosedRange<CGFloat> = 240...316
    /// Where the labels can fall: under each icon, one or two lines.
    static let labelRects = [app, applications].map { CGRect(x: $0.x - 80, y: $0.y + iconSize / 2, width: 160, height: 46) }
}

enum Brand {
    static let lensBlue = RGB(0x42, 0x85, 0xF4)
    static let paper = RGB(0xFF, 0xFF, 0xFF)
    static let mist = RGB(0xEE, 0xF1, 0xF6)
    /// Labels need a luminance in 0.175…0.183 for 4.5:1 against both black and white; aim for the middle.
    static let labelLuminance = 0.179
}

struct RGB {
    var r, g, b: Double
    init(_ r: Int, _ g: Int, _ b: Int) { (self.r, self.g, self.b) = (Double(r) / 255, Double(g) / 255, Double(b) / 255) }
    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func encoded(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    var luminance: Double { 0.2126 * RGB.linear(r) + 0.7152 * RGB.linear(g) + 0.0722 * RGB.linear(b) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// This hue at another relative luminance, rounded to whole 8-bit values.
    func atLuminance(_ target: Double) -> RGB {
        let k = target / luminance
        func channel(_ c: Double) -> Double { (min(1, RGB.encoded(RGB.linear(c) * k)) * 255).rounded() / 255 }
        return RGB(r: channel(r), g: channel(g), b: channel(b))
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
}

// MARK: - Drawing

/// An sRGB bitmap measured in points, `scale` pixels per point, drawn with its origin at the bottom left.
final class Canvas {
    let size: CGSize
    let scale: CGFloat
    let context: CGContext

    init(size: CGSize, scale: CGFloat) {
        self.size = size
        self.scale = scale
        context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
    }

    /// Runs `body` with AppKit drawing pointed at this canvas.
    func draw(_ body: (CGContext) throws -> Void) rethrows {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        try body(context)
    }

    /// A rectangle given from the top left, in the canvas's bottom-left coordinates.
    func rect(top r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
    func y(top: CGFloat) -> CGFloat { size.height - top }

    /// The colour of every pixel inside `top`, a rectangle from the top left.
    func pixels(inTop r: CGRect) -> [RGB] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let x0 = Int((r.minX * scale).rounded()), x1 = Int((r.maxX * scale).rounded())
        let y0 = Int((r.minY * scale).rounded()), y1 = Int((r.maxY * scale).rounded())
        var result: [RGB] = []
        for row in max(0, y0)..<min(context.height, y1) {
            for column in max(0, x0)..<min(context.width, x1) {
                let p = data + row * context.bytesPerRow + column * 4
                result.append(RGB(Int(p[0]), Int(p[1]), Int(p[2])))
            }
        }
        return result
    }

    func writePNG(to url: URL, dpi: CGFloat? = nil) throws {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure("can't write \(url.path)") }
        let ppi = dpi ?? 72 * scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: ppi, kCGImagePropertyDPIHeight: ppi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("can't write \(url.path)") }
    }
}

/// The app's mark in one colour. The template image is drawn into its own layer and coloured there.
func drawMark(in rect: CGRect, color: CGColor, context: CGContext) {
    let layer = rect.insetBy(dx: -2, dy: -2)
    context.saveGState()
    context.beginTransparencyLayer(in: layer, auxiliaryInfo: nil)
    LensMark.image(size: rect.width).draw(in: rect)
    context.setBlendMode(.sourceIn)
    context.setFillColor(color)
    context.fill(layer)
    context.endTransparencyLayer()
    context.restoreGState()
}

/// The brand typeface, Urbanist, at a weight on its variable axis.
func brandFont(_ url: URL, size: CGFloat, weight: Double) throws -> CTFont {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
          let base = descriptors.first else { throw Failure("can't load the font at \(url.path)") }
    let wght = 0x7767_6874
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, [kCTFontVariationAttribute: [wght: weight]] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
    let applied = (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[NSNumber(value: wght)]?.doubleValue
    guard CTFontCopyFamilyName(font) as String == "Urbanist", let applied, abs(applied - weight) < 1 else {
        throw Failure("\(url.lastPathComponent) isn't Urbanist with a weight axis")
    }
    return font
}

func textLine(_ string: String, font: CTFont, color: CGColor, tracking: CGFloat = 0) -> (line: CTLine, width: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    // The tracking also follows the last letter; leave it out so the text centres on its ink.
    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - tracking)
}

func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, in context: CGContext) {
    context.saveGState()
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
}

// MARK: - Background

/// The window background: a Lens-blue wash, darker at the top and bottom, flat behind the icon labels, with the
/// mark and wordmark, an arrow from the app to Applications, and the caption.
func drawBackground(on canvas: Canvas, font: URL, withArtwork: Bool) throws {
    let context = canvas.context
    let height = canvas.size.height
    let band = Brand.lensBlue.atLuminance(Brand.labelLuminance)
    let stops: [(top: CGFloat, luminance: Double)] = [
        (0, 0.10), (120, 0.135), (Layout.labelBand.lowerBound, Brand.labelLuminance),
        (Layout.labelBand.upperBound, Brand.labelLuminance), (height, 0.125),
    ]
    let fromBottom = stops.reversed()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: fromBottom.map { Brand.lensBlue.atLuminance($0.luminance).cgColor } as CFArray,
                              locations: fromBottom.map { 1 - $0.top / height })!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    let bandRect = CGRect(x: 0, y: Layout.labelBand.lowerBound, width: canvas.size.width,
                          height: Layout.labelBand.upperBound - Layout.labelBand.lowerBound)
    context.setFillColor(band.cgColor)
    context.fill(canvas.rect(top: bandRect))
    guard withArtwork else { return }

    let white = CGColor(gray: 1, alpha: 1)
    // The wordmark: the brand's lockup, the mark beside the name with its cap height centred on the mark.
    let size = Layout.wordmarkSize
    let cap = 0.70 * size, side = (cap * 1.62).rounded(), gap = side * 0.32
    let name = textLine(LensMark.label, font: try brandFont(font, size: size, weight: 640), color: white, tracking: -0.025 * size)
    let left = ((canvas.size.width - (side + gap + name.width)) / 2).rounded()
    let markTop = (Layout.wordmarkCentre - side / 2).rounded()
    drawMark(in: canvas.rect(top: CGRect(x: left, y: markTop, width: side, height: side)), color: white, context: context)
    draw(name.line, x: left + side + gap, baseline: canvas.y(top: markTop + side / 2 + cap / 2), in: context)

    // A quiet arrow across the gap between the two icons.
    let arrowY = canvas.y(top: Layout.app.y)
    let start = Layout.app.x + Layout.iconSize / 2 + 26, end = Layout.applications.x - Layout.iconSize / 2 - 26
    let head: CGFloat = 12
    context.saveGState()
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
    context.setLineWidth(3.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: start, y: arrowY))
    context.addLine(to: CGPoint(x: end, y: arrowY))
    context.move(to: CGPoint(x: end - head, y: arrowY + head))
    context.addLine(to: CGPoint(x: end, y: arrowY))
    context.addLine(to: CGPoint(x: end - head, y: arrowY - head))
    context.strokePath()
    context.restoreGState()

    let captionFont = try brandFont(font, size: Layout.captionSize, weight: 600)
    let caption = textLine(Layout.caption, font: captionFont, color: white)
    let captionCap = CTFontGetCapHeight(captionFont)
    draw(caption.line, x: ((canvas.size.width - caption.width) / 2).rounded(),
         baseline: canvas.y(top: Layout.captionCentre + captionCap / 2), in: context)
}

/// Fails unless Finder's labels and our white text keep at least 4.5:1 against the background under them.
func checkContrast(_ plain: Canvas) throws {
    let black = 0.0, white = 1.0
    for rect in Layout.labelRects {
        let lums = plain.pixels(inTop: rect).map(\.luminance)
        guard let low = lums.min(), let high = lums.max() else { throw Failure("no pixels under a label") }
        let worst = min(RGB.contrast(low, black), RGB.contrast(high, white))
        guard worst >= 4.5 else { throw Failure(String(format: "label contrast %.2f:1 (luminance %.3f…%.3f)", worst, low, high)) }
    }
    let textRects = [
        CGRect(x: 150, y: Layout.wordmarkCentre - 24, width: 360, height: 48),
        CGRect(x: 180, y: Layout.captionCentre - 14, width: 300, height: 28),
    ]
    for rect in textRects {
        guard let high = plain.pixels(inTop: rect).map(\.luminance).max(), RGB.contrast(high, white) >= 4.5 else {
            throw Failure("white text falls below 4.5:1 at \(rect)")
        }
    }
}

// MARK: - App icon

/// The brand's app icon: the mark in Lens blue on a white-to-mist rounded tile, as in the brand kit. It sits on
/// Apple's macOS icon grid (an 824 pt body in a 1024 pt canvas) so macOS 26 shows it as is, without the grey
/// container it puts around non-conforming icons.
func brandIcon(pixels: Int) -> Canvas {
    let side = CGFloat(pixels)
    let canvas = Canvas(size: CGSize(width: side, height: side), scale: 1)
    let k = side / 1024
    let small = pixels <= 32
    canvas.draw { context in
        let tile = squircle(CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k))
        // Apple's template shadow, fitted to the alpha falloff of the system apps' icons, which also drop it at 32 px.
        if !small {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 38 * k, color: CGColor(gray: 0, alpha: 0.26))
            context.addPath(tile)
            context.setFillColor(Brand.paper.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(tile)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [Brand.paper.cgColor, Brand.mist.cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924 * k), end: CGPoint(x: 0, y: 100 * k), options: [])
        context.restoreGState()
        context.addPath(tile)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
        context.setLineWidth(2 * k)
        context.strokePath()
        let mark = (small ? 640 : 560) * k
        drawMark(in: CGRect(x: (side - mark) / 2, y: (side - mark) / 2, width: mark, height: mark),
                 color: Brand.lensBlue.cgColor, context: context)
    }
    return canvas
}

/// A superellipse close to the macOS continuous-corner icon shape.
func squircle(_ rect: CGRect, n: Double = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let r = rect.width / 2
    for i in 0..<steps {
        let t = 2 * Double.pi * Double(i) / Double(steps)
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + r * CGFloat(copysign(pow(abs(c), 2 / n), c)),
                            y: rect.midY + r * CGFloat(copysign(pow(abs(s), 2 / n), s)))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Commands

func writeIconset(to iconset: URL) throws {
    let files = FileManager.default
    try? files.removeItem(at: iconset)
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
            try brandIcon(pixels: points * factor).writePNG(to: iconset.appendingPathComponent(name), dpi: 72 * CGFloat(factor))
        }
    }
}

func render(into directory: URL, font: URL) throws {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for scale in [1, 2] as [CGFloat] {
        let plain = Canvas(size: Layout.window, scale: scale)
        try plain.draw { _ in try drawBackground(on: plain, font: font, withArtwork: false) }
        try checkContrast(plain)
        let canvas = Canvas(size: Layout.window, scale: scale)
        try canvas.draw { _ in try drawBackground(on: canvas, font: font, withArtwork: true) }
        try canvas.writePNG(to: directory.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
    }

    let layout: [String: Any] = [
        "window": [Layout.window.width, Layout.window.height],
        "icon_size": Layout.iconSize, "text_size": Layout.textSize,
        "app": [Layout.app.x, Layout.app.y], "applications": [Layout.applications.x, Layout.applications.y],
    ]
    try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("layout.json"))

    let band = Brand.lensBlue.atLuminance(Brand.labelLuminance)
    print(String(format: "label band #%02X%02X%02X: %.2f:1 with black labels, %.2f:1 with white labels",
                 Int((band.r * 255).rounded()), Int((band.g * 255).rounded()), Int((band.b * 255).rounded()),
                 RGB.contrast(band.luminance, 0), RGB.contrast(band.luminance, 1)))
}

/// Resolves the background's alias (via the system's alias-to-bookmark conversion) and bookmark, without UI or mounting.
func resolve(aliasHex: String, bookmarkHex: String) throws {
    func data(_ hex: String) throws -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else { throw Failure("bad hex") }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
    func path(_ bookmark: Data) throws -> String {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            .resolvingSymlinksInPath().path
    }
    // CFURLCreateBookmarkDataFromAliasRecord is deprecated but is still how the system reads Finder's alias records;
    // look it up at run time so the build stays free of deprecation warnings.
    typealias FromAlias = @convention(c) (CFAllocator?, CFData) -> Unmanaged<CFData>?
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CFURLCreateBookmarkDataFromAliasRecord"),
          let converted = unsafeBitCast(symbol, to: FromAlias.self)(nil, try data(aliasHex) as CFData)?.takeRetainedValue()
    else { throw Failure("the system couldn't read the background alias") }
    print("alias", try path(converted as Data))
    print("bookmark", try path(try data(bookmarkHex)))
}

/// Light and dark previews of the window as Finder lays it out, from the image's mounted .DS_Store values.
func preview(dump: URL, volume: String, into directory: URL) throws {
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any],
          let window = json["window"] as? [String: Double], let icons = json["icons"] as? [String: [Double]],
          let iconSize = json["icon_size"] as? Double, let textSize = json["text_size"] as? Double,
          let title = json["volume_name"] as? String, let width = window["width"], let height = window["height"]
    else { throw Failure("unexpected dump") }
    guard let background = NSImage(contentsOfFile: (volume as NSString).appendingPathComponent(".background.tiff")) else {
        throw Failure("no background on the volume")
    }
    let reps = background.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ", ")
    print("background representations: \(reps) for a \(Int(background.size.width))x\(Int(background.size.height)) pt window")

    let margin: CGFloat = 40, titleBar: CGFloat = 28
    let content = CGSize(width: width, height: height)
    for dark in [false, true] {
        let canvas = Canvas(size: CGSize(width: content.width + margin * 2, height: content.height + titleBar + margin * 2), scale: 2)
        canvas.draw { context in
            context.setFillColor(dark ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                                      : CGColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvas.size))
            let frame = CGRect(x: margin, y: margin, width: content.width, height: content.height + titleBar)
            let shape = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.3))
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.setFillColor(dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                                      : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
            context.fill(frame)
            for (i, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
                context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
                context.fillEllipse(in: CGRect(x: frame.minX + 14 + CGFloat(i) * 20, y: frame.maxY - titleBar / 2 - 6, width: 12, height: 12))
            }
            let titleText = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.15, alpha: 1),
            ])
            titleText.draw(at: CGPoint(x: frame.midX - titleText.size().width / 2, y: frame.maxY - titleBar / 2 - titleText.size().height / 2))
            let contentRect = CGRect(x: margin, y: margin, width: content.width, height: content.height)
            background.draw(in: contentRect)

            for (name, centre) in icons.sorted(by: { $0.key < $1.key }) {
                let path = (volume as NSString).appendingPathComponent(name)
                let x = contentRect.minX + centre[0], top = centre[1]
                let iconRect = CGRect(x: x - iconSize / 2, y: contentRect.maxY - top - iconSize / 2, width: iconSize, height: iconSize)
                NSWorkspace.shared.icon(forFile: path).draw(in: iconRect)
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let label = NSAttributedString(string: FileManager.default.displayName(atPath: path), attributes: [
                    .font: NSFont.systemFont(ofSize: textSize),
                    .foregroundColor: dark ? NSColor.white : NSColor.black,
                    .paragraphStyle: style,
                ])
                label.draw(in: CGRect(x: x - 70, y: iconRect.minY - 4 - 34, width: 140, height: 34))
            }
            context.restoreGState()
        }
        try canvas.writePNG(to: directory.appendingPathComponent(dark ? "dmg.dark.png" : "dmg.light.png"))
    }

    let icon = Canvas(size: CGSize(width: 256, height: 256), scale: 2)
    icon.draw { _ in NSWorkspace.shared.icon(forFile: volume).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256)) }
    try icon.writePNG(to: directory.appendingPathComponent("dmg.volume-icon.png"))
}

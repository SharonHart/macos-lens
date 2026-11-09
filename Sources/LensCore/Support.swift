import AppKit
import CryptoKit
import NaturalLanguage

/// Width of the results sheet. Google switches to its cramped phone layout below about 560 points.
public enum PanelSizing {
    public static let minimum: CGFloat = 440
    public static let defaultsKey = "panelWidth"

    public static func defaultWidth(screenWidth: CGFloat) -> CGFloat {
        min(max(screenWidth * 0.36, 560), 760)
    }

    public static func maximum(screenWidth: CGFloat) -> CGFloat {
        screenWidth * 0.75 - 40
    }

    public static func clamp(_ width: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let largest = maximum(screenWidth: screenWidth)
        return min(max(width, min(minimum, largest)), largest)
    }

    /// The width the user last dragged to, or the default for this screen.
    public static func width(stored: Double?, screenWidth: CGFloat) -> CGFloat {
        let preferred = stored.map { CGFloat($0) }.flatMap { $0 > 0 ? $0 : nil } ?? defaultWidth(screenWidth: screenWidth)
        return clamp(preferred, screenWidth: screenWidth)
    }
}

/// The largest font size, in whole points, whose measured text fits a box, as Lens fits translated text to each line.
public enum TextFit {
    public static func size(fitting box: CGSize, minimum: CGFloat = 6, maximum: CGFloat = 96,
                            measure: (CGFloat) -> CGSize) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return minimum }
        func fits(_ size: Int) -> Bool {
            let measured = measure(CGFloat(size))
            return measured.width <= box.width && measured.height <= box.height
        }
        var low = Int(minimum.rounded(.up)), high = max(low, Int(maximum.rounded(.down)))
        guard fits(low) else { return minimum }
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return CGFloat(low)
    }

    public static func size(for text: String, in box: CGSize, weight: NSFont.Weight = .medium) -> CGFloat {
        size(fitting: box, maximum: box.height) { size in
            (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
        }
    }
}

public struct SampledColor: Equatable, Sendable {
    public let red: CGFloat, green: CGFloat, blue: CGFloat

    public var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    /// Black or white, whichever reads better on this colour.
    public var isLight: Bool { luminance > 0.55 }
    public var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

public enum ImageSampling {
    /// The colour around the edge of a text line — the page behind its letters — as the median of the line box's
    /// border pixels. `pixels` uses a top-left origin like `CGImage`.
    public static func background(of image: CGImage, pixels: CGRect) -> SampledColor? {
        let rect = pixels.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let crop = image.cropping(to: rect) else { return nil }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var samples: [(CGFloat, CGFloat, CGFloat)] = []
        func add(_ x: Int, _ y: Int) {
            let offset = (y * width + x) * 4
            samples.append((CGFloat(data[offset]) / 255, CGFloat(data[offset + 1]) / 255, CGFloat(data[offset + 2]) / 255))
        }
        let stepX = max(1, width / 64), stepY = max(1, height / 16)
        for x in stride(from: 0, to: width, by: stepX) { add(x, 0); add(x, height - 1) }
        for y in stride(from: 0, to: height, by: stepY) { add(0, y); add(width - 1, y) }
        let sorted = samples.sorted { ($0.0 * 0.2126 + $0.1 * 0.7152 + $0.2 * 0.0722) < ($1.0 * 0.2126 + $1.1 * 0.7152 + $1.2 * 0.0722) }
        let median = sorted[sorted.count / 2]
        return SampledColor(red: median.0, green: median.1, blue: median.2)
    }
}

public enum TextLanguage {
    /// The dominant language of `text`, such as "en", "fr", "ar" or "he", detected on this Mac.
    public static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// Vision languages to recognize: the user's preferred languages it supports, in order (automatic detection
    /// covers the rest). Languages Vision lacks, such as Hebrew, are skipped.
    public static func recognitionLanguages(preferred: [String], supported: [String]) -> [String] {
        var picked: [String] = []
        func code(_ identifier: String) -> [String] {
            identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map { $0.lowercased() }
        }
        for identifier in preferred {
            let wanted = code(identifier)
            guard let language = wanted.first else { continue }
            let candidates = supported.filter { code($0).first == language }
            // Prefer a matching script or region, such as zh-Hant for zh-Hant-TW.
            let match = candidates.first { code($0).dropFirst().contains { wanted.dropFirst().contains($0) } }
                ?? candidates.first
            if let match, !picked.contains(match) { picked.append(match) }
        }
        return picked.isEmpty ? Array(supported.prefix(1)) : picked
    }
}

/// A local page that makes the user's own browser upload the selection to Google Lens, like a browser's
/// "Search image with Google". The results page, including the searched-image thumbnail, then belongs to that
/// browser's session. This form posts to Lens's undocumented upload endpoint, not an official API.
public enum LensHandoff {
    public static let fieldName = "encoded_image"

    public static func action(language: String) -> URL {
        var components = URLComponents(string: "https://lens.google.com/v3/upload")!
        components.queryItems = [URLQueryItem(name: "hl", value: language)]
        return components.url!
    }

    public static let script = """
    (() => {
      const form = document.getElementById('lens');
      const input = document.getElementById('image-file');
      const status = document.getElementById('status');
      try {
        const source = document.getElementById('preview').getAttribute('src');
        const data = atob(source.slice(source.indexOf(',') + 1));
        const bytes = new Uint8Array(data.length);
        for (let i = 0; i < data.length; i++) bytes[i] = data.charCodeAt(i);
        const transfer = new DataTransfer();
        transfer.items.add(new File([bytes], 'selection.png', { type: 'image/png' }));
        input.files = transfer.files;
        form.submit();
      } catch (error) {
        input.style.display = 'block';
        status.textContent = 'Save the picture above, choose it below, then press “Search with Google Lens”.';
      }
    })();
    """

    public static var scriptHash: String {
        "sha256-" + Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The page for `png`, the selected crop. It carries nothing else: no URLs except the Lens form action and no
    /// other fields, cookies or identifiers.
    public static func html(png: Data, language: String) -> String {
        let action = escape(action(language: language).absoluteString)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '\(scriptHash)'; style-src 'unsafe-inline'; img-src data:; form-action https:">
        <meta name="referrer" content="no-referrer">
        <title>Opening Google Lens…</title>
        <style>
        body { font: 15px -apple-system, system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f6f8fc; color: #202124; }
        main { text-align: center; max-width: 420px; padding: 24px; }
        img { max-width: 240px; max-height: 160px; border-radius: 12px; box-shadow: 0 1px 6px rgba(0,0,0,.2); }
        button { margin-top: 16px; font: inherit; padding: 8px 18px; border-radius: 18px; border: 0; background: #1a73e8; color: white; cursor: pointer; }
        input[type=file] { display: none; margin: 12px auto 0; }
        p.note { color: #5f6368; font-size: 13px; }
        </style>
        </head>
        <body>
        <main>
        <img id="preview" alt="Your selection" src="data:image/png;base64,\(png.base64EncodedString())">
        <p id="status">Opening Google Lens…</p>
        <form id="lens" method="post" enctype="multipart/form-data" action="\(action)">
        <input id="image-file" type="file" name="\(fieldName)" accept="image/png">
        <button type="submit">Search with Google Lens</button>
        </form>
        <noscript><style>input[type=file] { display: block; }</style><p class="note">Scripts are turned off, so the picture can't be attached automatically. Save the picture above, choose it, then press “Search with Google Lens”.</p></noscript>
        <p class="note">macOS Lens made this page on your Mac. It sends only the picture above to Google Lens.</p>
        </main>
        <script>\(script)</script>
        </body>
        </html>
        """
    }
}

/// The Buy Me a Coffee page. Defined only by the `MLSupportURL` key in Info.plist, so it can change without code edits.
public enum SupportLink {
    public static let key = "MLSupportURL"

    public static func url(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> URL? {
        guard let value = infoDictionary?[key] as? String, let url = URL(string: value),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "buymeacoffee.com" || host == "www.buymeacoffee.com" else { return nil }
        return url
    }
}

/// Splits a translated paragraph back over the original lines, so each line can be drawn in place like Lens does.
public enum TranslationLayout {
    /// Words are assigned in order to the line whose share of the original characters covers their midpoint, so a
    /// line keeps roughly its proportion of the paragraph. Spaceless scripts are split into their word units.
    public static func distribute(_ text: String, across lineLengths: [Int]) -> [String] {
        guard !lineLengths.isEmpty else { return [] }
        let units = TextSplitter.units(of: text)
        guard lineLengths.count > 1 else {
            return [units.enumerated().map { index, unit in
                String(text[unit.range]) + (index + 1 < units.count ? unit.separator : "")
            }.joined()]
        }
        var lines = Array(repeating: "", count: lineLengths.count)
        guard !units.isEmpty else { return lines }
        let weights = lineLengths.map { Double(max(1, $0)) }
        let total = weights.reduce(0, +)
        var limits: [Double] = []
        var running = 0.0
        for weight in weights {
            running += weight
            limits.append(running / total)
        }
        let lengths = units.map {
            Double(max(1, text.distance(from: $0.range.lowerBound, to: $0.range.upperBound) + $0.separator.count))
        }
        let characters = lengths.reduce(0, +)
        var consumed = 0.0
        var assigned: [Int] = []
        var line = 0
        for length in lengths {
            let middle = (consumed + length / 2) / characters
            while line < limits.count - 1 && middle > limits[line] { line += 1 }
            assigned.append(line)
            consumed += length
        }
        for (index, unit) in units.enumerated() {
            let target = assigned[index]
            let last = index + 1 == units.count || assigned[index + 1] != target
            lines[target] += String(text[unit.range]) + (last ? "" : unit.separator)
        }
        return lines
    }
}

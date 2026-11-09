import AppKit
import LensCore
import WebKit

/// Reproduces the stretched image in the results sheet and checks the fix. Google's server-rendered Lens viewer
/// draws the searched image with `object-fit: fill` in a box that ignores the image's shape, and only its own
/// script corrects the box a second or more later. A generated page served from a local scheme does the same, and
/// it's loaded through the real overlay reveal path and sampled every 100 ms. Each sample records the page itself
/// (what the sheet used to show) and what the sheet shows now. Nothing is captured from the screen, and only the
/// optional `live` run sends anything: a generated picture, to Google Lens.
@MainActor
enum PanelAspectCheck {
    static let scheme = "lens-fixture"
    nonisolated static let tolerance: CGFloat = 0.02
    static let size = (width: 700, height: 500)

    struct Sample {
        var time: Int
        /// "crop" while our crop covers the page, "page" for the results page, or "nothing".
        var source: String
        /// How far the shown image's aspect ratio is from the picture's own, e.g. 0.37 for 37%.
        var error: CGFloat?
        var image: CGImage?
    }

    struct Trace {
        var page: [Sample] = []
        var shown: [Sample] = []
        var loadFrame: CGRect?
        var body: CGRect = .zero
    }

    static func run(folder: URL, label: String, delays: [Int]) async throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let handler = FixtureScheme()
        ResultsPanel.configureForChecks = { configuration in
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        ResultsPanel.checkScheme = scheme
        defer { ResultsPanel.configureForChecks = nil; ResultsPanel.checkScheme = nil }
        var passed = true
        // Google first commits a short-lived results page without the image, then replaces it; "hop" does the same.
        let cases = delays.map { (path: "page", delay: $0, name: "\($0)ms", what: "page answers after \($0) ms") }
            + [(path: "hop", delay: 0, name: "hop", what: "a blank results page first, then the real one")]
        for item in cases {
            let delay = item.delay
            handler.delay = delay
            let trace = try await record(ticks: 30) { URLRequest(url: URL(string: "\(scheme)://results/\(item.path)")!) }
            for (page, shown) in zip(trace.page, trace.shown) {
                print("SAMPLE \(item.name) t=\(page.time)ms page=\(percent(page.error)) " +
                      "shows=\(shown.source) error=\(percent(shown.error))")
            }
            let name = "panel.\(label).\(item.name)"
            try write(strip: trace.page, title: "Results page alone (old sheet), \(item.what)",
                      to: folder.appendingPathComponent("\(name).page.png"))
            try write(strip: trace.shown, title: "What the sheet shows now, \(item.what)",
                      to: folder.appendingPathComponent("\(name).shown.png"))
            let worst = trace.shown.compactMap(\.error).max() ?? 1
            let reproduced = trace.page.contains { ($0.error ?? 0) > tolerance }
            let complete = trace.shown.allSatisfy { $0.error != nil }
            let revealed = trace.shown.last?.source == "page"
            let sized = trace.loadFrame.map { $0.width >= 100 && $0.height >= 100 && $0.size == trace.body.size } == true
            let ok = reproduced && complete && revealed && sized && worst <= tolerance
            passed = passed && ok
            print("\(ok ? "PASS" : "FAIL") \(item.name): web view at load \(describe(trace.loadFrame)), " +
                  "final body \(describe(trace.body)); page alone stretched up to " +
                  "\(percent(trace.page.compactMap(\.error).max())); the sheet showed the image in " +
                  "\(trace.shown.filter { $0.error != nil }.count)/\(trace.shown.count) samples, worst error " +
                  "\(percent(worst)) (limit 2%), and the page itself by the end: \(revealed)")
        }
        return passed
    }

    /// Uploads only a generated picture to Google Lens through the real reveal path and records the same samples.
    static func live(folder: URL, label: String, seconds: Int = 12) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ResultsPanel.configureForChecks = { $0.websiteDataStore = .nonPersistent() }
        defer { ResultsPanel.configureForChecks = nil }
        let picture = try picture(width: size.width, height: size.height, pattern: true)
        let trace = try await record(ticks: seconds * 10, screen: 1800) { try LensUpload.request(for: picture) }
        for (page, shown) in zip(trace.page, trace.shown) {
            print("LIVE t=\(page.time)ms page=\(percent(page.error)) shows=\(shown.source) error=\(percent(shown.error))")
        }
        print("LIVE_RESULT web view at load \(describe(trace.loadFrame)), final body \(describe(trace.body)); " +
              "worst shown error \(percent(trace.shown.compactMap(\.error).max()))")
        try write(strip: trace.page, title: "Google Lens page alone, generated 700x500 picture",
                  to: folder.appendingPathComponent("panel.google.\(label).page.png"))
        try write(strip: trace.shown, title: "What the sheet shows, generated 700x500 picture",
                  to: folder.appendingPathComponent("panel.google.\(label).shown.png"))
    }

    /// Opens an overlay in a window, starts a search in the order AppController uses for a released selection (the
    /// sheet slides in, then the search starts), and samples the page and the sheet every 100 ms. With
    /// LENS_VISIBLE set, the window is ordered in nearly transparent and ignoring the mouse, so WebKit doesn't
    /// throttle the page's own scripts.
    private static func record(ticks: Int, screen: CGFloat = 1200,
                               request: () throws -> URLRequest) async throws -> Trace {
        let frame = NSRect(x: 0, y: 0, width: screen, height: (screen * 0.6).rounded())
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = OverlayView(frame: frame, image: try NativeChecks.fixture(), displayIndex: 0,
                               topInset: 32, controls: true, actions: OverlayActions())
        window.contentView = view
        if ProcessInfo.processInfo.environment["LENS_VISIBLE"] != nil {
            window.alphaValue = 0.03
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: 20, y: 20))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
        }
        view.layoutSubtreeIfNeeded()
        guard let panel = view.panel else { throw LensError.message("The overlay has no results sheet.") }
        let crop = try picture(width: size.width, height: size.height, pattern: true)
        panel.preview = crop
        panel.update(.uploading, allowed: true)
        view.revealPanel()
        let request = try request()
        let started = Date()
        let search = Task { try? await panel.search(request, preview: crop) }
        var trace = Trace()
        for tick in 1...ticks {
            let wait = started.addingTimeInterval(Double(tick) / 10).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            let page = await pageSample(panel, time: tick * 100)
            trace.page.append(page)
            if panel.covering, !panel.previewView.isHidden, panel.previewView.alphaValue > 0.5 {
                trace.shown.append(cropSample(panel, time: tick * 100))
            } else if let web = panel.webView, !web.isHidden, web.alphaValue > 0.5 {
                trace.shown.append(page)
            } else {
                trace.shown.append(Sample(time: tick * 100, source: "nothing"))
            }
        }
        search.cancel()
        trace.loadFrame = panel.frameAtLoad
        trace.body = panel.bodyFrame
        return trace
    }

    /// The results page's own viewer: the largest image near its top, compared with the image's natural shape.
    static let stretchScript = """
    (() => {
      let best = null, area = 0;
      for (const img of document.images) {
        if (!img.naturalWidth || !img.naturalHeight) continue;
        const r = img.getBoundingClientRect();
        if (r.width < 120 || r.height < 80 || r.top > 500 || r.bottom <= 0) continue;
        if (r.width * r.height > area) { area = r.width * r.height; best = { img, r }; }
      }
      if (!best) return '-';
      if (getComputedStyle(best.img).objectFit !== 'fill') return '1';
      return String((best.r.width / best.r.height) / (best.img.naturalWidth / best.img.naturalHeight));
    })()
    """

    private static func pageSample(_ panel: ResultsPanel, time: Int) async -> Sample {
        var sample = Sample(time: time, source: "page")
        guard let web = panel.webView, web.bounds.width >= 1, web.bounds.height >= 1 else { return sample }
        if let ratio = Double(await PanelCheck.evaluate(web, stretchScript)) { sample.error = abs(CGFloat(ratio) - 1) }
        sample.image = await snapshot(web)
        return sample
    }

    private static func cropSample(_ panel: ResultsPanel, time: Int) -> Sample {
        var sample = Sample(time: time, source: "crop")
        sample.image = render(panel.previewView)
        if let image = sample.image, let aspect = Bitmap(image)?.magentaAspect {
            sample.error = abs(aspect / (CGFloat(size.width) / CGFloat(size.height)) - 1)
        }
        return sample
    }

    private static func percent(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
    }

    private static func describe(_ rect: CGRect?) -> String {
        rect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"
    }

    /// A magenta picture with a white circle, so any stretching shows as an ellipse.
    static func picture(width: Int, height: Int, pattern: Bool = false) throws -> CGImage {
        let size = NSSize(width: width, height: height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        if pattern {
            let side = min(size.width, size.height) * 0.7
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                        width: side, height: side)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { throw LensError.message("The fixture picture could not be drawn.") }
        return image
    }

    /// Like Google's viewer: a fixed 340×385 box with `object-fit: fill`, corrected by script 1.2 s after load.
    static let page: Data = {
        let png = (try? picture(width: size.width, height: size.height, pattern: true))
            .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) } ?? Data()
        let source = "data:image/png;base64," + png.base64EncodedString()
        return Data("""
            <!doctype html><html><head><meta charset="utf-8"><title>Results fixture</title>
            <style>html,body{margin:0;background:#fff;font:14px -apple-system}
            #viewer{margin:16px auto;width:340px;height:385px;background:#222;border-radius:16px;overflow:hidden}
            #viewer img{display:block;width:100%;height:100%;object-fit:fill}p{margin:16px;color:#555}</style></head>
            <body><div id="viewer"><img alt="Searched image" src="\(source)"></div>
            <p>Generated fixture. Like Google's viewer, the image box ignores the image's shape until a script
            resizes it 1.2 s after load.</p>
            <script>
            setTimeout(() => {
              const box = document.getElementById('viewer'), img = box.querySelector('img');
              const fit = () => { box.style.height = Math.round(box.clientWidth * img.naturalHeight / img.naturalWidth) + 'px'; };
              if (img.complete) fit(); else img.addEventListener('load', fit);
            }, 1200);
            </script></body></html>
            """.utf8)
    }()

    /// Like Google's first results document: complete, without the image, and replaced by the real page shortly after.
    static let hopPage = Data("""
        <!doctype html><html><head><meta charset="utf-8"><title>Results fixture</title></head>
        <body style="margin:0;background:#fff;font:14px -apple-system"><p style="margin:16px;color:#555">Loading…</p>
        <script>setTimeout(() => location.replace('page'), 400);</script></body></html>
        """.utf8)

    private static func render(_ view: NSView) -> CGImage? {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func snapshot(_ web: WKWebView) async -> CGImage? {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            web.takeSnapshot(with: nil) { image, _ in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    private static func write(strip samples: [Sample], title: String, to url: URL) throws {
        let columns = 10, tileWidth: CGFloat = 132, tileHeight: CGFloat = 150, label: CGFloat = 30, header: CGFloat = 34
        let rows = (samples.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * tileWidth, height: header + CGFloat(rows) * (tileHeight + label))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        (title as NSString).draw(at: NSPoint(x: 10, y: size.height - 24),
                                 withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white])
        for (index, sample) in samples.enumerated() {
            let column = index % columns, row = index / columns
            let tile = NSRect(x: CGFloat(column) * tileWidth + 6,
                              y: size.height - header - CGFloat(row + 1) * (tileHeight + label) + label,
                              width: tileWidth - 12, height: tileHeight - 6)
            NSColor(white: 0.3, alpha: 1).setFill()
            tile.fill()
            if let image = sample.image {
                let scale = min(tile.width / CGFloat(image.width), tile.height / CGFloat(image.height))
                let drawn = NSRect(x: tile.midX - CGFloat(image.width) * scale / 2,
                                   y: tile.maxY - CGFloat(image.height) * scale,
                                   width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                NSImage(cgImage: image, size: .zero).draw(in: drawn)
            }
            let error = sample.error.map { String(format: "%.0f%%", $0 * 100) } ?? "none"
            let ok = sample.error.map { $0 <= tolerance } ?? false
            ("\(sample.time) ms · \(sample.source)" as NSString)
                .draw(at: NSPoint(x: tile.minX, y: tile.minY - 14), withAttributes: text)
            ("error \(error)" as NSString).draw(at: NSPoint(x: tile.minX, y: tile.minY - 27), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: ok ? NSColor.systemGreen : NSColor.systemRed
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw LensError.message("The sample strip could not be encoded.")
        }
        try png.write(to: url)
    }
}

/// Serves the generated results pages after a delay, standing in for the network.
final class FixtureScheme: NSObject, WKURLSchemeHandler {
    var delay = 0
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [self] in
            guard !stopped.contains(id), let url = task.request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            task.didReceive(response)
            task.didReceive(url.lastPathComponent == "hop" ? PanelAspectCheck.hopPage : PanelAspectCheck.page)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }
}

private extension Bitmap {
    /// The width over height of the magenta picture, or nil when too little of it is visible.
    var magentaAspect: CGFloat? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = rgb(x, y)
                guard r > 0.8, g < 0.3, b > 0.8 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count >= 40, maxX > minX, maxY > minY else { return nil }
        return CGFloat(maxX - minX + 1) / CGFloat(maxY - minY + 1)
    }
}

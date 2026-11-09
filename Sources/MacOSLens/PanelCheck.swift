import AppKit
import LensCore
import WebKit

/// Uploads a generated fixture through the real results panel and checks how Google's page renders in WebKit.
/// Uses non-persistent web storage; no screen content is captured.
@MainActor
enum PanelCheck {
    static func run(snapshot: URL?) async throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 860),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "macOS Lens results panel check (synthetic image)"
        window.isReleasedWhenClosed = false
        let panel = ResultsPanel(frame: window.contentView!.bounds, dataStore: .nonPersistent())
        panel.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(panel)
        window.orderFrontRegardless()
        defer { window.close() }

        let image = try OCR.fixture()
        panel.update(.uploading, allowed: true)
        let url = try await panel.search(LensUpload.request(for: image))
        panel.update(.loaded(url), allowed: true)
        guard let web = panel.webView else { throw LensError.message("The results panel did not create a web view.") }
        try await settle(web)
        print("PANEL_STATUS \(panel.statusLabel.stringValue)")
        if !panel.messageLabel.isHidden { print("PANEL_MESSAGE \(panel.messageLabel.stringValue)") }
        print("PANEL_URL \(url.absoluteString.prefix(120))…")
        print("PANEL_TITLE \(await evaluate(web, "document.title"))")
        print("PANEL_TEXT \(await evaluate(web, "document.body ? document.body.innerText.slice(0, 400) : ''").replacingOccurrences(of: "\n", with: " | "))")
        let thumbnail = await self.thumbnail(web)
        print("PANEL_THUMBNAIL \(thumbnail)")
        if let snapshot { try await save(web, to: snapshot) }

        // A cached selection reloads its results URL with GET in the same panel session.
        _ = web.load(URLRequest(url: URL(string: "about:blank")!))
        try await settle(web, extra: .milliseconds(300))
        panel.load(url)
        try await settle(web)
        let cached = await self.thumbnail(web)
        print("PANEL_CACHED_THUMBNAIL \(cached)")

        // Typed words refine the visual search through the results URL's `q` parameter (multisearch).
        let refined = LensUpload.refined(url, query: "red sign")
        panel.load(refined)
        try await settle(web)
        let refinedThumbnail = await self.thumbnail(web)
        let box = await evaluate(web, "(document.querySelector('textarea[name=q], input[name=q]') || {}).value || ''")
        let keepsImage = web.url.map(LensUpload.isResult) == true
        print("PANEL_REFINED title=\(await evaluate(web, "document.title")) box=\(box) thumbnail=\(refinedThumbnail) " +
              "keepsVisualResult=\(keepsImage)")
        print("PANEL_REFINED_TEXT \(await evaluate(web, "document.body ? document.body.innerText.slice(0, 300) : ''").replacingOccurrences(of: "\n", with: " | "))")
        if let snapshot {
            try await save(web, to: snapshot.deletingPathExtension().appendingPathExtension("refined.png"))
        }

        // Cancellation uses an unroutable documentation address (RFC 5737), so nothing reaches Google.
        var request = URLRequest(url: URL(string: "http://192.0.2.1/")!)
        request.timeoutInterval = 20
        let search = Task { try await panel.search(request) }
        try await Task.sleep(for: .milliseconds(300))
        search.cancel()
        let started = Date()
        do {
            _ = try await search.value
            throw LensError.message("A cancelled panel search returned a result.")
        } catch is CancellationError {
            print("PANEL_CANCEL stopped in \(Int(Date().timeIntervalSince(started) * 1000)) ms; still loading: \(web.isLoading)")
        }
        guard thumbnail.hasPrefix("loaded"), cached.hasPrefix("loaded"), !web.isLoading else {
            throw LensError.message("The results page thumbnail did not load, or cancellation did not stop loading.")
        }
        print("PASS results panel upload, thumbnail, cached reload and cancellation (synthetic image only).")
    }

    static func settle(_ web: WKWebView, extra: Duration = .seconds(3)) async throws {
        let deadline = Date().addingTimeInterval(30)
        while web.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        try await Task.sleep(for: extra)
        guard !web.isLoading else { throw LensError.message("The results page did not finish loading in 30 seconds.") }
    }

    static func thumbnail(_ web: WKWebView) async -> String {
        await evaluate(web, """
            (() => {
              const image = [...document.images].find(i => /searched image/i.test(i.alt || ''));
              if (!image) return 'missing';
              return (image.complete && image.naturalWidth > 0 ? 'loaded ' : 'broken ') + image.naturalWidth + 'x' + image.naturalHeight;
            })()
            """)
    }

    static func save(_ web: WKWebView, to url: URL) async throws {
        let image = try await web.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]) else {
            throw LensError.message("The panel snapshot could not be encoded.")
        }
        try png.write(to: url)
        print("PANEL_SNAPSHOT \(url.path)")
    }

    static func evaluate(_ web: WKWebView, _ script: String) async -> String {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: (value as? String) ?? error?.localizedDescription ?? "")
            }
        }
    }
}

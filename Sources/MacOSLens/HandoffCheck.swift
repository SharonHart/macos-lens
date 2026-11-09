import AppKit
import LensCore
import WebKit

/// Opens the "Open in browser" handoff page for a generated fixture in a private WebKit view standing in for the
/// user's browser, and checks that the page itself uploads the picture and lands on Lens results that show it.
/// Never opens the user's browser, captures the screen or keeps web data.
@MainActor
enum HandoffCheck {
    static func run(snapshot: URL?) async throws {
        let crop = try OCR.fixture()
        let page = try AppController.handoffPage(for: crop)
        defer { try? FileManager.default.removeItem(at: page) }
        let permissions = try FileManager.default.attributesOfItem(atPath: page.path)[.posixPermissions] as? Int
        let html = try String(contentsOf: page, encoding: .utf8)
        guard permissions == 0o600, html.components(separatedBy: "data:image/png;base64,").count == 2 else {
            throw LensError.message("The handoff page is not private (0600) or does not hold exactly one picture.")
        }
        print("HANDOFF_FILE \(page.lastPathComponent) mode 0600, \(html.utf8.count) bytes, one \(crop.width)x\(crop.height) picture")

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "macOS Lens browser handoff check (synthetic image)"
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        defer { window.close() }

        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(60)
        var landed: URL?
        while Date() < deadline {
            if let url = web.url, url.scheme == "https" {
                let host = url.host ?? "", path = url.path
                if host.hasPrefix("consent.") || path.hasPrefix("/sorry") || host.hasPrefix("accounts.") {
                    landed = url
                    break
                }
                if host.contains("google.") && path == "/search" && !web.isLoading {
                    landed = url
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let landed else {
            throw LensError.message("The handoff page did not reach Google Lens results in 60 seconds " +
                                    "(last address: \(web.url?.absoluteString.prefix(80) ?? "none")).")
        }
        try await PanelCheck.settle(web)
        let title = await PanelCheck.evaluate(web, "document.title")
        print("HANDOFF_URL \(landed.absoluteString.prefix(120))…")
        print("HANDOFF_TITLE \(title)")
        if let snapshot { try await PanelCheck.save(web, to: snapshot) }
        guard landed.path == "/search", landed.host?.hasPrefix("consent.") == false else {
            throw LensError.message("Google answered with a consent, sign-in or rate-limit page (\(landed.host ?? "")" +
                                    "\(landed.path)); it was not bypassed.")
        }
        let thumbnail = await PanelCheck.thumbnail(web)
        print("HANDOFF_THUMBNAIL \(thumbnail)")
        guard LensUpload.isResult(landed), thumbnail.hasPrefix("loaded") else {
            throw LensError.message("The browser reached \(landed.path) but the searched-image thumbnail is \(thumbnail).")
        }
        print("PASS the handoff page posts the selected picture to Google Lens by itself and lands on results " +
              "showing it (synthetic image, private WebKit session; the user's browser was not opened).")
    }
}

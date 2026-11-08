import AppKit
import LensCore
import WebKit

/// The right-hand results panel, similar to the Google Lens side panel in Chrome and Edge.
final class ResultsPanel: NSView, WKNavigationDelegate, WKUIDelegate {
    var onAllow: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    var onHide: (() -> Void)?
    var onResize: ((CGFloat, Bool) -> Void)?

    private let background = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Google Lens results")
    let statusLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let openButton = NSButton(title: "Open in browser", target: nil, action: nil)
    private let hideButton = NSButton(title: "Hide", target: nil, action: nil)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let disclosure = NSView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let divider = PanelDivider()
    private(set) var webView: WKWebView?
    private(set) var resultURL: URL?
    private var loadedURL: URL?
    private var pageNote: String?
    private let dataStore: WKWebsiteDataStore
    private var pending: (id: Int, navigation: WKNavigation?, continuation: CheckedContinuation<URL, Error>)?
    private var searchCount = 0
    private var mainStatus: Int?

    /// Results use persistent, app-specific storage by default so the user can sign in to Google here if prompted.
    init(frame: NSRect, dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        addSubview(background)
        titleLabel.font = .boldSystemFont(ofSize: 15)
        addSubview(titleLabel)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        openButton.target = self
        openButton.action = #selector(openInBrowser)
        openButton.isEnabled = false
        addSubview(openButton)
        hideButton.target = self
        hideButton.action = #selector(hidePanel)
        hideButton.toolTip = "Hide the results panel"
        addSubview(hideButton)
        messageLabel.textColor = .systemRed
        messageLabel.isHidden = true
        addSubview(messageLabel)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        addSubview(placeholder)
        buildDisclosure()
        addSubview(disclosure)
        divider.onDrag = { [weak self] delta, finished in
            guard let self else { return }
            self.onResize?(self.frame.width - delta, finished)
        }
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildDisclosure() {
        let heading = NSTextField(labelWithString: "Visual search is off")
        heading.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(wrappingLabelWithString:
            "Visual search sends ONLY the area inside the selection to Google, through Google Lens's " +
            "undocumented upload endpoint (not an official API; it can stop working).\n\n" +
            "The selection starts as your WHOLE SCREEN. After you allow it, the current area is uploaded " +
            "each time you pause adjusting the selection, so shrink it first if anything private is visible.\n\n" +
            "Screen capture and text recognition (OCR) stay on this Mac. The upload and results happen in " +
            "this panel, which keeps its own Google cookies and optional sign-in, separate from your browser; " +
            "macOS Lens never reads your browser's cookies.")
        body.textColor = .secondaryLabelColor
        let allow = NSButton(title: "Allow visual search", target: self, action: #selector(allow))
        allow.bezelColor = .controlAccentColor
        allow.keyEquivalent = ""
        let footer = NSTextField(wrappingLabelWithString: "You can turn this off again in Settings & privacy.")
        footer.textColor = .tertiaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        for (index, view) in [heading, body, allow, footer].enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.identifier = NSUserInterfaceItemIdentifier("disclosure-\(index)")
            disclosure.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: disclosure.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: disclosure.leadingAnchor),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: disclosure.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: disclosure.trailingAnchor),
            allow.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            allow.leadingAnchor.constraint(equalTo: disclosure.leadingAnchor),
            footer.topAnchor.constraint(equalTo: allow.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: disclosure.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: disclosure.trailingAnchor)
        ])
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        background.frame = bounds
        divider.frame = NSRect(x: 0, y: 0, width: 8, height: height)
        hideButton.frame = NSRect(x: width - 74, y: height - 40, width: 62, height: 28)
        openButton.frame = NSRect(x: width - 214, y: height - 40, width: 138, height: 28)
        titleLabel.frame = NSRect(x: 18, y: height - 36, width: max(40, width - 238), height: 20)
        spinner.frame = NSRect(x: 18, y: height - 62, width: 16, height: 16)
        let statusX: CGFloat = spinner.isHidden || !isAnimating ? 18 : 40
        statusLabel.frame = NSRect(x: statusX, y: height - 64, width: width - statusX - 14, height: 18)
        var top = height - 74
        if !messageLabel.isHidden {
            let size = messageLabel.sizeThatFits(NSSize(width: width - 32, height: 200))
            messageLabel.frame = NSRect(x: 16, y: top - size.height, width: width - 32, height: size.height)
            top -= size.height + 8
        }
        let body = NSRect(x: 8, y: 8, width: width - 16, height: max(0, top - 8))
        webView?.frame = body
        placeholder.frame = NSRect(x: 24, y: body.midY - 40, width: width - 48, height: 80)
        disclosure.frame = NSRect(x: 18, y: 8, width: width - 36, height: max(0, top - 16))
    }

    private var isAnimating = false

    func update(_ state: LiveSearchState, allowed: Bool) {
        disclosure.isHidden = allowed
        messageLabel.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
        setBusy(false)
        guard allowed else {
            statusLabel.stringValue = "Nothing has been uploaded."
            placeholder.isHidden = true
            webView?.isHidden = true
            openButton.isEnabled = false
            needsLayout = true
            return
        }
        webView?.isHidden = loadedURL == nil
        placeholder.isHidden = loadedURL != nil
        placeholder.stringValue = "Adjust the selection. Results for the selected area appear here when you pause."
        switch state {
        case .idle:
            statusLabel.stringValue = "Ready."
        case .waiting:
            statusLabel.stringValue = "Waiting for you to finish adjusting…"
        case .uploading:
            setBusy(true)
            statusLabel.stringValue = "Uploading the selected area to Google…"
        case .loaded(let url):
            resultURL = url
            if url != loadedURL { load(url) }
            else if webView?.isLoading == true {
                setBusy(true)
                statusLabel.stringValue = "Loading results…"
            } else if let pageNote { show(note: pageNote) }
            else { statusLabel.stringValue = "Results from Google Lens." }
        case .failed(let message):
            showError("Search failed.", detail: message)
        }
        openButton.isEnabled = resultURL != nil
        needsLayout = true
    }

    private func setBusy(_ busy: Bool) {
        isAnimating = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    /// Uploads like a browser form so the results page and its image thumbnail share this panel's session.
    /// Returns the committed results URL; cancelling the calling task stops the upload.
    func search(_ request: URLRequest) async throws -> URL {
        let web = webView ?? makeWebView()
        finish(pending?.id, with: .failure(CancellationError()))
        searchCount += 1
        let id = searchCount
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = (id, nil, continuation)
                mainStatus = nil
                pageNote = nil
                pending?.navigation = web.load(request)
            }
        } onCancel: {
            Task { @MainActor in self.stopSearch(id) }
        }
    }

    /// Stops an upload that hasn't produced a page yet, leaving any earlier results visible.
    func stopSearch(_ id: Int? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        webView?.stopLoading()
        finish(pending.id, with: .failure(CancellationError()))
    }

    private func finish(_ id: Int?, with result: Result<URL, Error>) {
        guard let id, let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(with: result)
    }

    private func isPending(_ navigation: WKNavigation?) -> Bool {
        guard let pending, let navigation else { return false }
        return pending.navigation === navigation
    }

    func load(_ url: URL) {
        let web = webView ?? makeWebView()
        loadedURL = url
        pageNote = nil
        web.isHidden = false
        placeholder.isHidden = true
        setBusy(true)
        statusLabel.stringValue = "Loading results…"
        web.load(URLRequest(url: url))
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.wantsLayer = true
        web.layer?.cornerRadius = 10
        web.layer?.masksToBounds = true
        addSubview(web, positioned: .below, relativeTo: divider)
        webView = web
        needsLayout = true
        return web
    }

    @objc private func openInBrowser() {
        let current = webView?.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        guard let url = current ?? resultURL else { return }
        onOpen?(url)
    }

    @objc private func hidePanel() { onHide?() }
    @objc private func allow() { onAllow?() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links that would open a new window stay in the panel.
        webView.load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { mainStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode }
        if navigationResponse.isForMainFrame, mainStatus == 429 {
            pageNote = "Google is limiting requests (HTTP 429). Complete any check shown here, or wait and retry."
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let host = url.host?.lowercased() ?? ""
        if host.hasPrefix("consent.") {
            pageNote = "Google is asking for cookie consent. Choose an option in this panel."
        } else if host == "accounts.google.com" {
            pageNote = "Google is asking you to sign in. This is optional; macOS Lens never reads these cookies."
        } else if url.path.hasPrefix("/sorry") {
            pageNote = "Google wants to verify you're not a robot. Complete it here, or use Open in browser."
        } else if pageNote?.contains("429") != true {
            pageNote = nil
        }
        if let pageNote { show(note: pageNote) }
        if isPending(navigation), let id = pending?.id {
            loadedURL = url
            do {
                let result = try LensUpload.committedResult(url, status: mainStatus)
                resultURL = result
                finish(id, with: .success(result))
            } catch {
                finish(id, with: .failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setBusy(false)
        if let pageNote { show(note: pageNote) }
        else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Results from Google Lens."
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isPending(navigation), let id = pending?.id {
            setBusy(false)
            finish(id, with: .failure(isCancellation(error) ? CancellationError() : error))
        } else {
            failed(error)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let error = LensError.message("The results page stopped unexpectedly. Press Return to search again.")
        finish(pending?.id, with: .failure(error))
        failed(error)
    }

    private func isCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    private func failed(_ error: Error) {
        if isCancellation(error) { return }
        setBusy(false)
        showError("The results page could not load.", detail: error.localizedDescription)
    }

    func showError(_ status: String, detail: String) {
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = status
        messageLabel.stringValue = detail
        messageLabel.isHidden = false
        needsLayout = true
    }

    private func show(note: String) {
        statusLabel.textColor = .systemOrange
        statusLabel.stringValue = note
        statusLabel.toolTip = note
    }
}

private final class PanelDivider: NSView {
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var start: CGFloat?

    override func resetCursorRects() {
        if #available(macOS 15, *) { addCursorRect(bounds, cursor: .columnResize(directions: .all)) }
        else { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) { start = event.locationInWindow.x }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag?(event.locationInWindow.x - start, false)
        self.start = event.locationInWindow.x
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event)
        start = nil
        onDrag?(0, true)
    }
}

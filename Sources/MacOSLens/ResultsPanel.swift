import AppKit
import LensCore
import WebKit

/// The results sheet: a rounded, translucent card that slides in over the side of the frozen screen, like
/// Android's Circle to Search results sheet or the Google Lens side panel in Chrome and Edge.
final class ResultsPanel: NSView, WKNavigationDelegate, WKUIDelegate {
    var onAllow: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    var onHide: (() -> Void)?
    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onResize: ((CGFloat, Bool) -> Void)?
    var onMove: ((CGFloat, Bool) -> Void)?

    enum Mode: Equatable { case lens, confirm, page }
    private(set) var mode = Mode.lens

    /// While the selection is being drawn or adjusted, clicks go through to the screenshot underneath.
    var passThrough = false
    var dockedLeft = false {
        didSet {
            guard dockedLeft != oldValue else { return }
            hideButton.image = Self.symbol(dockedLeft ? "sidebar.left" : "sidebar.right", "Hide results")
            needsLayout = true
        }
    }
    var expanded = false {
        didSet {
            expandButton.image = Self.symbol(expanded ? "arrow.down.right.and.arrow.up.left" :
                                             "arrow.up.left.and.arrow.down.right", expanded ? "Shrink" : "Expand")
            expandButton.toolTip = expanded ? "Make the results narrower" : "Make the results wider"
        }
    }
    /// Words typed in the search bar; Lens applies them to the visual search as its `q` parameter.
    var refinement = ""

    private let content = NSVisualEffectView()
    private let header = PanelHeader()
    private let grabber = NSView()
    let titleLabel = NSTextField(labelWithString: "Google Lens")
    let statusLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let openButton = NSButton()
    let expandButton = NSButton()
    let hideButton = NSButton()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let disclosure = NSView()
    let placeholder = NSTextField(wrappingLabelWithString: "Circle, highlight or tap what you want to search.")
    let confirmation = NSView()
    private let confirmText = NSTextView()
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private let divider = PanelDivider()
    private(set) var webView: WKWebView?
    private(set) var resultURL: URL?
    private(set) var loadedURL: URL?
    private var pageNote: String?
    private let dataStore: WKWebsiteDataStore
    private var pending: (id: Int, navigation: WKNavigation?, continuation: CheckedContinuation<URL, Error>)?
    private var searchCount = 0
    private var mainStatus: Int?
    private var isAnimating = false
    private var sheetPull = PullToDismiss(threshold: 90)
    private var pagePull = PullToDismiss(threshold: 120)
    /// Whether the results page is scrolled to its top, reported by a script in an isolated content world.
    private(set) var pageAtTop = true

    /// Results use persistent, app-specific storage by default so the user can sign in to Google here if prompted.
    init(frame: NSRect, dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        content.material = .popover
        content.blendingMode = .withinWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 20
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        addSubview(content)
        buildHeader()
        messageLabel.textColor = .systemRed
        messageLabel.isHidden = true
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 14)
        buildDisclosure()
        buildConfirmation()
        for view in [header, messageLabel, placeholder, disclosure, confirmation] { content.addSubview(view) }
        confirmation.isHidden = true
        divider.onDrag = { [weak self] delta, finished in
            guard let self else { return }
            self.onResize?(self.frame.width + (self.dockedLeft ? delta : -delta), finished)
        }
        content.addSubview(divider)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search results")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    private func buildHeader() {
        grabber.wantsLayer = true
        grabber.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        grabber.layer?.cornerRadius = 2.5
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let buttons: [(NSButton, String, String, Selector)] = [
            (openButton, "arrow.up.forward.app", "Open these results in your browser", #selector(openInBrowser)),
            (expandButton, "arrow.up.left.and.arrow.down.right", "Make the results wider", #selector(expand)),
            (hideButton, "sidebar.right", "Hide results (they come back when you select again)", #selector(hidePanel))
        ]
        for (button, symbol, tip, action) in buttons {
            button.image = Self.symbol(symbol, tip)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = action
            header.addSubview(button)
        }
        openButton.setAccessibilityLabel("Open in browser")
        openButton.isEnabled = false
        for view in [grabber, titleLabel, statusLabel, spinner] { header.addSubview(view) }
        header.onMove = { [weak self] dx, finished in self?.onMove?(dx, finished) }
    }

    private func buildDisclosure() {
        let heading = NSTextField(labelWithString: "Visual search is off")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "Visual search sends ONLY the area inside the selection to Google, through Google Lens's " +
            "undocumented upload endpoint (not an official API; it can stop working).\n\n" +
            "The selection starts as your WHOLE SCREEN. After you allow it, the selected area is uploaded " +
            "each time you finish circling or adjusting it, so select a smaller area first if anything private " +
            "is visible.\n\n" +
            "Screen capture and text recognition (OCR) stay on this Mac. The upload and results happen in " +
            "this sheet, which keeps its own Google cookies and optional sign-in, separate from your browser; " +
            "macOS Lens never reads your browser's cookies.")
        body.textColor = .secondaryLabelColor
        let allow = NSButton(title: "Allow visual search", target: self, action: #selector(allow))
        allow.bezelColor = .controlAccentColor
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

    private func buildConfirmation() {
        let heading = NSTextField(labelWithString: "Translate this text?")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString:
            "The text was recognized on this Mac. Only the text below is sent to Google Translate; " +
            "the screenshot stays here.")
        note.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        confirmText.isEditable = false
        confirmText.isSelectable = true
        confirmText.drawsBackground = false
        confirmText.font = .systemFont(ofSize: 13)
        confirmText.textContainerInset = NSSize(width: 4, height: 6)
        confirmText.isVerticallyResizable = true
        confirmText.autoresizingMask = [.width]
        confirmText.textContainer?.widthTracksTextView = true
        scroll.documentView = confirmText
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        let send = NSButton(title: "Translate with Google", target: self, action: #selector(confirmPressed))
        send.bezelColor = .controlAccentColor
        send.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        for (index, view) in [heading, note, scroll, send, cancel].enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.identifier = NSUserInterfaceItemIdentifier("confirm-\(index)")
            confirmation.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: confirmation.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: confirmation.leadingAnchor),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: confirmation.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: confirmation.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: confirmation.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: confirmation.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: send.topAnchor, constant: -14),
            send.leadingAnchor.constraint(equalTo: confirmation.leadingAnchor),
            send.bottomAnchor.constraint(equalTo: confirmation.bottomAnchor, constant: -6),
            cancel.leadingAnchor.constraint(equalTo: send.trailingAnchor, constant: 8),
            cancel.centerYAnchor.constraint(equalTo: send.centerYAnchor)
        ])
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        content.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 20, cornerHeight: 20, transform: nil)
        let width = bounds.width, height = bounds.height
        let headerHeight: CGFloat = 64
        header.frame = NSRect(x: 0, y: height - headerHeight, width: width, height: headerHeight)
        grabber.frame = NSRect(x: (width - 36) / 2, y: headerHeight - 11, width: 36, height: 5)
        var x = width - 14
        for button in [hideButton, expandButton, openButton] {
            x -= 30
            button.frame = NSRect(x: x, y: 18, width: 30, height: 28)
            x -= 2
        }
        let textWidth = max(40, x - 18 - 6)
        titleLabel.frame = NSRect(x: 18, y: 30, width: textWidth, height: 20)
        spinner.frame = NSRect(x: 18, y: 11, width: 16, height: 16)
        let statusX: CGFloat = isAnimating ? 40 : 18
        statusLabel.frame = NSRect(x: statusX, y: 10, width: max(20, x - statusX - 6), height: 16)
        var top = height - headerHeight
        if !messageLabel.isHidden {
            let size = messageLabel.sizeThatFits(NSSize(width: width - 36, height: 200))
            messageLabel.frame = NSRect(x: 18, y: top - size.height, width: width - 36, height: size.height)
            top -= size.height + 8
        }
        let body = NSRect(x: 8, y: 8, width: width - 16, height: max(0, top - 8))
        webView?.frame = body
        placeholder.frame = NSRect(x: 28, y: body.midY - 40, width: width - 56, height: 80)
        disclosure.frame = NSRect(x: 18, y: 8, width: width - 36, height: max(0, top - 16))
        confirmation.frame = NSRect(x: 18, y: 12, width: width - 36, height: max(0, top - 16))
        divider.frame = NSRect(x: dockedLeft ? width - 8 : 0, y: 0, width: 8, height: height - headerHeight)
    }

    // MARK: Modes

    /// Shows the live visual search for the current selection.
    func update(_ state: LiveSearchState, allowed: Bool) {
        mode = .lens
        titleLabel.stringValue = "Google Lens"
        confirmation.isHidden = true
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
        placeholder.stringValue = "Circle, highlight or tap what you want to search."
        switch state {
        case .idle:
            statusLabel.stringValue = "Ready."
        case .waiting:
            statusLabel.stringValue = "Waiting for you to finish selecting…"
        case .uploading:
            setBusy(true)
            statusLabel.stringValue = "Uploading the selected area to Google…"
        case .loaded(let url):
            let target = refinement.isEmpty ? url : LensUpload.refined(url, query: refinement)
            resultURL = target
            if target != loadedURL { load(target) }
            else if webView?.isLoading == true {
                setBusy(true)
                statusLabel.stringValue = "Loading results…"
            } else if let pageNote { show(note: pageNote) }
            else { statusLabel.stringValue = resultsStatus }
        case .failed(let message):
            showError("Search failed.", detail: message)
        }
        openButton.isEnabled = resultURL != nil
        needsLayout = true
    }

    private var resultsStatus: String {
        refinement.isEmpty ? "Results from Google Lens." : "Results from Google Lens with “\(refinement)”."
    }

    /// Shows the text recognized on this Mac and sends it to Google Translate only when confirmed.
    func confirmTranslation(text: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        mode = .confirm
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        titleLabel.stringValue = "Translate"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Nothing has been sent."
        setBusy(false)
        confirmText.string = text
        confirmation.isHidden = false
        disclosure.isHidden = true
        placeholder.isHidden = true
        messageLabel.isHidden = true
        webView?.isHidden = true
        openButton.isEnabled = false
        needsLayout = true
    }

    /// Shows an ordinary Google page, such as Google Translate, in the sheet.
    func showPage(_ url: URL, title: String) {
        mode = .page
        titleLabel.stringValue = title
        confirmation.isHidden = true
        disclosure.isHidden = true
        messageLabel.isHidden = true
        resultURL = url
        openButton.isEnabled = true
        load(url)
    }

    @objc private func confirmPressed() {
        let action = onConfirm
        onConfirm = nil
        onCancel = nil
        action?()
    }

    @objc private func cancelPressed() {
        let action = onCancel
        onConfirm = nil
        onCancel = nil
        action?()
    }

    private func setBusy(_ busy: Bool) {
        isAnimating = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    // MARK: Searching

    /// Uploads like a browser form so the results page and its image thumbnail share this sheet's session.
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
                pageAtTop = true
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
        pageAtTop = true
        web.isHidden = false
        placeholder.isHidden = true
        setBusy(true)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Loading results…"
        web.load(URLRequest(url: url))
    }

    private static let topScript = """
    (() => {
      const post = (value) => { try { window.webkit.messageHandlers.lensTop.postMessage(value); } catch (e) {} };
      const atTop = (node) => {
        for (let el = node instanceof Element ? node : null; el; el = el.parentElement) {
          if (el.scrollTop > 0) return false;
        }
        const root = document.scrollingElement || document.documentElement;
        return !root || root.scrollTop <= 0;
      };
      addEventListener('wheel', (e) => post(atTop(e.target)), { capture: true, passive: true });
      addEventListener('scroll', (e) => post(atTop(e.target === document ? null : e.target)),
                       { capture: true, passive: true });
      post(atTop(null));
    })();
    """

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.topScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(ScrollReporter(panel: self), contentWorld: .defaultClient, name: "lensTop")
        let web = PanelWebView(frame: .zero, configuration: configuration)
        web.onScroll = { [weak self] event in self?.pageScrolled(event) }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.wantsLayer = true
        web.layer?.cornerRadius = 12
        web.layer?.masksToBounds = true
        content.addSubview(web, positioned: .below, relativeTo: divider)
        webView = web
        needsLayout = true
        return web
    }

    fileprivate func reportTop(_ atTop: Bool) { pageAtTop = atTop }

    // MARK: Swipe down to close

    private static func phase(_ event: NSEvent) -> (PullToDismiss.Phase, Bool) {
        let momentum = !event.momentumPhase.isEmpty
        if event.phase.contains(.began) { return (.began, momentum) }
        if event.phase.contains(.changed) { return (.changed, momentum) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return (.ended, momentum) }
        return (.other, momentum)
    }

    /// Scrolling on the sheet itself (header, placeholder) never pans the screenshot; pulling it down closes.
    override func scrollWheel(with event: NSEvent) {
        let (phase, momentum) = Self.phase(event)
        if sheetPull.track(phase: phase, momentum: momentum, deltaY: event.scrollingDeltaY, atTop: true) {
            onDismiss?()
        }
    }

    /// Pulling the results page down past its top closes everything, like dragging Android's sheet down.
    func pageScrolled(_ event: NSEvent) {
        let (phase, momentum) = Self.phase(event)
        if pagePull.track(phase: phase, momentum: momentum, deltaY: event.scrollingDeltaY, atTop: pageAtTop) {
            onDismiss?()
        }
    }

    // MARK: Events

    override func hitTest(_ point: NSPoint) -> NSView? { passThrough ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The sheet's background must not start a selection on the screenshot underneath.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func openInBrowser() {
        let current = webView?.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        guard let url = current ?? resultURL else { return }
        onOpen?(url)
    }

    @objc private func hidePanel() { onHide?() }
    @objc private func expand() { onExpand?() }
    @objc private func allow() { onAllow?() }

    // MARK: Navigation

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Links that would open a new window stay in the sheet.
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
        pageAtTop = true
        guard let url = webView.url else { return }
        let host = url.host?.lowercased() ?? ""
        if host.hasPrefix("consent.") {
            pageNote = "Google is asking for cookie consent. Choose an option in this sheet."
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
            statusLabel.stringValue = mode == .page ? "Sent only the recognized text." : resultsStatus
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

/// The results web view, which also reports scroll gestures so pulling the page down can close the sheet.
final class PanelWebView: WKWebView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScroll?(event)
    }
}

/// Holds the sheet weakly so the web view's message handler doesn't keep it alive.
private final class ScrollReporter: NSObject, WKScriptMessageHandler {
    weak var panel: ResultsPanel?
    init(panel: ResultsPanel) { self.panel = panel }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let atTop = message.body as? Bool else { return }
        MainActor.assumeIsolated { panel?.reportTop(atTop) }
    }
}

/// The sheet's title area: dragging it moves the sheet, and its buttons work as usual.
private final class PanelHeader: NSView {
    var onMove: ((CGFloat, Bool) -> Void)?
    private var last: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        last = event.locationInWindow.x
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last else { return }
        onMove?(event.locationInWindow.x - last, false)
        self.last = event.locationInWindow.x
    }

    override func mouseUp(with event: NSEvent) {
        guard last != nil else { return }
        mouseDragged(with: event)
        last = nil
        NSCursor.pop()
        onMove?(0, true)
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

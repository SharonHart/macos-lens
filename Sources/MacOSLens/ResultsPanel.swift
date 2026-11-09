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
    private let confirmHeading = NSTextField(labelWithString: "")
    private let confirmNote = NSTextField(wrappingLabelWithString: "")
    private let confirmSend = NSButton(title: "", target: nil, action: nil)
    private let confirmAlternative = NSButton(title: "", target: nil, action: nil)
    private var onAlternative: (() -> Void)?
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private let divider = PanelDivider()
    private(set) var webView: WKWebView?
    private(set) var resultURL: URL?
    private(set) var loadedURL: URL?
    /// The web view's frame when the latest page load started.
    private(set) var frameAtLoad: CGRect?
    /// The selected area, shown at its true shape while Google's results page is still laying out its image.
    var preview: CGImage?
    let previewView = NSImageView()
    /// Whether the crop is covering a results page that hasn't settled yet.
    private(set) var covering = false
    private var settleID = 0
    /// How long to wait for Google's page to size its image before showing it anyway.
    static var settleTimeout: TimeInterval = 8
    /// How long a complete page without a large image must stay that way before it counts as settled.
    static let quietDelay: TimeInterval = 1.5
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
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 12
        previewView.layer?.cornerCurve = .continuous
        previewView.layer?.masksToBounds = true
        previewView.isHidden = true
        previewView.setAccessibilityLabel("Selected area")
        for view in [header, messageLabel, placeholder, disclosure, confirmation, previewView] {
            content.addSubview(view)
        }
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
            "Opening the overlay sends nothing. After you allow it, the area you circle, box or tap is " +
            "uploaded each time you finish adjusting it. Command-A frames the whole screen, which is sent only " +
            "if you then press Return or the Lens button.\n\n" +
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
        let heading = confirmHeading
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = confirmNote
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
        let send = confirmSend
        send.target = self
        send.action = #selector(confirmPressed)
        send.bezelColor = .controlAccentColor
        send.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let alternative = confirmAlternative
        alternative.target = self
        alternative.action = #selector(alternativePressed)
        alternative.isHidden = true
        for (index, view) in [heading, note, scroll, send, cancel, alternative].enumerated() {
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
            cancel.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            alternative.trailingAnchor.constraint(equalTo: confirmation.trailingAnchor),
            alternative.centerYAnchor.constraint(equalTo: send.centerYAnchor)
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
        let body = bodyFrame
        if let webView { Self.place(webView, body) }
        if let preview { Self.place(previewView, Self.previewFrame(for: preview, in: body)) }
        placeholder.frame = NSRect(x: 28, y: body.midY - 40, width: width - 56, height: 80)
        disclosure.frame = NSRect(x: 18, y: 8, width: width - 36, height: max(0, top - 16))
        confirmation.frame = NSRect(x: 18, y: 12, width: width - 36, height: max(0, top - 16))
        divider.frame = NSRect(x: dockedLeft ? width - 8 : 0, y: 0, width: 8, height: height - headerHeight)
    }

    /// Where the results page sits: below the header and any error message.
    var bodyFrame: CGRect {
        var top = bounds.height - 64
        if !messageLabel.isHidden {
            top -= messageLabel.sizeThatFits(NSSize(width: bounds.width - 36, height: 200)).height + 8
        }
        return NSRect(x: 8, y: 8, width: bounds.width - 16, height: max(0, top - 8))
    }

    /// The crop fitted to the top of the results area at its own aspect ratio, never stretched.
    static func previewFrame(for image: CGImage, in body: CGRect) -> CGRect {
        let box = body.insetBy(dx: 16, dy: 16)
        let height = min(box.height, max(80, body.height * 0.58))
        guard image.width > 0, image.height > 0, box.width > 0, height > 0 else { return .zero }
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(box.width / size.width, height / size.height, 2)
        let width = (size.width * scale).rounded(), fitted = (size.height * scale).rounded()
        return CGRect(x: (box.midX - width / 2).rounded(), y: box.maxY - fitted, width: width, height: fitted)
    }

    /// Sets a frame at once: the results page must never be stretched by an animation of its size.
    private static func place(_ view: NSView, _ frame: CGRect) {
        guard view.frame != frame else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
        NSAnimationContext.endGrouping()
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
            uncover(animated: false)
            webView?.isHidden = true
            openButton.isEnabled = false
            needsLayout = true
            return
        }
        let loading = loadedURL != nil || pending != nil || covering
        webView?.isHidden = !loading
        placeholder.isHidden = loading
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
        confirmSend(title: "Translate", heading: "Translate this text?",
                    note: "The text was recognized on this Mac. Only the text below is sent to Google Translate; " +
                          "the screenshot stays here.",
                    button: "Translate with Google", text: text, onConfirm: onConfirm, onCancel: onCancel)
    }

    /// Asks before sending text recognized on this Mac to Google; nothing is sent unless the user confirms.
    func confirmSend(title: String, heading: String, note: String, button: String, text: String,
                     alternative: (title: String, action: () -> Void)? = nil,
                     onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        mode = .confirm
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        onAlternative = alternative?.action
        confirmAlternative.title = alternative?.title ?? ""
        confirmAlternative.isHidden = alternative == nil
        titleLabel.stringValue = title
        confirmHeading.stringValue = heading
        confirmNote.stringValue = note
        confirmSend.title = button
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Nothing has been sent."
        setBusy(false)
        confirmText.string = text
        confirmation.isHidden = false
        disclosure.isHidden = true
        placeholder.isHidden = true
        messageLabel.isHidden = true
        uncover(animated: false)
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
        onAlternative = nil
        action?()
    }

    @objc private func cancelPressed() {
        let action = onCancel
        onConfirm = nil
        onCancel = nil
        onAlternative = nil
        action?()
    }

    @objc private func alternativePressed() {
        let action = onAlternative
        onConfirm = nil
        onCancel = nil
        onAlternative = nil
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
    func search(_ request: URLRequest, preview: CGImage? = nil) async throws -> URL {
        if let preview { self.preview = preview }
        let web = prepareWebView()
        finish(pending?.id, with: .failure(CancellationError()))
        searchCount += 1
        let id = searchCount
        web.isHidden = false
        placeholder.isHidden = true
        cover()
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
        uncover(animated: false)
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
        let web = prepareWebView()
        loadedURL = url
        pageNote = nil
        pageAtTop = true
        web.isHidden = false
        placeholder.isHidden = true
        // Google redraws its image viewer for every results page, so cover each one until it settles.
        if mode == .lens, LensUpload.isResult(url) { cover() } else { uncover(animated: false) }
        setBusy(true)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Loading results…"
        web.load(URLRequest(url: url))
    }

    /// Lays the sheet out and gives the web view its final size before any page starts loading, because
    /// Google sizes its results for the viewport it loads in.
    private func prepareWebView() -> WKWebView {
        if bounds.width < 100 || bounds.height < 100 {
            superview?.needsLayout = true
            superview?.layoutSubtreeIfNeeded()
        }
        layoutSubtreeIfNeeded()
        let web = webView ?? makeWebView()
        Self.place(web, bodyFrame)
        frameAtLoad = web.frame
        return web
    }

    // MARK: Covering an unsettled page

    /// Shows the selected area at its true aspect ratio in place of the page until Google has laid it out.
    private func cover() {
        guard mode == .lens, let preview, let web = webView else { return uncover(animated: false) }
        settleID += 1
        covering = true
        previewView.image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
        Self.place(previewView, Self.previewFrame(for: preview, in: bodyFrame))
        previewView.isHidden = false
        previewView.alphaValue = 1
        // Transparent rather than hidden, so WebKit keeps laying the page out at full speed.
        web.alphaValue = 0
        (web as? PanelWebView)?.blocksInput = true
    }

    /// Crossfades from the crop to the results page.
    private func uncover(animated: Bool) {
        settleID += 1
        guard covering else { return }
        covering = false
        let web = webView
        (web as? PanelWebView)?.blocksInput = false
        let fades = animated && OverlayView.animates && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard fades else {
            web?.alphaValue = 1
            previewView.alphaValue = 0
            previewView.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            web?.animator().alphaValue = 1
            previewView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.covering else { return }
            self.previewView.isHidden = true
        })
    }

    /// Waits until Google's image viewer shows the image at its natural aspect ratio, then reveals the page.
    private func watchSettling(_ web: WKWebView) {
        settleID += 1
        let id = settleID
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        Task { @MainActor [weak self, weak web] in
            while true {
                guard let self, let web, self.covering, self.settleID == id else { return }
                if Date() >= deadline { break }
                if await Self.isSettled(web) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.covering, self.settleID == id else { return }
            self.uncover(animated: true)
        }
    }

    /// Google's server-rendered viewer draws the image with `object-fit: fill` in a box that ignores the
    /// image's shape until its own script resizes the box, so wait for that box to match the image.
    /// Google first commits a short-lived, image-less results document, so a page without a large image
    /// only counts as settled once it has stayed complete and image-less for a while.
    static let settleScript = """
    (() => {
      if (document.readyState === 'loading') return false;
      let best = null, area = 0, loading = false;
      for (const img of document.images) {
        const r = img.getBoundingClientRect();
        if (r.width < 120 || r.height < 80 || r.top > 500 || r.bottom <= 0) continue;
        if (!img.naturalWidth || !img.naturalHeight) {
          if (img.currentSrc || img.getAttribute('src')) loading = true;
          continue;
        }
        if (r.width * r.height > area) { area = r.width * r.height; best = { img, r }; }
      }
      if (!best) {
        if (loading || document.readyState !== 'complete') { window.__lensQuietSince = undefined; return false; }
        const now = performance.now();
        if (window.__lensQuietSince === undefined) window.__lensQuietSince = now;
        return now - window.__lensQuietSince >= \(Int(quietDelay * 1000));
      }
      if (getComputedStyle(best.img).objectFit !== 'fill') return true;
      const shown = best.r.width / best.r.height, natural = best.img.naturalWidth / best.img.naturalHeight;
      return Math.abs(shown / natural - 1) <= 0.02;
    })()
    """

    static func isSettled(_ web: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(settleScript, in: nil, in: .defaultClient) { result in
                continuation.resume(returning: (try? result.get()) as? Bool ?? false)
            }
        }
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

    /// Lets offscreen checks serve generated pages from a local scheme; never set by the app.
    static var configureForChecks: ((WKWebViewConfiguration) -> Void)?
    static var checkScheme: String?

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        Self.configureForChecks?(configuration)
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.topScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(ScrollReporter(panel: self), contentWorld: .defaultClient, name: "lensTop")
        let web = PanelWebView(frame: bodyFrame, configuration: configuration)
        web.onScroll = { [weak self] event in self?.pageScrolled(event) }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.wantsLayer = true
        web.layer?.cornerRadius = 12
        web.layer?.masksToBounds = true
        content.addSubview(web, positioned: .below, relativeTo: previewView)
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
        let allowed = ["http", "https", "about", "data", "blob"].contains(scheme) || scheme == Self.checkScheme
        decisionHandler(allowed ? .allow : .cancel)
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
        // Consent, sign-in and robot checks need the user, so show them at once.
        if covering {
            let result = LensUpload.isResult(url) || (Self.checkScheme != nil && url.scheme == Self.checkScheme)
            if pageNote == nil, result { watchSettling(webView) } else { uncover(animated: false) }
        }
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
            uncover(animated: false)
            finish(id, with: .failure(isCancellation(error) ? CancellationError() : error))
        } else {
            failed(error)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let error = LensError.message("The results page stopped unexpectedly. Press Return to search again.")
        uncover(animated: false)
        finish(pending?.id, with: .failure(error))
        failed(error)
    }

    private func isCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    private func failed(_ error: Error) {
        if isCancellation(error) { return }
        uncover(animated: false)
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
    /// While the crop covers the page, clicks must not reach the invisible page underneath.
    var blocksInput = false

    override func hitTest(_ point: NSPoint) -> NSView? { blocksInput ? nil : super.hitTest(point) }

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

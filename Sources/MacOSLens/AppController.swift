import AppKit
import Carbon
import LensCore
import ScreenCaptureKit
import Security

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var menu: NSMenu!
    private var overlays: [OverlayWindow] = []
    private var settingsWindow: NSWindow?
    private var launcherWindow: NSWindow?
    private var launcherShortcutField: NSTextField?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var busy = false
    /// Bumped on every activation and dismissal so late results from an old overlay are ignored.
    private var session = 0
    private var lastActivation = Date.distantPast
    /// The user wants the results sheet: set by each new selection, cleared when they hide the sheet.
    private var wantsPanel = false
    /// The sheet shows a text search, translation or prompt, so live visual-search updates must not replace it.
    private var showingTextPage = false
    private var liveSearch: LiveSearch<String>?
    /// A settled text selection is searched as text after a short pause, so a double or triple click that grows the
    /// selection replaces it instead of searching each step.
    private var pendingTextSearch: DispatchWorkItem?
    private var lastTextSearch: String?
    private weak var panelView: OverlayView?
    private weak var selectedView: OverlayView?
    private var uploadCheckbox: NSButton?
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var browserField: NSTextField?
    /// Waiting for the user to turn on Screen Recording in System Settings.
    private var awaitingScreenRecording = false
    private var permissionTimer: Timer?
    private let defaults: UserDefaults
    /// Checks build overlays without putting them on screen.
    private let presentsOverlays: Bool
    /// Sends the selected crop to Google Lens in the results sheet; checks count calls instead.
    var upload: (ResultsPanel, CGImage) async throws -> URL = { panel, crop in
        try await panel.search(LensUpload.request(for: crop), preview: crop)
    }

    init(defaults: UserDefaults = .standard, presentsOverlays: Bool = true) {
        self.defaults = defaults
        self.presentsOverlays = presentsOverlays
        super.init()
    }

    static let bundleID = "dev.macos-lens.client"
    private static let searchHotKey: UInt32 = 1
    private static let textHotKey: UInt32 = 2

    private var shortcut: Shortcut { Shortcut.named(defaults.string(forKey: "shortcutID")) }
    private var textShortcut: Shortcut {
        Shortcut.text(named: defaults.string(forKey: "textShortcutID"), avoiding: shortcut,
                      symbolicHotKeys: systemHotKeys())
    }

    private func systemHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                  "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.removeTemporaryFiles()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = LensMark.image(size: LensMark.menuBarSize)
        status.button?.imageScaling = .scaleNone
        menu = NSMenu()
        menu.addItem(item("Search screen…", #selector(searchScreen)))
        menu.addItem(item("Select all text on screen…", #selector(selectText)))
        menu.addItem(.separator())
        menu.addItem(item("Settings & privacy…", #selector(showSettings)))
        menu.addItem(item("Fix Screen Recording permission…", #selector(fixScreenRecording)))
        menu.addItem(item("Buy Me a Coffee…", #selector(openSupportPage)))
        menu.addItem(.separator())
        menu.addItem(item("Quit macOS Lens", #selector(quit)))
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            lastExternalApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        registerShortcuts()
        // The menu-bar item can be hidden by the notch or menu-bar settings, so every launch shows a window.
        showLauncher()
        if !defaults.bool(forKey: "onboarded") { showSettings() }
        if !CGPreflightScreenCaptureAccess() { requestScreenRecording(forceReset: false) }
    }

    /// Opening the app again from Finder or Spotlight shows the launcher, but never as a side effect of the shortcut.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if overlays.isEmpty && !busy && Date().timeIntervalSince(lastActivation) > 2 { showLauncher() }
        return false
    }

    /// Coming back from System Settings after turning Screen Recording on.
    func applicationDidBecomeActive(_ notification: Notification) {
        if awaitingScreenRecording && CGPreflightScreenCaptureAccess() { screenRecordingGranted() }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != NSRunningApplication.current else { return }
        lastExternalApp = app
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.removeTemporaryFiles()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func searchScreen() { activate() }
    @objc private func selectText() { activate(selectingAllText: true) }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            if let button = status.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        } else {
            activate()
        }
    }

    // MARK: Shortcuts

    /// Two global shortcuts open the same view: one ready to circle or select anything, the other with all text
    /// already selected.
    private func registerShortcuts() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let install = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let text = id.id == AppController.textHotKey
                let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.activate(selectingAllText: text) }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard install == noErr else {
                showError(LensError.message("Could not install the global shortcut handler (\(install))."))
                return
            }
        }
        let search = shortcut, text = textShortcut
        status.button?.toolTip = "Search screen (\(search.title)) · select all text (\(text.title)); " +
                                 "right-click for more"
        setLauncherShortcutText()
        var problems: [String] = []
        for (shortcut, id, purpose) in [(search, Self.searchHotKey, "search"), (text, Self.textHotKey, "text")] {
            if shortcut.conflictsWithSystem(systemHotKeys()) {
                problems.append("\(shortcut.title) (\(purpose)) is already used by a macOS keyboard shortcut.")
                continue
            }
            var modifiers: UInt32 = 0
            if shortcut.modifiers & Shortcut.command != 0 { modifiers |= UInt32(cmdKey) }
            if shortcut.modifiers & Shortcut.shift != 0 { modifiers |= UInt32(shiftKey) }
            if shortcut.modifiers & Shortcut.option != 0 { modifiers |= UInt32(optionKey) }
            if shortcut.modifiers & Shortcut.control != 0 { modifiers |= UInt32(controlKey) }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, modifiers, EventHotKeyID(signature: 0x4c454e53, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                hotKeys.append(ref)
            } else {
                problems.append("\(shortcut.title) (\(purpose)) could not be registered (\(result)); " +
                                "another app may be using it.")
            }
        }
        if !problems.isEmpty {
            showError(LensError.message(problems.joined(separator: "\n") + "\nChoose another shortcut in Settings."))
        }
    }

    private func setLauncherShortcutText() {
        guard let field = launcherShortcutField, field.stringValue != launcherShortcutText else { return }
        field.stringValue = launcherShortcutText
        (launcherWindow?.contentView as? FormView)?.fitWindow()
    }

    private var launcherShortcutText: String {
        "\(shortcut.title): search the screen · \(textShortcut.title): select all text"
    }

    // MARK: Capture

    func activate(selectingAllText: Bool = false) {
        guard !busy, overlays.isEmpty else { return }
        // The shortcut always opens the selection overlay; only missing Screen Recording access stops it.
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecording(forceReset: false)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? lastExternalApp : front
        lastActivation = Date()
        session += 1
        settingsWindow?.orderOut(nil)
        launcherWindow?.close()
        busy = true
        Task {
            do {
                let frames = try await captureDisplays()
                // All screenshots are acquired before any overlay can appear in the capture.
                showOverlays(frames, selectingAllText: selectingAllText)
                busy = false
            } catch {
                busy = false
                dismiss()
                showError(error)
            }
        }
    }

    private func captureDisplays() async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var frames: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                throw LensError.message("A connected display could not be captured. Retry after the display change.")
            }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            frames.append((screen, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)))
        }
        guard !frames.isEmpty else { throw LensError.message("No displays are available.") }
        return frames
    }

    func showOverlays(_ frames: [(NSScreen, CGImage)], selectingAllText: Bool = false) {
        let mouse = NSEvent.mouseLocation
        let active = frames.firstIndex(where: { $0.0.frame.contains(mouse) }) ?? 0
        let search = LiveSearch<String>()
        liveSearch = search
        wantsPanel = false
        showingTextPage = false
        cancelTextSearch()
        lastTextSearch = nil
        var actions = OverlayActions()
        actions.began = { [weak self] _ in
            self?.liveSearch?.postpone()
            self?.cancelTextSearch()
        }
        actions.changed = { [weak self] view, immediately in self?.selectionChanged(view, immediately: immediately) }
        actions.textChanged = { [weak self] view, text, search in self?.textSelected(view, text: text, search: search) }
        actions.textCommand = { [weak self] view, command, text in self?.textCommand(view, command, text: text) }
        actions.quick = { [weak self] view, action in self?.quickAction(view, action) }
        actions.translate = { [weak self] view, request in self?.translate(view, request) }
        actions.refine = { [weak self] view, query in self?.refine(view, query: query) }
        actions.panelVisibility = { [weak self] _, visible in self?.panelVisibilityChanged(visible) }
        actions.cancel = { [weak self] in self?.dismiss() }
        overlays = frames.enumerated().map { index, frame in
            let (screen, image) = frame
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image,
                                   displayIndex: index, topInset: screen.safeAreaInsets.top,
                                   controls: index == active,
                                   selectingAllText: selectingAllText && index == active, actions: actions)
            return OverlayWindow(screen: screen, overlay: view, escape: { [weak self] in self?.dismiss() })
        }
        let main = overlays[active].overlay
        panelView = main
        selectedView = main
        main.panel?.onAllow = { [weak self] in self?.allowVisualSearch() }
        main.panel?.onOpen = { [weak self] url in self?.openInBrowser(url) }
        main.panel?.onDismiss = { [weak self] in self?.dismiss() }
        search.onChange = { [weak self] state in self?.liveSearchChanged(state) }
        if presentsOverlays {
            NSApp.activate(ignoringOtherApps: true)
            for window in overlays { window.orderFrontRegardless() }
            overlays[active].makeKey()
        }
        for window in overlays { window.overlay.playIntro() }
        // Nothing is selected or sent until the user circles, highlights or taps something.
        refreshPanel()
    }

    private var uploadAllowed: Bool { defaults.bool(forKey: "experimentalUpload") }
    var searchState: LiveSearchState? { liveSearch?.state }
    var activeOverlay: OverlayView? { panelView }
    var isShowingOverlay: Bool { !overlays.isEmpty }

    private func refreshPanel() {
        guard let liveSearch, !showingTextPage else { return }
        panelView?.panel?.update(liveSearch.state, allowed: uploadAllowed)
    }

    /// The sheet slides in once there is something to show: an upload, results, an error or the privacy disclosure.
    private func revealPanelIfWanted() {
        guard wantsPanel, let panelView, let liveSearch, !showingTextPage,
              !(selectedView ?? panelView).hasTextSelection else { return }
        switch liveSearch.state {
        case .uploading, .loaded, .failed: panelView.revealPanel()
        case .idle, .waiting: if !uploadAllowed { panelView.revealPanel() }
        }
    }

    private func liveSearchChanged(_ state: LiveSearchState) {
        refreshPanel()
        panelView?.setBusy(state == .uploading)
        panelView?.setActivity(state == .uploading ? "Uploading the selected area to Google…" : nil)
        revealPanelIfWanted()
    }

    func selectionChanged(_ view: OverlayView, immediately: Bool) {
        // Selected text never uploads the screenshot.
        guard overlays.contains(where: { $0.overlay === view }), !view.hasTextSelection else { return }
        if view.hasSelection {
            for window in overlays where window.overlay !== view { window.overlay.clearSelection() }
            selectedView = view
        }
        guard let target = view.hasSelection ? view : selectedView, target.hasSelection else {
            view.showWarning("Circle, highlight or tap something first")
            return
        }
        guard let panelView, let liveSearch, let panel = panelView.panel else { return }
        showingTextPage = false
        wantsPanel = true
        guard uploadAllowed else {
            refreshPanel()
            revealPanelIfWanted()
            return
        }
        guard let key = target.searchKey, let crop = try? target.crop() else {
            target.showWarning("Select an area at least \(Int(Selection.minimumSide)) points wide and high")
            return
        }
        // Shown at its true shape while Google's results page lays out, including cached and refined results.
        panel.preview = crop
        let upload = self.upload
        liveSearch.schedule(key, immediately: immediately) { try await upload(panel, crop) }
        // A cached result doesn't change the state, but the sheet may be showing a text page.
        refreshPanel()
        revealPanelIfWanted()
    }

    /// Words typed in the search bar refine the visual search, like Android's multisearch. With nothing selected
    /// they are searched as plain text, and no picture is sent.
    private func refine(_ view: OverlayView, query: String) {
        guard let panelView, let panel = panelView.panel else { return }
        guard (selectedView ?? view).hasSelection else {
            if query.isEmpty {
                view.showWarning("Circle, highlight or tap something first")
            } else {
                textCommand(view, .search, text: query)
            }
            return
        }
        panel.refinement = query
        if case .loaded = liveSearch?.state, uploadAllowed {
            showingTextPage = false
            wantsPanel = true
            refreshPanel()
            revealPanelIfWanted()
        } else {
            selectionChanged(selectedView ?? view, immediately: true)
        }
    }

    private func panelVisibilityChanged(_ visible: Bool) {
        wantsPanel = visible
        if visible {
            if let selectedView, !selectedView.hasTextSelection, !showingTextPage {
                selectionChanged(selectedView, immediately: false)
            }
        } else {
            liveSearch?.cancel()
            showingTextPage = false
            panelView?.hidePanel()
        }
    }

    /// Selected text is searched as text, never as a picture: the visual search stops, and when visual search is
    /// allowed only the selected words are sent to Google after a short pause. Selecting all text searches nothing.
    private func textSelected(_ view: OverlayView, text: String, search: Bool) {
        guard overlays.contains(where: { $0.overlay === view }) else { return }
        for window in overlays where window.overlay !== view {
            window.overlay.clearSelection()
            window.overlay.clearTextSelection()
        }
        selectedView = view
        liveSearch?.cancel()
        panelView?.setBusy(false)
        panelView?.setActivity(nil)
        cancelTextSearch()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search, uploadAllowed, !query.isEmpty else {
            if !showingTextPage {
                wantsPanel = false
                panelView?.hidePanel()
            }
            return
        }
        guard query != lastTextSearch || !showingTextPage else { return }
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, view.hasTextSelection, view.selectedText.trimmingCharacters(
                in: .whitespacesAndNewlines) == query else { return }
            self.showTextSearch(query)
        }
        pendingTextSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.35, NSEvent.doubleClickInterval), execute: work)
    }

    private func showTextSearch(_ query: String) {
        guard let panelView, let panel = panelView.panel else { return }
        pendingTextSearch = nil
        lastTextSearch = query
        liveSearch?.cancel()
        showingTextPage = true
        wantsPanel = true
        panel.showPage(SearchURL.text(query), title: "Google Search")
        panelView.revealPanel()
    }

    private func cancelTextSearch() {
        pendingTextSearch?.cancel()
        pendingTextSearch = nil
    }

    private func allowVisualSearch() {
        defaults.set(true, forKey: "experimentalUpload")
        defaults.set(true, forKey: "onboarded")
        uploadCheckbox?.state = .on
        refreshPanel()
        if let selectedView { selectionChanged(selectedView, immediately: true) }
    }

    // MARK: Text

    /// Search or translate selected text in the sheet. Searching goes straight to Google when visual search is
    /// allowed; otherwise, and for translation, the sheet first shows exactly what will be sent.
    private func textCommand(_ view: OverlayView, _ command: TextCommand, text: String, title: String? = nil) {
        guard let panelView, let panel = panelView.panel else { return }
        let googleLanguage = SearchURL.translateLanguage(for: Locale.preferredLanguages.first)
        let search = command == .search
        cancelTextSearch()
        if search, uploadAllowed {
            showTextSearch(text)
            return
        }
        let url = search ? SearchURL.text(text) : SearchURL.translate(text, to: googleLanguage)
        liveSearch?.cancel()
        showingTextPage = true
        wantsPanel = true
        panel.confirmSend(title: title ?? (search ? "Search" : "Translate"),
                          heading: search ? "Search this text with Google?" : "Translate this text with Google?",
                          note: "The text was recognized on this Mac. Only the text below is sent to Google; " +
                                "the screenshot stays here.",
                          button: search ? "Search with Google" : "Translate with Google", text: text,
                          onConfirm: { [weak panel] in
                              panel?.showPage(url, title: search ? "Google Search" : "Google Translate")
                          },
                          onCancel: { [weak self, weak panelView] in
                              self?.showingTextPage = false
                              panelView?.hidePanel()
                          })
        panelView.revealPanel()
    }

    /// Context actions for detected emails, phone numbers, addresses, links, dates and tracking numbers.
    private func quickAction(_ view: OverlayView, _ action: TextQuickAction) {
        switch action.kind {
        case .system(let url):
            dismiss(restore: false)
            if !NSWorkspace.shared.open(url) {
                showError(LensError.message("No app on this Mac opens \(url.scheme ?? "these") links."))
            }
        case .website(let url):
            openWebsite(url)
        case .contact(let card):
            openTemporary(card.vCard, name: "Contact", extension: "vcf", app: "com.apple.AddressBook",
                          appName: "Contacts")
        case .calendar(let event):
            openTemporary(event.iCalendar(), name: "Event", extension: "ics", app: "com.apple.iCal",
                          appName: "Calendar")
        case .track(let number):
            textCommand(view, .search, text: number, title: "Track package")
        }
    }

    private func openWebsite(_ url: URL) {
        let browser: URL
        do { browser = try browserURL() } catch {
            showError(error)
            return
        }
        dismiss(restore: false)
        Task {
            do { try await Browser.open(url, in: browser) } catch { showError(error) }
        }
    }

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacOSLens", isDirectory: true)
    }

    /// A private file (0600 in a 0700 folder) that another app opens, deleted after two minutes and on next launch.
    static func writeTemporary(_ data: Data, name: String, extension ext: String) throws -> URL {
        let folder = temporaryDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(ext)")
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw LensError.message("Could not write a temporary file in \(folder.path).")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Contacts and Calendar ask the user before adding anything, so no contacts or calendar permission is needed.
    private func openTemporary(_ contents: String, name: String, extension ext: String, app bundleID: String,
                               appName: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            showError(LensError.message("\(appName) isn't available on this Mac."))
            return
        }
        let file: URL
        do { file = try Self.writeTemporary(Data(contents.utf8), name: name, extension: ext) } catch {
            showError(error)
            return
        }
        dismiss(restore: false)
        Task {
            do {
                try await NSWorkspace.shared.open([file], withApplicationAt: app,
                                                  configuration: NSWorkspace.OpenConfiguration())
            } catch { showError(error) }
        }
    }

    /// Translates the text on screen in place: on this Mac with Apple's Translation when the languages are
    /// available, after a system download prompt if needed, otherwise with Google Translate after consent.
    private func translate(_ view: OverlayView, _ request: TranslationRequest) {
        let current = session
        Task {
            let outcome = await OnDeviceTranslation.translate(request.blocks, source: request.source,
                                                              target: request.target, host: view)
            guard current == session, view.window != nil, view.translating,
                  view.translateBar.source == request.source, view.translateBar.target == request.target else { return }
            switch outcome {
            case .translated(let blocks):
                view.applyTranslation(blocks: blocks)
            case .downloadable(let source, let target):
                offerLanguageDownload(view, request, source: source, target: target)
            case .unavailable(let reason):
                offerGoogleTranslate(view, request, reason: reason)
            }
        }
    }

    private func offerLanguageDownload(_ view: OverlayView, _ request: TranslationRequest, source: String,
                                       target: String) {
        guard let panelView, let panel = panelView.panel else {
            view.translationFailed("Translation languages need to be downloaded in System Settings → General → " +
                                   "Language & Region → Translation Languages.")
            return
        }
        let pair = "\(TranslateBar.name(of: source)) and \(TranslateBar.name(of: target))"
        let current = session
        showingTextPage = true
        panel.confirmSend(title: "Translate", heading: "Download \(pair) to translate on this Mac?",
                          note: "macOS translates on this Mac once these languages are downloaded, and asks before " +
                                "downloading. Or send only the text below to Google Translate.",
                          button: "Download languages…", text: request.text,
                          alternative: ("Use Google Translate", { [weak self] in
                              self?.showGoogleTranslate(view, request)
                          }),
                          onConfirm: { [weak self, weak panelView] in
                              self?.showingTextPage = false
                              panelView?.hidePanel()
                              Task { @MainActor in
                                  let error = await OnDeviceTranslation.download(source: source, target: target,
                                                                                 host: view)
                                  guard let self, current == self.session else { return }
                                  if let error { view.translationFailed(error) } else { self.translate(view, request) }
                              }
                          },
                          onCancel: { [weak self, weak panelView] in
                              self?.showingTextPage = false
                              panelView?.hidePanel()
                              view.translationFailed(nil)
                          })
        panelView.revealPanel()
    }

    private func offerGoogleTranslate(_ view: OverlayView, _ request: TranslationRequest, reason: String) {
        view.translationFailed(nil)
        guard let panelView, let panel = panelView.panel else {
            view.showWarning(reason)
            return
        }
        showingTextPage = true
        wantsPanel = true
        panel.confirmSend(title: "Translate", heading: "Translate with Google instead?",
                          note: "\(reason) Only the text below is sent to Google Translate; the screenshot stays " +
                                "on this Mac.",
                          button: "Translate with Google", text: request.text,
                          onConfirm: { [weak self] in self?.showGoogleTranslate(view, request) },
                          onCancel: { [weak self, weak panelView] in
                              self?.showingTextPage = false
                              panelView?.hidePanel()
                          })
        panelView.revealPanel()
    }

    private func showGoogleTranslate(_ view: OverlayView, _ request: TranslationRequest) {
        view.translationFailed(nil)
        guard let panelView, let panel = panelView.panel else { return }
        showingTextPage = true
        wantsPanel = true
        panel.showPage(SearchURL.translate(request.text, to: SearchURL.translateLanguage(for: request.target)),
                       title: "Google Translate")
        panelView.revealPanel()
    }

    // MARK: Browser

    /// Visual results open with the selected picture: the browser itself uploads it from a private local page, so
    /// the results (and the picture) belong to the user's own browser session. Other pages open by address.
    private func openInBrowser(_ url: URL) {
        let browser: URL
        do { browser = try browserURL() } catch {
            panelView?.panel?.showError("Could not open a browser.", detail: error.localizedDescription)
            return
        }
        var target = url
        if let panel = panelView?.panel, panel.mode == .lens, uploadAllowed, let view = selectedView,
           !view.hasTextSelection, view.hasSelection, let crop = try? view.crop(),
           let page = try? Self.handoffPage(for: crop) {
            target = page
        }
        dismiss(restore: false)
        Task {
            do { try await Browser.open(target, in: browser) } catch { showError(error) }
        }
    }

    /// Writes the page that posts only `crop` to Google Lens when the browser opens it.
    static func handoffPage(for crop: CGImage) throws -> URL {
        let image = LensUpload.scaledForUpload(crop)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw LensError.message("Could not encode the selected image.")
        }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return try writeTemporary(Data(LensHandoff.html(png: png, language: language).utf8), name: "Lens",
                                  extension: "html")
    }

    func dismiss(restore: Bool = true) {
        session += 1
        wantsPanel = false
        showingTextPage = false
        liveSearch?.onChange = nil
        liveSearch?.cancel()
        liveSearch = nil
        panelView = nil
        selectedView = nil
        for window in overlays {
            window.overlay.stopSpeaking()
            window.orderOut(nil)
            window.close()
        }
        overlays.removeAll()
        if restore { previousApp?.activate(options: []) }
        previousApp = nil
    }

    private func browserURL() throws -> URL {
        try Browser.applicationURL(preferredPath: defaults.string(forKey: "browserPath"))
    }

    private func browserDescription() -> String {
        if let path = defaults.string(forKey: "browserPath"), !path.isEmpty {
            return Browser.name(of: URL(fileURLWithPath: path))
        }
        guard let url = Browser.defaultApplication() else { return "Default browser (none set in macOS)" }
        return "Default browser (\(Browser.name(of: url)))"
    }

    @objc private func openSupportPage() {
        guard let url = SupportLink.url() else {
            showError(LensError.message("The support page address is missing from this build."))
            return
        }
        settingsWindow?.orderOut(nil)
        launcherWindow?.orderOut(nil)
        openWebsite(url)
    }

    func showError(_ error: Error) {
        if !overlays.isEmpty { dismiss(restore: false) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "macOS Lens"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: Screen Recording

    /// Identifies this exact build, so a stale permission entry is reset once per rebuild and never again.
    private static func buildIdentifier() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
           let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            return unique.map { String(format: "%02x", $0) }.joined()
        }
        let path = Bundle.main.executablePath ?? ""
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return "\(path)@\(date?.timeIntervalSince1970 ?? 0)"
    }

    /// Removes only this app's own Screen Recording entry, which an earlier ad-hoc build leaves behind.
    private static func resetOwnScreenRecordingEntry() {
        guard Bundle.main.bundleIdentifier == bundleID else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("macOS Lens: tccutil reset failed: \(error.localizedDescription)")
        }
    }

    /// Adds this copy of the app to System Settings → Screen Recording so the user only flips its switch.
    private func requestScreenRecording(forceReset: Bool) {
        guard !awaitingScreenRecording || forceReset else {
            showScreenRecordingHelp()
            return
        }
        let build = Self.buildIdentifier()
        if forceReset || defaults.string(forKey: "permissionResetBuild") != build {
            defaults.set(build, forKey: "permissionResetBuild")
            Self.resetOwnScreenRecordingEntry()
        }
        awaitingScreenRecording = true
        CGRequestScreenCaptureAccess()
        busy = true
        Task {
            // A ScreenCaptureKit request also lists the app when the CoreGraphics request alone does not.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            busy = false
            openScreenRecordingSettings()
            showScreenRecordingHelp()
        }
    }

    @objc private func fixScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Screen Recording is on"
            alert.informativeText = "macOS Lens can capture your screen. If capturing still fails, quit and reopen it."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Quit & Reopen")
            if alert.runModal() == .alertSecondButtonReturn { relaunch() }
            return
        }
        requestScreenRecording(forceReset: true)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
              NSWorkspace.shared.open(url) else {
            NSLog("macOS Lens: System Settings could not be opened")
            return
        }
    }

    private static let grantedResponse = NSApplication.ModalResponse(rawValue: 9_001)

    /// Waits for the switch to be turned on while the alert is up, then offers to reopen the app.
    private func showScreenRecordingHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn on macOS Lens, then reopen"
        alert.informativeText = "macOS Lens is now listed in System Settings → Privacy & Security → " +
                                "Screen & System Audio Recording. Turn its switch on; this message notices and " +
                                "offers to reopen the app. Nothing was captured or uploaded."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Later")
        let granted = Self.grantedResponse
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            if CGPreflightScreenCaptureAccess() { NSApp.stopModal(withCode: granted) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        permissionTimer = timer
        let response = alert.runModal()
        timer.invalidate()
        permissionTimer = nil
        switch response {
        case Self.grantedResponse:
            alert.window.orderOut(nil)
            screenRecordingGranted()
        case .alertFirstButtonReturn:
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    private func screenRecordingGranted() {
        awaitingScreenRecording = false
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording is on"
        alert.informativeText = "Reopen macOS Lens so macOS lets it capture the screen."
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// Starts a fresh copy once this one has exited.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try process.run() } catch {
            showError(LensError.message("macOS Lens couldn't reopen itself. Quit and open it again."))
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Windows

    @objc private func showLauncher() {
        present(makeLauncherWindow())
    }

    /// Builds the launcher once. The native checks render it offscreen without showing it.
    func makeLauncherWindow() -> NSWindow {
        if let launcherWindow {
            setLauncherShortcutText()
            return launcherWindow
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 318),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "macOS Lens"
        window.isReleasedWhenClosed = false
        let form = FormView()
        window.contentView = form
        let icon = NSImageView(image: LensMark.image(size: 36))
        icon.imageScaling = .scaleNone
        icon.contentTintColor = googleBlue
        let heading = NSTextField(wrappingLabelWithString: "macOS Lens is running")
        heading.font = .boldSystemFont(ofSize: 16)
        form.add(.item(icon, .fixed(40), height: 40), .item(heading))
        let shortcutField = NSTextField(wrappingLabelWithString: launcherShortcutText)
        launcherShortcutField = shortcutField
        form.add(.item(shortcutField), gap: 14)
        let hint = NSTextField(wrappingLabelWithString:
            "Can't see the Lens icon in the menu bar? It may be hidden behind the camera notch " +
            "or turned off in System Settings → Menu Bar. Open macOS Lens again from Finder or " +
            "Spotlight to show this window.")
        hint.textColor = .secondaryLabelColor
        form.add(.item(hint), gap: 8)
        func button(_ title: String, _ action: Selector) -> FormView.Item {
            let button = NSButton(title: title, target: self, action: action)
            // Room around the title, so the longest one doesn't touch the button's ends.
            return .item(button, .fill(min: ceil(button.fittingSize.width) + 24))
        }
        let search = button("Search screen…", #selector(searchScreen))
        (search.view as? NSButton)?.keyEquivalent = "\r"
        form.add(search, button("Select all text on screen…", #selector(selectText)), gap: 18)
        form.add(button("Fix Screen Recording permission…", #selector(fixScreenRecording)),
                 button("Settings & privacy…", #selector(showSettings)), gap: 8)
        form.add(.item(CoffeeButton(target: self, action: #selector(openSupportPage)), height: 34),
                 button("Quit macOS Lens", #selector(quit)), gap: 14)
        form.fitWindow(width: max(480, form.naturalWidth))
        form.letUserResize(window)
        launcherWindow = window
        window.center()
        return window
    }

    // An accessory app opened in the background is not activated on macOS 14+, so its windows would stay behind others.
    private func present(_ window: NSWindow?) {
        guard let window else { return }
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    @objc private func showSettings() {
        present(makeSettingsWindow())
    }

    /// Builds Settings once. The native checks render it offscreen without showing it.
    func makeSettingsWindow() -> NSWindow {
        if let settingsWindow { return settingsWindow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "macOS Lens — Settings & privacy"
        window.isReleasedWhenClosed = false
        let form = FormView()
        window.contentView = form
        func label(_ text: String, bold: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            if bold { field.font = .boldSystemFont(ofSize: 18) }
            return field
        }
        func fixed(_ button: NSButton, _ width: CGFloat) -> FormView.Item {
            .item(button, .fixed(max(width, ceil(button.fittingSize.width))))
        }
        let mark = NSImageView(image: LensMark.image(size: 30))
        mark.imageScaling = .scaleNone
        mark.contentTintColor = googleBlue
        form.add(.item(mark, .fixed(32), height: 32), .item(label("Circle to Search, adapted for your Mac", bold: true)))
        form.add(.item(label(
            "Press the shortcut or use the menu-bar Lens icon. The screen freezes in place with nothing selected " +
            "and nothing sent. Circle, scribble or tap something to search it; drag the corners to adjust, and " +
            "drag inside to move. Click, highlight or circle text to select its words, then copy, listen, " +
            "translate or search them; the text shortcut opens it with all text selected. Pinch or scroll with " +
            "two fingers to zoom and pan. Escape, ✕ or swiping the results down closes it.")), gap: 10)
        form.add(.item(label(
            "Screen capture, text recognition, Listen and Apple translation stay on this Mac. Visual search sends " +
            "ONLY the area you circle, box or tap to Google, each time you pause adjusting it; opening the " +
            "overlay sends nothing. Selected text is searched as text, sending only those words, and only when " +
            "visual search is allowed; otherwise it asks first, as Google Translate does. " +
            "Your browser's cookies are never read and no public image host is used.")), gap: 10)
        let checkbox = NSButton(checkboxWithTitle: "Allow visual search (experimental Google Lens image upload)",
                                target: self, action: #selector(toggleUpload(_:)))
        checkbox.state = uploadAllowed ? .on : .off
        uploadCheckbox = checkbox
        form.add(.item(checkbox, .fit), gap: 14)
        form.add(.item(label(
            "This uses an undocumented Google endpoint, not an official API, and can stop working. Results load " +
            "in the sheet on the right of the screen, where Google may show rate-limit (429), consent or sign-in " +
            "pages. “Open in browser” lets the browser upload the same selection itself.")), gap: 6)
        form.add(.item(label("Browser for “Open in browser”, links and text search")), gap: 18)
        let browser = label(browserDescription())
        browserField = browser
        form.add(.item(browser), fixed(NSButton(title: "Choose…", target: self, action: #selector(chooseBrowser)), 110),
                 fixed(NSButton(title: "Use default", target: self, action: #selector(useDefaultBrowser)), 110), gap: 6)
        let systemKeys = systemHotKeys()
        func popup(_ title: String, _ options: [Shortcut], selected: Shortcut, action: Selector) -> FormView.Item {
            let popup = NSPopUpButton()
            popup.autoenablesItems = false
            for option in options {
                let used = option.conflictsWithSystem(systemKeys)
                popup.addItem(withTitle: used ? "\(option.title) — used by macOS" : option.title)
                popup.lastItem?.representedObject = option.id
                popup.lastItem?.isEnabled = !used
            }
            popup.selectItem(at: options.firstIndex(of: selected) ?? 0)
            popup.target = self
            popup.action = action
            // Wide enough for any title it can show; the open menu shows unavailable shortcuts in full anyway.
            let sizing = NSPopUpButton()
            sizing.addItems(withTitles: options.filter { !$0.conflictsWithSystem(systemKeys) }.map(\.title))
            let column = FormView()
            column.margin = 0
            column.add(.item(label(title)))
            column.add(.item(popup, .fill(min: max(180, ceil(sizing.fittingSize.width)))), gap: 6)
            return .item(column)
        }
        form.add(popup("Search shortcut", Shortcut.all, selected: shortcut, action: #selector(changeShortcut(_:))),
                 popup("Text shortcut", Shortcut.textOptions, selected: textShortcut,
                       action: #selector(changeTextShortcut(_:))), gap: 18)
        form.add(.item(label("Screen Recording: each new build of this unsigned app needs the switch turned on again.")),
                 gap: 22)
        form.add(.item(NSButton(title: "Fix Screen Recording permission…", target: self,
                                action: #selector(fixScreenRecording))),
                 .item(CoffeeButton(target: self, action: #selector(openSupportPage)), height: 34), gap: 8)
        form.add(fixed(NSButton(title: "Try local OCR", target: self, action: #selector(tryOCR)), 150), .spacer(),
                 fixed(NSButton(title: "Save settings", target: self, action: #selector(saveSettings)), 130), gap: 28)
        form.fitWindow(width: max(600, form.naturalWidth))
        form.letUserResize(window)
        settingsWindow = window
        window.center()
        return window
    }

    @objc private func toggleUpload(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "experimentalUpload")
        if sender.state == .off { liveSearch?.cancel() }
        refreshPanel()
    }

    @objc private func changeShortcut(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        defaults.set(id, forKey: "shortcutID")
        registerShortcuts()
    }

    @objc private func changeTextShortcut(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        defaults.set(id, forKey: "textShortcutID")
        registerShortcuts()
    }

    @objc private func chooseBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Browser.opensWebLinks(url) else {
            showError(LensError.message("\(Browser.name(of: url)) cannot open web links. Choose a web browser."))
            return
        }
        defaults.set(url.path, forKey: "browserPath")
        updateBrowserField()
    }

    @objc private func useDefaultBrowser() {
        defaults.removeObject(forKey: "browserPath")
        updateBrowserField()
    }

    private func updateBrowserField() {
        browserField?.stringValue = browserDescription()
        (settingsWindow?.contentView as? FormView)?.fitWindow()
    }

    @objc private func saveSettings() {
        defaults.set(true, forKey: "onboarded")
        settingsWindow?.orderOut(nil)
    }

    @objc private func tryOCR() {
        saveSettings()
        activate(selectingAllText: true)
    }
}

/// A Buy Me a Coffee button in its own colours, drawn locally: nothing contacts Buy Me a Coffee until it's clicked.
final class CoffeeButton: NSButton {
    static let yellow = NSColor(srgbRed: 1, green: 0xDD / 255, blue: 0, alpha: 1)
    static let ink = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)

    convenience init(target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.backgroundColor = Self.yellow.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = Self.ink.withAlphaComponent(0.85).cgColor
        image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = Self.ink
        attributedTitle = NSAttributedString(string: "Buy me a coffee", attributes: [
            .foregroundColor: Self.ink, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ])
        toolTip = SupportLink.url().map { "Opens \($0.absoluteString) in your browser" }
        setAccessibilityLabel("Buy me a coffee")
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

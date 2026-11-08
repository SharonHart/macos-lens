import AppKit
import AVFoundation
import Carbon
import LensCore
import ScreenCaptureKit

enum CaptureMode { case search, text }

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var menu: NSMenu!
    private var overlays: [OverlayWindow] = []
    private var resultWindow: TextWindow?
    private var settingsWindow: NSWindow?
    private var launcherWindow: NSWindow?
    private var launcherShortcutField: NSTextField?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var busy = false
    private var liveSearch: LiveSearch<String>?
    private weak var panelView: OverlayView?
    private weak var selectedView: OverlayView?
    private var uploadCheckbox: NSButton?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var browserField: NSTextField?
    private let defaults = UserDefaults.standard
    private let speech = AVSpeechSynthesizer()

    private var shortcut: Shortcut { Shortcut.named(defaults.string(forKey: "shortcutID")) }

    private func systemHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                  "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "macOS Lens")
        menu = NSMenu()
        menu.addItem(item("Search screen…", #selector(searchScreen)))
        menu.addItem(item("Extract screen text…", #selector(extractScreen)))
        menu.addItem(.separator())
        menu.addItem(item("Settings & privacy…", #selector(showSettings)))
        menu.addItem(item("Quit macOS Lens", #selector(quit)))
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status.button?.toolTip = "Search screen; right-click for text, settings and quit"
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            lastExternalApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        registerShortcut()
        // The menu-bar item can be hidden by the notch or menu-bar settings, so every launch shows a window.
        showLauncher()
        if !defaults.bool(forKey: "onboarded") { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if overlays.isEmpty && !busy { showLauncher() }
        return false
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != NSRunningApplication.current else { return }
        lastExternalApp = app
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        speech.stopSpeaking(at: .immediate)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func searchScreen() { activate(mode: .search) }
    @objc private func extractScreen() { activate(mode: .text) }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            if let button = status.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        } else {
            activate(mode: .search)
        }
    }

    private func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let install = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.activate(mode: .search) }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard install == noErr else {
                showError(LensError.message("Could not install the global shortcut handler (\(install))."))
                return
            }
        }
        let shortcut = self.shortcut
        status.button?.toolTip = "Search screen (\(shortcut.title)); right-click for text, settings and quit"
        launcherShortcutField?.stringValue = "Press \(shortcut.title) anywhere to open the screen selector."
        guard !shortcut.conflictsWithSystem(systemHotKeys()) else {
            showError(LensError.message("\(shortcut.title) is already used by a macOS keyboard shortcut, such as " +
                                       "input-source switching. Choose another shortcut in Settings."))
            return
        }
        var modifiers: UInt32 = 0
        if shortcut.modifiers & Shortcut.command != 0 { modifiers |= UInt32(cmdKey) }
        if shortcut.modifiers & Shortcut.shift != 0 { modifiers |= UInt32(shiftKey) }
        if shortcut.modifiers & Shortcut.option != 0 { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers & Shortcut.control != 0 { modifiers |= UInt32(controlKey) }
        let result = RegisterEventHotKey(shortcut.keyCode, modifiers,
                                        EventHotKeyID(signature: 0x4c454e53, id: 1),
                                        GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            showError(LensError.message("The shortcut could not be registered (\(result)). Choose another in Settings."))
        }
    }

    func activate(mode: CaptureMode) {
        guard !busy, overlays.isEmpty else { return }
        // The shortcut always opens the selection overlay; only missing Screen Recording access stops it.
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecording()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? lastExternalApp : front
        settingsWindow?.orderOut(nil)
        launcherWindow?.orderOut(nil)
        resultWindow?.orderOut(nil)
        busy = true
        Task {
            do {
                let frames = try await captureDisplays()
                // All screenshots are acquired before any overlay can appear in the capture.
                showOverlays(frames, mode: mode)
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

    func showOverlays(_ frames: [(NSScreen, CGImage)], mode: CaptureMode) {
        let mouse = NSEvent.mouseLocation
        let active = frames.firstIndex(where: { $0.0.frame.contains(mouse) }) ?? 0
        let search = LiveSearch<String>()
        liveSearch = search
        var actions = OverlayActions()
        actions.began = { [weak self] _ in self?.liveSearch?.postpone() }
        actions.changed = { [weak self] view, immediately in self?.selectionChanged(view, immediately: immediately) }
        actions.text = { [weak self] view in self?.readText(from: view) }
        actions.panelVisibility = { [weak self] _, visible in self?.panelVisibilityChanged(visible) }
        actions.cancel = { [weak self] in self?.dismiss() }
        overlays = frames.enumerated().map { index, frame in
            let (screen, image) = frame
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image,
                                   displayIndex: index, mode: mode, topInset: screen.safeAreaInsets.top,
                                   selected: index == active, showsPanel: index == active,
                                   panelCollapsed: mode == .text, actions: actions)
            return OverlayWindow(screen: screen, overlay: view, escape: { [weak self] in self?.dismiss() })
        }
        let main = overlays[active].overlay
        panelView = main
        selectedView = main
        main.panel?.onAllow = { [weak self] in self?.allowVisualSearch() }
        main.panel?.onOpen = { [weak self] url in self?.openInBrowser(url) }
        search.onChange = { [weak self] state in self?.liveSearchChanged(state) }
        NSApp.activate(ignoringOtherApps: true)
        for window in overlays { window.orderFrontRegardless() }
        overlays[active].makeKey()
        refreshPanel()
        // The whole-display selection is searched after the debounce unless the user starts adjusting it first.
        if mode == .search { selectionChanged(main, immediately: false) }
    }

    private var uploadAllowed: Bool { defaults.bool(forKey: "experimentalUpload") }
    var searchState: LiveSearchState? { liveSearch?.state }
    var activeOverlay: OverlayView? { panelView }

    private func refreshPanel() {
        guard let liveSearch else { return }
        panelView?.panel?.update(liveSearch.state, allowed: uploadAllowed)
    }

    private func liveSearchChanged(_ state: LiveSearchState) {
        refreshPanel()
        panelView?.setActivity(state == .uploading ? "Uploading selected area to Google…" : nil)
    }

    func selectionChanged(_ view: OverlayView, immediately: Bool) {
        guard overlays.contains(where: { $0.overlay === view }) else { return }
        if view.hasSelection {
            for window in overlays where window.overlay !== view { window.overlay.clearSelection() }
            selectedView = view
        }
        guard let target = view.hasSelection ? view : selectedView, target.hasSelection else {
            view.showWarning("Drag to select an area first")
            return
        }
        guard let panelView, let liveSearch else { return }
        if immediately { panelView.setPanelCollapsed(false) }
        guard !panelView.panelCollapsed else { return }
        guard uploadAllowed else {
            refreshPanel()
            return
        }
        guard let key = target.searchKey, let crop = try? target.crop() else {
            target.showWarning("Select an area at least \(Int(Selection.minimumSide)) points wide and high")
            return
        }
        guard let panel = panelView.panel else { return }
        liveSearch.schedule(key, immediately: immediately) {
            try await panel.search(LensUpload.request(for: crop))
        }
    }

    private func panelVisibilityChanged(_ visible: Bool) {
        if visible {
            if let selectedView { selectionChanged(selectedView, immediately: false) }
        } else {
            liveSearch?.cancel()
        }
    }

    private func allowVisualSearch() {
        defaults.set(true, forKey: "experimentalUpload")
        defaults.set(true, forKey: "onboarded")
        uploadCheckbox?.state = .on
        refreshPanel()
        if let selectedView { selectionChanged(selectedView, immediately: true) }
    }

    private func openInBrowser(_ url: URL) {
        let browser: URL
        do { browser = try browserURL() } catch {
            panelView?.panel?.showError("Could not open a browser.", detail: error.localizedDescription)
            return
        }
        dismiss(restore: false)
        Task {
            do { try await Browser.open(url, in: browser) } catch { showError(error) }
        }
    }

    private func readText(from view: OverlayView) {
        guard let target = view.hasSelection ? view : selectedView, let crop = try? target.crop() else {
            view.showWarning("Drag to select an area first")
            return
        }
        recognizeText(crop)
    }

    func dismiss(restore: Bool = true) {
        liveSearch?.onChange = nil
        liveSearch?.cancel()
        liveSearch = nil
        panelView = nil
        selectedView = nil
        for window in overlays { window.orderOut(nil); window.close() }
        overlays.removeAll()
        if restore { previousApp?.activate(options: []) }
        previousApp = nil
    }

    private func recognizeText(_ image: CGImage) {
        guard !busy else { return }
        dismiss()
        busy = true
        status.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Reading text")
        Task {
            do {
                let lines = try await Task.detached(priority: .userInitiated) { try OCR.recognize(image) }.value
                guard !lines.isEmpty else {
                    throw LensError.message("No readable text was found in the selected area. Try a larger selection.")
                }
                resultWindow = TextWindow(text: lines.map(\.text).joined(separator: "\n"), action: { [weak self] action, text in
                    self?.textAction(action, text: text)
                })
                NSApp.activate(ignoringOtherApps: true)
                resultWindow?.makeKeyAndOrderFront(nil)
            } catch { showError(error) }
            busy = false
            status.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "macOS Lens")
        }
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

    private func textAction(_ action: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError(LensError.message("Select some text first."))
            return
        }
        switch action {
        case "Copy":
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                showError(LensError.message("Could not copy text to the clipboard."))
                return
            }
        case "Listen":
            speech.stopSpeaking(at: .immediate)
            guard let voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier) else {
                showError(LensError.message("The system speech voice is unavailable."))
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            speech.speak(utterance)
        case "Stop":
            speech.stopSpeaking(at: .immediate)
        default:
            let alert = NSAlert()
            alert.messageText = action == "Translate" ? "Send selected text to Google Translate?" : "Search selected text with Google?"
            alert.informativeText = "Only the selected text will be sent, opened in \(browserDescription()). OCR itself runs locally."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                do {
                    let url = action == "Translate" ? SearchURL.translate(text) : SearchURL.text(text)
                    try await Browser.open(url, in: browserURL())
                } catch { showError(error) }
            }
        }
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

    private func requestScreenRecording() {
        busy = true
        CGRequestScreenCaptureAccess()
        Task {
            // A ScreenCaptureKit request adds the app to the Screen Recording list when the CoreGraphics prompt does not.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            busy = false
            showScreenRecordingHelp()
        }
    }

    private func showScreenRecordingHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Turn on macOS Lens in System Settings → Privacy & Security → " +
                                "Screen & System Audio Recording, then quit and reopen macOS Lens. " +
                                "Nothing was captured or uploaded."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        if !NSWorkspace.shared.open(url) {
            showError(LensError.message("System Settings could not be opened. Open Privacy & Security manually."))
        }
    }

    @objc private func showLauncher() {
        if launcherWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "macOS Lens"
            window.isReleasedWhenClosed = false
            let root = window.contentView!
            let heading = NSTextField(labelWithString: "macOS Lens is running")
            heading.font = .boldSystemFont(ofSize: 16)
            heading.frame = NSRect(x: 24, y: 206, width: 392, height: 24)
            root.addSubview(heading)
            let shortcutField = NSTextField(labelWithString: "")
            shortcutField.frame = NSRect(x: 24, y: 182, width: 392, height: 20)
            launcherShortcutField = shortcutField
            root.addSubview(shortcutField)
            let hint = NSTextField(wrappingLabelWithString:
                "Can't see the viewfinder icon in the menu bar? It may be hidden behind the camera notch " +
                "or turned off in System Settings → Menu Bar. Open macOS Lens again from Finder or " +
                "Spotlight to show this window.")
            hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 24, y: 104, width: 392, height: 70)
            root.addSubview(hint)
            func button(_ title: String, _ action: Selector, x: CGFloat, y: CGFloat) -> NSButton {
                let button = NSButton(title: title, target: self, action: action)
                button.frame = NSRect(x: x, y: y, width: 190, height: 32)
                root.addSubview(button)
                return button
            }
            button("Search screen…", #selector(searchScreen), x: 24, y: 60).keyEquivalent = "\r"
            _ = button("Extract screen text…", #selector(extractScreen), x: 226, y: 60)
            _ = button("Settings & privacy…", #selector(showSettings), x: 24, y: 20)
            _ = button("Quit macOS Lens", #selector(quit), x: 226, y: 20)
            launcherWindow = window
            window.center()
        }
        launcherShortcutField?.stringValue = "Press \(shortcut.title) anywhere to open the screen selector."
        present(launcherWindow)
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
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "macOS Lens — Settings & privacy"
        window.isReleasedWhenClosed = false
        let root = window.contentView!
        func label(_ text: String, y: CGFloat, height: CGFloat = 24, bold: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.frame = NSRect(x: 24, y: y, width: 550, height: height)
            if bold { field.font = .boldSystemFont(ofSize: 18) }
            root.addSubview(field)
        }
        label("Circle to Search, adapted for your Mac", y: 452, bold: true)
        label("Press the shortcut, Search screen in the macOS Lens window, or the menu-bar viewfinder. The " +
              "selection starts as the whole screen: drag its edges or corners to resize it, drag inside to move " +
              "it, or drag across the screen (or use Draw) for a new area. Escape returns to your previous app.",
              y: 372, height: 70)
        label("Screen capture and Apple Vision OCR stay in memory on this Mac. Visual search sends ONLY the area " +
              "inside the selection to Google — the WHOLE SCREEN unless you shrink it — each time you pause " +
              "adjusting it. The results panel uploads with its own Google cookies (and sign-in, if you choose); your " +
              "browser's cookies are never read and no public image host is used.", y: 300, height: 62)
        let checkbox = NSButton(checkboxWithTitle: "Allow visual search (experimental Google Lens image upload)",
                                target: self, action: #selector(toggleUpload(_:)))
        checkbox.frame = NSRect(x: 24, y: 270, width: 550, height: 24)
        checkbox.state = uploadAllowed ? .on : .off
        uploadCheckbox = checkbox
        root.addSubview(checkbox)
        label("This uses an undocumented Google endpoint, not an official API, and can stop working. Results load " +
              "in the overlay's right-hand panel, where Google may show rate-limit (429), consent or sign-in pages.",
              y: 218, height: 44)
        label("Browser for “Open in browser” and text search", y: 187)
        let browser = NSTextField(labelWithString: browserDescription())
        browser.frame = NSRect(x: 24, y: 160, width: 318, height: 24)
        browser.lineBreakMode = .byTruncatingMiddle
        browserField = browser
        root.addSubview(browser)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseBrowser))
        choose.frame = NSRect(x: 352, y: 158, width: 110, height: 28)
        root.addSubview(choose)
        let useDefault = NSButton(title: "Use default", target: self, action: #selector(useDefaultBrowser))
        useDefault.frame = NSRect(x: 464, y: 158, width: 110, height: 28)
        root.addSubview(useDefault)
        label("Global shortcut", y: 125)
        let popup = NSPopUpButton(frame: NSRect(x: 24, y: 96, width: 300, height: 28))
        popup.autoenablesItems = false
        let systemKeys = systemHotKeys()
        for option in Shortcut.all {
            let used = option.conflictsWithSystem(systemKeys)
            popup.addItem(withTitle: used ? "\(option.title) — used by macOS" : option.title)
            popup.lastItem?.representedObject = option.id
            popup.lastItem?.isEnabled = !used
        }
        popup.selectItem(at: Shortcut.all.firstIndex(of: shortcut) ?? 0)
        popup.target = self
        popup.action = #selector(changeShortcut(_:))
        root.addSubview(popup)
        let done = NSButton(title: "Save settings", target: self, action: #selector(saveSettings))
        done.frame = NSRect(x: 444, y: 22, width: 130, height: 30)
        root.addSubview(done)
        let text = NSButton(title: "Try local OCR", target: self, action: #selector(tryOCR))
        text.frame = NSRect(x: 24, y: 22, width: 150, height: 30)
        root.addSubview(text)
        settingsWindow = window
        window.center()
        present(window)
    }

    @objc private func toggleUpload(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "experimentalUpload")
        if sender.state == .off { liveSearch?.cancel() }
        refreshPanel()
    }

    @objc private func changeShortcut(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        defaults.set(id, forKey: "shortcutID")
        registerShortcut()
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
        browserField?.stringValue = browserDescription()
    }

    @objc private func useDefaultBrowser() {
        defaults.removeObject(forKey: "browserPath")
        browserField?.stringValue = browserDescription()
    }

    @objc private func saveSettings() {
        defaults.set(true, forKey: "onboarded")
        settingsWindow?.orderOut(nil)
    }

    @objc private func tryOCR() {
        saveSettings()
        activate(mode: .text)
    }
}

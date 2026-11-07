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
    private var previousApp: NSRunningApplication?
    private var busy = false
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
        registerShortcut()
        if !defaults.bool(forKey: "onboarded") { showSettings() }
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
        if mode == .search && !defaults.bool(forKey: "experimentalUpload") {
            showSettings()
            return
        }
        if mode == .search {
            do { _ = try browserURL() } catch { showError(error); return }
        }
        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecording()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        settingsWindow?.orderOut(nil)
        resultWindow?.orderOut(nil)
        busy = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var frames: [(NSScreen, CGImage)] = []
                let screens = NSScreen.screens
                for screen in screens {
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
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    frames.append((screen, image))
                }
                guard !frames.isEmpty else { throw LensError.message("No displays are available.") }
                // All screenshots are acquired before any overlay can appear in the capture.
                overlays = frames.map { screen, image in
                    OverlayWindow(screen: screen, image: image, mode: mode,
                                  submit: { [weak self] crop, selectedMode in self?.submit(crop, mode: selectedMode) },
                                  cancel: { [weak self] in self?.dismiss() },
                                  failure: { [weak self] error in self?.showError(error) })
                }
                NSApp.activate(ignoringOtherApps: true)
                for window in overlays { window.orderFrontRegardless() }
                let mouse = NSEvent.mouseLocation
                (overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first)?.makeKey()
                busy = false
            } catch {
                busy = false
                dismiss()
                showError(error)
            }
        }
    }

    private func dismiss(restore: Bool = true) {
        for window in overlays { window.orderOut(nil); window.close() }
        overlays.removeAll()
        if restore { previousApp?.activate(options: []) }
        previousApp = nil
    }

    private func submit(_ image: CGImage, mode: CaptureMode) {
        guard !busy else { return }
        if mode == .search && !defaults.bool(forKey: "experimentalUpload") {
            dismiss()
            showSettings()
            return
        }
        let browser: URL?
        do { browser = mode == .search ? try browserURL() : nil }
        catch { showError(error); return }
        dismiss()
        busy = true
        status.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Processing selection")
        Task {
            do {
                if mode == .text {
                    let lines = try await Task.detached(priority: .userInitiated) {
                        try OCR.recognize(image)
                    }.value
                    guard !lines.isEmpty else {
                        throw LensError.message("No readable text was found in the selected area. Try a larger selection.")
                    }
                    resultWindow = TextWindow(text: lines.map(\.text).joined(separator: "\n"), action: { [weak self] action, text in
                        self?.textAction(action, text: text)
                    })
                    NSApp.activate(ignoringOtherApps: true)
                    resultWindow?.makeKeyAndOrderFront(nil)
                } else {
                    let result = try await LensUpload.upload(image)
                    if let browser { try await Browser.open(result, in: browser) }
                }
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

    @objc private func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
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
        label("Circle to Search, adapted for your Mac", y: 398, bold: true)
        label("Use the menu-bar viewfinder or a global shortcut. Drag a rectangle or draw around an area. " +
              "Release to search; hold Option to adjust first. Escape returns to your previous app.", y: 333, height: 56)
        label("Screen capture and Apple Vision OCR stay in memory on this Mac. Visual search sends ONLY your " +
              "chosen crop to Google. No browser cookies are read and no public image host is used.", y: 268, height: 56)
        let checkbox = NSButton(checkboxWithTitle: "Enable experimental Google Lens image upload", target: self,
                                action: #selector(toggleUpload(_:)))
        checkbox.frame = NSRect(x: 24, y: 240, width: 550, height: 24)
        checkbox.state = defaults.bool(forKey: "experimentalUpload") ? .on : .off
        root.addSubview(checkbox)
        label("This uses an undocumented Google endpoint, not an official API. It can stop working. " +
              "Results open in your browser, not an Android-style embedded result sheet.", y: 190, height: 42)
        label("Browser", y: 161)
        let browser = NSTextField(labelWithString: browserDescription())
        browser.frame = NSRect(x: 24, y: 134, width: 318, height: 24)
        browser.lineBreakMode = .byTruncatingMiddle
        browserField = browser
        root.addSubview(browser)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseBrowser))
        choose.frame = NSRect(x: 352, y: 132, width: 110, height: 28)
        root.addSubview(choose)
        let useDefault = NSButton(title: "Use default", target: self, action: #selector(useDefaultBrowser))
        useDefault.frame = NSRect(x: 464, y: 132, width: 110, height: 28)
        root.addSubview(useDefault)
        label("Global shortcut", y: 99)
        let popup = NSPopUpButton(frame: NSRect(x: 24, y: 70, width: 300, height: 28))
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleUpload(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "experimentalUpload")
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

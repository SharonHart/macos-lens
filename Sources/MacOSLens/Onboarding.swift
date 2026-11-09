import AppKit
import CoreGraphics

/// The calls macOS gates behind Screen Recording. Checks replace them, so they count calls without touching the
/// Mac's privacy settings.
@MainActor
struct ScreenAccess {
    /// Never prompts.
    var granted: () -> Bool
    /// Shows the system prompt, at most once per app entry.
    var request: () -> Void
    /// Clears this app's own entry, which an earlier build leaves behind.
    var reset: () -> Void
    var openSettings: () -> Void

    static var system: ScreenAccess {
        ScreenAccess(granted: { CGPreflightScreenCaptureAccess() },
                     request: { _ = CGRequestScreenCaptureAccess() },
                     reset: resetOwnEntry,
                     openSettings: {
                         guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" +
                                                     "Privacy_ScreenCapture"),
                               NSWorkspace.shared.open(url) else {
                             NSLog("macOS Lens: System Settings could not be opened")
                             return
                         }
                     })
    }

    private static func resetOwnEntry() {
        guard Bundle.main.bundleIdentifier == AppController.bundleID else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", AppController.bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("macOS Lens: tccutil reset failed: \(error.localizedDescription)")
        }
    }
}

/// The one Screen Recording window. macOS is asked only when the user clicks “Allow Screen Recording…”; the window
/// then waits for the switch and offers to reopen the app, which macOS needs before capture works.
@MainActor
final class ScreenRecordingOnboarding: NSObject, NSWindowDelegate {
    enum Step { case ask, waiting, granted }

    static let allowTitle = "Allow Screen Recording…"
    static let settingsTitle = "Open System Settings"
    static let reopenTitle = "Quit & Reopen"

    private(set) var step: Step = .ask
    let window: NSWindow
    private let access: ScreenAccess
    private let relaunch: () -> Void
    private let shortcutTitle: () -> String?
    private var timer: Timer?

    init(access: ScreenAccess, shortcutTitle: @escaping () -> String?, relaunch: @escaping () -> Void) {
        self.access = access
        self.relaunch = relaunch
        self.shortcutTitle = shortcutTitle
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "macOS Lens — Screen Recording"
        window.isReleasedWhenClosed = false
        window.delegate = self
        render()
        window.center()
    }

    /// Shows the step that matches the current permission, without asking macOS for anything.
    func prepare() {
        if access.granted() {
            step = .granted
        } else if step == .granted {
            step = .ask
        }
        render()
    }

    /// Resets this app's stale entry and asks macOS once. Only a click on a button calls this.
    @objc func allow() {
        access.reset()
        access.request()
        step = .waiting
        render()
        startPolling()
    }

    @objc func openSettings() { access.openSettings() }
    @objc func reopen() { relaunch() }

    @objc func later() {
        stopPolling()
        window.orderOut(nil)
    }

    /// Notices the switch being turned on, from the timer or when the app becomes active again.
    func refresh() {
        guard step != .granted, access.granted() else { return }
        stopPolling()
        step = .granted
        render()
    }

    func windowWillClose(_ notification: Notification) { stopPolling() }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// The buttons of the current step, primary last. Checks read them.
    private(set) var buttons: [NSButton] = []

    private func render() {
        let form = FormView()
        let mark = NSImageView(image: LensMark.image(size: 30))
        mark.imageScaling = .scaleNone
        mark.contentTintColor = googleBlue
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: 18)
        form.add(.item(mark, .fixed(32), height: 32), .item(heading))
        form.add(.item(NSTextField(wrappingLabelWithString: message)), gap: 10)
        if step == .ask {
            let privacy = NSTextField(wrappingLabelWithString:
                "Screenshots and text recognition stay on this Mac. Opening the lens sends nothing; visual search " +
                "sends only the area you circle, box or tap to Google.")
            privacy.textColor = .secondaryLabelColor
            form.add(.item(privacy), gap: 10)
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            return button
        }
        switch step {
        case .ask: buttons = [button("Later", #selector(later)), button(Self.allowTitle, #selector(allow))]
        case .waiting: buttons = [button(Self.reopenTitle, #selector(reopen)),
                                  button(Self.settingsTitle, #selector(openSettings))]
        case .granted: buttons = [button("Later", #selector(later)), button(Self.reopenTitle, #selector(reopen))]
        }
        buttons.last?.keyEquivalent = "\r"
        form.add([.spacer()] + buttons.map { .item($0, .fixed(ceil($0.fittingSize.width) + 24)) }, gap: 20)
        window.contentView = form
        form.fitWindow(width: 520)
    }

    private var title: String {
        switch step {
        case .ask: "Allow Screen Recording"
        case .waiting: "Turn on macOS Lens"
        case .granted: "Screen Recording is on"
        }
    }

    private var message: String {
        switch step {
        case .ask:
            let opener = shortcutTitle().map { "When you press \($0) or click the Lens icon" } ??
                "When you click the Lens icon"
            return "\(opener), macOS Lens freezes the screen so you can circle what to search. macOS needs your " +
                   "permission for that. Click “Allow Screen Recording…” and macOS asks once."
        case .waiting:
            return "In the macOS prompt choose Open System Settings, then turn on macOS Lens under Privacy & " +
                   "Security › Screen & System Audio Recording. If no prompt appeared, open System Settings " +
                   "yourself. Once it's on, quit and reopen macOS Lens."
        case .granted:
            return "Reopen macOS Lens so macOS lets it capture the screen."
        }
    }
}

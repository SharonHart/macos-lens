import AppKit
import LensCore
import WebKit

/// Drives the real overlay and live results panel with a generated image instead of a screen capture.
/// It shows the overlay on the main display for a few seconds and uploads only the synthetic fixture.
@MainActor
enum OverlayCheck {
    static func run() async throws {
        guard Bundle.main.bundleIdentifier == nil, let screen = NSScreen.main else {
            throw LensError.message("Run the overlay check from the debug binary on a Mac with a display.")
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "experimentalUpload")
        defer { defaults.removePersistentDomain(forName: ProcessInfo.processInfo.processName) }
        let controller = AppController()
        controller.showOverlays([(screen, try OCR.fixture())], mode: .search)
        defer { controller.dismiss() }
        guard let view = controller.activeOverlay, let panel = view.panel, let window = view.window else {
            throw LensError.message("The overlay did not open with a results panel.")
        }
        try expect(controller.searchState == .waiting, "the whole-display selection waits for the debounce")
        let first = try await results(controller, panel)
        print("PASS whole-display selection searched after the debounce: \(first.absoluteString.prefix(70))…")

        let wholeKey = view.searchKey
        let brackets = view.bracketFrame ?? view.bounds
        try expect(view.panelShown, "the results sheet slid in for the whole-screen search")
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        let start = CGPoint(x: brackets.maxX, y: brackets.midY)
        try expect(view.hitTest(start) === view, "the right bracket is reachable beside the results sheet")
        view.mouseDown(with: mouse(.leftMouseDown, start))
        for step in 1...4 {
            view.mouseDragged(with: mouse(.leftMouseDragged,
                                          CGPoint(x: start.x - brackets.width * 0.1 * CGFloat(step), y: start.y)))
        }
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: start.x - brackets.width * 0.4, y: start.y)))
        try expect(view.searchKey != wholeKey && controller.searchState == .waiting,
                   "resizing with the right-edge handle schedules a new debounced search")
        let second = try await results(controller, panel)
        try expect(second != first, "the resized selection got its own results")
        print("PASS right-edge resize searched the new area: \(view.searchKey ?? "none")")

        view.selectWholeScreen()
        try expect(controller.searchState == .loaded(first), "returning to a searched area reuses its results")
        try await settle(panel)
        try expect(panel.webView?.url == first, "the sheet shows the reused results")
        print("PASS Command-A reused the earlier results without another upload")
        print("PANEL_STATUS \(panel.statusLabel.stringValue)")

        // Text mode never uploads, even with visual search allowed and a selection reported to the app.
        view.setMode(.text)
        let deadline = Date().addingTimeInterval(20)
        while view.textLayout == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let state = controller.searchState
        let page = panel.webView?.url
        view.selectAllText()
        controller.selectionChanged(view, immediately: true)
        try await Task.sleep(for: .seconds(2))
        try expect(view.selectedText == "HELLO LENS 123", "Text mode recognized the fixture on this Mac")
        try expect(controller.searchState == state && panel.webView?.url == page && !view.panelShown,
                   "a Text-mode selection starts no upload and hides the visual results")
        print("PASS Text mode selected \"HELLO LENS 123\" locally and uploaded nothing")
    }

    private static func results(_ controller: AppController, _ panel: ResultsPanel) async throws -> URL {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            switch controller.searchState {
            case .loaded(let url):
                try await settle(panel)
                return url
            case .failed(let message):
                throw LensError.message("Search failed: \(message)")
            default:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw LensError.message("No results within 40 seconds (\(String(describing: controller.searchState))).")
    }

    private static func settle(_ panel: ResultsPanel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while panel.webView?.isLoading == true && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        try await Task.sleep(for: .seconds(1))
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw LensError.message("FAIL \(message)") }
    }
}

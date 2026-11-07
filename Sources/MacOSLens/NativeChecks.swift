import AppKit
import LensCore

@MainActor
enum NativeChecks {
    static func run() -> Bool {
        _ = NSApplication.shared
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("PASS \(message)") }
            else { failures += 1; fputs("FAIL \(message)\n", stderr) }
        }
        do {
            let image = try OCR.fixture()
            var submitted: CGImage?
            var submittedMode: CaptureMode?
            var cancelled = false
            var error: Error?
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 640, height: 240),
                                   image: image, mode: .search,
                                   submit: { submitted = $0; submittedMode = $1 },
                                   cancel: { cancelled = true }, failure: { error = $0 })
            window.contentView = view
            // The test window is never shown, and only generated pixels are rendered.
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                   timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 10, y: 20)))
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 11, y: 21)))
            view.keyDown(with: enter)
            check(submitted == nil && error == nil && !cancelled,
                  "tap and empty Return keep the overlay open without an error")
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 10, y: 20)))
            view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 110, y: 80)))
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 110, y: 80)))
            check(submitted?.width == image.width * 100 / 640 &&
                  submitted?.height == image.height * 60 / 240 && submittedMode == .search,
                  "native drag immediately submits only selected crop")
            submitted = nil
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 200, y: 100)))
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 300, y: 180), flags: .option))
            check(submitted == nil, "Option holds selection for adjustment")
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 300, y: 180)))
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 350, y: 200)))
            check(submitted == nil, "corner adjustment waits for Return")
            view.keyDown(with: enter)
            check(submitted?.width == image.width * 150 / 640 &&
                  submitted?.height == image.height * 100 / 240, "Return submits adjusted bounds")
            let strip = view.subviews.first!
            let modeControl = strip.subviews.compactMap { $0 as? NSSegmentedControl }.first!
            modeControl.selectedSegment = 1
            NSApp.sendAction(modeControl.action!, to: modeControl.target, from: modeControl)
            let shape = strip.subviews.compactMap { $0 as? NSButton }.first(where: { $0.title == "Draw / circle" })!
            shape.performClick(nil)
            submitted = nil
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 30, y: 30)))
            view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 80, y: 35)))
            view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 60, y: 90)))
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 30, y: 30)))
            check(submitted?.width == image.width * 50 / 640 &&
                  submitted?.height == image.height * 60 / 240 && submittedMode == .text,
                  "freehand bounds submit to local OCR mode")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53)!
            view.keyDown(with: escape)
            check(cancelled, "Escape cancels")
            check(error == nil, "valid native gestures report no errors")
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "overlay renders offscreen synthetic image")
            window.close()
        } catch {
            failures += 1
            fputs("FAIL native checks: \(error.localizedDescription)\n", stderr)
        }
        print("Native checks: \(failures) failures; no screen capture or browser launch.")
        return failures == 0
    }
}

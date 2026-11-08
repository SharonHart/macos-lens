import AppKit
import LensCore

/// Offscreen checks of the Circle to Search overlay with a generated image: no screen capture, upload or browser.
@MainActor
enum NativeChecks {
    static func run(snapshot: URL? = nil) -> Bool {
        _ = NSApplication.shared
        OverlayView.animates = false
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("PASS \(message)") }
            else { failures += 1; fputs("FAIL \(message)\n", stderr) }
        }
        func near(_ a: CGRect?, _ b: CGRect, _ accuracy: CGFloat = 0.5) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) <= accuracy && abs(a.minY - b.minY) <= accuracy &&
                abs(a.width - b.width) <= accuracy && abs(a.height - b.height) <= accuracy
        }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
        }
        func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        do {
            let image = try fixture()
            var began = 0
            var changes: [(OverlayView, Bool)] = []
            var texts = 0
            var translations = 0
            var refinements: [String] = []
            var visibility: [Bool] = []
            var cancelled = 0
            var actions = OverlayActions()
            actions.began = { _ in began += 1 }
            actions.changed = { changes.append(($0, $1)) }
            actions.text = { _ in texts += 1 }
            actions.translate = { _ in translations += 1 }
            actions.refine = { refinements.append($1) }
            actions.panelVisibility = { visibility.append($1) }
            actions.cancel = { cancelled += 1 }
            let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
            let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = OverlayView(frame: size, image: image, displayIndex: 0, mode: .search, topInset: 32,
                                   selected: true, controls: true, actions: actions)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.playIntro()
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
            }
            func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [],
                     in window: NSWindow) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            }
            var midDrag: (() -> Void)?
            func gesture(_ points: [CGPoint]) {
                view.mouseDown(with: mouse(.leftMouseDown, points[0]))
                for point in points.dropFirst() { view.mouseDragged(with: mouse(.leftMouseDragged, point)) }
                midDrag?()
                midDrag = nil
                view.mouseUp(with: mouse(.leftMouseUp, points.last!))
            }
            let bounds = view.bounds
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let panel = view.panel!

            // Activation: the frozen screen fills the display 1:1 with only the Android-style controls on top.
            check(view.canvas == bounds && image.width == Int(bounds.width) * 2 && view.layer?.backgroundColor?.alpha == 0,
                  "the Retina screenshot fills the display exactly, with no border, inset or scaling")
            check(view.isWhole && view.pixelRect == full && !view.isDimmed &&
                  near(view.bracketFrame, bounds.insetBy(dx: 10, dy: 10)),
                  "the whole screen starts selected, shown as corner brackets with no dimming")
            let group = view.barFrame.union(view.translateFrame)
            check(abs(group.midX - bounds.midX) <= 1 && view.barFrame.minY < 40 &&
                  view.field.placeholderString == "Add to your search" && view.bar.superview === view &&
                  view.translateCard.superview === view && view.translateFrame.minX > view.barFrame.maxX,
                  "a search bar with “Add to your search” and Translate to its right floats at the bottom centre")
            check(view.closeFrame.minX < 40 && view.closeFrame.maxY > bounds.maxY - 32 - 60 &&
                  view.closeCard.superview === view, "an ✕ close button sits at the top left, below the menu bar")
            check(!buttons(in: view).contains { ["Draw", "Full screen", "Search", "Text"].contains($0.title) } &&
                  !view.panelShown && panel.isHidden, "there is no toolbar and no results sheet until a search")

            // Results sheet: slides in on the right without covering the selection handles.
            view.revealPanel()
            view.layoutSubtreeIfNeeded()
            check(view.panelShown && !panel.isHidden && near(panel.frame, view.panelFrame) &&
                  panel.frame.maxX < bounds.maxX - 10 && panel.frame.minY > view.barFrame.maxY,
                  "the results sheet appears as a floating card on the right, above the search bar")
            let brackets = view.bracketFrame!
            let handlePoints: [(SelectionHandle, CGPoint)] = SelectionHandle.allCases.map { ($0, $0.point(in: brackets)) }
            check(handlePoints.allSatisfy { handle, point in
                view.hitTest(point) === view && view.target(at: point) == .resize(handle)
            }, "all eight corner and edge handles stay reachable with the sheet shown")
            let inside = CGPoint(x: panel.frame.midX, y: panel.frame.midY - 40)
            check(view.hitTest(inside).map { $0 === panel || $0.isDescendant(of: panel) } == true,
                  "clicks on the sheet stay in the sheet instead of starting a selection")

            var passedThrough = false
            midDrag = { passedThrough = panel.passThrough && view.hitTest(inside) === view }
            let edge = CGPoint(x: brackets.maxX, y: brackets.midY)
            gesture([edge, CGPoint(x: edge.x - 150, y: edge.y), CGPoint(x: 900, y: edge.y)])
            let resized = CGRect(x: 0, y: 0, width: 900 + bounds.maxX - edge.x, height: bounds.height)
            check(passedThrough && !panel.passThrough,
                  "the sheet lets the screenshot through while a selection is being adjusted")
            check(near(view.selection, resized) && !view.isWhole && view.isDimmed && changes.last?.1 == false &&
                  view.pixelRect == Selection.pixels(for: resized, in: view.canvas, width: image.width,
                                                     height: image.height),
                  "dragging the right bracket resizes the selection, dims the rest lightly and schedules a search")

            // Corner brackets: move and resize a smaller selection.
            let start = view.selection!
            gesture([CGPoint(x: start.midX, y: start.midY), CGPoint(x: start.midX - 100, y: start.midY - 50)])
            check(near(view.selection, start), "a selection as tall as the screen cannot move past its edges")
            gesture([CGPoint(x: start.minX, y: start.maxY), CGPoint(x: start.minX + 200, y: start.maxY - 150)])
            let corner = CGRect(x: 200, y: 0, width: start.width - 200, height: start.height - 150)
            check(near(view.selection, corner), "the top-left bracket resizes both edges")
            gesture([CGPoint(x: corner.midX, y: corner.midY), CGPoint(x: corner.midX - 120, y: corner.midY + 60)])
            check(near(view.selection, corner.offsetBy(dx: -120, dy: 60)), "dragging inside moves the selection")

            // Hide and bring back the sheet.
            panel.hideButton.performClick(nil)
            check(!view.panelShown && visibility == [false], "Hide closes the sheet and tells the app")
            view.revealPanel()
            view.dockPanel(left: true)
            view.layoutSubtreeIfNeeded()
            check(view.panelShown && panel.frame.minX <= 20.5 && panel.frame.maxY < view.closeFrame.minY,
                  "the sheet can dock on the left without covering the close button")
            view.dockPanel(left: false)
            view.hidePanel()

            // Circle, highlight, scribble and tap.
            changes.removeAll()
            view.selectWholeScreen()
            check(view.isWhole && changes.count == 1 && changes[0].1 == false, "Command-A selects the whole screen again")
            let red = CGRect(x: 760, y: 160, width: 120, height: 120)
            let circle = (0...24).map { step -> CGPoint in
                let angle = CGFloat(step) / 24 * 2 * .pi
                return CGPoint(x: red.midX + cos(angle) * 85, y: red.midY + sin(angle) * 85)
            }
            var inked: CGRect?
            midDrag = { inked = view.inkBounds }
            gesture(circle)
            check(inked.map { $0.width > 160 && $0.height > 160 } == true && view.inkBounds == nil,
                  "circling draws glowing ink that disappears when the finger lifts")
            check(view.selection.map { $0.contains(red) && $0.width < 200 } == true &&
                  near(view.bracketFrame, view.selection!) && view.isDimmed && changes.last?.1 == false,
                  "a circle becomes a bracketed selection around what was circled")
            view.revealPanel()
            view.layoutSubtreeIfNeeded()
            check(view.panelShown && view.panelDockedLeft && !panel.frame.intersects(view.selection!),
                  "the sheet slides in on the side away from what was circled")
            let circled = view.selection!
            gesture([CGPoint(x: circled.midX, y: circled.midY), CGPoint(x: circled.midX - 600, y: circled.midY)])
            view.layoutSubtreeIfNeeded()
            check(!view.panelDockedLeft && !panel.frame.intersects(view.selection!),
                  "moving the selection under the sheet moves the sheet to the other side")
            view.hidePanel()

            view.selectWholeScreen()
            gesture([CGPoint(x: 100, y: 528), CGPoint(x: 300, y: 530), CGPoint(x: 470, y: 527)])
            check(view.selection.map { $0.height >= 40 && $0.minX < 101 && $0.maxX > 469 } == true,
                  "a highlight across a line of text selects the whole highlighted strip")

            view.selectWholeScreen()
            let count = changes.count
            let tap = CGPoint(x: 290, y: 528)
            gesture([tap, tap])
            check(spin(until: { changes.count > count }) && view.selection.map {
                $0.contains(tap) && $0.width > 250 && $0.height < 110
            } == true, "tapping text selects its line, found on this Mac with Apple Vision")

            // Zoom and pan never change which pixels are searched.
            let tapped = view.pixelRect
            view.zoom(by: 2, at: CGPoint(x: 300, y: 500))
            let onScreen = Selection.pixels(for: view.selection!, in: view.canvas, width: image.width,
                                            height: image.height)
            check(view.viewport.isZoomed && view.canvas.width == bounds.width * 2 && view.pixelRect == tapped &&
                  tapped.map { near(onScreen, $0, 1) } == true,
                  "pinch-zooming enlarges the screenshot and keeps the selected pixels")
            view.pan(by: CGVector(dx: -200, dy: 80))
            check(view.pixelRect == tapped && view.canvas.contains(bounds), "two-finger panning keeps the selection on its pixels")
            changes.removeAll()
            view.selectWholeScreen()
            view.zoom(by: 2, at: CGPoint(x: bounds.midX, y: bounds.midY))
            check(view.pixelRect == CGRect(x: 600, y: 350, width: 1200, height: 700) &&
                  spin(until: { changes.count == 2 }, timeout: 2),
                  "zooming the whole-screen selection searches only what is visible, after the gesture pauses")
            view.selectWholeScreen()
            check(!view.viewport.isZoomed && view.pixelRect == full, "Command-A also resets zoom")

            // Search bar, Translate and close.
            view.field.stringValue = "  red shoes "
            view.fieldSubmitted()
            check(refinements == ["red shoes"], "Return in the search bar refines the search with the typed words")
            view.translateButton.performClick(nil)
            view.textButton.performClick(nil)
            check(translations == 1 && texts == 1, "Translate and select-text act on the selection")
            changes.removeAll()
            view.keyDown(with: key(36, "\r", in: window))
            check(changes.count == 1 && changes[0].1, "Return searches the selection immediately")
            view.closeButton.performClick(nil)
            check(cancelled == 1, "✕ closes the overlay")

            // Sheet states.
            panel.update(.idle, allowed: false)
            check(!panel.disclosure.isHidden && !panel.openButton.isEnabled &&
                  panel.statusLabel.stringValue.contains("Nothing has been uploaded"),
                  "with visual search off the sheet shows the upload disclosure and uploads nothing")
            panel.update(.uploading, allowed: true)
            view.setActivity("Uploading the selected area to Google…")
            view.setBusy(true)
            check(panel.disclosure.isHidden && panel.statusLabel.stringValue.contains("Uploading") &&
                  view.toastText.hasPrefix("Uploading the selected area"), "uploads are visibly indicated")
            view.setBusy(false)
            view.setActivity(nil)
            panel.update(.failed("Google Lens is limiting requests (HTTP 429)."), allowed: true)
            check(!panel.messageLabel.isHidden && panel.messageLabel.stringValue.contains("429"),
                  "search errors such as HTTP 429 are shown in the sheet")
            var sent = false, kept = false
            panel.confirmTranslation(text: "HELLO LENS 123", onConfirm: { sent = true }, onCancel: { kept = true })
            check(!panel.confirmation.isHidden && panel.statusLabel.stringValue == "Nothing has been sent." &&
                  panel.titleLabel.stringValue == "Translate", "Translate asks before sending the recognized text")
            buttons(in: panel.confirmation).first { $0.title == "Cancel" }?.performClick(nil)
            check(kept && !sent, "cancelling a translation sends nothing")
            check(panel.webView == nil, "no web page is created or loaded by these checks")

            // Swipe down on the sheet closes everything.
            var dismissed = 0
            panel.onDismiss = { dismissed += 1 }
            for (phase, delta) in [(1, 0), (2, 40), (2, 40), (2, 30), (4, 0)] {
                if let event = scroll(phase: phase, deltaY: delta) { panel.scrollWheel(with: event) }
            }
            for (phase, delta) in [(1, 0), (2, -30), (2, 200), (4, 0)] {
                if let event = scroll(phase: phase, deltaY: delta) { panel.scrollWheel(with: event) }
            }
            check(dismissed == 1, "pulling the sheet down closes it; scrolling up first does not")

            // Other displays: frozen, but without controls or a selection.
            let other = OverlayView(frame: size, image: image, displayIndex: 1, mode: .text, selected: false,
                                    controls: false, actions: actions)
            other.keyDown(with: key(36, "\r", in: window))
            check(other.selection == nil && other.searchKey == nil && texts == 2 && other.panel == nil &&
                  other.bar.superview == nil, "other displays start without a selection or controls")

            if let screen = NSScreen.screens.first {
                let screenView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image,
                                             displayIndex: 0, mode: .search, selected: false, controls: true,
                                             actions: actions)
                let overlayWindow = OverlayWindow(screen: screen, overlay: screenView, escape: { cancelled += 1 })
                check(overlayWindow.frame == screen.frame && !overlayWindow.isOpaque &&
                      overlayWindow.backgroundColor == .clear && overlayWindow.styleMask == [.borderless],
                      "each overlay window covers its display exactly, borderless and transparent")
                changes.removeAll()
                _ = overlayWindow.performKeyEquivalent(with: key(0, "a", flags: .command, in: overlayWindow))
                check(screenView.isWhole && changes.count == 1, "Command-A selects the whole screen")
                overlayWindow.sendEvent(key(53, "\u{1b}", in: overlayWindow))
                check(cancelled == 2, "Escape cancels from anywhere in the overlay window")
                overlayWindow.close()
            }

            if let snapshot {
                view.field.stringValue = ""
                view.hidePanel()
                view.dockPanel(left: false)
                view.selectWholeScreen()
                view.layoutSubtreeIfNeeded()
                let activation = snapshot.deletingPathExtension().appendingPathExtension("activation.png")
                try render(view, to: activation)
                print("Saved \(activation.path)")
                gesture(circle)
                view.revealPanel()
                panel.update(.idle, allowed: false)
                view.layoutSubtreeIfNeeded()
                try render(view, to: snapshot)
                print("Saved \(snapshot.path)")
            }
            window.close()
        } catch {
            failures += 1
            fputs("FAIL native checks: \(error.localizedDescription)\n", stderr)
        }
        print("Native checks: \(failures) failures; no screen capture, upload or browser launch.")
        return failures == 0
    }

    /// A 1200×700 point Retina image with a line of text and a red circle, standing in for a screen.
    static func fixture() throws -> CGImage {
        let size = NSSize(width: 1200, height: 700)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1400,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw LensError.message("Could not generate the test image.")
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        ("HELLO LENS 123" as NSString).draw(at: NSPoint(x: 100, y: 500), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black
        ])
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 760, y: 160, width: 120, height: 120)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw LensError.message("Could not generate the test image.") }
        return image
    }

    /// A trackpad scroll event in the given gesture phase (1 began, 2 changed, 4 ended).
    private static func scroll(phase: Int, deltaY: Int) -> NSEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        return NSEvent(cgEvent: event)
    }

    private static func render(_ view: NSView, to url: URL) throws {
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LensError.message("Could not render the overlay.")
        }
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw LensError.message("Could not encode the overlay snapshot.")
        }
        try data.write(to: url)
    }
}

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
        func near(_ a: CGRect?, _ b: CGRect, _ accuracy: CGFloat = 0.5) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) <= accuracy && abs(a.minY - b.minY) <= accuracy &&
                abs(a.width - b.width) <= accuracy && abs(a.height - b.height) <= accuracy
        }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] + buttons(in: $0) }
        }
        do {
            // Only a generated fixture is drawn; the windows are never shown and nothing is uploaded.
            let image = try OCR.fixture()
            var began = 0
            var changes: [(OverlayView, Bool)] = []
            var texts = 0
            var visibility: [Bool] = []
            var cancelled = 0
            var actions = OverlayActions()
            actions.began = { _ in began += 1 }
            actions.changed = { changes.append(($0, $1)) }
            actions.text = { _ in texts += 1 }
            actions.panelVisibility = { visibility.append($1) }
            actions.cancel = { cancelled += 1 }
            let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
            let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = OverlayView(frame: size, image: image, displayIndex: 0, mode: .search, topInset: 32,
                                   selected: true, showsPanel: true, actions: actions)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
            }
            func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            }
            func gesture(_ points: [CGPoint]) {
                view.mouseDown(with: mouse(.leftMouseDown, points[0]))
                for point in points.dropFirst() { view.mouseDragged(with: mouse(.leftMouseDragged, point)) }
                view.mouseUp(with: mouse(.leftMouseUp, points.last!))
            }
            func button(_ title: String) -> NSButton? { buttons(in: view).first { $0.title == title } }
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let canvas = view.canvas

            check(near(view.selection, canvas) && view.pixelRect == full &&
                  view.searchKey == "0:0,0,\(image.width),\(image.height)",
                  "the overlay opens with the whole display selected")
            check(!view.toolbarFrame.intersects(canvas.insetBy(dx: -SelectionEditor.tolerance,
                                                               dy: -SelectionEditor.tolerance)) &&
                  !(view.panelFrame?.intersects(canvas.insetBy(dx: -SelectionEditor.tolerance, dy: 0)) ?? true),
                  "toolbar and results panel never cover the screenshot or its handles")

            let drawn = CGRect(x: canvas.minX + 100, y: canvas.minY + 40, width: 200, height: 90)
            gesture([drawn.origin, CGPoint(x: drawn.midX, y: drawn.midY), CGPoint(x: drawn.maxX, y: drawn.maxY)])
            check(near(view.selection, drawn) && began == 1 && changes.last?.1 == false,
                  "dragging inside the full selection draws a new area and schedules a debounced search")
            check(view.pixelRect == Selection.pixels(for: drawn, in: canvas, width: image.width, height: image.height) &&
                  (try? view.crop())?.width == Int(view.pixelRect!.width),
                  "the crop is the selected Retina pixels only")

            gesture([CGPoint(x: drawn.midX, y: drawn.midY), CGPoint(x: drawn.midX + 40, y: drawn.midY - 15)])
            let moved = drawn.offsetBy(dx: 40, dy: -15)
            check(near(view.selection, moved), "dragging inside a smaller selection moves it")

            gesture([CGPoint(x: moved.maxX, y: moved.midY), CGPoint(x: moved.maxX + 50, y: moved.midY + 30)])
            let widened = CGRect(x: moved.minX, y: moved.minY, width: moved.width + 50, height: moved.height)
            check(near(view.selection, widened), "the right edge handle resizes only the width")

            gesture([CGPoint(x: widened.minX, y: widened.maxY), CGPoint(x: widened.minX - 30, y: widened.maxY + 20)])
            let cornered = CGRect(x: widened.minX - 30, y: widened.minY, width: widened.width + 30,
                                  height: widened.height + 20)
            check(near(view.selection, cornered), "the top-left corner handle resizes both edges")

            gesture([CGPoint(x: cornered.maxX + 200, y: cornered.minY), CGPoint(x: cornered.maxX + 201, y: cornered.minY)])
            check(near(view.selection, cornered) && view.hintLabel.stringValue.contains("Drag across"),
                  "a tap keeps the selection and shows a hint instead of an error")

            gesture([CGPoint(x: cornered.minX, y: cornered.minY), CGPoint(x: canvas.minX - 500, y: canvas.minY - 500)])
            check(view.selection.map { canvas.insetBy(dx: -0.5, dy: -0.5).contains($0) } == true,
                  "handles cannot drag the selection outside the screenshot")

            button("Draw")?.performClick(nil)
            let start = CGPoint(x: canvas.minX + 450, y: canvas.minY + 60)
            gesture([start, CGPoint(x: start.x + 60, y: start.y + 5), CGPoint(x: start.x + 30, y: start.y + 70), start])
            check(view.freehand && near(view.selection, CGRect(x: start.x, y: start.y, width: 60, height: 70)),
                  "Draw mode turns a circle or scribble into its bounding area")
            button("Draw")?.performClick(nil)

            changes.removeAll()
            button("Full screen")?.performClick(nil)
            check(near(view.selection, canvas) && view.pixelRect == full && changes.count == 1,
                  "Full screen resets the selection to the whole display")

            changes.removeAll()
            view.keyDown(with: key(36, "\r", in: window))
            check(changes.count == 1 && changes[0].1 && texts == 0, "Return searches the selection immediately")
            view.readText()
            check(texts == 1, "Text (OCR) is available from the search overlay")

            let keyBefore = view.searchKey
            button("Hide results")?.performClick(nil)
            view.layoutSubtreeIfNeeded()
            check(view.panelCollapsed && view.panel?.isHidden == true && visibility == [false] &&
                  view.canvas.width > canvas.width && view.searchKey == keyBefore,
                  "hiding the results panel enlarges the screenshot without changing the searched pixels")
            button("Show results")?.performClick(nil)
            view.panel?.onResize?(5000, true)
            view.layoutSubtreeIfNeeded()
            check(visibility == [false, true] && (view.panelFrame?.width ?? 0) <= size.width * 0.6 + 0.5 &&
                  view.searchKey == keyBefore, "the results panel resizes within limits and keeps the selection")

            let panel = view.panel!
            panel.update(.idle, allowed: false)
            check(!panel.disclosure.isHidden && !panel.openButton.isEnabled &&
                  panel.statusLabel.stringValue.contains("Nothing has been uploaded"),
                  "with visual search off the panel shows the upload disclosure and uploads nothing")
            panel.update(.uploading, allowed: true)
            view.setActivity("Uploading selected area to Google…")
            check(panel.disclosure.isHidden && panel.statusLabel.stringValue.contains("Uploading") &&
                  view.hintLabel.stringValue.hasPrefix("Uploading selected area to Google"),
                  "uploads are visibly indicated in the panel and the overlay")
            panel.update(.failed("Google Lens is limiting requests (HTTP 429)."), allowed: true)
            check(!panel.messageLabel.isHidden && panel.messageLabel.stringValue.contains("429"),
                  "search errors such as HTTP 429 are shown in the panel")
            check(panel.webView == nil, "no web page is created or loaded by these checks")

            let other = OverlayView(frame: size, image: image, displayIndex: 1, mode: .text, selected: false,
                                    showsPanel: false, actions: actions)
            other.keyDown(with: key(36, "\r", in: window))
            check(other.selection == nil && other.searchKey == nil && texts == 2 && other.panel == nil,
                  "other displays start without a selection and Return in text mode reads text")

            if let screen = NSScreen.screens.first {
                let overlayWindow = OverlayWindow(screen: screen, overlay: other, escape: { cancelled += 1 })
                overlayWindow.sendEvent(key(53, "\u{1b}", in: overlayWindow))
                check(cancelled == 1, "Escape cancels from anywhere in the overlay window, including the results page")
                overlayWindow.close()
            }

            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "overlay renders the synthetic image offscreen")
            window.close()
        } catch {
            failures += 1
            fputs("FAIL native checks: \(error.localizedDescription)\n", stderr)
        }
        print("Native checks: \(failures) failures; no screen capture, upload or browser launch.")
        return failures == 0
    }
}

import AppKit
import LensCore

/// Offscreen checks of the Circle to Search overlay, its text selection and its frame with generated images: no screen capture, upload or
/// browser, and nothing written to the user's clipboard or settings.
@MainActor
enum NativeChecks {
    static func run(snapshot: URL? = nil) -> Bool {
        _ = NSApplication.shared
        OverlayView.animates = false
        let privateName = "dev.macos-lens.checks"
        let suite = UserDefaults(suiteName: privateName)!
        suite.removePersistentDomain(forName: privateName)
        let board = NSPasteboard(name: NSPasteboard.Name(privateName))
        board.clearContents()
        let speaker = SilentSpeaker()
        let saved = (OverlayView.defaults, OverlayView.pasteboard, OverlayView.speaker)
        OverlayView.defaults = suite
        OverlayView.pasteboard = board
        OverlayView.speaker = speaker
        let clipboard = NSPasteboard.general.changeCount
        defer {
            (OverlayView.defaults, OverlayView.pasteboard, OverlayView.speaker) = saved
            suite.removePersistentDomain(forName: privateName)
            board.releaseGlobally()
        }

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
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow, clicks: Int = 1,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: clicks, pressure: 1)!
        }
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [],
                 in window: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        var midDrag: (() -> Void)?
        func gesture(_ points: [CGPoint], on target: OverlayView) {
            guard let window = target.window else { return }
            target.mouseDown(with: mouse(.leftMouseDown, points[0], in: window))
            for point in points.dropFirst() { target.mouseDragged(with: mouse(.leftMouseDragged, point, in: window)) }
            midDrag?()
            midDrag = nil
            target.mouseUp(with: mouse(.leftMouseUp, points.last!, in: window))
        }
        func click(_ point: CGPoint, on target: OverlayView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            guard let window = target.window else { return }
            target.mouseDown(with: mouse(.leftMouseDown, point, in: window, clicks: clicks, flags: flags))
            target.mouseUp(with: mouse(.leftMouseUp, point, in: window, clicks: clicks, flags: flags))
        }
        func chip(_ target: OverlayView) -> [String] {
            target.actionChip.isHidden ? [] : target.actionChip.buttons.map { $0.title }
        }
        func press(_ title: String, in target: OverlayView) {
            target.actionChip.buttons.first { $0.title == title }?.performClick(nil)
        }
        func save(_ view: NSView, _ name: String?) throws {
            guard let snapshot, let image = Self.snapshot(view) else { return }
            let url = name.map { snapshot.deletingPathExtension().appendingPathExtension("\($0).png") } ?? snapshot
            try Self.write(image, to: url)
            print("Saved \(url.path)")
        }

        func views(in view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { views(in: $0) } }

        do {
            let image = try fixture()
            var began = 0
            var changes: [(OverlayView, Bool)] = []
            var texts: [(text: String, search: Bool)] = []
            var requests: [TranslationRequest] = []
            var refinements: [String] = []
            var visibility: [Bool] = []
            var cancelled = 0
            var actions = OverlayActions()
            actions.began = { _ in began += 1 }
            actions.changed = { changes.append(($0, $1)) }
            actions.textChanged = { texts.append(($1, $2)) }
            actions.translate = { requests.append($1) }
            actions.refine = { refinements.append($1) }
            actions.panelVisibility = { visibility.append($1) }
            actions.cancel = { cancelled += 1 }
            let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
            let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = OverlayView(frame: size, image: image, displayIndex: 0, topInset: 32, controls: true, actions: actions)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.playIntro()
            let bounds = view.bounds
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let panel = view.panel!
            let wordPoint = CGPoint(x: 290, y: 528)

            // Activation: the frozen screen fills the display 1:1 with only the Android-style controls on top.
            check(view.canvas == bounds && image.width == Int(bounds.width) * 2 && view.layer?.backgroundColor?.alpha == 0,
                  "the Retina screenshot fills the display exactly, with no border, inset or scaling")
            check(!view.hasSelection && view.selection == nil && view.searchKey == nil && view.bracketFrame == nil &&
                  view.framedRect == nil && !view.isDimmed && changes.isEmpty && began == 0,
                  "the overlay opens with nothing selected: no brackets, no dimming and no search scheduled")
            let lensImage = view.lensButton.image
            check(lensImage?.isTemplate == true && lensImage?.size == NSSize(width: 28, height: 28) &&
                  lensImage?.accessibilityDescription == LensMark.label && view.lensButton.contentTintColor == googleBlue,
                  "the search bar shows the shared 28 pt mark in Google blue")
            let group = view.barFrame.union(view.translateFrame)
            check(abs(group.midX - bounds.midX) <= 1 && view.barFrame.minY < 40 &&
                  view.field.placeholderString == "Add to your search" && view.bar.superview === view &&
                  view.translateCard.superview === view && view.translateFrame.minX > view.barFrame.maxX,
                  "a search bar with “Add to your search” and Translate to its right floats at the bottom centre")
            check(!views(in: view).contains { $0 is NSSegmentedControl } && !view.field.isHidden &&
                  !buttons(in: view).contains { ["Search", "Text"].contains($0.title) } &&
                  view.toastText == OverlayView.hintText && OverlayView.hintText == "Circle, highlight or tap to search",
                  "there is no Search | Text toggle: one view, with the hint “\(OverlayView.hintText)”")
            check(view.recognizing && view.textLayout == nil && view.cursor(at: wordPoint) == .crosshair,
                  "the screen's text is read on this Mac as soon as the overlay opens; until then presses select visually")
            check(view.closeFrame.minX < 40 && view.closeFrame.maxY > bounds.maxY - 32 - 60 &&
                  view.closeCard.superview === view, "an ✕ close button sits at the top left, below the menu bar")
            check(!buttons(in: view).contains { ["Draw", "Full screen"].contains($0.title) } &&
                  !view.panelShown && panel.alphaValue == 0 && !panel.frame.intersects(bounds) &&
                  view.actionChip.isHidden && view.selectTextChip.isHidden,
                  "there is no toolbar, text menu or results sheet until they are needed")

            // Command-A frames the whole screen but sends nothing; only Return or the Lens button searches it.
            view.selectWholeScreen()
            check(view.isWhole && view.pixelRect == full && !view.isDimmed && changes.isEmpty &&
                  near(view.bracketFrame, bounds.insetBy(dx: 22, dy: 22)) &&
                  near(view.framedRect, bounds.insetBy(dx: 22, dy: 22)) &&
                  abs(SelectionBrackets(around: bounds.insetBy(dx: 22, dy: 22)).outerRect.minX - 10) < 0.5 &&
                  view.toastText == OverlayView.wholeScreenHint && visibility == [false],
                  "Command-A frames the whole screen with corner brackets and no dimming, without searching it")
            visibility.removeAll()

            // Results sheet: slides in on the right without covering the selection handles.
            view.revealPanel()
            view.layoutSubtreeIfNeeded()
            check(view.panelShown && panel.alphaValue == 1 && near(panel.frame, view.panelFrame) &&
                  panel.frame.maxX < bounds.maxX - 10 && panel.frame.minY > view.barFrame.maxY,
                  "the results sheet appears as a floating card on the right, above the search bar")
            check(view.panelFrame.width == PanelSizing.defaultWidth(screenWidth: bounds.width) &&
                  view.panelFrame.width == 560, "the sheet is wide enough for Google's desktop layout (560 pt here)")
            let brackets = view.bracketFrame!
            // Grabbed where they are drawn: on the bracket line, just outside the framed area.
            let drawn = SelectionBrackets(around: brackets).centreRect
            let handlePoints: [(SelectionHandle, CGPoint)] = SelectionHandle.allCases.map { ($0, $0.point(in: drawn)) }
            check(handlePoints.allSatisfy { handle, point in
                view.hitTest(point) === view && view.target(at: point) == .resize(handle)
            }, "all eight corner and edge handles stay reachable with the sheet shown")
            let inside = CGPoint(x: panel.frame.midX, y: panel.frame.midY - 40)
            check(view.hitTest(inside).map { $0 === panel || $0.isDescendant(of: panel) } == true,
                  "clicks on the sheet stay in the sheet instead of starting a selection")

            var passedThrough = false
            midDrag = { passedThrough = panel.passThrough && view.hitTest(inside) === view }
            let edge = CGPoint(x: drawn.maxX, y: drawn.midY)
            gesture([edge, CGPoint(x: edge.x - 150, y: edge.y), CGPoint(x: 900, y: edge.y)], on: view)
            let resized = CGRect(x: 0, y: 0, width: 900 + bounds.maxX - edge.x, height: bounds.height)
            check(passedThrough && !panel.passThrough,
                  "the sheet lets the screenshot through while a selection is being adjusted")
            check(near(view.selection, resized) && !view.isWhole && view.isDimmed && changes.last?.1 == false &&
                  view.pixelRect == Selection.pixels(for: resized, in: view.canvas, width: image.width,
                                                     height: image.height),
                  "dragging the right bracket resizes the selection, dims the rest and schedules a search")

            // Corner brackets: move and resize a smaller selection.
            let start = view.selection!
            gesture([CGPoint(x: start.midX, y: start.midY), CGPoint(x: start.midX - 100, y: start.midY - 50)], on: view)
            check(near(view.selection, start), "a selection as tall as the screen cannot move past its edges")
            gesture([CGPoint(x: start.minX, y: start.maxY), CGPoint(x: start.minX + 200, y: start.maxY - 150)], on: view)
            let corner = CGRect(x: 200, y: 0, width: start.width - 200, height: start.height - 150)
            check(near(view.selection, corner), "the top-left bracket resizes both edges")
            gesture([CGPoint(x: corner.midX, y: corner.midY), CGPoint(x: corner.midX - 120, y: corner.midY + 60)],
                    on: view)
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

            // Circle, highlight, scribble and tap: the words read on this Mac decide what a gesture selects.
            changes.removeAll()
            view.selectWholeScreen()
            check(view.isWhole && changes.isEmpty, "Command-A selects the whole screen again, without searching it")
            let red = CGRect(x: 760, y: 160, width: 120, height: 120)
            let circle = (0...24).map { step -> CGPoint in
                let angle = CGFloat(step) / 24 * 2 * .pi
                return CGPoint(x: red.midX + cos(angle) * 85, y: red.midY + sin(angle) * 85)
            }
            var inked: CGRect?
            var liveFrame: CGRect?
            var dimmedWhileDrawing = true
            midDrag = {
                inked = view.inkBounds
                liveFrame = view.framedRect
                dimmedWhileDrawing = view.isDimmed
            }
            gesture(circle, on: view)
            check(inked.map { $0.width > 160 && $0.height > 160 } == true && view.inkBounds == nil,
                  "circling draws glowing ink that disappears when the finger lifts")
            check(liveFrame == nil && !dimmedWhileDrawing,
                  "a freehand circle shows only its white ink while it is drawn, with no brackets or dimming")
            check(view.selection.map { $0.contains(red) && $0.width < 200 } == true &&
                  near(view.bracketFrame, view.selection!) && near(view.framedRect, view.selection!, 1) &&
                  view.isDimmed && changes.last?.1 == false && !view.hasTextSelection,
                  "a circle around a picture snaps to corner brackets on release and is searched visually")
            if let shot = Self.snapshot(view).flatMap(Bitmap.init) {
                let selected = view.selection!
                let outside = shot.luma(300, 300)
                let within = shot.luma(Int(selected.midX), Int(selected.minY + selected.height * 0.12))
                let circleColour = shot.rgb(Int(red.midX), Int(red.midY))
                let bracket = Self.bracketSamples(selected, in: shot)
                check(circleColour.r > 0.7 && circleColour.g < 0.45 && circleColour.b < 0.45,
                      "the rendered overlay is sampled the right way up")
                check(bracket.ink > 0.75 && bracket.saturation < 0.03,
                      "the circle snaps to plain light brackets on a tinted page (dimmest \(fmt(bracket.ink)), " +
                      "saturation \(fmt(bracket.saturation)))")
                check(abs(outside / within - (1 - OverlayView.dimAlpha)) < 0.07,
                      "outside a smaller selection is dimmed by about 35% (\(fmt(outside / within)) of the brightness)")
            } else {
                check(false, "the overlay can be rendered for pixel checks")
            }
            view.revealPanel()
            view.layoutSubtreeIfNeeded()
            check(view.panelShown && view.panelDockedLeft && !panel.frame.intersects(view.selection!),
                  "the sheet slides in on the side away from what was circled")
            let circled = view.selection!
            gesture([CGPoint(x: circled.midX, y: circled.midY), CGPoint(x: circled.midX - 600, y: circled.midY)],
                    on: view)
            view.layoutSubtreeIfNeeded()
            check(!view.panelDockedLeft && !panel.frame.intersects(view.selection!),
                  "moving the selection under the sheet moves the sheet to the other side")
            view.hidePanel()

            guard spin(until: { view.textLayout != nil }, timeout: 20), let layout = view.textLayout,
                  let lens = layout.words.firstIndex(where: { $0.text == "LENS" }) else {
                throw LensError.message("The fixture's text was not recognized.")
            }
            view.selectWholeScreen()
            check(layout.view(lens, in: view.canvas).contains(wordPoint) && view.cursor(at: wordPoint) == .iBeam &&
                  view.cursor(at: CGPoint(x: 600, y: 300)) == .crosshair,
                  "once the text is read, the cursor is an I-beam over words and a crosshair elsewhere")

            // Highlighting a line or clicking a word goes straight to text selection, without any upload.
            var count = changes.count
            gesture([CGPoint(x: 100, y: 528), CGPoint(x: 300, y: 530), CGPoint(x: 470, y: 527)], on: view)
            check(view.hasTextSelection && view.selectedText == "HELLO LENS 123" &&
                  texts.last?.text == "HELLO LENS 123" && texts.last?.search == true && view.framedRect == nil &&
                  !view.isDimmed && !view.actionChip.isHidden && changes.count == count,
                  "a highlight along a line of text selects its words straight away and searches them as text")
            click(wordPoint, on: view)
            check(view.selectedText == "LENS" && texts.last?.text == "LENS" && texts.last?.search == true &&
                  changes.count == count && ["Copy", "Listen", "Translate", "Search"].allSatisfy(chip(view).contains),
                  "clicking a word selects it with handles and the text menu")
            click(wordPoint, on: view, clicks: 2)
            check(view.selectedText == "HELLO LENS 123" && changes.count == count, "double-clicking a word selects its line")

            // Tapping a picture leaves text for visual search; tapping a word switches back.
            click(CGPoint(x: red.midX, y: red.midY), on: view)
            check(!view.hasTextSelection && view.actionChip.isHidden && spin(until: { changes.count > count }) &&
                  view.selection.map { $0.contains(CGPoint(x: red.midX, y: red.midY)) && $0.width < 400 } == true &&
                  view.framedRect != nil && changes.last?.1 == false,
                  "tapping a picture leaves text selection and selects the object, found on this Mac, for visual search")
            let objectArea = view.selection
            count = changes.count
            click(wordPoint, on: view)
            check(view.selectedText == "LENS" && view.framedRect == nil && view.selection == objectArea &&
                  changes.count == count, "clicking a word outside the area switches to text, keeping the area")
            gesture(circle, on: view)
            check(!view.hasTextSelection && view.framedRect != nil && changes.count == count + 1 &&
                  changes.last?.1 == false, "circling a picture again clears the text and searches the area visually")

            // A box around a picture and some text: the picture wins, and the words are offered.
            count = changes.count
            gesture([CGPoint(x: 70, y: 590), CGPoint(x: 500, y: 360), CGPoint(x: 930, y: 130)], on: view)
            check(spin(until: { !view.selectTextChip.isHidden }, timeout: 20) && !view.hasTextSelection &&
                  view.selectTextButton?.title == "Select text" && changes.count == count + 1 &&
                  changes.last?.1 == false,
                  "a box around a picture and some text searches visually and offers “Select text”")
            view.selectTextButton?.performClick(nil)
            check(view.selectedText == "HELLO LENS 123" && view.selectTextChip.isHidden &&
                  texts.last?.text == "HELLO LENS 123" && texts.last?.search == true && changes.count == count + 1,
                  "“Select text” selects the words in the area and searches them as text")

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
                  !spin(until: { !changes.isEmpty }, timeout: 1.2),
                  "zooming the whole-screen selection keeps only what is visible selected and searches nothing")
            view.selectWholeScreen()
            check(!view.viewport.isZoomed && view.pixelRect == full, "Command-A also resets zoom")

            // Search bar, Translate and close.
            view.field.stringValue = "  red shoes "
            view.fieldSubmitted()
            check(refinements == ["red shoes"], "Return in the search bar refines the search with the typed words")
            view.translateButton.performClick(nil)
            check(requests.count == 1 && requests[0].blocks.contains { $0.contains("HELLO") } &&
                  !view.translateBar.isHidden && view.isWhole,
                  "Translate next to the bar translates the whole screen's text in place")
            view.endTranslation()
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
            let other = OverlayView(frame: size, image: image, displayIndex: 1, controls: false,
                                    actions: actions)
            other.keyDown(with: key(36, "\r", in: window))
            check(other.selection == nil && other.searchKey == nil && other.panel == nil &&
                  other.bar.superview == nil, "other displays start without a selection or controls")

            if let screen = NSScreen.screens.first {
                let screenView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image,
                                             displayIndex: 0, controls: true, actions: actions)
                let overlayWindow = OverlayWindow(screen: screen, overlay: screenView, escape: { cancelled += 1 })
                check(overlayWindow.frame == screen.frame && !overlayWindow.isOpaque &&
                      overlayWindow.backgroundColor == .clear && overlayWindow.styleMask == [.borderless],
                      "each overlay window covers its display exactly, borderless and transparent")
                changes.removeAll()
                _ = overlayWindow.performKeyEquivalent(with: key(0, "a", flags: .command, in: overlayWindow))
                check(screenView.isWhole && changes.isEmpty && !screenView.hasTextSelection,
                      "Command-A selects the whole screen without searching it")
                let closedBefore = cancelled
                let boardBefore = board.changeCount
                _ = overlayWindow.performKeyEquivalent(with: key(8, "c", flags: .command, in: overlayWindow))
                check(!spin(until: { cancelled != closedBefore }, timeout: OverlayView.copyCloseDelay + 0.3) &&
                      board.changeCount == boardBefore,
                      "with no text selected, Command-C neither copies nor closes the overlay")
                let offered = spin(until: { screenView.textLayout != nil && !screenView.selectTextChip.isHidden },
                                   timeout: 20)
                check(offered && screenView.selectTextButton?.title == "Select all text",
                      "the whole-screen selection offers “Select all text” once the words are read")
                screenView.selectTextButton?.performClick(nil)
                let all = screenView.selectedText
                _ = overlayWindow.performKeyEquivalent(with: key(8, "c", flags: .command, in: overlayWindow))
                check(all == "HELLO LENS 123" && board.string(forType: .string) == all &&
                      screenView.toastText == "Copied" && changes.isEmpty && cancelled == closedBefore,
                      "“Select all text” selects every word and Command-C copies it (to a private pasteboard here), " +
                      "showing “Copied” first")
                check(spin(until: { cancelled == closedBefore + 1 }, timeout: OverlayView.copyCloseDelay + 1) &&
                      board.string(forType: .string) == all,
                      "then Command-C closes the overlay the way Escape does, leaving the text on the pasteboard")
                overlayWindow.sendEvent(key(53, "\u{1b}", in: overlayWindow))
                check(cancelled == closedBefore + 2, "Escape cancels from anywhere in the overlay window")
                overlayWindow.close()
            }

            if snapshot != nil {
                view.field.stringValue = ""
                view.hidePanel()
                view.dockPanel(left: false)
                view.selectWholeScreen()
                view.layoutSubtreeIfNeeded()
                try save(view, "activation")
                gesture(circle, on: view)
                view.revealPanel()
                panel.update(.idle, allowed: false)
                view.layoutSubtreeIfNeeded()
                try save(view, nil)
                if let folder = snapshot?.deletingLastPathComponent(), let whole = Self.snapshot(view, scale: 2) {
                    let area = view.bar.frame.insetBy(dx: -24, dy: -24).intersection(view.bounds)
                    let crop = CGRect(x: area.minX * 2, y: (view.bounds.height - area.maxY) * 2,
                                      width: area.width * 2, height: area.height * 2).integral
                    if let bar = whole.cropping(to: crop) { try write(bar, to: folder.appendingPathComponent("mark.bar.png")) }
                }
            }
            window.close()

            try textChecks(check: check, spin: spin, gesture: gesture, click: click, chip: chip, press: press,
                           midDrag: { midDrag = $0 }, key: key, save: save, board: board, speaker: speaker,
                           suite: suite)
            try frameChecks(check: check, gesture: gesture, midDrag: { midDrag = $0 },
                            folder: snapshot?.deletingLastPathComponent())
            try markChecks(check: check, folder: snapshot?.deletingLastPathComponent())
            try panelLoadChecks(check: check, spin: spin)
            try openChecks(check: check, spin: spin, gesture: gesture, suite: suite)
            try permissionChecks(check: check, spin: spin, suite: suite, folder: snapshot?.deletingLastPathComponent())
            try shortcutNoneChecks(check: check)
        } catch {
            failures += 1
            fputs("FAIL native checks: \(error.localizedDescription)\n", stderr)
        }
        check(NSPasteboard.general.changeCount == clipboard, "the user's clipboard was never touched")
        print("Native checks: \(failures) failures; no screen capture, upload or browser launch.")
        return failures == 0
    }

    // MARK: - Opening

    /// Opening the overlay sends nothing: no upload, sheet or page until a gesture selects an area. Uploads are
    /// counted by a stub that fails, so nothing leaves the Mac and no page is loaded.
    private static func openChecks(check: (Bool, String) -> Void, spin: (() -> Bool, TimeInterval) -> Bool,
                                   gesture: ([CGPoint], OverlayView) -> Void, suite: UserDefaults) throws {
        guard let screen = NSScreen.screens.first else { return check(false, "a display is available for the checks") }
        suite.set(true, forKey: "experimentalUpload")
        defer { suite.removeObject(forKey: "experimentalUpload") }
        let controller = AppController(defaults: suite, presentsOverlays: false)
        var uploads = 0
        controller.upload = { _, _ in
            uploads += 1
            throw LensError.message("The checks never upload.")
        }
        controller.showOverlays([(screen, try fixture())])
        defer { controller.dismiss(restore: false) }
        guard let view = controller.activeOverlay, let panel = view.panel else {
            return check(false, "opening builds an overlay with a results sheet")
        }
        let debounce: TimeInterval = 1.2
        _ = spin({ false }, debounce)
        check(uploads == 0 && !view.hasSelection && !view.panelShown && panel.webView == nil &&
              controller.searchState == .idle && view.toastText == OverlayView.hintText,
              "opening the overlay and waiting \(fmt(debounce)) s uploads nothing, shows no sheet and loads no page")
        view.selectWholeScreen()
        _ = spin({ false }, debounce)
        check(uploads == 0 && !view.panelShown, "Command-A alone sends nothing either")
        controller.dismiss(restore: false)
        check(!controller.isShowingOverlay && uploads == 0, "closing again without a gesture made no upload at all")

        controller.showOverlays([(screen, try fixture())])
        guard let next = controller.activeOverlay else { return check(false, "the overlay opens a second time") }
        let box = next.bounds
        gesture([CGPoint(x: box.width * 0.58, y: box.height * 0.18), CGPoint(x: box.width * 0.68, y: box.height * 0.3),
                 CGPoint(x: box.width * 0.78, y: box.height * 0.45)], next)
        check(next.hasSelection && !next.hasTextSelection && uploads == 0,
              "a box around a picture selects it, and the upload waits for the pause after the gesture")
        check(spin({ uploads == 1 }, debounce + 1) && next.panelShown,
              "the first upload happens only after the gesture, and only once")
    }

    // MARK: - Screen Recording

    /// Launching or pressing the shortcut without Screen Recording shows the onboarding window and never asks macOS;
    /// only its button resets the app's entry and asks, once. Fake calls stand in for the real permission calls.
    /// Either shortcut can be None. None registers no Carbon hotkey; the checks never register a real one.
    private static func shortcutNoneChecks(check: (Bool, String) -> Void) throws {
        let name = "dev.macos-lens.checks.shortcuts"
        let defaults = try XCTUnwrapCheck(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        ShortcutSettings(defaults).setText(nil)
        let controller = AppController(defaults: defaults, presentsOverlays: false)
        check(controller.plannedHotKeys.map(\.id) == [1], "with Text set to None, only the Search hotkey is planned")

        func popups(_ controller: AppController) -> [NSPopUpButton] {
            func find(_ view: NSView) -> [NSPopUpButton] {
                view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? find($0) }
            }
            let window = controller.makeSettingsWindow()
            defer { window.close() }
            return window.contentView.map(find) ?? []
        }
        let shown = popups(controller)
        check(shown.count == 2 && shown.allSatisfy { popup in
                  popup.item(at: 0)?.title == "None" && popup.item(at: 1)?.isSeparatorItem == true &&
                  popup.item(at: 0)?.representedObject as? String == ShortcutSettings.noneID
              } && shown[0].indexOfSelectedItem == 2 && shown[1].indexOfSelectedItem == 0,
              "both Settings popups start with None and a separator; Search keeps its key, Text shows None")

        if shown.count == 2 {
            shown[0].selectItem(at: 0)
            _ = shown[0].sendAction(shown[0].action, to: shown[0].target)
        }
        check(defaults.string(forKey: ShortcutSettings.searchKey) == ShortcutSettings.noneID &&
              controller.plannedHotKeys.isEmpty && controller.registeredHotKeyCount == 0,
              "choosing None for both saves “none” and registers no hotkey at all")

        let relaunched = AppController(defaults: defaults, presentsOverlays: false)
        relaunched.registerShortcuts()
        let restored = popups(relaunched)
        check(relaunched.plannedHotKeys.isEmpty && relaunched.registeredHotKeyCount == 0 &&
              restored.count == 2 && restored.allSatisfy { $0.indexOfSelectedItem == 0 },
              "None for both shortcuts survives a relaunch and still registers no hotkey")
    }

    private static func XCTUnwrapCheck<T>(_ value: T?) throws -> T {
        guard let value else { throw LensError.message("missing value") }
        return value
    }

    private static func permissionChecks(check: (Bool, String) -> Void, spin: (() -> Bool, TimeInterval) -> Bool,
                                         suite: UserDefaults, folder: URL?) throws {
        var granted = false
        var calls: [String] = []
        let controller = AppController(defaults: suite, presentsOverlays: false)
        controller.screenAccess = ScreenAccess(granted: { granted }, request: { calls.append("request") },
                                               reset: { calls.append("reset") },
                                               openSettings: { calls.append("settings") })
        let onboarding = controller.makeScreenRecordingOnboarding()
        defer { onboarding.later(); onboarding.window.close() }
        func titles() -> [String] { onboarding.buttons.map(\.title) }
        func snapshot(_ name: String) throws {
            if folder != nil { _ = try preview(onboarding.window, folder, "onboarding.\(name).png") }
        }

        controller.showFirstWindows()
        check(controller.presentedWindow === onboarding.window && onboarding.step == .ask && calls.isEmpty &&
              titles() == ["Later", ScreenRecordingOnboarding.allowTitle] &&
              onboarding.buttons.last?.keyEquivalent == "\r",
              "launching without Screen Recording shows only the onboarding window, with “Allow Screen " +
              "Recording…” as its one primary button, and asks macOS nothing")
        try snapshot("ask")
        controller.activate()
        _ = spin({ false }, 1.2)
        check(calls.isEmpty && !controller.isShowingOverlay && controller.presentedWindow === onboarding.window,
              "the shortcut without access shows the same window again and still asks macOS nothing")

        onboarding.buttons.last?.performClick(nil)
        check(calls == ["reset", "request"] && onboarding.step == .waiting &&
              Set(titles()) == [ScreenRecordingOnboarding.settingsTitle, ScreenRecordingOnboarding.reopenTitle],
              "clicking the button resets the app's own entry, then asks macOS exactly once, and offers System " +
              "Settings in case no prompt appeared")
        try snapshot("waiting")
        onboarding.buttons.first { $0.title == ScreenRecordingOnboarding.settingsTitle }?.performClick(nil)
        check(calls == ["reset", "request", "settings"], "System Settings opens only from its button")

        granted = true
        check(spin({ onboarding.step == .granted }, 2) && titles().last == ScreenRecordingOnboarding.reopenTitle &&
              calls.filter { $0 == "request" }.count == 1,
              "polling notices the switch and offers Quit & Reopen, without asking again")
        try snapshot("granted")

        granted = false
        calls = []
        controller.fixScreenRecording()
        check(calls == ["reset", "request"] && onboarding.step == .waiting,
              "Fix Screen Recording permission… runs the same reset and single request")
        granted = true
        calls = []
        controller.fixScreenRecording()
        check(calls.isEmpty && onboarding.step == .granted,
              "Fix Screen Recording permission… leaves a working permission alone and offers Quit & Reopen")
    }

    // MARK: - Results sheet loading

    /// The sheet sizes its web view before a page loads, shows the crop at its true shape until the page has laid
    /// out, and never animates the web view's size. Pages come from a local scheme, so nothing is uploaded.
    private static func panelLoadChecks(check: (Bool, String) -> Void,
                                        spin: (() -> Bool, TimeInterval) -> Bool) throws {
        let scheme = PanelAspectCheck.scheme
        let handler = FixtureScheme()
        handler.delay = 5000
        ResultsPanel.configureForChecks = { configuration in
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        ResultsPanel.checkScheme = scheme
        defer {
            ResultsPanel.configureForChecks = nil
            ResultsPanel.checkScheme = nil
            OverlayView.animates = false
        }
        let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = OverlayView(frame: size, image: try fixture(), displayIndex: 0, topInset: 32,
                               controls: true, actions: OverlayActions())
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let panel = view.panel else { return check(false, "the overlay has a results sheet") }
        check(!view.panelShown && !panel.isHidden && panel.alphaValue == 0 && !panel.frame.intersects(view.bounds) &&
              panel.frame.size == view.panelFrame.size,
              "the hidden sheet waits offscreen, transparent but not hidden, already at its final size")

        let crop = try PanelAspectCheck.picture(width: 700, height: 500, pattern: true)
        let request = URLRequest(url: URL(string: "\(scheme)://results/page")!)
        var search = Task { try? await panel.search(request, preview: crop) }
        let started = spin({ panel.frameAtLoad != nil }, 2)
        let body = panel.bodyFrame
        check(started && panel.frameAtLoad == body && body.width >= 100 && body.height >= 100 &&
              panel.webView?.frame == body,
              "a search starts loading in a web view already at the sheet's final body size " +
              "(\(Int(body.width))×\(Int(body.height)) pt), before the sheet is revealed")
        guard let web = panel.webView else { return }
        let preview = panel.previewView.frame
        let ratio = preview.height > 0 ? preview.width / preview.height / (700.0 / 500.0) : 0
        check(panel.covering && !panel.previewView.isHidden && panel.previewView.alphaValue == 1 &&
              !web.isHidden && web.alphaValue == 0 && abs(ratio - 1) <= PanelAspectCheck.tolerance &&
              body.contains(preview) && web.hitTest(NSPoint(x: web.frame.midX, y: web.frame.midY)) == nil,
              "from the first paint the sheet shows the crop at its true aspect ratio over a transparent, " +
              "still-loading page (aspect error \(String(format: "%.1f", abs(ratio - 1) * 100))%)")
        view.revealPanel()
        view.layoutSubtreeIfNeeded()
        check(panel.bodyFrame == body && web.frame == body,
              "revealing the sheet keeps the size the page was loaded at")

        // Slide-in, expand and docking: sample every frame for a changed web view size or a size animation.
        OverlayView.animates = true
        var steady = true, keys = Set<String>(), origins = Set<CGFloat>()
        func watch(_ seconds: TimeInterval, sameSize: Bool) {
            _ = spin({
                if sameSize, panel.frame.size != view.panelFrame.size { steady = false }
                if web.frame != panel.bodyFrame || web.frame.size != panel.bodyFrame.size { steady = false }
                keys.formUnion(web.layer?.animationKeys() ?? [])
                origins.insert(panel.layer?.presentation()?.position.x ?? panel.frame.minX)
                return false
            }, seconds)
        }
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.hidePanel()
        watch(0.4, sameSize: true)
        view.revealPanel()
        watch(0.45, sameSize: true)
        view.dockPanel(left: true)
        watch(0.4, sameSize: true)
        view.dockPanel(left: false)
        watch(0.4, sameSize: true)
        let slid = origins.count > 3 || !motion
        panel.expandButton.performClick(nil)
        watch(0.4, sameSize: false)
        let expanded = web.frame == panel.bodyFrame && panel.frame.size == view.panelFrame.size
        panel.expandButton.performClick(nil)
        watch(0.4, sameSize: false)
        OverlayView.animates = false
        let sizeKeys = keys.filter { ["bounds", "bounds.size", "transform", "frameSize", "contentsScale"].contains($0) }
        check(steady && slid && expanded && sizeKeys.isEmpty,
              "hiding, revealing and docking move only the sheet's position; while expanding, the page is placed " +
              "at the sheet's size on every frame; the web view's size is never animated " +
              "(\(origins.count) slide positions sampled)")

        search.cancel()
        check(spin({ !panel.covering }, 2) && web.alphaValue == 1 && panel.previewView.isHidden,
              "cancelling a search removes the crop and shows the earlier page")

        handler.delay = 0
        let begun = Date()
        search = Task { try? await panel.search(request, preview: crop) }
        let covered = spin({ panel.covering }, 1)
        let settled = spin({ !panel.covering }, ResultsPanel.settleTimeout + 2)
        let waited = Date().timeIntervalSince(begun)
        var stretch: Double?
        Task { stretch = Double(await PanelCheck.evaluate(web, PanelAspectCheck.stretchScript)) }
        _ = spin({ stretch != nil }, 3)
        check(covered && settled && waited < ResultsPanel.settleTimeout - 1 && web.alphaValue == 1 &&
              stretch.map { abs($0 - 1) <= Double(PanelAspectCheck.tolerance) } == true,
              "the crop gives way only once the page shows the image at its own shape " +
              "(after \(String(format: "%.1f", waited)) s, stretch \(stretch.map { String(format: "%.1f", abs($0 - 1) * 100) } ?? "?")%)")
        search.cancel()

        // Google commits an image-less results page that's already complete, then replaces it with the real one.
        let hop = URLRequest(url: URL(string: "\(scheme)://results/hop")!)
        let hopped = Date()
        search = Task { try? await panel.search(hop, preview: crop) }
        var early = false
        let hopCovered = spin({ panel.covering }, 1)
        let hopSettled = spin({
            if !panel.covering, web.url?.lastPathComponent == "hop" { early = true }
            return !panel.covering
        }, ResultsPanel.settleTimeout + 2)
        let hopWait = Date().timeIntervalSince(hopped)
        stretch = nil
        Task { stretch = Double(await PanelCheck.evaluate(web, PanelAspectCheck.stretchScript)) }
        _ = spin({ stretch != nil }, 3)
        check(hopCovered && hopSettled && !early && web.url?.lastPathComponent == "page" &&
              hopWait < ResultsPanel.settleTimeout - 1 &&
              stretch.map { abs($0 - 1) <= Double(PanelAspectCheck.tolerance) } == true,
              "a complete results page without the image doesn't end the crop; the page that replaces it is " +
              "shown once its image has its own shape (after \(String(format: "%.1f", hopWait)) s)")
        search.cancel()

        panel.showPage(URL(string: "about:blank")!, title: "Page")
        check(!panel.covering && panel.previewView.isHidden && web.alphaValue == 1,
              "ordinary pages opened in the sheet are shown directly, never covered")
    }

    // MARK: - Text

    /// Text in the one overlay view on a multi-line fixture: recognition on open, words, lines and paragraphs,
    /// circles around text, handles, the action menu, translation in place and Escape, all offscreen. No text path
    /// starts a visual search, loads a page or uploads the screenshot.
    private static func textChecks(
        check: (Bool, String) -> Void, spin: (() -> Bool, TimeInterval) -> Bool,
        gesture: ([CGPoint], OverlayView) -> Void,
        click: (CGPoint, OverlayView, Int, NSEvent.ModifierFlags) -> Void,
        chip: (OverlayView) -> [String], press: (String, OverlayView) -> Void,
        midDrag: (@escaping () -> Void) -> Void,
        key: (UInt16, String, NSEvent.ModifierFlags, NSWindow) -> NSEvent,
        save: (NSView, String?) throws -> Void, board: NSPasteboard, speaker: SilentSpeaker, suite: UserDefaults
    ) throws {
        let image = try textFixture()
        var searches = 0
        var texts: [(text: String, search: Bool)] = []
        var commands: [(TextCommand, String)] = []
        var requests: [TranslationRequest] = []
        var quick: [String] = []
        var cancelled = 0
        var actions = OverlayActions()
        actions.changed = { _, _ in searches += 1 }
        actions.textChanged = { texts.append(($1, $2)) }
        actions.textCommand = { commands.append(($1, $2)) }
        actions.translate = { requests.append($1) }
        actions.quick = { quick.append($1.title) }
        actions.cancel = { cancelled += 1 }
        let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = OverlayView(frame: size, image: image, displayIndex: 0, topInset: 32, controls: true, actions: actions)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func tap(_ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            click(point, view, clicks, flags)
        }

        // Opening the overlay reads the whole frozen display on this Mac, off the main thread.
        check(view.recognizing && view.toastText == OverlayView.hintText && !view.field.isHidden && !view.hasSelection,
              "the screen's text is read on this Mac while the overlay opens, with the search bar and hint as usual")
        guard spin({ view.textLayout != nil }, 20), let layout = view.textLayout, !layout.isEmpty else {
            throw LensError.message("No text was recognized in the text fixture.")
        }
        print("INFO recognized: \(layout.allText.replacingOccurrences(of: "\n", with: " ⏎ "))")
        func word(_ text: String) -> Int? { layout.words.firstIndex { $0.text == text } }
        func centre(_ index: Int) -> CGPoint {
            let box = layout.view(index, in: view.canvas)
            return CGPoint(x: box.midX, y: box.midY)
        }
        guard let the = word("The"), let quickWord = word("quick"), let brown = word("brown"), let fox = word("fox"),
              let jumps = word("jumps"), let over = word("over"), word("lazy") != nil, let dog = word("dog"),
              let good = word("Good"), let write = word("Write"),
              let email = layout.words.firstIndex(where: { $0.text.contains("@") }) else {
            throw LensError.message("The text fixture was read as \(layout.words.map { $0.text }).")
        }
        let paragraph = "The quick brown fox\njumps over the lazy dog"
        check(layout.blocks.count == 3 && layout.allText.hasPrefix(paragraph + "\n\n") &&
              layout.allText.hasSuffix("\n\nGood morning"),
              "words are joined in reading order with line breaks inside paragraphs and blank lines between them")
        check(view.textSurface.words.path?.isEmpty == false && view.textSurface.words.opacity == 0 &&
              !view.isDimmed && view.cursor(at: centre(quickWord)) == .iBeam &&
              view.cursor(at: CGPoint(x: 900, y: 300)) == .crosshair,
              "words are not marked permanently; the cursor is an I-beam over them and a crosshair elsewhere")

        // Marking text like a text cursor, in the same view.
        tap(centre(quickWord))
        check(view.selectedText == "quick" && texts.last?.text == "quick" && texts.last?.search == true &&
              view.framedRect == nil && ["Copy", "Select all", "Listen", "Translate", "Search"].allSatisfy(chip(view).contains),
              "clicking a word selects it, searches it as text and shows Copy, Select all, Listen, Translate and Search")
        var hiddenWhileDragging = false
        midDrag { hiddenWhileDragging = view.actionChip.isHidden }
        gesture([centre(quickWord), centre(brown), centre(fox)], view)
        check(view.selectedText == "quick brown fox" && view.textSurface.selection.path?.isEmpty == false &&
              view.textSurface.handles.path?.isEmpty == false && hiddenWhileDragging && !view.actionChip.isHidden,
              "pressing a word and dragging along its line selects whole words with handles; the menu waits for release")
        if let range = view.textRange, let ends = layout.handlePoints(for: range, canvas: view.canvas) {
            let end = TextSurface.knobCenter(ends.end)
            let down = centre(dog).y - centre(fox).y
            gesture([end, CGPoint(x: (end.x + centre(dog).x) / 2, y: end.y + down / 2),
                     CGPoint(x: centre(dog).x, y: end.y + down)], view)
            let extended = view.selectedText
            let lines = view.textRange.map { layout.lineRects(for: $0, canvas: view.canvas) } ?? []
            let covered = lines.reduce(CGRect.null) { $0.union($1) }
            check(extended == "quick brown fox\njumps over the lazy dog" && lines.count == 2 &&
                  !view.actionChip.frame.intersects(covered) && view.bounds.contains(view.actionChip.frame),
                  "dragging the end handle extends the selection across lines, highlighted per line, menu beside it")
            try save(view, "text")
            let begin = TextSurface.knobCenter(ends.start)
            gesture([begin, CGPoint(x: centre(brown).x, y: begin.y)], view)
            check(view.selectedText == "brown fox\njumps over the lazy dog", "dragging the start handle moves the start")
        } else {
            check(false, "the selection has start and end handles")
        }
        tap(centre(over), clicks: 2)
        check(view.selectedText == "jumps over the lazy dog", "double-clicking selects the line")
        tap(centre(over), clicks: 3)
        check(view.selectedText == paragraph, "triple-clicking selects the paragraph")
        tap(centre(brown))
        tap(centre(over), flags: .shift)
        check(view.selectedText == "brown fox\njumps over", "Shift-click extends the selection")
        press("Select all", view)
        check(view.selectedText == layout.allText, "Select all selects every word on the screen")
        let closes = cancelled
        press("Copy", view)
        check(board.string(forType: .string) == layout.allText && view.toastText == "Copied" && cancelled == closes,
              "the Copy button keeps line breaks and says “Copied” first")
        check(spin({ cancelled == closes + 1 }, OverlayView.copyCloseDelay + 1),
              "then Copy closes the overlay the way Escape does, like Command-C")

        // Things Lens offers for what is selected, detected on this Mac.
        tap(centre(email), clicks: 2)
        check(view.selectedText == "Write to hello@example.com" &&
              ["Send email", "Add to contacts"].allSatisfy(chip(view).contains),
              "an email address adds Send email and Add to contacts")
        press("Send email", view)
        check(quick == ["Send email"], "quick actions are handed to the app")
        press("Listen", view)
        check(speaker.spoken.last?.text == "Write to hello@example.com" && speaker.isSpeaking &&
              chip(view).contains("Stop") && !chip(view).contains("Listen"), "Listen reads the selection aloud and becomes Stop")
        speaker.finish()
        check(chip(view).contains("Listen") && !chip(view).contains("Stop"), "the menu returns when reading ends")
        press("Search", view)
        check(commands.count == 1 && commands[0].0 == .search && commands[0].1 == "Write to hello@example.com",
              "Search hands only the selected text to the app")

        // Circling, boxing or scribbling over text goes straight to text selection, as Lens does.
        func loop(around first: Int, _ last: Int, padding: CGSize) -> [CGPoint] {
            let box = layout.view(first, in: view.canvas).union(layout.view(last, in: view.canvas))
            return (0...32).map { step in
                let angle = CGFloat(step) / 32 * 2 * .pi
                return CGPoint(x: box.midX + cos(angle) * (box.width / 2 + padding.width),
                               y: box.midY + sin(angle) * (box.height / 2 + padding.height))
            }
        }
        let loose = CGSize(width: 30, height: 14), snug = CGSize(width: 24, height: 8)
        // Vision may read the address as one word or split it at the "@".
        let emailLineEnd = layout.lines[layout.words[email].line].words.upperBound - 1
        let circles: [(String, [CGPoint], String)] = [
            ("a paragraph", loop(around: the, dog, padding: loose), paragraph),
            ("a single line", loop(around: jumps, dog, padding: snug), "jumps over the lazy dog"),
            ("a phrase", loop(around: brown, fox, padding: snug), "brown fox"),
            ("a line with an email address", loop(around: write, emailLineEnd, padding: snug),
             "Write to hello@example.com"),
            ("light text on a dark band", loop(around: good, good + 1, padding: snug), "Good morning")
        ]
        var inked = false
        for (name, points, expected) in circles {
            let before = searches
            inked = false
            midDrag { inked = view.inkBounds != nil }
            gesture(points, view)
            let selected = spin({ view.hasTextSelection }, 10)
            check(selected && inked && view.inkBounds == nil && view.selectedText == expected &&
                  texts.last?.text == expected && texts.last?.search == true && searches == before &&
                  view.framedRect == nil && view.selectTextChip.isHidden,
                  "circling \(name) selects its words straight away and searches them as text " +
                  "(“\(view.selectedText.replacingOccurrences(of: "\n", with: " ⏎ "))”)")
        }
        let box = [CGPoint(x: 60, y: 620), CGPoint(x: 380, y: 540), CGPoint(x: 720, y: 480)]
        gesture(box, view)
        check(spin({ view.hasTextSelection }, 10) && view.selectedText == paragraph && searches == 0,
              "a box dragged around a paragraph selects it as text too")

        let visualBefore = searches
        tap(CGPoint(x: 900, y: 300))
        check(view.textRange == nil && view.actionChip.isHidden && spin({ searches == visualBefore + 1 }, 5) &&
              view.framedRect != nil, "tapping empty space leaves text selection and goes back to visual search")

        // Highlights and hit-testing follow zoom.
        tap(centre(quickWord))
        view.zoom(by: 2, at: CGPoint(x: 300, y: 560))
        let zoomedWord = layout.view(quickWord, in: view.canvas)
        let highlight = view.textSurface.selection.path?.boundingBoxOfPath ?? .null
        check(view.viewport.isZoomed && highlight.contains(CGPoint(x: zoomedWord.midX, y: zoomedWord.midY)) &&
              highlight.width > zoomedWord.width * 0.9 && highlight.width < zoomedWord.width * 1.5,
              "the highlight stays on its word when zoomed")
        tap(centre(brown))
        check(view.selectedText == "brown", "clicking a word while zoomed selects that word")
        view.zoom(by: 0.5, at: CGPoint(x: 300, y: 560))
        check(view.canvas == view.bounds, "zooming back out restores the 1:1 screen")

        // Translate in place, on this Mac when Apple's translation is available.
        press("Translate", view)
        let request = requests.last
        check(requests.count == 1 && request?.blocks.count == layout.blocks.count && request?.text == "brown" &&
              !view.translateBar.isHidden && view.toastText == "Translating…",
              "Translate sends each paragraph, as flowing text, to the translator and shows progress; only the " +
              "selected words are kept for the web fallback")
        view.applyTranslation(blocks: (request?.blocks ?? []).map { $0.uppercased() })
        let layer = view.textSurface.translation
        check(view.translatedLines != nil && !layer.isHidden && layer.frame == view.canvas && layer.contents != nil &&
              view.textSurface.words.path?.isEmpty == true,
              "the translation is drawn over the original lines, in place on the screenshot")
        if let drawn = layer.contents.map({ $0 as! CGImage }), let pixels = Bitmap(drawn) {
            func fill(_ index: Int) -> CGFloat {
                let box = layout.lines[layout.words[index].line].box
                return pixels.luma(Int(box.minX * CGFloat(drawn.width)) - 2, Int(box.midY * CGFloat(drawn.height)))
            }
            check(drawn.width == image.width && fill(good) < 0.3 && fill(quickWord) > 0.8,
                  "each translated line sits on the colour sampled behind it (dark \(fmt(fill(good))), " +
                  "light \(fmt(fill(quickWord))))")
        } else {
            check(false, "the translation layer holds a rendered image")
        }
        press("Select all", view)
        let everything = view.textRange.map { layout.lineRects(for: $0, canvas: view.canvas) } ?? []
        check(!everything.isEmpty && !everything.contains { $0.intersects(view.actionChip.frame) } &&
              view.bounds.contains(view.actionChip.frame),
              "with no room above or below, the action menu sits beside the selection instead of covering it")
        check(view.selectedText.contains("QUICK") && chip(view).contains("Copy") && chip(view).contains("Listen") &&
              chip(view).contains("Search") && !chip(view).contains("Translate"),
              "translated text can be selected, copied, read aloud and searched")
        try save(view, "translation")
        view.translateBar.originalToggle.performClick(nil)
        check(view.showOriginal && layer.isHidden && view.selectedText.contains("quick"),
              "Show original reveals the screenshot's own text")
        view.translateBar.originalToggle.performClick(nil)
        check(!view.showOriginal && !layer.isHidden, "turning Show original off shows the translation again")
        view.clearTextSelection()
        let copiesAll = cancelled
        let offersAll = chip(view).contains("Copy all text")
        press("Copy all text", view)
        check(offersAll && board.string(forType: .string)?.contains("QUICK") == true &&
              view.toastText == "Copied all text" && spin({ cancelled == copiesAll + 1 }, OverlayView.copyCloseDelay + 1),
              "with nothing selected, “Copy all text” copies the translation and then closes the overlay too")
        view.translateBar.closeButton.performClick(nil)
        check(view.translatedLines == nil && view.translateBar.isHidden && layer.isHidden,
              "closing the translate bar returns to the original screen")

        check(searches == visualBefore + 1 && view.panel?.webView == nil && commands.allSatisfy { $0.0 == .search },
              "only the tap on empty space searched visually: no text path uploads the screenshot or loads a page")
        let escapes = cancelled
        view.keyDown(with: key(53, "\u{1b}", [], window))
        check(cancelled == escapes + 1, "Escape closes the overlay from a text selection too")

        // The Select text shortcut opens the same view with every word already selected.
        var preselected: [(text: String, search: Bool)] = []
        var uploads = 0
        var quiet = OverlayActions()
        quiet.changed = { _, _ in uploads += 1 }
        quiet.textChanged = { preselected.append(($1, $2)) }
        let shortcut = OverlayView(frame: size, image: image, displayIndex: 0, topInset: 32, controls: true, selectingAllText: true, actions: quiet)
        check(spin({ shortcut.hasTextSelection }, 20) && shortcut.selectedText == layout.allText &&
              preselected.last?.search == false && uploads == 0 && !shortcut.field.isHidden &&
              shortcut.framedRect == nil && !shortcut.actionChip.isHidden,
              "the Select text shortcut opens the same view with every word selected, without searching anything")

        // The results sheet remembers the width the user drags it to.
        view.panel?.onResize?(700, true)
        let next = OverlayView(frame: size, image: image, displayIndex: 0, controls: true,
                               actions: OverlayActions())
        check(suite.double(forKey: PanelSizing.defaultsKey) == 700 && next.panelFrame.width == 700,
              "a sheet width set by dragging is remembered for the next activation")
    }

    // MARK: - Selection frame

    /// The Android-style frame on plain white and dark screens: four thick, light corner brackets with flat ends,
    /// sitting just outside the selection with a faint halo, live while a box is dragged and after release, with no
    /// colour, no edge line and no grip between them, a rounded undimmed selection and the dimming outside. With a
    /// folder, writes the previews there.
    private static func frameChecks(check: (Bool, String) -> Void, gesture: ([CGPoint], OverlayView) -> Void,
                                    midDrag: (@escaping () -> Void) -> Void, folder: URL?) throws {
        var subpaths = 0
        let sample = CGRect(x: 0, y: 0, width: 300, height: 200)
        LensFrameLayer.bracketPath(sample).applyWithBlock {
            if $0.pointee.type == .moveToPoint { subpaths += 1 }
        }
        let bounding = LensFrameLayer.bracketPath(sample).boundingBoxOfPath
        let centre = SelectionBrackets(around: sample).centreRect
        check(subpaths == 4 && abs(bounding.minX - centre.minX) + abs(bounding.maxX - centre.maxX) +
                abs(bounding.minY - centre.minY) + abs(bounding.maxY - centre.maxY) < 0.01 &&
              LensFrameLayer.whiteness == 0.85 && LensFrameLayer.shadowOpacity == 0.2 && LensFrameLayer.shadowRadius == 2,
              "the frame is four corner brackets on a line 4 pt plus half a stroke outside the selection, white at " +
              "85% with a 20% black, 2 pt halo")
        let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
        for (name, shade) in [("white", CGFloat(1)), ("dark", CGFloat(0.1))] {
            let image = try drawn { size in
                NSColor(calibratedWhite: shade, alpha: 1).setFill()
                NSRect(origin: .zero, size: size).fill()
            }
            let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = OverlayView(frame: size, image: image, displayIndex: 0, topInset: 32, controls: true, actions: OverlayActions())
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            check(view.frameLayer.sublayers?.count == 1, "on \(name), the frame is a single layer of brackets")
            var live: (frame: CGRect?, dimmed: Bool, ink: CGRect?, shot: Bitmap?)?
            midDrag {
                live = (view.framedRect, view.isDimmed, view.inkBounds, Self.snapshot(view).flatMap(Bitmap.init))
                if let folder, let preview = Self.snapshot(view, scale: 2) {
                    try? write(preview, to: folder.appendingPathComponent("frame.corners.live.\(name).png"))
                }
            }
            gesture([CGPoint(x: 360, y: 220), CGPoint(x: 600, y: 360), CGPoint(x: 840, y: 470)], view)
            guard let rect = view.selection, let shot = Self.snapshot(view).flatMap(Bitmap.init) else {
                check(false, "on \(name), a dragged box becomes a selection that can be rendered")
                continue
            }
            let geometry = SelectionBrackets(around: rect)
            let shape = view.frameLayer.sublayers?.first as? CAShapeLayer
            check(shape?.lineCap == .butt && shape?.lineWidth == geometry.stroke && geometry.stroke == 8 &&
                  geometry.radius == 28 && geometry.reach == 48,
                  "on \(name), a \(Int(min(rect.width, rect.height))) pt tall box gets 8 pt flat-ended strokes, a 28 pt " +
                  "radius and 48 pt reach " +
                  "(6%, 18% and 28% of the shorter side, clamped)")
            let liveRect = live?.frame
            check(liveRect.map { $0.width > 400 && $0.height > 200 } == true && liveRect.map { abs($0.minX - rect.minX) + abs($0.maxX - rect.maxX) + abs($0.minY - rect.minY) +
                    abs($0.maxY - rect.maxY) < 2 } == true &&
                  live?.dimmed == false && live?.ink == nil,
                  "on \(name), the corner brackets frame a box live while it is dragged, undimmed and without ink, " +
                  "and stay put on release")
            if let liveRect, let liveShot = live?.shot {
                let ink = bracketSamples(liveRect, in: liveShot).ink
                let colour = saturation(around: liveRect, in: liveShot, band: 18)
                check(ink > 0.75 && colour < 0.05,
                      "on \(name), the live brackets are light (\(fmt(ink))) with no colour (\(fmt(colour)))")
            }
            check(view.framedRect == rect && view.isDimmed, "on \(name), the released selection keeps its brackets")
            let page = shot.luma(60, 60)
            let inside = shot.luma(Int(rect.midX), Int(rect.midY))
            let samples = bracketSamples(rect, in: shot)
            let colour = saturation(around: rect, in: shot, band: 18)
            let strays = edgeStrays(rect, in: shot, inside: inside, outside: page)
            check(samples.ink > 0.75 && samples.ink - page > 0.2,
                  "on \(name), all eight arms are drawn light (dimmest \(fmt(samples.ink)) on \(fmt(page)))")
            check(samples.gap < samples.ink - 0.2 && abs(samples.gap - page) < 0.08,
                  "on \(name), the brackets sit just outside the selection, leaving a 4 pt gap " +
                  "(\(fmt(samples.gap)) beside the edge, page \(fmt(page)))")
            check(samples.beyond < samples.ink - 0.2,
                  "on \(name), the arms end flat, with nothing drawn past their ends (\(fmt(samples.beyond)))")
            check(colour < 0.05, "on \(name), there is no gradient or colour anywhere on the selection " +
                  "(saturation \(fmt(colour)))")
            check(strays == 0, "on \(name), nothing is drawn along the middle of the edges between the brackets " +
                  "(\(strays) stray pixels)")
            if name == "white" {
                let halo = page - samples.halo
                check(halo > 0.005 && halo < 0.15 && samples.ink - page > 0.2,
                      "on white, a faint dark halo (\(fmt(halo)) darker than the dimmed page) keeps the light " +
                      "brackets legible")
                // Along the top-left diagonal from the arcs' shared centre: just inside the hole's arc is undimmed,
                // the 4 pt gap beyond it is dimmed and the bracket's arc beyond that covers the selection's corner.
                let r = geometry.innerRadius
                func diagonal(_ distance: CGFloat) -> CGFloat {
                    shot.luma(Int((rect.minX + r - distance / 2.squareRoot()).rounded(.down)),
                              Int((rect.maxY - r + distance / 2.squareRoot()).rounded(.down)))
                }
                let within = diagonal(r - 3), corner = diagonal(r + 2.5), arc = diagonal(r + SelectionBrackets.gap + 4)
                let edge = shot.luma(Int(rect.minX) + 1, Int(rect.midY))
                check(within > inside - 0.03 && edge > inside - 0.03 && abs(corner - page) < 0.06 && arc - page > 0.2,
                      "on white, the selection is undimmed as a rounded rect concentric with the brackets " +
                      "(\(fmt(r)) pt radius: \(fmt(within)) inside the arc, \(fmt(corner)) in the gap, \(fmt(arc)) " +
                      "on the bracket)")
            } else {
                check(samples.ink < 0.93 && samples.ink - max(page, inside) > 0.6,
                      "on dark, the brackets are light grey-white rather than pure white and stand out " +
                      "(\(fmt(samples.ink)) on \(fmt(max(page, inside))))")
            }
            check(abs(page / inside - (1 - OverlayView.dimAlpha)) < 0.07 || name == "dark",
                  "on \(name), outside the selection is dimmed by about 35%")
            let topLeft = geometry.corners[0]
            let onArm = CGPoint(x: topLeft.point.x, y: topLeft.point.y + topLeft.dy * (geometry.arm - 6))
            let onArc = CGPoint(x: topLeft.point.x + geometry.radius * 0.3, y: topLeft.point.y - geometry.radius * 0.3)
            let edgeMiddle = CGPoint(x: geometry.centreRect.maxX, y: rect.midY)
            check(view.target(at: onArm) == .resize(.topLeft) && view.target(at: onArc) == .resize(.topLeft) &&
                  view.target(at: edgeMiddle) == .resize(.right) &&
                  view.target(at: CGPoint(x: rect.midX, y: rect.midY)) == .move,
                  "on \(name), grabbing a bracket along its arm resizes from that corner, the edge between them " +
                  "still resizes and the inside still moves")
            if let folder, let preview = Self.snapshot(view, scale: 2) {
                try write(preview, to: folder.appendingPathComponent("frame.corners.\(name).png"))
            }
            OverlayView.animates = true
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let layers = [view.frameLayer] + (view.frameLayer.sublayers ?? [])
            check(layers.allSatisfy { $0.animationKeys() == nil },
                  "on \(name), the brackets stand still once settled, with no rotation")
            OverlayView.animates = false
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Pixels around each of the eight arms, 6 pt before its flat end: the dimmest of the brightest pixels across
    /// the stroke (`ink`), the brightest pixel in the gap 1.5 pt outside the selection (`gap`), the brightest
    /// pixel 2.5 pt past each flat end (`beyond`), the darkest pixel 1.5 pt outside each stroke (`halo`) and the most
    /// saturated of the ink pixels (`saturation`).
    private static func bracketSamples(_ rect: CGRect, in bitmap: Bitmap)
        -> (ink: CGFloat, gap: CGFloat, beyond: CGFloat, halo: CGFloat, saturation: CGFloat) {
        let geometry = SelectionBrackets(around: rect)
        let along = geometry.arm - 6
        var ink: CGFloat = 1, gap: CGFloat = 0, beyond: CGFloat = 0, halo: CGFloat = 1, saturation: CGFloat = 0
        func luma(_ point: CGPoint) -> CGFloat { bitmap.luma(Int(point.x.rounded(.down)), Int(point.y.rounded(.down))) }
        for corner in geometry.corners {
            let p = corner.point
            // Each arm: its direction and the inward normal, toward the selection.
            let arms: [(CGVector, CGVector)] = [(CGVector(dx: corner.dx, dy: 0), CGVector(dx: 0, dy: corner.dy)),
                                                (CGVector(dx: 0, dy: corner.dy), CGVector(dx: corner.dx, dy: 0))]
            for (direction, inward) in arms {
                func at(_ distance: CGFloat, _ offset: CGFloat) -> CGPoint {
                    CGPoint(x: p.x + direction.dx * distance + inward.dx * offset,
                            y: p.y + direction.dy * distance + inward.dy * offset)
                }
                let across = (-1...1).map { at(along, CGFloat($0)) }
                if let brightest = across.max(by: { luma($0) < luma($1) }) {
                    let c = bitmap.rgb(Int(brightest.x.rounded(.down)), Int(brightest.y.rounded(.down)))
                    ink = min(ink, luma(brightest))
                    saturation = max(saturation, max(c.r, c.g, c.b) - min(c.r, c.g, c.b))
                }
                gap = max(gap, luma(at(along, geometry.outset - 1.5)))
                beyond = max(beyond, (-1...1).map { luma(at(geometry.arm + 2.5, CGFloat($0))) }.max() ?? 1)
                halo = min(halo, luma(at(along, -(geometry.stroke / 2 + 1.5))))
            }
        }
        return (ink, gap, beyond, halo, saturation)
    }

    /// The most saturated pixel in a band around `rect`'s border: 0 where everything is grey.
    private static func saturation(around rect: CGRect, in bitmap: Bitmap, band: CGFloat = 12) -> CGFloat {
        let outer = rect.insetBy(dx: -band, dy: -band), inner = rect.insetBy(dx: band, dy: band)
        var worst: CGFloat = 0
        for y in Int(outer.minY)...Int(outer.maxY) {
            for x in Int(outer.minX)...Int(outer.maxX) where !inner.contains(CGPoint(x: x, y: y)) {
                let c = bitmap.rgb(x, y)
                worst = max(worst, max(c.r, c.g, c.b) - min(c.r, c.g, c.b))
            }
        }
        return worst
    }

    /// Pixels beside the middle of each edge, between the brackets, that are neither the page inside nor the dimmed
    /// page outside, out to past where the brackets are drawn: any edge line, grip, glow or halo there is a stray.
    private static func edgeStrays(_ rect: CGRect, in bitmap: Bitmap, inside: CGFloat, outside: CGFloat) -> Int {
        let geometry = SelectionBrackets(around: rect)
        let clear = geometry.reach + 8
        var strays = 0
        func probe(_ x: CGFloat, _ y: CGFloat, inward: CGVector) {
            for distance in [2, 3, 4, 6, 9] as [CGFloat] {
                let inner = bitmap.luma(Int(x + inward.dx * distance), Int(y + inward.dy * distance))
                if abs(inner - inside) > 0.03 { strays += 1 }
            }
            for distance in [2, 4, 6, 8, 10, 12, 14, 17] as [CGFloat] {
                let outer = bitmap.luma(Int(x - inward.dx * distance), Int(y - inward.dy * distance))
                if abs(outer - outside) > 0.03 { strays += 1 }
            }
        }
        for x in stride(from: rect.minX + clear, through: rect.maxX - clear, by: 3) {
            probe(x, rect.maxY, inward: CGVector(dx: 0, dy: -1))
            probe(x, rect.minY, inward: CGVector(dx: 0, dy: 1))
        }
        for y in stride(from: rect.minY + clear, through: rect.maxY - clear, by: 3) {
            probe(rect.minX, y, inward: CGVector(dx: 1, dy: 0))
            probe(rect.maxX, y, inward: CGVector(dx: -1, dy: 0))
        }
        return strays
    }

    // MARK: - Mark

    /// The shared mark at the sizes it is shown at, drawn offscreen at 1x and 2x, and where the app shows it. With a
    /// folder, also writes preview images of the menu bar, the launcher and Settings there.
    private static func markChecks(check: (Bool, String) -> Void, folder: URL?) throws {
        let menuBar = (LensMark.metrics(side: 18, scale: 1), LensMark.metrics(side: 18, scale: 2))
        check(menuBar.0.stroke == 2 && menuBar.1.stroke == 2 && menuBar.0.arm == 5 && menuBar.1.arm == 5.5 &&
              LensMark.cornerRadius(side: 100, stroke: 11, arm: 30) == 20 &&
              abs(LensMark.cornerRadius(side: 18, stroke: 2, arm: 5) - 3.4) < 0.001,
              "the mark follows the brand geometry: stroke 0.11 and arm 0.30 of the side, corner radius " +
              "min(0.20, 0.85 × (arm − stroke/2)); 2 pt strokes and 5 pt arms in the 18 pt menu bar")
        for side in [16, 18, 22] as [CGFloat] {
            let image = LensMark.image(size: side)
            check(image.isTemplate && image.size == NSSize(width: side, height: side) &&
                  image.accessibilityDescription == LensMark.label,
                  "the \(Int(side)) pt mark is a square template image labelled for accessibility")
            for scale in [1, 2] as [CGFloat] {
                guard let bitmap = Bitmap(try rendered(image.size, scale: scale, { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    image.draw(in: rect)
                })) else { throw LensError.message("Could not read the rendered mark.") }
                let n = bitmap.width
                func ink(_ x: Int, _ y: Int) -> CGFloat { 1 - bitmap.luma(x, y) }
                let (stroke, arm) = LensMark.metrics(side: side, scale: scale)
                let strokePixels = Int((stroke * scale).rounded())
                let row = Int(((side - arm) * scale).rounded())
                let crisp = ink(0, row) > 0.85 && ink(strokePixels - 1, row) > 0.85 && ink(strokePixels, row) < 0.15 &&
                    ink(n - 1, n - 1 - row) > 0.85 && ink(n - strokePixels, n - 1 - row) > 0.85 &&
                    ink(n - 1 - strokePixels, n - 1 - row) < 0.15
                // Butt caps: the arms stop flat at their length, with no rounded cap beyond it.
                let flat = ink(0, row - 1) < 0.15 && ink(strokePixels - 1, row - 1) < 0.15 &&
                    ink(n - 1, n - row) < 0.15 && ink(n - strokePixels, n - row) < 0.15
                let open = [ink(n / 2, n - 1), ink(n / 2, 0), ink(0, n / 2), ink(n - 1, n / 2)].allSatisfy { $0 < 0.1 }
                let coverage = (0..<n).reduce(CGFloat(0)) { sum, y in sum + (0..<n).reduce(0) { $0 + ink($1, y) } } /
                    CGFloat(n * n)
                let columns = Int(CGFloat(n) * 0.44)...Int(CGFloat(n) * 0.56)
                let rows = (0..<n).filter { y in columns.contains { ink($0, y) > 0.5 } }
                let height = CGFloat((rows.max() ?? 0) - (rows.min() ?? 0) + 1) / CGFloat(n)
                let width = CGFloat((0..<n).filter { ink($0, n / 2) > 0.5 }.count) / CGFloat(n)
                let unit = side * scale * LensMark.appleShare / 100
                let body = Int(CGFloat(n) / 2 - 44 * unit)..<Int(CGFloat(n) / 2 + 12 * unit)
                let mismatch = body.reduce(CGFloat(0)) { sum, y in
                    sum + (0..<n / 2).reduce(0) { $0 + abs(ink($1, y) - ink(n - 1 - $1, y)) }
                } / CGFloat(body.count * n / 2)
                check(crisp && flat && open && ink(n / 2, n / 2) > 0.9 && (0.15...0.55).contains(coverage) &&
                      (0.5...0.66).contains(height) && (0.45...0.62).contains(width) && mismatch < 0.03,
                      "the \(Int(side)) pt mark at \(Int(scale))x has pixel-sharp corners with flat ends and a solid " +
                      "centred apple " +
                      "with a symmetric body and no bite (apple \(fmt(height)) × \(fmt(width)) of the box, " +
                      "ink \(fmt(coverage)), asymmetry \(fmt(mismatch)))")
            }
        }

        let controller = AppController()
        let launcher = try preview(controller.makeLauncherWindow(), folder, "mark.launcher.png")
        let settings = try preview(controller.makeSettingsWindow(), folder, "mark.settings.png")
        for (name, window, side, rendered) in [("launcher", launcher.window, 36.0, launcher.bitmap),
                                               ("Settings header", settings.window, 30.0, settings.bitmap)] {
            let icon = window.contentView?.subviews.compactMap { $0 as? NSImageView }.first { $0.image?.isTemplate == true }
            let scale = CGFloat(rendered.width) / (window.contentView?.bounds.width ?? 1)
            let centre = icon.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } ?? .zero
            let colour = rendered.rgb(Int(centre.x * scale), Int(centre.y * scale))
            check(icon?.image?.size == NSSize(width: side, height: side) && icon?.contentTintColor == googleBlue &&
                  colour.b > 0.85 && colour.r < 0.4 && colour.g < 0.65,
                  "the \(name) shows the shared \(Int(side)) pt mark, drawn in Google blue")
        }
        try fitChecks(check: check, launcher.window, settings.window, folder)
        launcher.window.close()
        settings.window.close()

        guard let folder else { return }
        let mark = LensMark.image(size: LensMark.menuBarSize)
        for (scale, suffix) in [(CGFloat(1), "1x"), (2, "2x")] {
            for (theme, background, foreground) in [("light", NSColor(white: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.85)),
                                                    ("dark", NSColor(white: 0.14, alpha: 1), NSColor.white)] {
                let strip = try rendered(NSSize(width: 168, height: 24), scale: scale) { rect in
                    background.setFill()
                    rect.fill()
                    tinted(mark, in: NSRect(x: 10, y: 3, width: 18, height: 18), foreground)
                    var x: CGFloat = 40
                    for name in ["wifi", "battery.75"] {
                        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
                        if let symbol {
                            tinted(symbol, in: NSRect(x: x, y: (24 - symbol.size.height) / 2, width: symbol.size.width,
                                                      height: symbol.size.height), foreground)
                            x += symbol.size.width + 12
                        }
                    }
                    ("Mon 9:41" as NSString).draw(at: NSPoint(x: x, y: 4), withAttributes: [
                        .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: foreground
                    ])
                }
                try write(strip, to: folder.appendingPathComponent("mark.menubar.\(suffix).\(theme).png"))
            }
        }
        let large = LensMark.image(size: 128)
        try write(try rendered(NSSize(width: 160, height: 160), scale: 2) { rect in
            NSColor.white.setFill()
            rect.fill()
            tinted(large, in: NSRect(x: 16, y: 16, width: 128, height: 128), googleBlue)
        }, to: folder.appendingPathComponent("mark.large.png"))
    }

    /// Every label and button in the launcher and Settings fits its frame, so no text is clipped or truncated, at
    /// the windows' own widths, at the narrowest width their layout supports and when much wider. The windows grow
    /// to fit and nothing overlaps.
    private static func fitChecks(check: (Bool, String) -> Void, _ launcher: NSWindow, _ settings: NSWindow,
                                  _ folder: URL?) throws {
        func textFits(_ field: NSTextField) -> (needed: CGSize, fits: Bool) {
            let bounds = NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)
            let cell = field.cell?.cellSize(forBounds: bounds) ?? .zero
            let fitting = field.fittingSize
            // The height is also measured apart from the cell, from the text's own line layout inside the cell's
            // 2 pt side insets. Its width counts the space at each line break, so it is not used.
            let text = field.attributedStringValue.boundingRect(
                with: NSSize(width: field.frame.width - 4, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            let needed = CGSize(width: max(cell.width, fitting.width),
                                height: max(cell.height, fitting.height, ceil(text.height)))
            return (needed, needed.width <= field.frame.width + 0.5 && needed.height <= field.frame.height + 0.5)
        }
        func problems(in form: FormView) -> [String] {
            var found: [String] = []
            let views = form.arrangedViews
            for view in views {
                let frame = view.convert(view.bounds, to: form)
                let name = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? "\(type(of: view))"
                let short = String(name.prefix(32))
                if !form.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) { found.append("\(short) is outside the window") }
                if let field = view as? NSTextField {
                    let (needed, fits) = textFits(field)
                    if !fits {
                        found.append("\(short) needs \(fmt(needed.width))×\(fmt(needed.height)) of " +
                                     "\(fmt(frame.width))×\(fmt(frame.height))")
                    }
                } else if let control = view as? NSControl {
                    var fitting = control.fittingSize
                    if let popup = control as? NSPopUpButton {
                        // A closed pop-up shows only its selected title.
                        let shown = NSPopUpButton()
                        shown.font = popup.font
                        shown.addItem(withTitle: popup.titleOfSelectedItem ?? "")
                        fitting = shown.fittingSize
                    }
                    if fitting.width > frame.width + 0.5 || fitting.height > frame.height + 0.5 {
                        found.append("\(short) needs \(fmt(fitting.width))×\(fmt(fitting.height)) of " +
                                     "\(fmt(frame.width))×\(fmt(frame.height))")
                    }
                }
            }
            let solid = views.filter { $0.frame.height > 0 }.map { $0.convert($0.bounds, to: form) }
            for (index, frame) in solid.enumerated() where solid[(index + 1)...].contains(where: { $0.intersects(frame) }) {
                found.append("overlap at \(fmt(frame.minX)),\(fmt(frame.minY))")
            }
            return found
        }
        for (name, window) in [("launcher", launcher), ("Settings", settings)] {
            guard let form = window.contentView as? FormView else {
                check(false, "the \(name) window is laid out by a FormView")
                continue
            }
            let width = form.bounds.width
            for test in [form.minimumWidth, width, width * 1.5] {
                form.fitWindow(width: test)
                let found = problems(in: form)
                let fitted = abs(window.contentLayoutRect.height - form.place(width: form.bounds.width)) < 1
                check(found.isEmpty && fitted && abs(form.bounds.width - test) < 1,
                      "every \(name) label and button fits its frame at \(Int(test)) pt wide, the window is " +
                      "\(Int(form.bounds.height)) pt tall to fit and nothing overlaps" +
                      (found.isEmpty ? "" : ": " + found.joined(separator: "; ")))
                if test == form.minimumWidth {
                    _ = try preview(window, folder, "mark.\(name.lowercased()).narrow.png")
                }
            }
            // Dragging the window narrower than the narrowest layout, or to any height, keeps the content's height.
            for (proposed, expected) in [(NSSize(width: form.minimumWidth - 120, height: 120), form.minimumWidth),
                                         (NSSize(width: width + 140, height: 2000), width + 140)] {
                let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: proposed)).size
                let size = form.windowWillResize(window, to: frame)
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
                let found = problems(in: form)
                let fitted = abs(form.bounds.height - form.place(width: form.bounds.width)) < 1
                check(window.styleMask.contains(.resizable) && window.delegate === form && found.isEmpty && fitted &&
                      abs(form.bounds.width - expected) < 1,
                      "dragging the \(name) window to \(Int(proposed.width))×\(Int(proposed.height)) pt gives " +
                      "\(Int(form.bounds.width))×\(Int(form.bounds.height)), with every label and button in full" +
                      (found.isEmpty ? "" : ": " + found.joined(separator: "; ")))
            }
            form.fitWindow(width: width)
        }
        // The text and button that used to be cut off.
        let views = (settings.contentView as? FormView)?.arrangedViews ?? []
        for start in ["Screen capture, text recognition", "This uses an undocumented Google endpoint"] {
            let field = views.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix(start) }
            let result = field.map(textFits)
            check(result?.fits == true && field?.stringValue.hasSuffix(".") == true,
                  "the Settings paragraph \"\(start)…\" wraps in full: it needs \(fmt(result?.needed.height ?? 0)) of " +
                  "\(fmt(field?.frame.height ?? 0)) pt")
        }
        let fix = ((launcher.contentView as? FormView)?.arrangedViews ?? []).compactMap { $0 as? NSButton }
            .first { $0.title == "Fix Screen Recording permission…" }
        check(fix.map { $0.fittingSize.width <= $0.frame.width + 0.5 } == true,
              "the launcher's \"Fix Screen Recording permission…\" title fits: it needs " +
              "\(fmt(fix?.fittingSize.width ?? 0)) of \(fmt(fix?.frame.width ?? 0)) pt")
    }

    /// Draws a template image in `colour`, as the menu bar, buttons and image views do.
    private static func tinted(_ image: NSImage, in rect: NSRect, _ colour: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        colour.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }

    /// A window's content as AppKit draws it at 2x, written to `folder` when there is one. The window is never shown.
    private static func preview(_ window: NSWindow, _ folder: URL?, _ name: String) throws
        -> (window: NSWindow, bitmap: Bitmap) {
        guard let root = window.contentView,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * 2),
                                         pixelsHigh: Int(root.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            throw LensError.message("Could not render the \(window.title) window.")
        }
        rep.size = root.bounds.size
        root.layoutSubtreeIfNeeded()
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let image = rep.cgImage, let bitmap = Bitmap(image) else {
            throw LensError.message("Could not read the \(window.title) window.")
        }
        if let folder { try write(image, to: folder.appendingPathComponent(name)) }
        return (window, bitmap)
    }

    // MARK: - Fixtures and rendering

    private static func fmt(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }

    /// A 1200×700 point Retina image drawn by `draw`, standing in for a screen.
    private static func drawn(_ draw: (NSSize) -> Void) throws -> CGImage {
        try rendered(NSSize(width: 1200, height: 700), scale: 2) { draw($0.size) }
    }

    /// An image `size` points large with `scale` pixels per point, drawn by `draw` with AppKit.
    private static func rendered(_ size: NSSize, scale: CGFloat, _ draw: (NSRect) -> Void) throws -> CGImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                            pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw LensError.message("Could not generate the test image.")
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw LensError.message("Could not generate the test image.") }
        return image
    }

    /// A line of text and a red circle.
    static func fixture() throws -> CGImage {
        try drawn { size in
            NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            ("HELLO LENS 123" as NSString).draw(at: NSPoint(x: 100, y: 500), withAttributes: [
                .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black
            ])
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 760, y: 160, width: 120, height: 120)).fill()
        }
    }

    /// A two-line paragraph, an email address and a white-on-dark line.
    static func textFixture() throws -> CGImage {
        try drawn { size in
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let dark: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
            ("The quick brown fox" as NSString).draw(at: NSPoint(x: 100, y: 560), withAttributes: dark)
            ("jumps over the lazy dog" as NSString).draw(at: NSPoint(x: 100, y: 505), withAttributes: dark)
            ("Write to hello@example.com" as NSString).draw(at: NSPoint(x: 100, y: 380), withAttributes: dark)
            NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.2, alpha: 1).setFill()
            NSRect(x: 0, y: 120, width: size.width, height: 120).fill()
            ("Good morning" as NSString).draw(at: NSPoint(x: 100, y: 160), withAttributes: [
                .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.white
            ])
        }
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

    /// The view as drawn, `scale` pixels per point.
    private static func snapshot(_ view: NSView, scale: CGFloat = 1) -> CGImage? {
        // AppKit attaches subview layers to the tree during a display pass.
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        if view.layer?.sublayers == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(view.bounds.width * scale),
                                      height: Int(view.bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw LensError.message("Could not encode the overlay snapshot.")
        }
        try data.write(to: url)
    }
}

/// RGBA pixels of an image, addressed from the bottom left like AppKit and Core Graphics.
struct Bitmap {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        bytesPerRow = context.bytesPerRow
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
    }

    func rgb(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let column = min(max(x, 0), width - 1), row = height - 1 - min(max(y, 0), height - 1)
        let offset = row * bytesPerRow + column * 4
        return (CGFloat(bytes[offset]) / 255, CGFloat(bytes[offset + 1]) / 255, CGFloat(bytes[offset + 2]) / 255)
    }

    func luma(_ x: Int, _ y: Int) -> CGFloat {
        let colour = rgb(x, y)
        return 0.299 * colour.r + 0.587 * colour.g + 0.114 * colour.b
    }
}

/// Records what would be read aloud instead of speaking.
@MainActor
final class SilentSpeaker: Speaker {
    private(set) var spoken: [(text: String, language: String?)] = []
    private(set) var isSpeaking = false
    var onFinish: (() -> Void)?

    func speak(_ text: String, language: String?) -> Bool {
        guard !text.isEmpty else { return false }
        spoken.append((text, language))
        isSpeaking = true
        return true
    }

    func stop() { isSpeaking = false }

    func finish() {
        isSpeaking = false
        onFinish?()
    }
}

import AppKit
import LensCore

/// Offscreen checks of the Circle to Search overlay and Text mode with generated images: no screen capture, upload or
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

        do {
            let image = try fixture()
            var began = 0
            var changes: [(OverlayView, Bool)] = []
            var modes: [CaptureMode] = []
            var requests: [TranslationRequest] = []
            var refinements: [String] = []
            var visibility: [Bool] = []
            var cancelled = 0
            var actions = OverlayActions()
            actions.began = { _ in began += 1 }
            actions.changed = { changes.append(($0, $1)) }
            actions.modeChanged = { modes.append($1) }
            actions.translate = { requests.append($1) }
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
            let bounds = view.bounds
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let panel = view.panel!

            // Activation: the frozen screen fills the display 1:1 with only the Android-style controls on top.
            check(view.canvas == bounds && image.width == Int(bounds.width) * 2 && view.layer?.backgroundColor?.alpha == 0,
                  "the Retina screenshot fills the display exactly, with no border, inset or scaling")
            check(view.isWhole && view.pixelRect == full && !view.isDimmed && view.outlineFrame == nil &&
                  near(view.bracketFrame, bounds.insetBy(dx: 10, dy: 10)),
                  "the whole screen starts selected, shown as corner brackets with no border or dimming")
            let lensImage = view.lensButton.image
            check(lensImage?.isTemplate == true && lensImage?.size == NSSize(width: 28, height: 28) &&
                  lensImage?.accessibilityDescription == LensMark.label && view.lensButton.contentTintColor == googleBlue,
                  "the search bar shows the shared 28 pt mark in Google blue")
            let group = view.barFrame.union(view.translateFrame)
            check(abs(group.midX - bounds.midX) <= 1 && view.barFrame.minY < 40 &&
                  view.field.placeholderString == "Add to your search" && view.bar.superview === view &&
                  view.translateCard.superview === view && view.translateFrame.minX > view.barFrame.maxX,
                  "a search bar with “Add to your search” and Translate to its right floats at the bottom centre")
            check(view.modeControl.segmentCount == 2 && view.modeControl.label(forSegment: 0) == "Search" &&
                  view.modeControl.label(forSegment: 1) == "Text" && view.modeControl.selectedSegment == 0 &&
                  view.modeControl.isDescendant(of: view.bar) && view.textLabel.isHidden,
                  "a Search | Text toggle sits in the search bar, starting on Search")
            check(view.closeFrame.minX < 40 && view.closeFrame.maxY > bounds.maxY - 32 - 60 &&
                  view.closeCard.superview === view, "an ✕ close button sits at the top left, below the menu bar")
            check(!buttons(in: view).contains { ["Draw", "Full screen"].contains($0.title) } &&
                  !view.panelShown && panel.isHidden && view.actionChip.isHidden && view.selectTextChip.isHidden,
                  "there is no toolbar, text menu or results sheet until they are needed")

            // Results sheet: slides in on the right without covering the selection handles.
            view.revealPanel()
            view.layoutSubtreeIfNeeded()
            check(view.panelShown && !panel.isHidden && near(panel.frame, view.panelFrame) &&
                  panel.frame.maxX < bounds.maxX - 10 && panel.frame.minY > view.barFrame.maxY,
                  "the results sheet appears as a floating card on the right, above the search bar")
            check(view.panelFrame.width == PanelSizing.defaultWidth(screenWidth: bounds.width) &&
                  view.panelFrame.width == 560, "the sheet is wide enough for Google's desktop layout (560 pt here)")
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
            var liveOutline: CGRect?
            var dimmedWhileDrawing = true
            midDrag = {
                inked = view.inkBounds
                liveOutline = view.outlineFrame
                dimmedWhileDrawing = view.isDimmed
            }
            gesture(circle, on: view)
            check(inked.map { $0.width > 160 && $0.height > 160 } == true && view.inkBounds == nil,
                  "circling draws glowing ink that disappears when the finger lifts")
            check(liveOutline.map { $0.width > 160 && $0.height > 160 && $0.contains(red) } == true &&
                  !dimmedWhileDrawing, "a full outline follows the area while it is being drawn")
            check(view.selection.map { $0.contains(red) && $0.width < 200 } == true &&
                  near(view.bracketFrame, view.selection!) && near(view.outlineFrame, view.selection!, 1) &&
                  view.isDimmed && changes.last?.1 == false,
                  "a circle becomes a selection with corner brackets and a continuous border")
            if let shot = Self.snapshot(view).flatMap(Bitmap.init) {
                let selected = view.selection!
                let left = Int(selected.minX.rounded()), y = Int(selected.minY + selected.height * 0.3)
                let line = (left - 1...left + 1).map { shot.luma($0, y) }.max() ?? 0
                let halo = (left - 4...left - 1).map { shot.luma($0, y) }.min() ?? 1
                let outside = shot.luma(300, 300)
                let within = shot.luma(Int(selected.minX + selected.width * 0.12),
                                       Int(selected.minY + selected.height * 0.12))
                let circleColour = shot.rgb(Int(red.midX), Int(red.midY))
                check(circleColour.r > 0.7 && circleColour.g < 0.45 && circleColour.b < 0.45,
                      "the rendered overlay is sampled the right way up")
                check(line > 0.85 && halo < outside - 0.1,
                      "the border is a white line on a dark halo, visible on light and dark pages " +
                      "(line \(fmt(line)), halo \(fmt(halo)), page \(fmt(outside)))")
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

            view.selectWholeScreen()
            gesture([CGPoint(x: 100, y: 528), CGPoint(x: 300, y: 530), CGPoint(x: 470, y: 527)], on: view)
            let highlighted = view.selection
            check(highlighted.map { $0.height >= 40 && $0.minX < 101 && $0.maxX > 469 } == true,
                  "a highlight across a line of text selects the whole highlighted strip")

            // Lens's "Select text": circled words open in Text mode, already selected.
            check(spin(until: { !view.selectTextChip.isHidden }, timeout: 20) && view.selectTextButton != nil &&
                  view.selectTextChip.frame.maxY <= (highlighted?.minY ?? 0) + 14,
                  "a “Select text” chip appears next to a selection that contains text")
            view.selectTextButton?.performClick(nil)
            check(view.mode == .text && view.selectedText == "HELLO LENS 123" && modes.last == .text &&
                  view.selectTextChip.isHidden && view.modeControl.selectedSegment == 1,
                  "“Select text” switches to Text mode with the circled words selected")
            view.setMode(.search)
            check(view.mode == .search && near(view.selection, highlighted ?? .null) && view.textRange == nil &&
                  view.actionChip.isHidden, "switching back to Search keeps the circled area")

            view.selectWholeScreen()
            let count = changes.count
            let tap = CGPoint(x: 290, y: 528)
            gesture([tap, tap], on: view)
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

            // The Search | Text toggle keeps the same frozen screenshot, zoom and selection.
            let zoomedCanvas = view.canvas
            let searches = changes.count
            view.modeControl.selectedSegment = 1
            view.modeControl.sendAction(view.modeControl.action, to: view.modeControl.target)
            check(view.mode == .text && view.image === image && view.canvas == zoomedCanvas && view.pixelRect == tapped &&
                  view.field.isHidden && !view.textLabel.isHidden && modes.last == .text,
                  "switching to Text keeps the screenshot and zoom, and the bar shows the text status")
            view.modeControl.selectedSegment = 0
            view.modeControl.sendAction(view.modeControl.action, to: view.modeControl.target)
            check(view.mode == .search && view.canvas == zoomedCanvas && view.pixelRect == tapped &&
                  !view.field.isHidden && view.textLabel.isHidden && changes.count == searches,
                  "switching back to Search keeps them too, without starting another search")

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
            check(view.mode == .text && requests.count == 1 && requests[0].blocks.contains { $0.contains("HELLO") },
                  "Translate switches to Text mode and translates the recognized text in place")
            view.endTranslation()
            view.setMode(.search)
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
            let other = OverlayView(frame: size, image: image, displayIndex: 1, mode: .search, selected: false,
                                    controls: false, actions: actions)
            other.keyDown(with: key(36, "\r", in: window))
            check(other.selection == nil && other.searchKey == nil && other.panel == nil &&
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
                screenView.setMode(.text)
                let read = spin(until: { screenView.textLayout != nil }, timeout: 20)
                _ = overlayWindow.performKeyEquivalent(with: key(0, "a", flags: .command, in: overlayWindow))
                let all = screenView.selectedText
                _ = overlayWindow.performKeyEquivalent(with: key(8, "c", flags: .command, in: overlayWindow))
                check(read && all == "HELLO LENS 123" && board.string(forType: .string) == all &&
                      screenView.toastText == "Copied" && changes.count == 1,
                      "in Text mode Command-A selects all text and Command-C copies it (to a private pasteboard here)")
                overlayWindow.sendEvent(key(53, "\u{1b}", in: overlayWindow))
                check(cancelled == 2, "Escape cancels from anywhere in the overlay window")
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
            try markChecks(check: check, folder: snapshot?.deletingLastPathComponent())
        } catch {
            failures += 1
            fputs("FAIL native checks: \(error.localizedDescription)\n", stderr)
        }
        check(NSPasteboard.general.changeCount == clipboard, "the user's clipboard was never touched")
        print("Native checks: \(failures) failures; no screen capture, upload or browser launch.")
        return failures == 0
    }

    // MARK: - Text mode

    /// Text mode on a multi-line fixture: recognition, marking, handles, the action menu, translation in place and
    /// Escape, all offscreen and without any upload.
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
        var modes: [CaptureMode] = []
        var commands: [(TextCommand, String)] = []
        var requests: [TranslationRequest] = []
        var quick: [String] = []
        var cancelled = 0
        var actions = OverlayActions()
        actions.changed = { _, _ in searches += 1 }
        actions.modeChanged = { modes.append($1) }
        actions.textCommand = { commands.append(($1, $2)) }
        actions.translate = { requests.append($1) }
        actions.quick = { quick.append($1.title) }
        actions.cancel = { cancelled += 1 }
        let size = NSRect(x: 0, y: 0, width: 1200, height: 700)
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = OverlayView(frame: size, image: image, displayIndex: 0, mode: .text, topInset: 32,
                               selected: true, controls: true, actions: actions)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func tap(_ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            click(point, view, clicks, flags)
        }

        // Entering Text mode reads the whole frozen display on this Mac, off the main thread.
        check(view.mode == .text && view.recognizing && view.toastText == "Finding text…" && view.field.isHidden &&
              !view.textLabel.isHidden && view.modeControl.selectedSegment == 1 && modes.isEmpty,
              "opening straight into Text mode shows “Finding text…” while Apple Vision reads the screen")
        guard spin({ view.textLayout != nil }, 20), let layout = view.textLayout, !layout.isEmpty else {
            throw LensError.message("No text was recognized in the text fixture.")
        }
        print("INFO recognized: \(layout.allText.replacingOccurrences(of: "\n", with: " ⏎ "))")
        func word(_ text: String) -> Int? { layout.words.firstIndex { $0.text == text } }
        func centre(_ index: Int) -> CGPoint {
            let box = layout.view(index, in: view.canvas)
            return CGPoint(x: box.midX, y: box.midY)
        }
        guard let quickWord = word("quick"), let brown = word("brown"), let fox = word("fox"), let over = word("over"),
              let lazy = word("lazy"), let dog = word("dog"), let good = word("Good"),
              let email = layout.words.firstIndex(where: { $0.text.contains("@") }) else {
            throw LensError.message("The text fixture was read as \(layout.words.map { $0.text }).")
        }
        let paragraph = "The quick brown fox\njumps over the lazy dog"
        check(layout.blocks.count == 3 && layout.allText.hasPrefix(paragraph + "\n\n") &&
              layout.allText.hasSuffix("\n\nGood morning"),
              "words are joined in reading order with line breaks inside paragraphs and blank lines between them")
        check(view.toastText == OverlayView.textHint && view.textSurface.words.path?.isEmpty == false &&
              !view.isDimmed && abs((view.textSurface.dim.fillColor?.alpha ?? 1) - TextSurface.dimAlpha) < 0.01 &&
              TextSurface.dimAlpha < OverlayView.dimAlpha && !view.textSurface.isHidden,
              "every word gets a subtle highlight, other areas are dimmed only lightly, and a hint explains what to do")

        // Marking text like a text cursor.
        tap(centre(quickWord))
        check(view.selectedText == "quick" && view.textLabel.stringValue == "1 word selected" &&
              ["Copy", "Select all", "Listen", "Translate", "Search"].allSatisfy(chip(view).contains),
              "clicking a word selects it and shows Copy, Select all, Listen, Translate and Search")
        var hiddenWhileDragging = false
        midDrag { hiddenWhileDragging = view.actionChip.isHidden }
        gesture([centre(quickWord), centre(fox), centre(lazy)], view)
        let dragged = view.textRange.map { layout.lineRects(for: $0, canvas: view.canvas) } ?? []
        let covered = dragged.reduce(CGRect.null) { $0.union($1) }
        check(view.selectedText == "quick brown fox\njumps over the lazy" && dragged.count == 2 &&
              view.textSurface.selection.path?.isEmpty == false && view.textSurface.handles.path?.isEmpty == false,
              "dragging across words selects them in reading order, highlighted per line, with two handles")
        check(hiddenWhileDragging && !view.actionChip.isHidden && !view.actionChip.frame.intersects(covered) &&
              view.bounds.contains(view.actionChip.frame),
              "the action menu hides while dragging and then floats next to the selection, on screen")
        try save(view, "text")

        if let range = view.textRange, let ends = layout.handlePoints(for: range, canvas: view.canvas) {
            let end = TextSurface.knobCenter(ends.end)
            gesture([end, CGPoint(x: (end.x + centre(dog).x) / 2, y: end.y), CGPoint(x: centre(dog).x, y: end.y)], view)
            let extended = view.selectedText
            let begin = TextSurface.knobCenter(ends.start)
            gesture([begin, CGPoint(x: centre(brown).x, y: begin.y)], view)
            check(extended == "quick brown fox\njumps over the lazy dog" &&
                  view.selectedText == "brown fox\njumps over the lazy dog",
                  "dragging the end and start handles changes the selected range")
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
        press("Copy", view)
        check(board.string(forType: .string) == layout.allText && view.toastText == "Copied" &&
              !view.actionChip.isHidden, "Copy keeps line breaks, says “Copied” and leaves the overlay open")

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

        // Circling still works in Text mode, and a tap on empty space clears the selection.
        var inked = false
        midDrag { inked = view.inkBounds != nil }
        gesture([CGPoint(x: 60, y: 600), CGPoint(x: 380, y: 540), CGPoint(x: 700, y: 470)], view)
        check(inked && view.inkBounds == nil && view.selectedText == paragraph,
              "circling or boxing empty space selects every word inside")
        tap(CGPoint(x: 900, y: 300))
        check(view.textRange == nil && chip(view).contains("Copy all text"), "tapping empty space clears the selection")
        press("Copy all text", view)
        check(board.string(forType: .string) == layout.allText && view.toastText == "Copied all text",
              "with nothing selected, Copy all text copies everything")

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
        tap(CGPoint(x: 900, y: 300))
        press("Translate", view)
        let request = requests.last
        check(requests.count == 1 && request?.blocks.count == layout.blocks.count && request?.text == layout.allText &&
              !view.translateBar.isHidden && view.toastText == "Translating…",
              "Translate sends each paragraph, as flowing text, to the translator and shows progress")
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
        view.translateBar.closeButton.performClick(nil)
        check(view.translatedLines == nil && view.translateBar.isHidden && layer.isHidden,
              "closing the translate bar returns to the original screen")

        check(searches == 0 && view.panel?.webView == nil && commands.allSatisfy { $0.0 == .search },
              "Text mode never starts a visual search or loads a page; the screenshot is never uploaded")
        view.keyDown(with: key(53, "\u{1b}", [], window))
        check(cancelled == 1, "Escape closes Text mode too")

        // The results sheet remembers the width the user drags it to.
        view.panel?.onResize?(700, true)
        let next = OverlayView(frame: size, image: image, displayIndex: 0, mode: .search, selected: true,
                               controls: true, actions: OverlayActions())
        check(suite.double(forKey: PanelSizing.defaultsKey) == 700 && next.panelFrame.width == 700,
              "a sheet width set by dragging is remembered for the next activation")
    }

    // MARK: - Mark

    /// The shared mark at the sizes it is shown at, drawn offscreen at 1x and 2x, and where the app shows it. With a
    /// folder, also writes preview images of the menu bar, the launcher and Settings there.
    private static func markChecks(check: (Bool, String) -> Void, folder: URL?) throws {
        check(LensMark.metrics(side: 18, scale: 1).stroke == 2 && LensMark.metrics(side: 18, scale: 2).stroke == 2,
              "the 18 pt menu-bar mark has 2 pt corner strokes at 1x and 2x")
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
                check(crisp && open && ink(n / 2, n / 2) > 0.9 && (0.15...0.55).contains(coverage) &&
                      (0.5...0.66).contains(height) && (0.45...0.62).contains(width) && mismatch < 0.03,
                      "the \(Int(side)) pt mark at \(Int(scale))x has pixel-sharp corners and a solid centred apple " +
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
            let centre = icon.map { CGPoint(x: $0.frame.midX * scale, y: $0.frame.midY * scale) } ?? .zero
            let colour = rendered.rgb(Int(centre.x), Int(centre.y))
            check(icon?.image?.size == NSSize(width: side, height: side) && icon?.contentTintColor == googleBlue &&
                  colour.b > 0.85 && colour.r < 0.4 && colour.g < 0.65,
                  "the \(name) shows the shared \(Int(side)) pt mark, drawn in Google blue")
            window.close()
        }

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
private struct Bitmap {
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

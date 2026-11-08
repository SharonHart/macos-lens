import AppKit
import LensCore

private var failures = 0

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(actual == expected, "\(actual) != \(expected) \(message)", file: file, line: line)
}

private func XCTAssertTrue(_ condition: Bool, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        failures += 1
        fputs("FAIL \(file):\(line) \(message)\n", stderr)
    }
}

private func XCTAssertFalse(_ condition: Bool, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(!condition, message, file: file, line: line)
}

private func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value == nil, "Expected nil", file: file, line: line)
}

private func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value != nil, "Expected non-nil", file: file, line: line)
}

private func XCTAssertThrowsError<T>(_ operation: @autoclosure () throws -> T,
                                    file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try operation()
        XCTAssertTrue(false, "Expected error", file: file, line: line)
    } catch {}
}

final class LensCoreTests {
    func testReverseDragAndClipping() {
        XCTAssertEqual(Selection.rectangle(from: CGPoint(x: 90, y: 80), to: CGPoint(x: -10, y: 20),
                                           in: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       CGRect(x: 0, y: 20, width: 90, height: 60))
    }

    func testRetinaAndTopLeftConversion() {
        XCTAssertEqual(Selection.pixels(for: CGRect(x: 10, y: 20, width: 30, height: 40),
                                       in: CGRect(x: 0, y: 0, width: 100, height: 100), width: 200, height: 200),
                       CGRect(x: 20, y: 80, width: 60, height: 80))
    }

    func testFractionalScaleAndNonzeroOrigin() {
        XCTAssertEqual(Selection.pixels(for: CGRect(x: -95, y: 15, width: 10, height: 10),
                                       in: CGRect(x: -100, y: 10, width: 100, height: 100), width: 150, height: 150),
                       CGRect(x: 7, y: 127, width: 16, height: 16))
        XCTAssertNil(Selection.pixels(for: .zero, in: .zero, width: 0, height: 0))
        XCTAssertNil(Selection.pixels(for: CGRect(x: 1000, y: 1000, width: 10, height: 10),
                                     in: CGRect(x: 0, y: 0, width: 100, height: 100), width: 200, height: 200))
    }

    func testCropDimensions() throws {
        let fixture = try OCR.fixture()
        let cropped = try Selection.crop(fixture, region: CGRect(x: 0, y: 0, width: 320, height: 120),
                                         bounds: CGRect(x: 0, y: 0, width: 640, height: 240))
        XCTAssertEqual(cropped.width, fixture.width / 2)
        XCTAssertEqual(cropped.height, fixture.height / 2)
    }

    func testOCRWithGeneratedFixture() throws {
        let recognized = try OCR.recognize(OCR.fixture()).map(\.text).joined(separator: " ")
        XCTAssertTrue(recognized.contains("HELLO LENS 123"), recognized)
    }

    func testMultipartPreservesImageBytes() {
        let bytes = Data([0, 255, 13, 10, 127])
        let body = LensUpload.multipart(png: bytes, boundary: "test-boundary")
        XCTAssertNotNil(body.range(of: bytes))
        XCTAssertTrue(body.starts(with: Data("--test-boundary\r\n".utf8)))
        XCTAssertTrue(body.range(of: Data("name=\"encoded_image\"".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("\r\n--test-boundary--\r\n".utf8)) != nil)
    }

    func testRedirectValidation() throws {
        XCTAssertEqual(try LensUpload.resultURL(status: 303, location: "https://www.google.com/search?vsrid=abc").host,
                       "www.google.com")
        for location in ["https://evil.test/search?vsrid=x", "https://www.google.com.evil.test/search?vsrid=x",
                         "http://www.google.com/search?vsrid=x", "https://www.google.com/search?q=text",
                         "https://www.google.com/sorry?vsrid=x", "https://user@www.google.com/search?vsrid=x"] {
            XCTAssertThrowsError(try LensUpload.resultURL(status: 303, location: location))
        }
        XCTAssertThrowsError(try LensUpload.resultURL(status: 200, location: "https://www.google.com/search?vsrid=x"))
    }

    func testTextURLsPreserveSpecialCharacters() {
        let text = "lens & café #1 + שלום"
        let query = URLComponents(url: SearchURL.text(text), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first?.value, text)
        XCTAssertEqual(URLComponents(url: SearchURL.translate(text), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "text" })?.value, text)
    }

    func testBrowserSelection() {
        XCTAssertThrowsError(try Browser.applicationURL(preferredPath: "/not-installed/Browser.app"))
        XCTAssertThrowsError(try Browser.applicationURL(preferredPath: "/System/Applications/TextEdit.app"))
        XCTAssertTrue(!Browser.opensWebLinks(URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
        if let system = Browser.defaultApplication() {
            XCTAssertEqual(try? Browser.applicationURL(preferredPath: nil), system)
            XCTAssertEqual(try? Browser.applicationURL(preferredPath: ""), system)
            XCTAssertTrue(Browser.opensWebLinks(system), "default browser must open web links")
            XCTAssertEqual(try? Browser.applicationURL(preferredPath: system.path), system)
        }
    }

    func testCropUsesTopImageRows() throws {
        var pixels: [UInt8] = []
        for row in 0..<8 {
            for _ in 0..<8 {
                pixels += row < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let crop = try Selection.crop(image, region: CGRect(x: 0, y: 4, width: 8, height: 4),
                                      bounds: CGRect(x: 0, y: 0, width: 8, height: 8))
        let color = NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        XCTAssertTrue(color.redComponent > 0.9 && color.blueComponent < 0.1, "Top region must select red pixels.")
    }

    func testTinySelectionsAreRejected() {
        XCTAssertTrue(!Selection.isUsable(nil))
        XCTAssertTrue(!Selection.isUsable(CGRect(x: 10, y: 10, width: 1, height: 1)))
        XCTAssertTrue(!Selection.isUsable(CGRect(x: 10, y: 10, width: 40, height: 3)))
        XCTAssertTrue(Selection.isUsable(CGRect(x: 10, y: 10, width: 4, height: 4)))
        XCTAssertTrue(Selection.isUsable(CGRect(x: 10, y: 10, width: -4, height: -4)))
    }

    func testShortcutSystemConflicts() {
        let controlOption = Shortcut.named("control-option-space")
        let commandShift2 = Shortcut.named("command-shift-2")
        XCTAssertEqual(Shortcut.named(nil), commandShift2)
        XCTAssertEqual(Shortcut.named("missing"), commandShift2)
        XCTAssertTrue(controlOption.conflictsWithSystem(nil), "macOS enables input-source switching by default")
        XCTAssertTrue(!controlOption.conflictsWithSystem(["61": ["enabled": false]]))
        let custom: [String: Any] = [
            "61": ["enabled": 1, "value": ["parameters": [65535, 19, 1_179_648], "type": "standard"]]
        ]
        XCTAssertTrue(!controlOption.conflictsWithSystem(custom), "A remapped system shortcut no longer conflicts")
        XCTAssertTrue(commandShift2.conflictsWithSystem(custom), "Remapped system shortcut conflicts with the new keys")
        let functionFlag: [String: Any] = [
            "200": ["enabled": true, "value": ["parameters": [50, 19, 1_179_648 | 8_388_608], "type": "standard"]]
        ]
        XCTAssertTrue(commandShift2.conflictsWithSystem(functionFlag), "Unrelated modifier bits are ignored")
        XCTAssertTrue(!Shortcut.named("control-shift-space").conflictsWithSystem(nil))
        XCTAssertTrue(!commandShift2.conflictsWithSystem(nil))
        XCTAssertEqual(Set(Shortcut.all.map(\.id)).count, Shortcut.all.count)
    }

    private let canvas = CGRect(x: 10, y: 20, width: 400, height: 300)

    func testDefaultSelectionCoversWholeCanvas() {
        let whole = SelectionEditor.view(SelectionEditor.whole, in: canvas)
        XCTAssertEqual(whole, canvas)
        XCTAssertEqual(SelectionEditor.unit(whole, in: canvas), SelectionEditor.whole)
        XCTAssertEqual(Selection.pixels(for: whole, in: canvas, width: 800, height: 600),
                       CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(SelectionEditor.target(at: CGPoint(x: 200, y: 150), selection: whole, bounds: canvas), .draw,
                       "Dragging inside a full-screen selection draws a smaller area")
        XCTAssertEqual(SelectionEditor.fit(CGSize(width: 1600, height: 1000),
                                           in: CGRect(x: 0, y: 0, width: 800, height: 800)),
                       CGRect(x: 0, y: 150, width: 800, height: 500))
    }

    func testHandleHitTesting() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        func target(_ x: CGFloat, _ y: CGFloat) -> SelectionDrag {
            SelectionEditor.target(at: CGPoint(x: x, y: y), selection: rect, bounds: canvas)
        }
        XCTAssertEqual(target(102, 98), .resize(.bottomLeft))
        XCTAssertEqual(target(299, 201), .resize(.topRight))
        XCTAssertEqual(target(100, 150), .resize(.left))
        XCTAssertEqual(target(305, 150), .resize(.right))
        XCTAssertEqual(target(200, 195), .resize(.top))
        XCTAssertEqual(target(200, 105), .resize(.bottom))
        XCTAssertEqual(target(200, 150), .move)
        XCTAssertEqual(target(380, 300), .draw)
        XCTAssertEqual(SelectionEditor.target(at: CGPoint(x: 200, y: 150), selection: rect, bounds: canvas,
                                              freehand: true), .draw)
        XCTAssertEqual(SelectionEditor.target(at: CGPoint(x: 200, y: 150), selection: nil, bounds: canvas), .draw)
    }

    func testHandleResizeClampsToCanvasAndMinimum() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionEditor.resize(rect, handle: .right, by: CGVector(dx: 50, dy: 80), in: canvas),
                       CGRect(x: 100, y: 100, width: 250, height: 100), "edge handles change one side only")
        XCTAssertEqual(SelectionEditor.resize(rect, handle: .topLeft, by: CGVector(dx: -40, dy: 30), in: canvas),
                       CGRect(x: 60, y: 100, width: 240, height: 130))
        XCTAssertEqual(SelectionEditor.resize(rect, handle: .bottomRight, by: CGVector(dx: 500, dy: -500), in: canvas),
                       CGRect(x: 100, y: 20, width: 310, height: 180), "clamped to the canvas")
        XCTAssertEqual(SelectionEditor.resize(rect, handle: .left, by: CGVector(dx: 400, dy: 0), in: canvas),
                       CGRect(x: 284, y: 100, width: 16, height: 100), "handles cannot cross or collapse")
        XCTAssertEqual(SelectionEditor.resize(canvas, handle: .top, by: CGVector(dx: 0, dy: -100), in: canvas),
                       CGRect(x: 10, y: 20, width: 400, height: 200), "the full-screen default shrinks from an edge")
    }

    func testMoveKeepsSizeAndStaysInCanvas() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionEditor.move(rect, by: CGVector(dx: 30, dy: -20), in: canvas),
                       CGRect(x: 130, y: 80, width: 200, height: 100))
        XCTAssertEqual(SelectionEditor.move(rect, by: CGVector(dx: 1000, dy: 1000), in: canvas),
                       CGRect(x: 210, y: 220, width: 200, height: 100))
        XCTAssertEqual(SelectionEditor.move(rect, by: CGVector(dx: -1000, dy: -1000), in: canvas),
                       CGRect(x: 10, y: 20, width: 200, height: 100))
    }

    func testUnitSelectionSurvivesCanvasResize() {
        let rect = CGRect(x: 110, y: 95, width: 100, height: 75)
        let unit = SelectionEditor.unit(rect, in: canvas)
        let smaller = CGRect(x: 0, y: 0, width: 200, height: 150)
        XCTAssertEqual(SelectionEditor.view(unit, in: smaller), CGRect(x: 50, y: 37.5, width: 50, height: 37.5))
        XCTAssertEqual(Selection.pixels(for: rect, in: canvas, width: 800, height: 600),
                       Selection.pixels(for: SelectionEditor.view(unit, in: smaller), in: smaller,
                                        width: 800, height: 600), "the same pixels are cropped at any panel width")
        XCTAssertEqual(SelectionEditor.pixels(forUnit: unit, width: 800, height: 600),
                       CGRect(x: 200, y: 300, width: 200, height: 150), "unit pixels use a top-left origin")
        XCTAssertEqual(SelectionEditor.pixels(forUnit: SelectionEditor.whole, width: 3456, height: 2234),
                       CGRect(x: 0, y: 0, width: 3456, height: 2234), "the default selection is every pixel")
        let noisy = SelectionEditor.unit(SelectionEditor.view(unit, in: CGRect(x: 3, y: 7, width: 333, height: 777)),
                                        in: CGRect(x: 3, y: 7, width: 333, height: 777))
        XCTAssertEqual(SelectionEditor.pixels(forUnit: noisy, width: 800, height: 600),
                       CGRect(x: 200, y: 300, width: 200, height: 150), "float noise does not change the pixels")
    }

    func testUploadScalingAndRateLimitMessage() throws {
        let context = CGContext(data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let large = context.makeImage()!
        let scaled = LensUpload.scaledForUpload(large)
        XCTAssertEqual(scaled.width, 2000)
        XCTAssertEqual(scaled.height, 500)
        let fixture = try OCR.fixture()
        XCTAssertTrue(LensUpload.scaledForUpload(fixture) === fixture, "small images are uploaded unchanged")
        do {
            _ = try LensUpload.resultURL(status: 429, location: nil)
            XCTAssertTrue(false, "429 must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 429"), error.localizedDescription)
        }
    }

    func testPanelUploadRequestCarriesOnlyTheScaledSelection() throws {
        let context = CGContext(data: nil, width: 3000, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let request = try LensUpload.request(for: context.makeImage()!)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, LensUpload.endpoint)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie") == nil, "the app never adds cookies")
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let boundary = type.components(separatedBy: "boundary=").last ?? ""
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=") && !boundary.isEmpty, type)
        let body = request.httpBody ?? Data()
        XCTAssertTrue(body.starts(with: Data("--\(boundary)\r\n".utf8)))
        let start = body.range(of: Data("\r\n\r\n".utf8))!.upperBound
        let end = body.range(of: Data("\r\n--\(boundary)--".utf8))!.lowerBound
        let image = NSBitmapImageRep(data: body.subdata(in: start..<end))
        XCTAssertEqual(image?.pixelsWide, 2000)
        XCTAssertEqual(image?.pixelsHigh, 400)
    }

    func testCommittedPanelPageValidation() throws {
        let result = URL(string: "https://www.google.com/search?vsrid=abc&udm=26")!
        XCTAssertEqual(try LensUpload.committedResult(result, status: 200), result)
        func message(_ url: String?, _ status: Int?) -> String {
            do {
                _ = try LensUpload.committedResult(url.flatMap(URL.init(string:)), status: status)
                return "accepted"
            } catch { return error.localizedDescription }
        }
        XCTAssertTrue(message(result.absoluteString, 429).contains("HTTP 429"))
        XCTAssertTrue(message("https://consent.google.com/ml?continue=x", 200).contains("cookie consent"))
        XCTAssertTrue(message("https://accounts.google.com/ServiceLogin", 200).contains("sign in"))
        XCTAssertTrue(message("https://www.google.com/sorry/index?continue=x", 429).contains("HTTP 429"))
        XCTAssertTrue(message("https://www.google.com/sorry/index?continue=x", 200).contains("not a robot"))
        XCTAssertTrue(message("https://www.google.com/search?q=x", 200).contains("HTTP 200"))
        XCTAssertTrue(message("https://evil.example/search?vsrid=abc", 200).contains("did not return"))
        XCTAssertTrue(message("http://www.google.com/search?vsrid=abc", 200).contains("did not return"))
        XCTAssertTrue(message(nil, nil).contains("no page"))
    }

    func testLiveSearchDebouncesToLastSelection() {
        MainActor.assumeIsolated {
            let search = LiveSearch<String>(delay: .milliseconds(60))
            var calls: [String] = []
            for key in ["a", "b", "c"] {
                search.schedule(key) { calls.append(key); return URL(string: "https://example.test/\(key)")! }
                XCTAssertEqual(search.state, .waiting)
            }
            XCTAssertTrue(waitUntil { search.state == .loaded(URL(string: "https://example.test/c")!) })
            XCTAssertEqual(calls, ["c"])
            search.schedule("d") { calls.append("d"); return URL(string: "https://example.test/d")! }
            search.postpone()
            XCTAssertEqual(search.state, .loaded(URL(string: "https://example.test/c")!),
                           "postponing keeps the previous results")
            _ = waitUntil(timeout: 0.2) { false }
            XCTAssertEqual(calls, ["c"])
        }
    }

    func testLiveSearchCancelsInFlightUpload() {
        MainActor.assumeIsolated {
            let search = LiveSearch<String>(delay: .milliseconds(10))
            var started = false
            var cancelled = false
            var history: [LiveSearchState] = []
            search.onChange = { history.append($0) }
            search.schedule("a", immediately: true) {
                started = true
                do { try await Task.sleep(for: .seconds(5)) } catch { cancelled = true; throw error }
                return URL(string: "https://example.test/a")!
            }
            XCTAssertEqual(search.state, .uploading)
            XCTAssertTrue(waitUntil { started })
            search.postpone()
            XCTAssertEqual(search.state, .uploading, "postpone never cancels an upload in progress")
            search.schedule("b", immediately: true) { URL(string: "https://example.test/b")! }
            XCTAssertTrue(waitUntil { cancelled && search.state == .loaded(URL(string: "https://example.test/b")!) })
            XCTAssertTrue(!history.contains(.loaded(URL(string: "https://example.test/a")!)),
                          "cancelled results are never shown")
            search.schedule("c", immediately: true) {
                try await Task.sleep(for: .seconds(5))
                return URL(string: "https://example.test/c")!
            }
            search.cancel()
            XCTAssertEqual(search.state, .loaded(URL(string: "https://example.test/b")!))
            XCTAssertTrue(!search.isBusy)
        }
    }

    func testLiveSearchSkipsDuplicateUploads() {
        MainActor.assumeIsolated {
            let search = LiveSearch<String>(delay: .milliseconds(10))
            var uploads = 0
            let slow: () async throws -> URL = {
                uploads += 1
                try await Task.sleep(for: .milliseconds(80))
                return URL(string: "https://example.test/a")!
            }
            search.schedule("a", search: slow)
            search.schedule("a", search: slow)
            XCTAssertTrue(waitUntil { search.state == .uploading })
            search.schedule("a", search: slow)
            search.schedule("a", immediately: true, search: slow)
            XCTAssertTrue(waitUntil { search.state == .loaded(URL(string: "https://example.test/a")!) })
            search.schedule("b", immediately: true) { uploads += 1; return URL(string: "https://example.test/b")! }
            XCTAssertTrue(waitUntil { search.state == .loaded(URL(string: "https://example.test/b")!) })
            search.schedule("a", search: slow)
            XCTAssertEqual(search.state, .loaded(URL(string: "https://example.test/a")!),
                           "returning to an earlier selection reuses its results")
            XCTAssertEqual(uploads, 2)
        }
    }

    func testLiveSearchReportsFailuresAndAllowsRetry() {
        MainActor.assumeIsolated {
            let search = LiveSearch<String>(delay: .milliseconds(10))
            var attempts = 0
            let flaky: () async throws -> URL = {
                attempts += 1
                if attempts == 1 { throw LensError.message("HTTP 429") }
                return URL(string: "https://example.test/a")!
            }
            search.schedule("a", immediately: true, search: flaky)
            XCTAssertTrue(waitUntil { search.state == .failed("HTTP 429") })
            search.schedule("a", immediately: true, search: flaky)
            XCTAssertTrue(waitUntil { search.state == .loaded(URL(string: "https://example.test/a")!) })
            XCTAssertEqual(attempts, 2)
        }
    }

    func testViewportZoomKeepsAnchorAndCoversScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        var viewport = Viewport()
        XCTAssertEqual(viewport.canvas(in: bounds), bounds, "unzoomed, the screenshot is exactly the screen")
        viewport.zoom(by: 2, at: CGPoint(x: 250, y: 150), in: bounds)
        XCTAssertEqual(viewport.canvas(in: bounds), CGRect(x: -250, y: -150, width: 2000, height: 1200),
                       "the point under the fingers stays put")
        viewport.pan(by: CGVector(dx: 400, dy: 400), in: bounds)
        XCTAssertEqual(viewport.canvas(in: bounds).origin, .zero, "panning stops at the screenshot edge")
        viewport.pan(by: CGVector(dx: -5000, dy: -5000), in: bounds)
        XCTAssertEqual(viewport.canvas(in: bounds).origin, CGPoint(x: -1000, y: -600))
        viewport.zoom(by: 100, at: .zero, in: bounds)
        XCTAssertEqual(viewport.zoom, Viewport.maximumZoom)
        viewport.zoom(by: 0.001, at: CGPoint(x: 500, y: 300), in: bounds)
        XCTAssertEqual(viewport.canvas(in: bounds), bounds, "zooming out never shows a border")
        XCTAssertTrue(!viewport.isZoomed)
    }

    func testZoomedSelectionCropsTheSamePixels() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        var viewport = Viewport()
        viewport.zoom(by: 4, at: CGPoint(x: 500, y: 300), in: bounds)
        let canvas = viewport.canvas(in: bounds)
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let unit = SelectionEditor.unit(visible, in: canvas)
        XCTAssertEqual(SelectionEditor.pixels(forUnit: unit, width: 2000, height: 1200),
                       CGRect(x: 750, y: 450, width: 500, height: 300), "at 4x the screen shows a quarter of each axis")
        XCTAssertEqual(SelectionEditor.pixels(forUnit: unit, width: 2000, height: 1200),
                       Selection.pixels(for: visible, in: canvas, width: 2000, height: 1200))
    }

    func testStrokeBoundsAndTaps() {
        let limit = CGRect(x: 0, y: 0, width: 800, height: 600)
        let circle = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 110), CGPoint(x: 190, y: 220), CGPoint(x: 95, y: 205)]
        XCTAssertEqual(SelectionEditor.strokeBounds(circle, in: limit), CGRect(x: 89, y: 94, width: 117, height: 132),
                       "a circle selects its bounding box with room for the ink")
        let highlight = [CGPoint(x: 300, y: 400), CGPoint(x: 500, y: 402)]
        XCTAssertEqual(SelectionEditor.strokeBounds(highlight, in: limit), CGRect(x: 294, y: 381, width: 212, height: 40),
                       "a thin highlight is thickened to cover its line of text")
        XCTAssertEqual(SelectionEditor.strokeBounds([CGPoint(x: 2, y: 598), CGPoint(x: 60, y: 598)], in: limit),
                       CGRect(x: 0, y: 560, width: 70, height: 40), "the ink area is kept on the screen")
        XCTAssertTrue(SelectionEditor.isTap([CGPoint(x: 10, y: 10), CGPoint(x: 13, y: 14)]))
        XCTAssertTrue(!SelectionEditor.isTap([CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)]))
        XCTAssertTrue(!SelectionEditor.isTap([]))

        let line = CGRect(x: 100, y: 100, width: 300, height: 30)
        let word = CGRect(x: 120, y: 102, width: 60, height: 26)
        let object = CGRect(x: 500, y: 200, width: 120, height: 120)
        func tap(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            SelectionEditor.tapSelection(at: CGPoint(x: x, y: y), textLines: [line, word], objects: [object], in: limit)
        }
        XCTAssertEqual(tap(150, 115), word.insetBy(dx: -6, dy: -6), "the smallest text under the tap wins")
        XCTAssertEqual(tap(300, 115), line.insetBy(dx: -6, dy: -6))
        XCTAssertEqual(tap(560, 260), object.insetBy(dx: -6, dy: -6), "otherwise the object under the tap")
        XCTAssertEqual(tap(780, 20), CGRect(x: 640, y: 0, width: 160, height: 160), "otherwise a square around it")
    }

    func testVisionBoxesMapToScreenshotUnits() {
        let crop = CGRect(x: 200, y: 100, width: 400, height: 200)
        let unit = SelectionEditor.unit(forNormalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
                                        inPixels: crop, width: 1000, height: 500)
        XCTAssertEqual(SelectionEditor.pixels(forUnit: unit, width: 1000, height: 500),
                       CGRect(x: 300, y: 150, width: 200, height: 50),
                       "a box in the top half of a crop maps to the crop's top pixel rows")
        XCTAssertEqual(SelectionEditor.unit(forNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
                                            inPixels: CGRect(x: 0, y: 0, width: 1000, height: 500),
                                            width: 1000, height: 500), SelectionEditor.whole)
    }

    func testRefineAndTranslateURLs() {
        let result = URL(string: "https://www.google.com/search?vsrid=abc&udm=26&q=old")!
        let refined = LensUpload.refined(result, query: "  red shoes + laces ")
        let items = URLComponents(url: refined, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "q" }.map(\.value), ["red shoes + laces"],
                       "typed words replace the previous refinement, with + kept literal")
        XCTAssertEqual(items.first { $0.name == "vsrid" }?.value, "abc", "the visual search is kept")
        XCTAssertTrue(LensUpload.isResult(refined))
        XCTAssertEqual(URLComponents(url: LensUpload.refined(refined, query: " "), resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "q" }, false, "an empty refinement shows the plain results")

        let long = String(repeating: "a", count: 6000)
        let translate = URLComponents(url: SearchURL.translate(long, to: "fr"), resolvingAgainstBaseURL: false)
        XCTAssertEqual(translate?.queryItems?.first { $0.name == "tl" }?.value, "fr")
        XCTAssertEqual(translate?.queryItems?.first { $0.name == "text" }?.value?.count, SearchURL.translateLimit)
        XCTAssertEqual(SearchURL.translateLanguage(for: "en-GB"), "en")
        XCTAssertEqual(SearchURL.translateLanguage(for: "zh-Hant-TW"), "zh-TW")
        XCTAssertEqual(SearchURL.translateLanguage(for: "zh-Hans"), "zh-CN")
        XCTAssertEqual(SearchURL.translateLanguage(for: "he_IL"), "iw")
        XCTAssertEqual(SearchURL.translateLanguage(for: nil), "en")
    }

    func testPullDownToDismiss() {
        var pull = PullToDismiss(threshold: 90)
        XCTAssertFalse(pull.track(phase: .began, momentum: false, deltaY: 30, atTop: true))
        XCTAssertFalse(pull.track(phase: .changed, momentum: false, deltaY: 40, atTop: true))
        XCTAssertTrue(pull.track(phase: .changed, momentum: false, deltaY: 30, atTop: true),
                      "pulling the sheet down past the threshold dismisses")
        XCTAssertFalse(pull.track(phase: .changed, momentum: false, deltaY: 60, atTop: true), "it fires once")

        XCTAssertFalse(pull.track(phase: .began, momentum: false, deltaY: 10, atTop: false))
        XCTAssertFalse(pull.track(phase: .changed, momentum: false, deltaY: 200, atTop: true),
                       "a gesture that starts while the page is scrolled never dismisses")

        XCTAssertFalse(pull.track(phase: .began, momentum: false, deltaY: 0, atTop: true))
        XCTAssertFalse(pull.track(phase: .changed, momentum: false, deltaY: -20, atTop: true))
        XCTAssertFalse(pull.track(phase: .changed, momentum: false, deltaY: 200, atTop: true),
                       "scrolling up first means the user is reading, not dismissing")

        XCTAssertFalse(pull.track(phase: .began, momentum: false, deltaY: 0, atTop: true))
        XCTAssertFalse(pull.track(phase: .changed, momentum: true, deltaY: 500, atTop: true), "momentum is ignored")
        XCTAssertFalse(pull.track(phase: .other, momentum: false, deltaY: 500, atTop: true),
                       "mouse wheels and events without a gesture phase are ignored")
        XCTAssertFalse(pull.track(phase: .changed, momentum: false, deltaY: 500, atTop: true),
                       "nothing counts after the gesture is interrupted")
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    return condition()
}

let tests = LensCoreTests()
let cases: [(String, () throws -> Void)] = [
    ("reverse drag and clipping", tests.testReverseDragAndClipping),
    ("Retina and top-left conversion", tests.testRetinaAndTopLeftConversion),
    ("fractional scale and display origin", tests.testFractionalScaleAndNonzeroOrigin),
    ("crop dimensions", tests.testCropDimensions),
    ("OCR synthetic fixture", tests.testOCRWithGeneratedFixture),
    ("multipart bytes", tests.testMultipartPreservesImageBytes),
    ("redirect validation", tests.testRedirectValidation),
    ("text URL encoding", tests.testTextURLsPreserveSpecialCharacters),
    ("Browser uses macOS default and rejects missing or non-browser apps", tests.testBrowserSelection),
    ("crop selects top image rows", tests.testCropUsesTopImageRows),
    ("tiny selections are rejected", tests.testTinySelectionsAreRejected),
    ("shortcut conflicts with macOS keyboard shortcuts", tests.testShortcutSystemConflicts),
    ("default selection covers the whole canvas", tests.testDefaultSelectionCoversWholeCanvas),
    ("corner and edge handle hit-testing", tests.testHandleHitTesting),
    ("handle resize clamps to canvas and minimum size", tests.testHandleResizeClampsToCanvasAndMinimum),
    ("move keeps size inside canvas", tests.testMoveKeepsSizeAndStaysInCanvas),
    ("selection keeps its pixels when the panel resizes", tests.testUnitSelectionSurvivesCanvasResize),
    ("upload scaling and 429 message", tests.testUploadScalingAndRateLimitMessage),
    ("panel upload request carries only the scaled selection", tests.testPanelUploadRequestCarriesOnlyTheScaledSelection),
    ("committed panel page validation", tests.testCommittedPanelPageValidation),
    ("live search debounces to the last selection", tests.testLiveSearchDebouncesToLastSelection),
    ("live search cancels in-flight uploads", tests.testLiveSearchCancelsInFlightUpload),
    ("live search skips duplicate uploads", tests.testLiveSearchSkipsDuplicateUploads),
    ("live search reports failures and allows retry", tests.testLiveSearchReportsFailuresAndAllowsRetry),
    ("viewport zoom keeps the anchor and covers the screen", tests.testViewportZoomKeepsAnchorAndCoversScreen),
    ("zoomed selection crops the same pixels", tests.testZoomedSelectionCropsTheSamePixels),
    ("stroke bounds and taps", tests.testStrokeBoundsAndTaps),
    ("Vision boxes map to screenshot units", tests.testVisionBoxesMapToScreenshotUnits),
    ("refine and translate URLs", tests.testRefineAndTranslateURLs),
    ("pull down to dismiss the results sheet", tests.testPullDownToDismiss)
]
for (name, test) in cases {
    let before = failures
    do { try test() }
    catch { failures += 1; fputs("FAIL \(name): \(error.localizedDescription)\n", stderr) }
    if failures == before { print("PASS \(name)") }
}
print("\(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)

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

private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 0.04) -> RecognizedLine {
    RecognizedLine.estimated(text: text, box: CGRect(x: x, y: y, width: width, height: height))
}

extension LensCoreTests {
    func testTextUnitsKeepPunctuationAndCJK() {
        func units(_ text: String) -> [String] { TextSplitter.units(of: text).map { String(text[$0.range]) + $0.separator } }
        XCTAssertEqual(units("Hello, world! Call 555-1234."), ["Hello, ", "world! ", "Call ", "555-", "1234."])
        XCTAssertEqual(units("(hello) world"), ["(hello) ", "world"])
        XCTAssertEqual(units("東京タワーへ行く"), ["東京", "タワー", "へ", "行く"])
        XCTAssertEqual(units("你好世界 东京塔").joined(), "你好世界 东京塔", "units rebuild the line exactly")
        XCTAssertEqual(units("   "), [])
        XCTAssertEqual(units("—"), ["—"], "a line of punctuation is still selectable")
    }

    func testBrokenVisionBoxesAreRepaired() {
        let text = "call 555-1234"
        let splits = TextSplitter.units(of: text)
        let line = CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.05)
        let shared = CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.05)
        let boxes = TextSplitter.repairedBoxes([CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.05), shared, shared],
                                               lineBox: line, text: text, ranges: splits.map(\.range), rightToLeft: false)
        XCTAssertEqual(boxes.count, 3)
        XCTAssertTrue(abs(boxes[1].minX - 0.3) < 1e-9 && abs(boxes[2].maxX - 0.5) < 1e-9, "\(boxes)")
        XCTAssertTrue(abs(boxes[1].maxX - boxes[2].minX) < 1e-9, "a shared box is divided between its words")
        let missing = TextSplitter.repairedBoxes([nil, line, CGRect(x: 0, y: 0, width: 0, height: 1)],
                                                 lineBox: line, text: text, ranges: splits.map(\.range), rightToLeft: false)
        XCTAssertTrue(missing.allSatisfy { $0.width < line.width && line.insetBy(dx: -0.001, dy: -0.001).contains($0) },
                      "missing and whole-line boxes are estimated: \(missing)")
        XCTAssertTrue(missing[0].minX < missing[1].minX && missing[1].minX < missing[2].minX)
    }

    func testReadingOrderBlocksAndJoining() {
        // Two columns of wrapped paragraphs, given to the layout out of order.
        let layout = TextLayout(lines: [
            line("right column one", 0.55, 0.80, 0.35), line("left wraps onto", 0.05, 0.80, 0.35),
            line("the next line.", 0.05, 0.75, 0.33), line("right two", 0.55, 0.75, 0.20),
            line("Footer", 0.05, 0.20, 0.10)
        ])
        XCTAssertEqual(layout.blocks.count, 3)
        XCTAssertEqual(layout.allText, "left wraps onto\nthe next line.\n\nright column one\nright two\n\nFooter",
                       "lines keep their breaks and paragraphs get a blank line")
        XCTAssertEqual(layout.text(for: layout.all!, flowing: true),
                       "left wraps onto the next line.\nright column one right two\nFooter")
        XCTAssertEqual(layout.words.first?.text, "left")
        XCTAssertEqual(layout.text(for: TextRange(anchor: 4, focus: 2)), "onto\nthe next",
                       "a range reads the same from either end")
    }

    func testRightToLeftAndCJKJoining() {
        let arabic = TextLayout(lines: [line("مرحبا بالعالم", 0.40, 0.80, 0.50), line("الجميل جدا", 0.60, 0.75, 0.30)])
        XCTAssertTrue(arabic.lines.allSatisfy(\.rightToLeft))
        XCTAssertEqual(arabic.allText, "مرحبا بالعالم\nالجميل جدا", "Arabic lines in reading order")
        XCTAssertEqual(arabic.text(for: arabic.all!, flowing: true), "مرحبا بالعالم الجميل جدا")
        let first = arabic.view(0, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = arabic.view(1, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(first.minX > second.minX, "the first Arabic word is on the right")
        let handles = arabic.handlePoints(for: TextRange(anchor: 0, focus: 1), canvas: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(handles.map { abs($0.start.x - first.maxX) < 1e-6 && abs($0.end.x - second.minX) < 1e-6 } == true,
                      "right-to-left handles sit on the right of the first word and the left of the last")

        let columns = TextLayout(lines: [line("يسار", 0.05, 0.80, 0.20), line("يمين", 0.70, 0.80, 0.20)])
        XCTAssertEqual(columns.allText, "يمين\n\nيسار", "right-to-left blocks side by side are read right first")

        let chinese = TextLayout(lines: [line("你好世界东京塔", 0.1, 0.80, 0.50), line("很高", 0.1, 0.75, 0.48)])
        XCTAssertEqual(chinese.text(for: chinese.all!, flowing: true), "你好世界东京塔很高",
                       "wrapped Chinese lines join without a space")
        XCTAssertEqual(chinese.allText, "你好世界东京塔\n很高")
    }

    func testTextRangesAndHitTesting() {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let layout = TextLayout(lines: [line("alpha beta gamma", 0.1, 0.80, 0.6), line("delta epsilon", 0.1, 0.75, 0.5),
                                        line("zeta", 0.1, 0.30, 0.2)])
        let beta = layout.view(1, in: canvas)
        XCTAssertEqual(layout.index(at: CGPoint(x: beta.midX, y: beta.midY), canvas: canvas), 1)
        XCTAssertNil(layout.index(at: CGPoint(x: 950, y: 500), canvas: canvas))
        XCTAssertEqual(layout.nearestIndex(to: CGPoint(x: 990, y: beta.midY), canvas: canvas), 2,
                       "past the end of a line, the cursor reaches its last word")
        XCTAssertEqual(layout.nearestIndex(to: CGPoint(x: 120, y: 760), canvas: canvas), 3)
        XCTAssertEqual(layout.lineRange(containing: 4), TextRange(anchor: 3, focus: 4))
        XCTAssertEqual(layout.blockRange(containing: 0), TextRange(anchor: 0, focus: 4))
        XCTAssertEqual(layout.blockRange(containing: 5), TextRange(anchor: 5, focus: 5))
        XCTAssertEqual(layout.all, TextRange(anchor: 0, focus: 5))
        XCTAssertEqual(layout.range(inside: CGRect(x: 0, y: 700, width: 1000, height: 150), canvas: canvas),
                       TextRange(anchor: 0, focus: 4), "circling words selects them")
        XCTAssertNil(layout.range(inside: CGRect(x: 0, y: 0, width: 50, height: 50), canvas: canvas))
        let rects = layout.lineRects(for: TextRange(anchor: 2, focus: 3), canvas: canvas)
        XCTAssertEqual(rects.count, 2, "one highlight per line")
        XCTAssertTrue(rects[0].maxY > rects[1].maxY)
        XCTAssertEqual(layout.text(for: TextRange(anchor: 2, focus: 3)), "gamma\ndelta")
        let handles = layout.handlePoints(for: TextRange(anchor: 1, focus: 1), canvas: canvas)
        XCTAssertTrue(handles.map { abs($0.start.x - beta.minX) < 1e-6 && abs($0.end.x - beta.maxX) < 1e-6 } == true)
        XCTAssertTrue(TextLayout.empty.isEmpty && TextLayout.empty.allText.isEmpty && TextLayout.empty.all == nil)
    }

    func testOCRWordsFromMultiLineFixture() throws {
        let image = NSImage(size: NSSize(width: 900, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 300).fill()
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        ("Quick brown fox" as NSString).draw(at: NSPoint(x: 40, y: 150), withAttributes: font)
        ("jumps over dogs" as NSString).draw(at: NSPoint(x: 40, y: 90), withAttributes: font)
        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let layout = TextLayout(lines: try OCR.recognizeWords(cgImage, preferredLanguages: ["en-US"]), aspect: 3)
        XCTAssertEqual(layout.words.map(\.text), ["Quick", "brown", "fox", "jumps", "over", "dogs"])
        XCTAssertTrue(layout.words[0].box.maxX <= layout.words[1].box.minX + 0.01, "words have their own boxes")
        XCTAssertEqual(layout.text(for: TextRange(anchor: 1, focus: 4)), "brown fox\njumps over")
    }

    func testRecognitionLanguagesAndDetection() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "ar-SA"]
        XCTAssertEqual(TextLanguage.recognitionLanguages(preferred: ["en-IL", "he-IL"], supported: supported), ["en-US"],
                       "Vision has no Hebrew, so it is skipped")
        XCTAssertEqual(TextLanguage.recognitionLanguages(preferred: ["zh-Hant-TW", "fr-CA", "en"], supported: supported),
                       ["zh-Hant", "fr-FR", "en-US"])
        XCTAssertEqual(TextLanguage.recognitionLanguages(preferred: ["he"], supported: supported), ["en-US"])
        XCTAssertEqual(TextLanguage.detect("Bonjour tout le monde, comment allez-vous aujourd'hui ?"), "fr")
        XCTAssertEqual(TextLanguage.detect("مرحبا بالعالم الجميل"), "ar")
        XCTAssertEqual(TextLanguage.detect("שלום עולם, מה שלומך היום"), "he")
        XCTAssertNil(TextLanguage.detect("1234 5678"))
    }

    func testDataDetectorClassification() {
        let text = "Write to bob@example.com or call +1 (408) 555-0199. Visit https://example.org/menu. " +
                   "Office: 1 Infinite Loop, Cupertino, CA 95014. Meet on March 5, 2027 at 3pm."
        let items = DataDetection.items(in: text)
        XCTAssertTrue(items.contains(.email("bob@example.com")), "\(items)")
        XCTAssertTrue(items.contains { if case .phone(let value) = $0 { return value.contains("555-0199") } else { return false } })
        XCTAssertTrue(items.contains { if case .address(let value) = $0 { return value.contains("Cupertino") } else { return false } })
        XCTAssertTrue(items.contains(.link(URL(string: "https://example.org/menu")!)))
        XCTAssertTrue(items.contains { if case .date(_, let allDay, _) = $0 { return !allDay } else { return false } },
                      "a date with a time is a timed event")
        let titles = DataDetection.actions(for: items, selectedText: text).map(\.title)
        XCTAssertEqual(titles, ["Send email", "Call", "Text", "Add to contacts", "Maps", "Open website", "Add to calendar"])

        let actions = DataDetection.actions(for: items, selectedText: text)
        XCTAssertTrue(actions.contains { $0.kind == .system(URL(string: "mailto:bob@example.com")!) })
        XCTAssertTrue(actions.contains { $0.kind == .system(URL(string: "tel:+14085550199")!) })
        XCTAssertTrue(actions.contains { $0.kind == .system(URL(string: "sms:+14085550199")!) })
        XCTAssertTrue(actions.contains { if case .system(let url) = $0.kind { return url.absoluteString.hasPrefix("maps://?q=1%20Infinite%20Loop") } else { return false } },
                      "addresses open in Apple Maps")
        XCTAssertTrue(DataDetection.items(in: "Due March 5, 2027").contains { if case .date(_, let allDay, _) = $0 { return allDay } else { return false } },
                      "a date without a time is an all-day event")
        XCTAssertEqual(DataDetection.items(in: "Nothing to see here"), [])
        XCTAssertNil(DataDetection.mailURL("a b@example.com"))
        XCTAssertEqual(DataDetection.phoneURL("03-555 1234 ext", scheme: "tel"), URL(string: "tel:035551234"))
    }

    func testTrackingNumbers() {
        XCTAssertEqual(DataDetection.trackingNumbers(in: "UPS 1Z999AA10123456784 shipped"), ["1Z999AA10123456784"])
        XCTAssertEqual(DataDetection.trackingNumbers(in: "Parcel RR123456785IL"), ["RR123456785IL"])
        XCTAssertEqual(DataDetection.trackingNumbers(in: "Code RR123456784IL"), [], "the S10 check digit must match")
        XCTAssertEqual(DataDetection.trackingNumbers(in: "rr123456785il"), ["RR123456785IL"])
        XCTAssertEqual(DataDetection.trackingNumbers(in: "USPS 9400 1118 9922 3197 4284 90"), [],
                       "spaced groups are not joined into one number")
        XCTAssertEqual(DataDetection.trackingNumbers(in: "9400111899223197428490"), ["9400111899223197428490"])
        XCTAssertEqual(DataDetection.trackingNumbers(in: "FedEx tracking: 123456789012"), ["123456789012"])
        XCTAssertEqual(DataDetection.trackingNumbers(in: "Order 123456789012"), [], "bare digits need a carrier mention")
        let items = DataDetection.items(in: "FedEx tracking: 123456789012")
        XCTAssertEqual(items, [.tracking("123456789012")], "a tracking number is not also offered as a phone number")
        XCTAssertEqual(DataDetection.actions(for: items, selectedText: "").map(\.kind), [.track("123456789012")])
    }

    func testContactAndCalendarFiles() {
        let card = ContactCard(emails: ["bob@example.com"], phones: ["+1 (408) 555-0199"],
                               addresses: ["1 Infinite Loop, Cupertino; CA"])
        let vcf = card.vCard
        XCTAssertTrue(vcf.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        XCTAssertTrue(vcf.hasSuffix("END:VCARD\r\n"))
        XCTAssertTrue(vcf.contains("\r\nFN:bob@example.com\r\n"))
        XCTAssertTrue(vcf.contains("\r\nEMAIL;TYPE=INTERNET:bob@example.com\r\n"))
        XCTAssertTrue(vcf.contains("\r\nTEL;TYPE=VOICE:+1 (408) 555-0199\r\n"))
        XCTAssertTrue(vcf.contains("\r\nADR;TYPE=WORK:;;1 Infinite Loop\\, Cupertino\\; CA;;;;\r\n"), vcf)
        XCTAssertFalse(vcf.replacingOccurrences(of: "\r\n", with: "").contains("\n"))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: DateComponents(year: 2027, month: 3, day: 5, hour: 15))!
        let notes = "Team lunch, room 4; bring a\nlaptop " + String(repeating: "é", count: 60)
        let event = CalendarEvent(title: CalendarEvent.title(from: "\n  Team lunch\nMarch 5", fallback: "x"), start: start,
                                  allDay: false, notes: notes)
        XCTAssertEqual(event.title, "Team lunch")
        let ics = event.iCalendar(uid: "fixed", stamp: start, timeZone: utc.timeZone)
        XCTAssertTrue(ics.contains("\r\nDTSTART:20270305T150000Z\r\nDTEND:20270305T160000Z\r\n"), ics)
        XCTAssertTrue(ics.contains("\r\nUID:fixed@macos-lens\r\n"))
        XCTAssertTrue(ics.contains("\r\nSUMMARY:Team lunch\r\n"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Team lunch\\, room 4\\; bring a\\nlaptop"), ics)
        for physical in ics.components(separatedBy: "\r\n") {
            XCTAssertTrue(physical.utf8.count <= 75, "folded: \(physical)")
        }
        XCTAssertTrue(ics.contains("\r\n é"), "long lines continue with a leading space")
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(unfolded.contains(String(repeating: "é", count: 60)), "folding never splits a character")

        let day = CalendarEvent(title: "Due", start: start, allDay: true, notes: "")
            .iCalendar(uid: "d", stamp: start, timeZone: utc.timeZone)
        XCTAssertTrue(day.contains("\r\nDTSTART;VALUE=DATE:20270305\r\nDTEND;VALUE=DATE:20270306\r\n"), day)
    }

    func testPanelWidthClamp() {
        XCTAssertTrue(abs(PanelSizing.defaultWidth(screenWidth: 1728) - 622.08) < 0.01)
        XCTAssertEqual(PanelSizing.defaultWidth(screenWidth: 1200), 560)
        XCTAssertEqual(PanelSizing.defaultWidth(screenWidth: 2560), 760)
        XCTAssertEqual(PanelSizing.clamp(300, screenWidth: 1728), 440)
        XCTAssertEqual(PanelSizing.clamp(2000, screenWidth: 1728), 1256)
        XCTAssertEqual(PanelSizing.clamp(400, screenWidth: 560), 380, "never wider than 75% of a small screen")
        XCTAssertEqual(PanelSizing.width(stored: 500, screenWidth: 1728), 500, "the width the user dragged to is reused")
        XCTAssertEqual(PanelSizing.width(stored: 5000, screenWidth: 1200), 860)
        XCTAssertTrue(abs(PanelSizing.width(stored: nil, screenWidth: 1728) - 622.08) < 0.01)
        XCTAssertEqual(PanelSizing.width(stored: 0, screenWidth: 1200), 560)
    }

    func testTextFitAndBackgroundSampling() throws {
        XCTAssertEqual(TextFit.size(fitting: CGSize(width: 100, height: 30)) { CGSize(width: $0 * 5, height: $0 * 1.2) }, 20)
        XCTAssertEqual(TextFit.size(fitting: CGSize(width: 1000, height: 12)) { CGSize(width: $0 * 5, height: $0 * 1.2) }, 10)
        XCTAssertEqual(TextFit.size(fitting: CGSize(width: 1, height: 1)) { CGSize(width: $0, height: $0) }, 6,
                       "text never shrinks below the minimum")
        let fitted = TextFit.size(for: "Translated line", in: CGSize(width: 200, height: 40))
        XCTAssertTrue(fitted >= 12 && fitted <= 40, "\(fitted)")

        func sample(background: NSColor) throws -> SampledColor? {
            let image = NSImage(size: NSSize(width: 200, height: 100))
            image.lockFocus()
            background.setFill()
            NSRect(x: 0, y: 0, width: 200, height: 100).fill()
            ("Text" as NSString).draw(at: NSPoint(x: 60, y: 30), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: background == .white ? NSColor.black : NSColor.white])
            image.unlockFocus()
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let scale = CGFloat(cgImage.width) / 200
            return ImageSampling.background(of: cgImage, pixels: CGRect(x: 50 * scale, y: 20 * scale,
                                                                        width: 110 * scale, height: 60 * scale))
        }
        let light = try XCTUnwrap(sample(background: .white))
        XCTAssertTrue(light.isLight && light.luminance > 0.95, "\(light)")
        let dark = try XCTUnwrap(sample(background: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)))
        XCTAssertFalse(dark.isLight)
        XCTAssertTrue(abs(dark.blue - 0.4) < 0.03, "\(dark)")
    }

    func testLensHandoffPage() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 255, 13, 10])
        let html = LensHandoff.html(png: png, language: "iw\"><script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>alert"), "the language is escaped")
        XCTAssertTrue(html.contains("action=\"https://lens.google.com/v3/upload?hl=iw%22%3E%3Cscript%3Ealert(1)%3C/script%3E\""), html)
        let plain = LensHandoff.html(png: png, language: "en")
        XCTAssertTrue(plain.contains("method=\"post\" enctype=\"multipart/form-data\" action=\"https://lens.google.com/v3/upload?hl=en\""))
        func count(_ needle: String) -> Int { plain.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(count("<input"), 1, "the form has only the image field")
        XCTAssertEqual(count("<textarea") + count("<select") + count("<iframe") + count("<link"), 0)
        XCTAssertTrue(plain.contains("type=\"file\" name=\"encoded_image\""))
        XCTAssertEqual(count("https://"), 1, "no URL other than the Lens form action")
        XCTAssertEqual(count("http://"), 0)
        XCTAssertEqual(count(png.base64EncodedString()), 1, "the picture is embedded once")
        XCTAssertEqual(count("<script"), 1, "one inline script, allowed by its hash")
        XCTAssertTrue(plain.contains("<script>\(LensHandoff.script)</script>"))
        XCTAssertTrue(plain.contains("script-src '\(LensHandoff.scriptHash)'"))
        XCTAssertTrue(plain.contains("default-src 'none'"))
        XCTAssertFalse(plain.lowercased().contains("cookie"))
        let source = try XCTUnwrap(plain.range(of: "data:image/png;base64,").map { plain[$0.upperBound...] })
        let encoded = String(source.prefix { $0 != "\"" })
        XCTAssertEqual(Data(base64Encoded: encoded), png)
    }

    func testTextShortcutAvoidsConflicts() {
        XCTAssertEqual(Shortcut.text(named: nil, avoiding: .standard, symbolicHotKeys: nil).id, "command-shift-1")
        let used: [String: Any] = ["900": ["enabled": 1, "value": ["parameters": [49, 18, Shortcut.command | Shortcut.shift]]]]
        XCTAssertEqual(Shortcut.text(named: nil, avoiding: .standard, symbolicHotKeys: used).id, "control-shift-1",
                       "a shortcut macOS uses is skipped")
        XCTAssertEqual(Shortcut.text(named: "control-option-t", avoiding: .standard, symbolicHotKeys: nil).id, "control-option-t")
        let search = Shortcut.textOptions[0]
        XCTAssertEqual(Shortcut.text(named: nil, avoiding: search, symbolicHotKeys: nil).id, "control-shift-1",
                       "never the same keys as the Search shortcut")
    }

    func testHandleToleranceIsAdjustable() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let point = CGPoint(x: 85, y: 85)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SelectionEditor.target(at: point, selection: rect, bounds: bounds), .draw)
        XCTAssertEqual(SelectionEditor.target(at: point, selection: rect, bounds: bounds, tolerance: 18), .resize(.bottomLeft))
    }

    func testSupportLinkComesFromInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let url = try XCTUnwrap(SupportLink.url(infoDictionary: info))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "buymeacoffee.com")
        XCTAssertEqual(url.absoluteString, info[SupportLink.key] as? String)
        XCTAssertNil(SupportLink.url(infoDictionary: [SupportLink.key: "http://buymeacoffee.com/x"]))
        XCTAssertNil(SupportLink.url(infoDictionary: [SupportLink.key: "https://buymeacoffee.com.evil.example/x"]))
        XCTAssertNil(SupportLink.url(infoDictionary: [:]))
    }

    func testTranslationIsDistributedOverLines() {
        XCTAssertEqual(TranslationLayout.distribute("Hola mundo", across: [10]), ["Hola mundo"])
        XCTAssertEqual(TranslationLayout.distribute("uno dos tres cuatro", across: [8, 8]), ["uno dos", "tres cuatro"])
        let three = TranslationLayout.distribute("a b c d e f", across: [2, 2, 2])
        XCTAssertEqual(three, ["a b", "c d", "e f"])
        XCTAssertEqual(three.joined(separator: " "), "a b c d e f")
        let weighted = TranslationLayout.distribute("one two three four five six", across: [30, 6])
        XCTAssertEqual(weighted.count, 2)
        XCTAssertTrue(weighted[0].count > weighted[1].count, "\(weighted)")
        XCTAssertEqual(TranslationLayout.distribute("", across: [3, 4]), ["", ""])
        XCTAssertEqual(TranslationLayout.distribute("x", across: []), [])
        let cjk = TranslationLayout.distribute("这是一个测试句子", across: [4, 4])
        XCTAssertEqual(cjk.joined(), "这是一个测试句子")
        XCTAssertFalse(cjk.contains(""), "\(cjk)")
    }
}

private func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw LensError.message("Unexpected nil at \(file):\(line)") }
    return value
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
    ("pull down to dismiss the results sheet", tests.testPullDownToDismiss),
    ("text units keep punctuation and CJK words", tests.testTextUnitsKeepPunctuationAndCJK),
    ("broken Vision word boxes are repaired", tests.testBrokenVisionBoxesAreRepaired),
    ("reading order, blocks and line joining", tests.testReadingOrderBlocksAndJoining),
    ("right-to-left and CJK joining", tests.testRightToLeftAndCJKJoining),
    ("text ranges and hit-testing", tests.testTextRangesAndHitTesting),
    ("OCR words from a multi-line fixture", tests.testOCRWordsFromMultiLineFixture),
    ("recognition languages and language detection", tests.testRecognitionLanguagesAndDetection),
    ("data detector classification", tests.testDataDetectorClassification),
    ("tracking numbers", tests.testTrackingNumbers),
    ("contact and calendar files", tests.testContactAndCalendarFiles),
    ("panel width clamp", tests.testPanelWidthClamp),
    ("text fit and background sampling", tests.testTextFitAndBackgroundSampling),
    ("Lens browser handoff page", tests.testLensHandoffPage),
    ("Text shortcut avoids conflicts", tests.testTextShortcutAvoidsConflicts),
    ("handle tolerance is adjustable", tests.testHandleToleranceIsAdjustable),
    ("support link comes from Info.plist", tests.testSupportLinkComesFromInfoPlist),
    ("translation is distributed over lines", tests.testTranslationIsDistributedOverLines)
]
for (name, test) in cases {
    let before = failures
    do { try test() }
    catch { failures += 1; fputs("FAIL \(name): \(error.localizedDescription)\n", stderr) }
    if failures == before { print("PASS \(name)") }
}
print("\(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)

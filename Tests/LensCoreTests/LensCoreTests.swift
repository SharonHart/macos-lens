import AppKit
import LensCore

private var failures = 0

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T,
                                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(actual == expected, "\(actual) != \(expected)", file: file, line: line)
}

private func XCTAssertTrue(_ condition: Bool, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        failures += 1
        fputs("FAIL \(file):\(line) \(message)\n", stderr)
    }
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
    ("shortcut conflicts with macOS keyboard shortcuts", tests.testShortcutSystemConflicts)
]
for (name, test) in cases {
    let before = failures
    do { try test() }
    catch { failures += 1; fputs("FAIL \(name): \(error.localizedDescription)\n", stderr) }
    if failures == before { print("PASS \(name)") }
}
print("\(cases.count) cases, \(failures) failures")
exit(failures == 0 ? 0 : 1)

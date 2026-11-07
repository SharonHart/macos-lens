import AppKit
import LensCore

@main
struct AppMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test-native") {
            exit(NativeChecks.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--integration-fixture") {
            Task {
                do {
                    let image = try OCR.fixture()
                    let url = try await LensUpload.upload(image)
                    let dimensions = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "vsdim" })?.value
                    guard dimensions == "\(image.width),\(image.height)" else {
                        throw LensError.message("Lens returned dimensions inconsistent with the synthetic image.")
                    }
                    print("PASS synthetic PNG upload and Lens redirect validation (\(dimensions!)).")
                    print("Browser results rendering is NOT verified by this upload-only test.")
                    print("No user screen content captured; browser cookies were not accessed.")
                    if CommandLine.arguments.contains("--browser-check") {
                        print("UPLOAD_RESULT_URL \(url.absoluteString)")
                    }
                    exit(0)
                } catch {
                    fputs("Integration fixture failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
        } else {
            let app = NSApplication.shared
            let delegate = AppController()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

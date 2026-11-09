import AppKit
import LensCore

@main
struct AppMain {
    @MainActor
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-native") {
            let output = CommandLine.arguments.dropFirst(index + 1).first.map { URL(fileURLWithPath: $0) }
            exit(NativeChecks.run(snapshot: output) ? 0 : 1)
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
        } else if CommandLine.arguments.contains("--overlay-check") {
            Task {
                do {
                    try await OverlayCheck.run()
                    exit(0)
                } catch {
                    fputs("Overlay check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } else if let index = CommandLine.arguments.firstIndex(of: "--panel-check") {
            let output = CommandLine.arguments.dropFirst(index + 1).first.map { URL(fileURLWithPath: $0) }
            Task {
                do {
                    try await PanelCheck.run(snapshot: output)
                    exit(0)
                } catch {
                    fputs("Panel check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } else if let index = CommandLine.arguments.firstIndex(of: "--panel-aspect-check") {
            let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst(index + 1).first ?? ".")
            let label = CommandLine.arguments.dropFirst(index + 2).first ?? "after"
            Task {
                do {
                    if label.hasPrefix("live") {
                        try await PanelAspectCheck.live(folder: folder, label: label)
                        exit(0)
                    }
                    exit(try await PanelAspectCheck.run(folder: folder, label: label, delays: [0, 400]) ? 0 : 1)
                } catch {
                    fputs("Panel aspect check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } else if let index = CommandLine.arguments.firstIndex(of: "--handoff-check") {
            let output = CommandLine.arguments.dropFirst(index + 1).first.map { URL(fileURLWithPath: $0) }
            Task {
                do {
                    try await HandoffCheck.run(snapshot: output)
                    exit(0)
                } catch {
                    fputs("Handoff check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } else if let index = CommandLine.arguments.firstIndex(of: "--apply-update-check") {
            // The native checks run this in a child process: it installs a local mock release over a copy of the
            // app in a temporary folder and exits, so the swap helper has to outlive the process it waits for.
            let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
            guard arguments.count == 3 else {
                fputs("Usage: --apply-update-check <feed> <target app> <current version>\n", stderr)
                exit(2)
            }
            Task {
                let updater = Updater(feed: UpdateFeed.url(environment: [UpdateFeed.environmentKey: arguments[0]]),
                                      currentVersion: arguments[2])
                do {
                    guard case .available(let update) = try await updater.check() else {
                        throw LensError.message("The mock feed offered no update.")
                    }
                    try await updater.install(update, target: URL(fileURLWithPath: arguments[1]),
                                              waitingFor: ProcessInfo.processInfo.processIdentifier, reopen: false)
                    print("HELPER_STARTED \(update.version)")
                    exit(0)
                } catch {
                    fputs("Update check failed: \(error.localizedDescription)\n", stderr)
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

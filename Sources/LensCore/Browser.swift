import AppKit

public enum Browser {
    private static let webURL = URL(string: "https://www.google.com/")!

    public static func defaultApplication() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: webURL)
    }

    public static func opensWebLinks(_ application: URL) -> Bool {
        let target = application.resolvingSymlinksInPath().standardizedFileURL
        return NSWorkspace.shared.urlsForApplications(toOpen: webURL)
            .contains { $0.resolvingSymlinksInPath().standardizedFileURL == target }
    }

    public static func applicationURL(preferredPath: String?) throws -> URL {
        guard let path = preferredPath, !path.isEmpty else {
            guard let url = defaultApplication() else {
                throw LensError.message("macOS has no default web browser. Set one in System Settings or choose a browser in macOS Lens Settings.")
            }
            return url
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path), opensWebLinks(url) else {
            throw LensError.message("The browser chosen in Settings (\(url.lastPathComponent)) is missing or cannot open web links. " +
                                    "Choose another browser or switch back to the default browser.")
        }
        return url
    }

    public static func name(of application: URL) -> String {
        let info = Bundle(url: application)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? application.deletingPathExtension().lastPathComponent
    }

    @MainActor
    public static func open(_ url: URL, in application: URL) async throws {
        try await NSWorkspace.shared.open([url], withApplicationAt: application,
                                          configuration: NSWorkspace.OpenConfiguration())
    }
}

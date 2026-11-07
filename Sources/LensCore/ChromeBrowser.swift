import AppKit

public enum ChromeBrowser {
    public static func applicationURL(preferredPath: String?) throws -> URL {
        let url: URL?
        if let path = preferredPath, !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        }
        guard let url, let bundle = Bundle(url: url),
              ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
               "com.google.Chrome.canary"].contains(bundle.bundleIdentifier ?? ""),
              FileManager.default.fileExists(atPath: url.path) else {
            throw LensError.message("Google Chrome was not found. Choose an installed Chrome application in Settings. " +
                                    "The default browser will not be used instead.")
        }
        return url
    }

    @MainActor
    public static func open(_ url: URL, in application: URL) async throws {
        try await NSWorkspace.shared.open([url], withApplicationAt: application,
                                          configuration: NSWorkspace.OpenConfiguration())
    }
}

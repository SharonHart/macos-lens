import AppKit
import Foundation

public enum SearchURL {
    public static func text(_ text: String) -> URL {
        make(host: "www.google.com", path: "/search", items: [URLQueryItem(name: "q", value: text)])
    }

    public static func translate(_ text: String) -> URL {
        make(host: "translate.google.com", path: "/", items: [
            URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "tl", value: "en"),
            URLQueryItem(name: "text", value: text), URLQueryItem(name: "op", value: "translate")
        ])
    }

    private static func make(host: String, path: String, items: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        return components.url!
    }
}

public enum LensUpload {
    public static let endpoint = URL(string: "https://lens.google.com/v3/upload?hl=en")!

    public static func multipart(png: Data, boundary: String) -> Data {
        var data = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"encoded_image\"; " +
                         "filename=\"selection.png\"\r\nContent-Type: image/png\r\n\r\n").utf8)
        data.append(png)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }

    static let rateLimited = LensError.message(
        "Google is limiting requests from this Mac (HTTP 429). Nothing was retried automatically. " +
        "Wait a few minutes, then press Return to search again.")

    public static func isResult(_ url: URL) -> Bool {
        guard url.scheme == "https", ["www.google.com", "google.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil, url.path == "/search",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.queryItems?.contains(where: { $0.name == "vsrid" && !($0.value ?? "").isEmpty }) == true
    }

    public static func resultURL(status: Int, location: String?) throws -> URL {
        if status == 429 { throw rateLimited }
        guard [302, 303].contains(status), let location, let url = URL(string: location), isResult(url) else {
            throw LensError.message("Google Lens did not return a valid visual-search result (HTTP \(status)). " +
                                    "Its undocumented upload service may have changed. Nothing was opened in your browser.")
        }
        return url
    }

    /// Checks the page the results panel showed after its upload, without bypassing Google's checks.
    public static func committedResult(_ url: URL?, status: Int?) throws -> URL {
        if status == 429 { throw rateLimited }
        guard let url else { throw LensError.message("Google Lens returned no page.") }
        if isResult(url) { return url }
        let host = url.host?.lowercased() ?? ""
        if host.hasPrefix("consent.") {
            throw LensError.message("Google is asking for cookie consent. Choose an option in the panel below, " +
                                    "then press Search now.")
        }
        if host == "accounts.google.com" {
            throw LensError.message("Google is asking you to sign in. Signing in below is optional; macOS Lens " +
                                    "never reads these cookies. Then press Search now.")
        }
        if url.path.hasPrefix("/sorry") {
            throw LensError.message("Google wants to check that you're not a robot. Complete the check in the " +
                                    "panel below (macOS Lens does not bypass it), or wait and press Search now.")
        }
        let code = status.map { "HTTP \($0)" } ?? "no status"
        throw LensError.message("Google Lens did not return a visual-search result (\(code)). The page it " +
                                "returned is shown below; its undocumented upload service may have changed.")
    }

    public static let maximumSide = 2000

    /// Large Retina crops are scaled down before upload; Lens does not need more detail than this.
    public static func scaledForUpload(_ image: CGImage, maximumSide: Int = maximumSide) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maximumSide, maximumSide > 0 else { return image }
        let scale = CGFloat(maximumSide) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// A multipart POST of the scaled PNG; the panel loads it as a browser form upload.
    public static func request(for image: CGImage) throws -> URLRequest {
        let image = scaledForUpload(image)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw LensError.message("Could not encode the selected image.")
        }
        guard png.count <= 20 * 1024 * 1024 else {
            throw LensError.message("The selected image exceeds 20 MB. Choose a smaller region.")
        }
        let boundary = "Lens-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart(png: png, boundary: boundary)
        return request
    }

    /// Uploads without cookies and returns the redirect target, without loading the results page.
    public static func upload(_ image: CGImage) async throws -> URL {
        var request = try request(for: image)
        let body = request.httpBody ?? Data()
        request.httpBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw LensError.message("Google Lens returned a non-HTTP response.")
        }
        return try resultURL(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"))
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

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

    public static func resultURL(status: Int, location: String?) throws -> URL {
        guard [302, 303].contains(status), let location,
              let url = URL(string: location),
              url.scheme == "https", ["www.google.com", "google.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil, url.path == "/search",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "vsrid" && !($0.value ?? "").isEmpty }) == true else {
            throw LensError.message("Google Lens did not return a valid visual-search result (HTTP \(status)). " +
                                    "Its undocumented upload service may have changed. Nothing was opened in Chrome.")
        }
        return url
    }

    public static func upload(_ image: CGImage) async throws -> URL {
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
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.upload(for: request, from: multipart(png: png, boundary: boundary))
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

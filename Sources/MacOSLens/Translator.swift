import AppKit
import LensCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

enum TranslationOutcome {
    case translated([String])
    /// macOS can translate these languages after the user downloads them.
    case downloadable(source: String, target: String)
    case unavailable(String)
}

/// Apple's on-device translation (macOS 15 and later). Nothing is sent anywhere; when the languages aren't available
/// the caller decides whether to offer Google Translate.
@MainActor
enum OnDeviceTranslation {
    static func translate(_ blocks: [String], source: String?, target: String, host: NSView) async -> TranslationOutcome {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            return await AppleTranslation.translate(blocks, source: source, target: target, host: host)
        }
        #endif
        return .unavailable("On-device translation needs macOS 15 or later.")
    }

    /// Shows macOS's own prompt to download the languages. Returns an error message, or nil once they're ready.
    static func download(source: String, target: String, host: NSView) async -> String? {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            return await AppleTranslation.download(source: source, target: target, host: host)
        }
        #endif
        return "On-device translation needs macOS 15 or later."
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
@MainActor
private enum AppleTranslation {
    static func translate(_ blocks: [String], source: String?, target: String, host: NSView) async -> TranslationOutcome {
        let sample = blocks.joined(separator: "\n")
        guard let sourceCode = source ?? TextLanguage.detect(sample) else {
            return .unavailable("macOS couldn't tell which language this text is in.")
        }
        let from = Locale.Language(identifier: sourceCode), to = Locale.Language(identifier: target)
        if from.minimalIdentifier == to.minimalIdentifier { return .translated(blocks) }
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed:
            do {
                return .translated(try await run(blocks, from: from, to: to, host: host))
            } catch {
                return .unavailable("On-device translation failed: \(error.localizedDescription)")
            }
        case .supported:
            return .downloadable(source: sourceCode, target: target)
        case .unsupported:
            return .unavailable("macOS can't translate \(TranslateBar.name(of: sourceCode)) to " +
                                "\(TranslateBar.name(of: target)) on this Mac.")
        @unknown default:
            return .unavailable("On-device translation isn't available for these languages.")
        }
    }

    static func download(source: String, target: String, host: NSView) async -> String? {
        do {
            _ = try await withSession(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target),
                                      host: host) { session in
                try await session.prepareTranslation()
                return []
            }
            return nil
        } catch {
            return "The languages weren't downloaded: \(error.localizedDescription)"
        }
    }

    private static func run(_ blocks: [String], from: Locale.Language, to: Locale.Language,
                            host: NSView) async throws -> [String] {
        let requests = blocks.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let translate: (TranslationSession) async throws -> [String] = { session in
            let responses = try await session.translations(from: requests)
            var result = blocks
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id), result.indices.contains(index) {
                    result[index] = response.targetText
                }
            }
            return result
        }
        if #available(macOS 26.0, *) {
            return try await translate(TranslationSession(installedSource: from, target: to))
        }
        return try await withSession(from: from, to: to, host: host, translate)
    }

    /// Before macOS 26 a session only comes from SwiftUI's `translationTask`, so a tiny invisible view hosts it in
    /// the overlay. Removing the overlay cancels the task.
    private static func withSession(from: Locale.Language, to: Locale.Language, host: NSView,
                                    _ body: @escaping (TranslationSession) async throws -> [String]) async throws
        -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            var hosting: NSView?
            let root = SessionHost(configuration: .init(source: from, target: to)) { session in
                do { continuation.resume(returning: try await body(session)) } catch {
                    continuation.resume(throwing: error)
                }
                await MainActor.run { hosting?.removeFromSuperview() }
            }
            let view = NSHostingView(rootView: root)
            view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            host.addSubview(view)
            hosting = view
        }
    }
}

@available(macOS 15.0, *)
private struct SessionHost: View {
    let configuration: TranslationSession.Configuration
    let action: (TranslationSession) async -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1).translationTask(configuration, action: action)
    }
}
#endif

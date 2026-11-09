import AppKit
import LensCore

/// Checks GitHub for a newer release and installs it in place. A download is installed only after its SHA-256
/// matches the release's SHA256SUMS, and the unzipped app has the expected bundle id and version and a valid code
/// signature. A detached `/bin/sh` helper then swaps the bundle once this copy has quit, and reopens it.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle, checking
        case upToDate(String), available(String)
        case downloading(String), verifying(String), installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?() } }
    }
    /// The newest release found by the last successful check, if it is newer than this copy.
    private(set) var update: AvailableUpdate?
    var onChange: (() -> Void)?
    let feed: URL
    let currentVersion: String
    private var timer: Timer?
    private var lastCheck: Date?

    static let firstCheckDelay: TimeInterval = 10
    static let checkInterval: TimeInterval = 24 * 60 * 60

    init(feed: URL = UpdateFeed.url(environment: ProcessInfo.processInfo.environment),
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0") {
        self.feed = feed
        self.currentVersion = currentVersion
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    var statusText: String {
        switch state {
        case .idle: return "macOS Lens \(currentVersion)"
        case .checking: return "macOS Lens \(currentVersion) · checking for updates…"
        case .upToDate: return "You're up to date (\(currentVersion))."
        case .available(let version): return "macOS Lens \(version) is available; you have \(currentVersion)."
        case .downloading(let version): return "Downloading \(version)…"
        case .verifying(let version): return "Verifying \(version)…"
        case .installing(let version): return "Installing \(version); macOS Lens will reopen…"
        case .failed(let message): return "macOS Lens \(currentVersion) · \(message)"
        }
    }

    /// Checks about 10 seconds after launch, then once a day while `enabled` allows it. Automatic checks never show
    /// alerts; a newer release only appears in the menu, the menu-bar icon and Settings.
    func startAutomaticChecks(enabled: @escaping () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.firstCheckDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.automaticCheck(enabled: enabled)
                // Hourly ticks rather than one 24-hour timer, which would not count time asleep.
                self.timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.automaticCheck(enabled: enabled) }
                }
            }
        }
    }

    private func automaticCheck(enabled: () -> Bool) {
        guard enabled(), !isBusy else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        Task { _ = try? await check() }
    }

    @discardableResult
    func check() async throws -> UpdateFeed.Outcome {
        guard !isBusy else { throw LensError.message("An update check or installation is already running.") }
        state = .checking
        do {
            let outcome = try UpdateFeed.evaluate(try await Self.fetch(feed), current: currentVersion)
            lastCheck = Date()
            switch outcome {
            case .upToDate:
                update = nil
                state = .upToDate(currentVersion)
            case .available(let found):
                update = found
                state = .available(found.version.description)
            }
            return outcome
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Downloads and verifies `update`, then starts the helper that replaces `target` once process `pid` has exited.
    /// The caller quits right after this returns. Nothing in `target` changes if any step fails.
    func install(_ update: AvailableUpdate, target: URL, waitingFor pid: Int32, reopen: Bool) async throws {
        guard !isBusy else { throw LensError.message("An update check or installation is already running.") }
        let version = update.version.description
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("macOS-Lens-update-\(UUID().uuidString)", isDirectory: true)
        do {
            guard target.pathExtension == "app" else {
                throw UpdateError.wrongBundle("This copy of macOS Lens isn't an app bundle, so it can't replace itself.")
            }
            let folder = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: folder.path),
                  FileManager.default.isWritableFile(atPath: target.path) else {
                throw UpdateError.notWritable(folder.path)
            }
            for asset in [update.archive, update.checksums] where !allowed(asset.url) {
                throw UpdateError.feed("The release lists \(asset.name) at an address that isn't HTTPS.")
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            state = .downloading(version)
            let archive = staging.appendingPathComponent(update.archive.name)
            let checksums = staging.appendingPathComponent(UpdateFeed.checksumsName)
            try await Self.download(update.archive.url, to: archive)
            try await Self.download(update.checksums.url, to: checksums)

            state = .verifying(version)
            try Checksums.verify(archive, named: update.archive.name,
                                 against: try String(contentsOf: checksums, encoding: .utf8))
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path],
                               failure: "The downloaded zip couldn't be unpacked")
            let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first else {
                throw UpdateError.wrongBundle("The downloaded zip doesn't contain exactly one app.")
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            try UpdateFeed.validate(info: info, expected: update.version)
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                               failure: "The downloaded app's code signature doesn't verify")
            try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            state = .installing(version)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = UpdateSwap.arguments(waitingFor: pid, new: app, target: target, reopen: reopen,
                                                    staging: staging)
            helper.currentDirectoryURL = URL(fileURLWithPath: "/")
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Release assets must be HTTPS; a test feed given as a file or local URL may point at the same kind of address.
    private func allowed(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == feed.scheme?.lowercased()
    }

    // MARK: Network

    /// Anonymous requests: no token, cookies, cache or user data, only a User-Agent as GitHub's API requires.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    nonisolated static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "macOS-Lens/\(version) (+https://github.com/SharonHart/macos-lens)"
    }

    private nonisolated static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated static func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(for: request(url, accept: "application/vnd.github+json"))
        try check(response)
        return data
    }

    nonisolated static func download(_ url: URL, to destination: URL) async throws {
        if url.isFileURL { return try FileManager.default.copyItem(at: url, to: destination) }
        let (file, response) = try await session.download(for: request(url, accept: "application/octet-stream"))
        defer { try? FileManager.default.removeItem(at: file) }
        try check(response)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private nonisolated static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) else { return }
        switch status {
        case 403, 429:
            throw UpdateError.feed("GitHub refused the request (HTTP \(status)), probably its hourly limit for " +
                                   "anonymous requests. Try again later.")
        case 404: throw UpdateError.feed("GitHub has no published release there (HTTP 404).")
        default: throw UpdateError.feed("GitHub answered HTTP \(status).")
        }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String], failure: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { process in
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus != 0 else { return continuation.resume() }
                let reason = failure ?? "\((tool as NSString).lastPathComponent) failed"
                continuation.resume(throwing: LensError.message(
                    "\(reason) (\(process.terminationStatus))\(detail.isEmpty ? "" : ": \(detail)"). Nothing was installed."))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

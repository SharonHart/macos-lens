import Foundation

public enum LiveSearchState: Equatable, Sendable {
    case idle, waiting, uploading, loaded(URL), failed(String)
}

/// Debounces selection changes into at most one visual search at a time.
/// A new selection cancels queued or in-flight work, and selections that already
/// have results are reused instead of being uploaded again.
@MainActor
public final class LiveSearch<Key: Hashable> {
    public let delay: Duration
    public var onChange: ((LiveSearchState) -> Void)?
    public private(set) var state: LiveSearchState = .idle {
        didSet {
            if case .loaded(let url) = state { lastLoaded = url }
            if state != oldValue { onChange?(state) }
        }
    }
    private var lastLoaded: URL?
    private let sleep: ((Duration) async throws -> Void)?
    private let cacheLimit: Int
    private var task: Task<Void, Never>?
    private var activeKey: Key?
    private var generation = 0
    private var results: [Key: URL] = [:]
    private var order: [Key] = []

    public init(delay: Duration = .milliseconds(700), cacheLimit: Int = 16,
                sleep: ((Duration) async throws -> Void)? = nil) {
        self.delay = delay
        self.cacheLimit = max(1, cacheLimit)
        self.sleep = sleep
    }

    public var isBusy: Bool { activeKey != nil }

    public func schedule(_ key: Key, immediately: Bool = false, search: @escaping () async throws -> URL) {
        if key == activeKey && !(immediately && state == .waiting) { return }
        stop()
        if let url = results[key] {
            state = .loaded(url)
            return
        }
        generation += 1
        let current = generation
        let delay = self.delay
        let sleep = self.sleep
        activeKey = key
        state = immediately ? .uploading : .waiting
        task = Task { [weak self] in
            do {
                if !immediately {
                    if let sleep { try await sleep(delay) } else { try await Task.sleep(for: delay) }
                    guard let self, self.generation == current else { return }
                    self.state = .uploading
                }
                let url = try await search()
                guard let self, self.generation == current else { return }
                self.activeKey = nil
                self.remember(url, for: key)
                self.state = .loaded(url)
            } catch {
                guard let self, self.generation == current else { return }
                self.activeKey = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancels queued and in-flight work, keeping the last results on screen.
    public func cancel() {
        stop()
        if state == .waiting || state == .uploading {
            state = lastLoaded.map { .loaded($0) } ?? .idle
        }
    }

    /// Cancels only a search that is still waiting for the user to pause.
    public func postpone() {
        guard state == .waiting else { return }
        cancel()
    }

    private func stop() {
        generation += 1
        task?.cancel()
        task = nil
        activeKey = nil
    }

    private func remember(_ url: URL, for key: Key) {
        results[key] = url
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > cacheLimit { results[order.removeFirst()] = nil }
    }
}

import CrawlCore
import Foundation

/// Fetches and caches robots.txt per origin, sharing one in-flight fetch between concurrent callers.
///
/// Fetch outcomes follow Google's handling: 2xx is parsed, 4xx (except 429) allows everything,
/// and 5xx, 429 or network failure disallows everything for that origin.
public actor RobotsCache {
    public struct Entry: Sendable {
        public enum Policy: Sendable { case parsed(RobotsTxt), allowAll, disallowAll }
        public let origin: String
        public let policy: Policy
        public let statusCode: Int?
        public let text: String?
        public let failure: String?
    }

    private let fetcher: Fetcher
    private let productToken: String
    private var entries: [String: Task<Entry, Never>] = [:]

    public init(fetcher: Fetcher, productToken: String) {
        self.fetcher = fetcher
        self.productToken = productToken
    }

    public func verdict(for url: URL) async -> RobotsTxt.Verdict {
        guard let origin = Self.origin(of: url) else { return .init(allowed: true, rule: nil) }
        let entry = await entry(for: origin)
        switch entry.policy {
        case .allowAll:
            return .init(allowed: true, rule: nil)
        case .disallowAll:
            return .init(allowed: RobotsTxt.pathAndQuery(of: url) == "/robots.txt", rule: nil)
        case .parsed(let robots):
            return robots.verdict(for: url, productToken: productToken)
        }
    }

    public func entry(for origin: String) async -> Entry {
        if let existing = entries[origin] { return await existing.value }
        let fetcher = fetcher
        let task = Task<Entry, Never> {
            guard let robotsURL = URL(string: origin + "/robots.txt") else {
                return Entry(origin: origin, policy: .allowAll, statusCode: nil, text: nil, failure: "Invalid origin")
            }
            switch await fetcher.fetchFollowingRedirects(robotsURL, body: .always(maxBytes: RobotsTxt.maxBytes)) {
            case .failure(let failure):
                return Entry(origin: origin, policy: .disallowAll, statusCode: nil, text: nil, failure: failure.label)
            case .success(let response):
                switch response.statusCode {
                case 200...299:
                    let text = response.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    return Entry(origin: origin, policy: .parsed(RobotsTxt(text)), statusCode: response.statusCode, text: text, failure: nil)
                case 429, 500...:
                    return Entry(origin: origin, policy: .disallowAll, statusCode: response.statusCode, text: nil, failure: nil)
                default:
                    return Entry(origin: origin, policy: .allowAll, statusCode: response.statusCode, text: nil, failure: nil)
                }
            }
        }
        entries[origin] = task
        return await task.value
    }

    public func fetchedEntries() async -> [Entry] {
        var result: [Entry] = []
        for task in entries.values { result.append(await task.value) }
        return result
    }

    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: true) else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let bracketedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(bracketedHost)\(port)"
    }
}

/// Global rate cap plus per-host pauses after 429/503 responses.
actor RateLimiter {
    private let interval: Duration?
    private var nextSlot = ContinuousClock.now
    private var hostPausedUntil: [String: ContinuousClock.Instant] = [:]

    init(maxPerSecond: Double) {
        interval = maxPerSecond > 0 ? .seconds(1 / maxPerSecond) : nil
    }

    func acquire(host: String) async {
        if let until = hostPausedUntil[host], until > .now {
            try? await Task.sleep(until: until, clock: .continuous)
        }
        guard let interval else { return }
        let now = ContinuousClock.now
        let slot = max(nextSlot, now)
        nextSlot = slot + interval
        if slot > now {
            try? await Task.sleep(until: slot, clock: .continuous)
        }
    }

    func pause(host: String, seconds: Double) {
        let until = ContinuousClock.now + .seconds(min(max(seconds, 1), 120))
        if let existing = hostPausedUntil[host], existing > until { return }
        hostPausedUntil[host] = until
    }
}

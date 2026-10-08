import Foundation

/// Decides which discovered URLs are internal, and which are crawled, recorded-but-skipped, or ignored.
public struct CrawlScope: Sendable {
    public enum Decision: Sendable, Equatable {
        case crawl
        /// Recorded in the crawl (so it shows in reports) but never fetched.
        case skip(String)
        /// Not recorded at all (matches an exclude pattern).
        case ignore
    }

    public let startURL: URL?
    public let startHost: String
    public let startFolder: String
    private let config: CrawlConfig
    private let rootDomain: String
    private let include: [RegexBox]
    private let exclude: [RegexBox]

    public init(config: CrawlConfig) {
        self.config = config
        let start = URLNormalizer.normalize(config.startURL)
            ?? config.listURLs.lazy.compactMap { URLNormalizer.normalize($0) }.first
        startURL = start
        startHost = start?.host() ?? ""
        rootDomain = startHost.hasPrefix("www.") ? String(startHost.dropFirst(4)) : startHost
        if config.mode == .spider, let path = start?.path(percentEncoded: true), let slash = path.lastIndex(of: "/") {
            startFolder = String(path[...slash])
        } else {
            startFolder = "/"
        }
        include = config.includePatterns.compactMap(RegexBox.init)
        exclude = config.excludePatterns.compactMap(RegexBox.init)
    }

    public func isInternal(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        switch config.subdomainPolicy {
        case .exactHost:
            return host == startHost
        case .allSubdomains:
            return host == rootDomain || host.hasSuffix("." + rootDomain)
        }
    }

    /// Classifies a newly discovered URL. `followable` is false for nofollow links.
    public func decide(url: URL, isInternal: Bool, depth: Int, linkType: LinkType, followable: Bool) -> Decision {
        let string = url.absoluteString
        if exclude.contains(where: { $0.matches(string) }) { return .ignore }

        guard isInternal else {
            if !config.checkExternalLinks { return .skip("External link (not checked)") }
            if !followable && !config.followExternalNofollow { return .skip("Nofollow external link") }
            return .crawl
        }

        if config.mode == .spider, !config.crawlOutsideStartFolder, linkType.impliedResourceType == .page,
           !url.path(percentEncoded: true).hasPrefix(startFolder) {
            return .skip("Outside start folder")
        }
        if !include.isEmpty, !include.contains(where: { $0.matches(string) }) {
            return .skip("Doesn't match include pattern")
        }
        switch linkType {
        case .image where !config.crawlImages: return .skip("Image crawling disabled")
        case .stylesheet where !config.crawlCSS: return .skip("CSS crawling disabled")
        case .script where !config.crawlJavaScript: return .skip("JavaScript crawling disabled")
        case .canonical where !config.crawlCanonicals: return .skip("Canonical crawling disabled")
        case .hreflang where !config.crawlHreflang: return .skip("Hreflang crawling disabled")
        default: break
        }
        if !followable && !config.followInternalNofollow { return .skip("Nofollow link") }
        if config.maxDepth > 0 && depth > config.maxDepth { return .skip("Beyond max crawl depth") }
        if config.maxURLLength > 0 && string.utf8.count > config.maxURLLength { return .skip("URL longer than limit") }
        if config.maxPathSegmentRepeats > 0 && hasRepeatedSegments(url.path(percentEncoded: true)) {
            return .skip("Repeating path segments (possible crawler trap)")
        }
        return .crawl
    }

    private func hasRepeatedSegments(_ path: String) -> Bool {
        var counts: [Substring: Int] = [:]
        for segment in path.split(separator: "/") {
            counts[segment, default: 0] += 1
            if counts[segment]! > config.maxPathSegmentRepeats { return true }
        }
        return false
    }
}

/// `NSRegularExpression` is immutable and documented as thread-safe once created.
struct RegexBox: @unchecked Sendable {
    let regex: NSRegularExpression

    init?(_ pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.regex = regex
    }

    func matches(_ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}

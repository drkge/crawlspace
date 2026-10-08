import Foundation

/// A robots.txt parser and matcher following RFC 9309 (the Robots Exclusion Protocol),
/// with the practical leniencies Google's parser applies (missing colons, common typos).
///
/// Matching rules:
/// - Groups whose `User-agent` product token equals the crawler's token are combined; if none
///   match, all `*` groups are combined; if there are none, everything is allowed.
/// - The rule with the longest pattern (in octets) wins; an equal-length Allow beats Disallow.
/// - `*` matches any sequence of characters, a trailing `$` anchors to the end of the path.
/// - `/robots.txt` itself is always allowed.
public struct RobotsTxt: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        public let allow: Bool
        /// Pattern as written, with percent-encoding normalised.
        public let pattern: String
        /// 1-based line number in the source file (for the tester UI).
        public let line: Int
    }

    public struct Group: Sendable, Hashable {
        public var userAgents: [String]
        public var rules: [Rule]
    }

    public struct Verdict: Sendable, Hashable {
        public let allowed: Bool
        /// The rule that decided the outcome, or nil when no rule matched.
        public let rule: Rule?

        public init(allowed: Bool, rule: Rule?) {
            self.allowed = allowed
            self.rule = rule
        }
    }

    /// Google enforces a 500 KiB limit; content past it is ignored.
    public static let maxBytes = 500 * 1024

    public let groups: [Group]
    public let sitemaps: [String]

    public init(_ text: String) {
        var groups: [Group] = []
        var sitemaps: [String] = []
        var current: Group?
        var previousWasUserAgent = false

        var content = Substring(text)
        if content.utf8.count > Self.maxBytes {
            content = Substring(String(decoding: text.utf8.prefix(Self.maxBytes), as: UTF8.self))
        }
        if content.hasPrefix("\u{FEFF}") { content = content.dropFirst() }

        var lineNumber = 0
        for rawLine in content.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lineNumber += 1
            guard let (key, value) = Self.parseLine(rawLine) else { continue }

            switch key {
            case .userAgent:
                if !previousWasUserAgent {
                    if let finished = current { groups.append(finished) }
                    current = Group(userAgents: [], rules: [])
                }
                current?.userAgents.append(Self.productToken(value))
                previousWasUserAgent = true
            case .allow, .disallow:
                previousWasUserAgent = false
                // Rules before any user-agent line don't belong to a group; empty values match nothing.
                guard current != nil, !value.isEmpty else { continue }
                current?.rules.append(Rule(allow: key == .allow, pattern: Self.normalizePattern(value), line: lineNumber))
            case .sitemap:
                if !value.isEmpty { sitemaps.append(value) }
            }
        }
        if let finished = current { groups.append(finished) }
        self.groups = groups
        self.sitemaps = sitemaps
    }

    /// Rules that apply to a crawler with the given product token (e.g. "Crawlspace").
    public func rules(for productToken: String) -> [Rule] {
        let token = productToken.lowercased()
        let specific = groups.filter { $0.userAgents.contains(token) }
        let chosen = specific.isEmpty ? groups.filter { $0.userAgents.contains("*") } : specific
        return chosen.flatMap(\.rules)
    }

    /// Evaluates a URL's path and query (e.g. `/shop?page=2`).
    public func verdict(pathAndQuery: String, productToken: String) -> Verdict {
        let path = pathAndQuery.isEmpty ? "/" : URLNormalizer.normalizePercentEncoding(pathAndQuery)
        if path == "/robots.txt" { return Verdict(allowed: true, rule: nil) }

        let target = Array(path.utf8)
        var best: Rule?
        var bestLength = -1
        for rule in rules(for: productToken) {
            let length = rule.pattern.utf8.count
            guard length >= bestLength, Self.matches(path: target, pattern: Array(rule.pattern.utf8)) else { continue }
            if length > bestLength || (rule.allow && best?.allow == false) {
                best = rule
                bestLength = length
            }
        }
        return Verdict(allowed: best?.allow ?? true, rule: best)
    }

    public func verdict(for url: URL, productToken: String) -> Verdict {
        verdict(pathAndQuery: Self.pathAndQuery(of: url), productToken: productToken)
    }

    public static func pathAndQuery(of url: URL) -> String {
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let query = url.query(percentEncoded: true) { path += "?" + query }
        return path
    }

    // MARK: - Matching

    /// Tracks every position in the path the pattern could have reached so far.
    static func matches(path: [UInt8], pattern: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*"), dollar = UInt8(ascii: "$")
        var positions = [0]
        for (index, char) in pattern.enumerated() {
            if char == dollar && index == pattern.count - 1 {
                return positions.last == path.count
            }
            if char == star {
                positions = Array(positions[0]...path.count)
                continue
            }
            var next: [Int] = []
            for position in positions where position < path.count && path[position] == char {
                next.append(position + 1)
            }
            if next.isEmpty { return false }
            positions = next
        }
        return true
    }

    // MARK: - Parsing helpers

    private enum Key { case userAgent, allow, disallow, sitemap }

    private static func parseLine(_ line: Substring) -> (Key, String)? {
        var text = line
        if let hash = text.firstIndex(of: "#") { text = text[..<hash] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let keyPart: Substring
        let valuePart: Substring
        if let colon = trimmed.firstIndex(of: ":") {
            keyPart = trimmed[..<colon]
            valuePart = trimmed[trimmed.index(after: colon)...]
        } else if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            // Google accepts a missing colon when the key is followed by whitespace.
            keyPart = trimmed[..<space]
            valuePart = trimmed[space...]
        } else {
            return nil
        }

        let value = valuePart.trimmingCharacters(in: .whitespaces)
        switch keyPart.trimmingCharacters(in: .whitespaces).lowercased() {
        case "user-agent", "useragent", "user agent": return (.userAgent, value)
        case "allow": return (.allow, value)
        case "disallow", "dissallow", "dissalow", "disalow", "diasllow", "disallaw": return (.disallow, value)
        case "sitemap", "site-map": return (.sitemap, value)
        default: return nil
        }
    }

    /// `Googlebot/2.1 (+http://…)` → `googlebot`; `*` stays `*`.
    private static func productToken(_ value: String) -> String {
        if value.hasPrefix("*") { return "*" }
        let token = value.prefix { $0.isLetter || $0 == "_" || $0 == "-" }
        return token.lowercased()
    }

    /// Percent-encodes non-ASCII octets and normalises existing escapes so patterns compare
    /// against normalised URL paths.
    private static func normalizePattern(_ pattern: String) -> String {
        var out = ""
        for scalar in pattern.unicodeScalars {
            if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
        }
        return URLNormalizer.normalizePercentEncoding(out)
    }
}
